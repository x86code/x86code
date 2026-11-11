//! The chunked AOT image.
//!
//! One chunk per library / executable: a dyld-cache dylib, a placed runtime Mach-O, or (app tier) a placed app
//! executable of the device. Each chunk is translated by libarm64jit's builder (X86SIM_A64_AOT_JOB, see
//! linux/arm64jit/jitcache.cpp) into its own *slot* of the code slab: translated code is slab-position dependent
//! (rel32 to the prelude, RIP-relative constants), so a slot is fixed once assigned and a rebuilt chunk goes back into
//! it. The image libarm64jit loads (`<uuid>-<build>.aot`, format A64JC06) is assembled here from the chunk files, so
//! the fast-load path (mapped `.map` / `.idx`, lazy registration) is unchanged.
//!
//! Layout under the jitcache dir J:
//!   J/placement.txt               non-cache Mach-O slots (cli/libexec/arm64/mkplacement.py)
//!   J/aot/config.json             runtime, training dirs, scope, budget
//!   J/aot/manifest.json           built chunks (key, slot, sizes) and the assembled image
//!   J/aot/chunks/<id>.<key>.aotc  chunk files (A64CK01)
//!   J/aot/progress.json           live build progress (GUI / CLI)
//!   J/<uuid>-<build>.aot          the image
use crate::discover::{self, Kind, Source};
use crate::dyldcache::Cache;
use crate::features;
use crate::hot::{self, Hot};
use crate::key;
use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::io::{BufRead, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

/// libarm64jit's code cache is at most 2000 MB (RAM 13: host calls go through a stub page next to it, so only reach to
/// that page limits it; was 1344 MB, rel32 reach of libarm64jit and glibc); 384 MB of it stays free for
/// each process's own translations.
pub const SLAB_MB: u64 = 2000;
pub const DEFAULT_BUDGET_MB: u64 = SLAB_MB - 384;
/// Speed 35: slab space a full build leaves for each process's live translations. 2026-11-03: 384 (was 128), the whole
/// per-process live allowance (code cache = min(image + 384, SLAB_MB) MB): with scope "hot" a full build packed the slab to
/// 1216 MB and Maps' route (search, place card, directions) aborted "shared code cache full" 3 of 3 times.
pub const FULL_LIVE_ROOM_MB: u64 = 256;
const HOT_BYTES_PER_BLOCK: f64 = 260.0;
/// x86 bytes per arm64 code byte for full static coverage (default until a measurement sets it in the manifest)
const DEFAULT_STATIC_RATIO: f64 = 3.0;
const SLOT_ALIGN: u64 = 64 << 10;
const POOL_TOTAL: u64 = 2 << 20;
const POOL_REGION: u64 = 32 << 10;

pub fn repo_root() -> PathBuf {
    if let Ok(r) = std::env::var("X86SIM_ROOT") {
        return PathBuf::from(r);
    }
    // a build in place (<root>/tools/launcher/target/release/<exe>, as in the AppImage's data dir): that root
    if let Some(r) = std::env::current_exe().ok().and_then(|e| e.ancestors().nth(5).map(Path::to_path_buf)) {
        if r.join("cli/libexec/arm64/boot-a64.sh").exists() {
            return r;
        }
    }
    // tools/launcher/core -> repo
    let here = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    here.ancestors().nth(3).map(Path::to_path_buf).unwrap_or(here)
}

pub fn scratch() -> PathBuf {
    std::env::var("X86SIM_SCRATCH").map(PathBuf::from).unwrap_or_else(|_| std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default().join("scratch/x86sim"))
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct Config {
    pub runtime_root: PathBuf,
    /// device dir (app tier and feature profile); None: system tier only
    pub device: Option<PathBuf>,
    pub training: Vec<PathBuf>,
    /// "hot": training blocks only (the pre-Speed 18 image); "loaded": libraries any process loads (dependency
    /// closure of the placed executables plus every library with training blocks), hot first, then static code up to
    /// the budget; "all": every library
    pub scope: String,
    pub budget_mb: u64,
    /// leave out the chunks of features turned off in the device's features.json
    pub follow_features: bool,
    /// Darling prefix for builder processes (never the live sim's)
    pub test_prefix: PathBuf,
    /// Speed 31: per-process training .bins newer than this (unix seconds) are left out of the hot set (`.live` files
    /// always count): keeps an image update to what was asked for (e.g. the .live feedback) instead of every profile
    /// recorded since. None: every file.
    pub train_until: Option<u64>,
    /// Speed 32 (opt-in, needs `build --full`): hot/cold layout. With N > 0 (scope "hot"), the globally hottest N% of
    /// the trained blocks of each cache library stay in its chunk and the rest goes to a "<name>#cold" chunk; every hot
    /// head is laid out before every cold tail, so the code that runs most is contiguous across libraries (fewer
    /// pages and cache sets). No successor is followed in scope "hot", so the two halves never share a block.
    pub hot_split_pct: u32,
}

impl Default for Config {
    fn default() -> Self {
        let r = repo_root();
        let s = scratch();
        Config {
            runtime_root: r.join("runtimes/ios-27.2-24B8117-arm64/RuntimeRoot"),
            device: Some(r.join("var/device-a64")),
            training: vec![s.join("s15/train5"), s.join("s17/train6")],
            scope: "hot".into(),
            budget_mb: DEFAULT_BUDGET_MB,
            follow_features: false,
            test_prefix: s.join("a64testprefix"),
            train_until: None,
            hot_split_pct: 0,
        }
    }
}

/// A saved path that no longer exists, moved by the x86Code -> x86Sim rename (AppRun moves ~/.local/share/x86code and
/// ~/.cache/x86code once): the same path with the x86code component renamed, if that one exists.
fn renamed(p: &Path) -> Option<PathBuf> {
    if p.exists() {
        return None;
    }
    let mut hit = false;
    let q: PathBuf = p
        .components()
        .map(|c| match c.as_os_str().to_str() {
            Some("x86code") => {
                hit = true;
                std::ffi::OsStr::new("x86sim")
            }
            _ => c.as_os_str(),
        })
        .collect();
    (hit && q.exists()).then_some(q)
}

impl Config {
    /// config.json keeps absolute paths. After the rename move they pointed into the old directories: the test prefix
    /// under a missing ~/.cache/x86code made every pre-translate worker fail ("only 0 of N chunks finished"), the
    /// training dirs were silently missing. Renamed paths are followed; a test prefix whose directory is gone is the
    /// default one.
    pub fn healed(mut self) -> Config {
        let heal = |p: &mut PathBuf| {
            if let Some(q) = renamed(p) {
                *p = q;
            }
        };
        heal(&mut self.runtime_root);
        if let Some(d) = self.device.as_mut() {
            heal(d);
        }
        self.training.iter_mut().for_each(heal);
        heal(&mut self.test_prefix);
        if !self.test_prefix.parent().is_some_and(|d| d.is_dir()) {
            self.test_prefix = scratch().join("a64testprefix");
        }
        self
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ChunkRec {
    pub name: String,
    pub kind: Option<Kind>,
    pub key: String,
    pub ident: String,
    pub addr: u64,
    pub codegen: u64,
    pub slot_off: u64,
    pub slot_size: u64,
    pub used: u64,
    pub blocks: u64,
    pub hot: u64,
    pub file: Option<String>,
    pub bytes: u64,
    /// "built" | "empty" (nothing persistable) | "truncated" (slot full: the rest stays lazy)
    pub state: String,
    pub secs: f64,
    pub pool: u64,
    pub built_at: u64,
    /// Speed 33: .live blocks in this chunk's ranges when it was built (bounds feedback rebuilds: only new live
    /// blocks since then make it stale, so a chunk whose slot cannot hold them all is not rebuilt on every update)
    #[serde(default)]
    pub live_seen: u64,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Image {
    pub file: String,
    pub size: u64,
    pub code_size: u64,
    pub chunks: usize,
    pub blocks: u64,
    pub built_at: u64,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Manifest {
    pub version: u32,
    pub cache_uuid: String,
    pub static_ratio: Option<f64>,
    pub chunks: BTreeMap<String, ChunkRec>,
    pub image: Option<Image>,
}

pub struct Paths {
    pub jc: PathBuf,
    pub aot: PathBuf,
}

impl Paths {
    pub fn new(jc: &Path) -> Paths {
        Paths { jc: jc.to_path_buf(), aot: jc.join("aot") }
    }
    pub fn default_jc() -> PathBuf {
        std::env::var("X86SIM_A64_JITCACHE_DIR").map(PathBuf::from).unwrap_or_else(|_| scratch().join("jitcache"))
    }
    pub fn config(&self) -> PathBuf {
        self.aot.join("config.json")
    }
    pub fn manifest(&self) -> PathBuf {
        self.aot.join("manifest.json")
    }
    pub fn progress(&self) -> PathBuf {
        self.aot.join("progress.json")
    }
    pub fn chunks(&self) -> PathBuf {
        self.aot.join("chunks")
    }
    pub fn placement(&self) -> PathBuf {
        self.jc.join("placement.txt")
    }
    pub fn load_config(&self) -> Config {
        let c: Config = std::fs::read(self.config()).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        c.healed()
    }
    pub fn save_config(&self, c: &Config) -> Result<()> {
        write_json(&self.config(), c)
    }
    pub fn load_manifest(&self) -> Manifest {
        std::fs::read(self.manifest()).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
    }
}

pub fn write_json<T: Serialize>(p: &Path, v: &T) -> Result<()> {
    if let Some(d) = p.parent() {
        std::fs::create_dir_all(d)?;
    }
    let tmp = p.with_extension(format!("tmp.{}", std::process::id()));
    std::fs::write(&tmp, serde_json::to_vec_pretty(v)?)?;
    std::fs::rename(&tmp, p)?;
    Ok(())
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

/// A chunk of the current plan.
#[derive(Debug, Clone)]
pub struct PlanChunk {
    pub src: Source,
    pub key: String,
    pub hot: Vec<(u64, u32)>,
    pub est_hot: u64,
    pub est_full: u64,
    /// slot size this plan wants for a fresh build
    pub want: u64,
    pub feature: Option<String>,
    pub placed_path: Option<PathBuf>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ChunkStatus {
    pub name: String,
    pub kind: Kind,
    /// "up-to-date" | "stale" | "missing"
    pub state: String,
    pub reasons: Vec<String>,
    pub hot_blocks: usize,
    pub blocks: u64,
    pub bytes: u64,
    pub slot_mb: f64,
    pub feature: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct Status {
    pub cache_uuid: String,
    pub image: String,
    pub image_present: bool,
    /// the image on disk was assembled from exactly the up-to-date chunks
    pub image_current: bool,
    pub scope: String,
    pub budget_mb: u64,
    pub total: usize,
    pub up_to_date: usize,
    pub stale: usize,
    pub missing: usize,
    pub dropped: usize,
    pub training_files: usize,
    pub hot_blocks: usize,
    /// the installed translator's codegen version (and where it was read): keys and the image name follow it
    pub codegen: u64,
    pub codegen_source: key::CodegenSource,
    pub chunks: Vec<ChunkStatus>,
}

pub struct Plan {
    pub cfg: Config,
    pub cache_uuid: String,
    pub build: u64,
    pub image_name: String,
    pub chunks: Vec<PlanChunk>,
    pub hot: Hot,
}

/// The release's training file for this cache dir's iOS build (cli/libexec/arm64/training-<build>.x86t).
pub fn shipped_training(p: &Paths) -> Option<PathBuf> {
    let build = p.jc.file_name()?.to_str()?.strip_prefix("jc-")?;
    Some(repo_root().join(format!("cli/libexec/arm64/training-{build}.x86t")))
}

/// Perf 8: libarm64jit maps the libsystem stub dylibs it generates at fixed addresses at the top of the cache window
/// (linux/arm64jit/a64.h kStubBase, kStubSlot), so their blocks belong in the image (the cache's import stubs link to
/// them). One chunk each, trained blocks only (no file to scan); identity = the stubs' code hash that the first process
/// of the image key recorded in `<image key>.stubs`.
const STUB_BASE: u64 = 0x2_FFF0_0000;
const STUB_SLOT: u64 = 0x4_0000;
fn stub_sources(p: &Paths, uuid: &str) -> Vec<discover::Source> {
    let image = key::image_name(uuid, key::build_id(&p.placement()));
    let hash = std::fs::read_to_string(p.jc.join(image.replace(".aot", ".stubs"))).unwrap_or_default();
    let hash = hash.trim();
    if hash.is_empty() {
        return vec![];
    }
    ["libsystem_kernel", "libsystem_platform", "libsystem_pthread"]
        .iter()
        .enumerate()
        .map(|(i, n)| {
            let addr = STUB_BASE + i as u64 * STUB_SLOT;
            discover::Source {
                name: format!("x86sim-stubs/{n}.dylib"),
                kind: Kind::Placed,
                ident: hash.to_string(),
                addr,
                ranges: vec![(addr, addr + STUB_SLOT)],
                code_bytes: STUB_SLOT,
            }
        })
        .collect()
}

/// Discover the chunk sources, the hot set and the scope (no translation).
pub fn plan(p: &Paths, cfg: &Config) -> Result<Plan> {
    // the placement table is part of the image's key: a phone's first boot copies the committed one into the cache dir
    // (boot-a64.sh). Pre-translating before any boot (the setup page) must use that same table, or it builds an image
    // under a key no phone looks for.
    if !p.placement().exists() {
        let build = p.jc.file_name().and_then(|n| n.to_str()).and_then(|n| n.strip_prefix("jc-")).unwrap_or("");
        let shipped = repo_root().join(format!("cli/libexec/arm64/placement-{build}.txt"));
        if !build.is_empty() && shipped.exists() {
            std::fs::create_dir_all(&p.jc)?;
            std::fs::copy(&shipped, p.placement()).with_context(|| format!("copying {}", shipped.display()))?;
        }
    }
    let cache = Cache::open(&cfg.runtime_root).context("opening the dyld cache")?;
    let uuid = cache.uuid_hex();
    // the cache dir's own per-process JIT caches are training profiles too (the sim records them on every boot)
    let mut training = cfg.training.clone();
    if !training.contains(&p.jc) {
        training.push(p.jc.clone());
    }
    let shipped = shipped_training(p);
    let hot = hot::load(&training, &uuid, &p.aot.join("hot.bin"), cfg.train_until, shipped.as_deref().filter(|s| s.exists()))?;
    // "hot" and "loaded" pick what phones have run; with no training yet (a fresh install) they would pick nothing, so
    // the first build translates everything
    let mut cfg = cfg.clone();
    if hot.blocks.is_empty() && hot.live.is_empty() && cfg.scope != "all" {
        cfg.scope = "all".into();
    }
    let cfg = &cfg;
    let mut sources = discover::cache_sources(&cache);
    let mut placed_paths = HashMap::new();
    let placements = discover::read_placement(&p.placement());
    let mut placed_deps: Vec<String> = Vec::new();
    for pl in &placements {
        let Some(path) = discover::placed_path(pl, &cfg.runtime_root, cfg.device.as_deref()) else { continue };
        if let Some(pf) = discover::placed_source(pl, &path)? {
            if let Ok(data) = std::fs::read(&path) {
                if let Some(img) = crate::macho::FileImage::parse(&data) {
                    placed_deps.extend(img.header.dylibs.iter().cloned());
                }
            }
            placed_paths.insert(pf.source.name.clone(), path);
            sources.push(pf.source);
        }
    }
    sources.extend(stub_sources(p, &uuid));
    let man0 = p.load_manifest();
    let ratio = man0.static_ratio.unwrap_or(DEFAULT_STATIC_RATIO);
    // RAM 2 (JIT): x86 bytes per hot block from the chunks built so far (per library, else the image's mean) instead
    // of a fixed 260 (measured 2026-11-03: 218 on average): the fixed figure plus a 1/4 margin left 330 of 1088 MB of
    // slots empty while 969 libraries were out of the image.
    let built: Vec<&ChunkRec> = man0.chunks.values().filter(|r| r.blocks >= 256 && r.used > 0 && r.state == "built").collect();
    let mean_bpb = if built.is_empty() {
        HOT_BYTES_PER_BLOCK
    } else {
        built.iter().map(|r| r.used).sum::<u64>() as f64 / built.iter().map(|r| r.blocks).sum::<u64>() as f64
    };
    // Perf 22: a truncated chunk's own bytes per block too (its blocks are as dense as the full set's): with the mean
    // instead its estimate fit the slot it overflows, and update rebuilt it there, truncated again
    let bpb: HashMap<String, f64> = man0
        .chunks
        .values()
        .filter(|r| r.blocks >= 256 && r.used > 0 && (r.state == "built" || r.state == "truncated"))
        .map(|r| (r.name.clone(), r.used as f64 / r.blocks as f64))
        .collect();
    // a measurement (x86sim-aot measure: every chunk translated without a size limit) gives real sizes
    let measured: HashMap<String, (u64, u64)> = std::fs::read(p.aot.join("measure.json"))
        .ok()
        .and_then(|b| serde_json::from_slice::<serde_json::Value>(&b).ok())
        .and_then(|v| v["chunks"].as_array().cloned())
        .unwrap_or_default()
        .iter()
        .filter_map(|c| Some((c["name"].as_str()?.to_string(), (c["hot_used"].as_u64()?, c["used"].as_u64()?))))
        .collect();
    let feats = cfg.device.as_deref().map(features::load).unwrap_or_default();
    let mut chunks: Vec<PlanChunk> = sources
        .into_iter()
        .map(|src| {
            let h = hot.in_ranges(&src.ranges);
            let (est_hot, est_full) = match measured.get(&src.name) {
                Some(&(hu, fu)) => (hu, fu.max(hu)),
                None => {
                    let eh = (h.len() as f64 * bpb.get(&src.name).copied().unwrap_or(mean_bpb)) as u64;
                    (eh, ((src.code_bytes as f64 * ratio) as u64).max(eh))
                }
            };
            PlanChunk {
                key: key::chunk_key(&src.name, &src.ident, src.addr),
                feature: features::feature_of_chunk(&src.name),
                placed_path: placed_paths.get(&src.name).cloned(),
                src,
                hot: h,
                est_hot,
                est_full,
                want: 0,
            }
        })
        .collect();
    // scope
    let loaded: HashSet<String> = if cfg.scope == "loaded" { dependency_closure(&cache, &placed_deps) } else { HashSet::new() };
    chunks.retain(|c| match cfg.scope.as_str() {
        // Speed 31: app-tier chunks always (an app on the image never trains: it would translate its own code live)
        "hot" => !c.hot.is_empty() || whole_static(c),
        "all" => true,
        _ => !c.hot.is_empty() || c.src.kind != Kind::Cache || loaded.contains(&c.src.name),
    });
    if cfg.follow_features {
        chunks.retain(|c| c.feature.as_ref().is_none_or(|f| feats.enabled(f)));
    }
    if cfg.hot_split_pct > 0 && cfg.scope == "hot" {
        split_hot_cold(&mut chunks, cfg.hot_split_pct);
    }
    allocate(&mut chunks, cfg);
    if cfg.scope == "hot" && trim_to_slab(&mut chunks) {
        allocate(&mut chunks, cfg);
    }
    if cfg.hot_split_pct > 0 && cfg.scope == "hot" {
        // allocate() orders by hot blocks; keep every hot head before every cold tail (stable: hottest first within)
        chunks.sort_by_key(|c| c.src.name.ends_with(COLD_SUFFIX));
    }
    let build = key::build_id(&p.placement());
    Ok(Plan { image_name: key::image_name(&uuid, build), cache_uuid: uuid, build, chunks, hot, cfg: cfg.clone() })
}

pub const COLD_SUFFIX: &str = "#cold";

/// RAM 13: chunks translated whole from their static entries (function starts etc.) whatever the scope: the app tier
/// (Speed 31) and a system app's own executable (placed "Applications/<X>.app/<X>") that has no training yet (newly
/// placed): otherwise none of its code is in the image until training reaches it. Trained ones stay hot-only (Maps
/// whole: 136+ MB, mostly cold, vs 21 MB hot).
fn whole_static(c: &PlanChunk) -> bool {
    c.src.kind == Kind::App || (c.src.kind == Kind::Placed && c.hot.is_empty() && is_system_app_exe(&c.src.name))
}

fn is_system_app_exe(key: &str) -> bool {
    let f: Vec<&str> = key.split('/').collect();
    f.len() == 3 && f[0] == "Applications" && f[1].strip_suffix(".app") == Some(f[2])
}

/// RAM 2 (JIT): when the hot set does not fit the slab (less FULL_LIVE_ROOM_MB), keep the highest-ranked blocks over
/// all libraries (hot::rank: most programs first) and cut each library's hot list at that line, instead of leaving
/// whole libraries out at build time. The training set may keep growing (every boot adds .live blocks); what grows
/// is its tail of blocks one program ran, and that tail is what stays out. Returns whether anything was cut.
fn trim_to_slab(chunks: &mut Vec<PlanChunk>) -> bool {
    let room = (SLAB_MB - FULL_LIVE_ROOM_MB - 8) << 20;
    let total: u64 = chunks.iter().map(|c| c.want).sum();
    if total <= room {
        return false;
    }
    // fixed part: app chunks (translated whole) and each library slot's alignment / margin over its blocks' bytes
    let mut fixed = 0u64;
    let mut cand: Vec<(u32, usize, f64)> = vec![];
    for (i, c) in chunks.iter().enumerate() {
        if whole_static(c) || c.hot.is_empty() {
            fixed += c.want;
            continue;
        }
        let per = c.est_hot as f64 / c.hot.len() as f64;
        fixed += c.want - c.est_hot - c.est_hot / 8;
        cand.extend(c.hot.iter().map(|h| (h.1, i, per * 9.0 / 8.0)));
    }
    cand.sort_by(|a, b| b.0.cmp(&a.0));
    let mut left = room.saturating_sub(fixed) as f64;
    let mut keep = vec![0usize; chunks.len()];
    let mut cut_rank = 0;
    for &(r, i, b) in &cand {
        if left < b {
            cut_rank = r;
            break;
        }
        left -= b;
        keep[i] += 1;
    }
    let before: usize = chunks.iter().map(|c| c.hot.len()).sum();
    for (i, c) in chunks.iter_mut().enumerate() {
        if whole_static(c) || c.hot.is_empty() {
            continue;
        }
        let n = c.hot.len() as u64;
        // c.hot is hottest first (Hot::in_ranges)
        c.hot.truncate(keep[i]);
        c.est_hot = c.est_hot * keep[i] as u64 / n;
        c.est_full = c.est_full.max(c.est_hot);
    }
    chunks.retain(|c| !c.hot.is_empty() || whole_static(c));
    let after: usize = chunks.iter().map(|c| c.hot.len()).sum();
    eprintln!(
        "x86sim-aot: hot set wants {} MB, slab holds {} MB: kept {after} of {before} hot blocks (cut at {} programs{})",
        total >> 20,
        room >> 20,
        hot::exes(cut_rank),
        if hot::is_live(cut_rank) { ", live-translated" } else { "" }
    );
    true
}

/// Speed 32: see Config::hot_split_pct. The cut is one global profile-count threshold: a block is hot when its count
/// is among the top pct% of all trained blocks (ties stay hot).
fn split_hot_cold(chunks: &mut Vec<PlanChunk>, pct: u32) {
    let mut counts: Vec<u32> = chunks.iter().filter(|c| c.src.kind == Kind::Cache).flat_map(|c| c.hot.iter().map(|h| h.1)).collect();
    if counts.is_empty() {
        return;
    }
    counts.sort_unstable_by(|a, b| b.cmp(a));
    let k = ((counts.len() as u64 * pct.min(100) as u64) / 100).clamp(1, counts.len() as u64) as usize;
    // profile counts are coarse (in how many profiles a block was seen): when the cut falls on the lowest count, ties
    // there go cold instead of keeping everything hot
    let thr = if counts[k - 1] == *counts.last().unwrap() { counts[k - 1].saturating_add(1) } else { counts[k - 1] };
    let mut cold = vec![];
    for c in chunks.iter_mut().filter(|c| c.src.kind == Kind::Cache) {
        let (h, t): (Vec<_>, Vec<_>) = c.hot.iter().partition(|h| h.1 >= thr);
        if t.is_empty() {
            continue;
        }
        let n = c.hot.len().max(1) as u64;
        let mut cc = c.clone();
        cc.src.name = format!("{}{}", c.src.name, COLD_SUFFIX);
        cc.key = key::chunk_key(&cc.src.name, &cc.src.ident, cc.src.addr);
        cc.est_hot = c.est_hot * t.len() as u64 / n;
        cc.est_full = cc.est_hot;
        cc.hot = t;
        c.est_hot = c.est_hot * h.len() as u64 / n;
        c.est_full = c.est_full.max(c.est_hot);
        c.hot = h;
        cold.push(cc);
    }
    chunks.retain(|c| !c.hot.is_empty() || c.src.kind != Kind::Cache);
    chunks.extend(cold);
}

fn dependency_closure(cache: &Cache, roots: &[String]) -> HashSet<String> {
    let by_path: HashMap<&str, &crate::dyldcache::CacheImage> = cache.images.iter().map(|i| (i.path.as_str(), i)).collect();
    let mut seen: HashSet<String> = HashSet::new();
    let mut work: Vec<String> = roots.to_vec();
    while let Some(n) = work.pop() {
        if !seen.insert(n.clone()) {
            continue;
        }
        if let Some(h) = by_path.get(n.as_str()).and_then(|i| cache.header(i)) {
            work.extend(h.dylibs.iter().filter(|d| !seen.contains(*d)).cloned());
        }
    }
    seen
}

/// Slot sizes for fresh builds: every chunk gets its hot part; the static rest is granted by hot density (hot blocks
/// per code byte: the most used libraries get full coverage first) until the budget is used up. Order = priority.
fn allocate(chunks: &mut [PlanChunk], cfg: &Config) {
    let budget = cfg.budget_mb << 20;
    let align = |v: u64| v.div_ceil(SLOT_ALIGN) * SLOT_ALIGN;
    let mut used = 0u64;
    for c in chunks.iter_mut() {
        c.want = if c.hot.is_empty() { 0 } else { align(c.est_hot + c.est_hot / 8 + (64 << 10)) };
        used += c.want;
    }
    // Speed 31: app-tier chunks get their whole static code (function starts etc.), whatever the scope
    for c in chunks.iter_mut().filter(|c| whole_static(c)) {
        // (app code is denser in blocks than the measured cache ratio: Cadence's debug dylib needed ~7x its code)
        // (RAM 13: untrained system apps too: Health's and News' executables truncated at 3x and 8x their code)
        let dense = c.src.code_bytes * if c.src.kind == Kind::App { 12 } else { 16 };
        let full = align((c.est_full * 9 / 8).max(dense) + (64 << 10)).max(c.want);
        used += full - c.want;
        c.want = full;
    }
    if cfg.scope != "hot" {
        let mut order: Vec<usize> = (0..chunks.len()).collect();
        let density = |c: &PlanChunk| c.hot.len() as f64 / c.src.code_bytes.max(1) as f64;
        order.sort_by(|&a, &b| density(&chunks[b]).total_cmp(&density(&chunks[a])).then(chunks[a].src.name.cmp(&chunks[b].src.name)));
        for i in order {
            let c = &mut chunks[i];
            let extra = align((c.est_full.saturating_sub(c.est_hot)) * 9 / 8 + if c.want == 0 { 64 << 10 } else { 0 });
            let grant = extra.min(budget.saturating_sub(used));
            if grant >= SLOT_ALIGN * 2 || (grant == extra && grant > 0) {
                c.want += grant;
                used += grant;
            }
        }
    }
    // hot libraries first (contiguous hot code), then by name
    chunks.sort_by(|a, b| b.hot.len().cmp(&a.hot.len()).then(a.src.name.cmp(&b.src.name)));
}

impl Plan {
    pub fn status(&self, p: &Paths) -> Status {
        let m = p.load_manifest();
        let mut st = Status {
            cache_uuid: self.cache_uuid.clone(),
            image: self.image_name.clone(),
            image_present: p.jc.join(&self.image_name).exists(),
            image_current: false,
            scope: self.cfg.scope.clone(),
            budget_mb: self.cfg.budget_mb,
            total: 0,
            up_to_date: 0,
            stale: 0,
            missing: 0,
            dropped: 0,
            training_files: self.hot.files,
            hot_blocks: self.hot.blocks.len(),
            codegen: key::codegen_info().0,
            codegen_source: key::codegen_info().1,
            chunks: vec![],
        };
        for c in &self.chunks {
            if c.want == 0 {
                st.dropped += 1;
                continue;
            }
            let (state, reasons) = chunk_state(p, &m, c);
            match state.as_str() {
                "up-to-date" => st.up_to_date += 1,
                "stale" => st.stale += 1,
                _ => st.missing += 1,
            }
            let rec = m.chunks.get(&c.src.name);
            st.chunks.push(ChunkStatus {
                name: c.src.name.clone(),
                kind: c.src.kind.clone(),
                state,
                reasons,
                hot_blocks: c.hot.len(),
                blocks: rec.map(|r| r.blocks).unwrap_or(0),
                bytes: rec.map(|r| r.bytes).unwrap_or(0),
                slot_mb: rec.map(|r| r.slot_size).unwrap_or(c.want) as f64 / 1048576.0,
                feature: c.feature.clone(),
            });
        }
        st.total = st.chunks.len();
        st.image_current = st.image_present
            && st.stale == 0
            && st.missing == 0
            && m.image.as_ref().is_some_and(|i| i.file == self.image_name && i.chunks == self.built_records(&m).len());
        st
    }

    fn built_records<'a>(&self, m: &'a Manifest) -> Vec<&'a ChunkRec> {
        self.chunks
            .iter()
            .filter(|c| c.want > 0)
            .filter_map(|c| m.chunks.get(&c.src.name).filter(|r| r.key == c.key && r.file.is_some()))
            .collect()
    }
}

fn chunk_state(p: &Paths, m: &Manifest, c: &PlanChunk) -> (String, Vec<String>) {
    let Some(r) = m.chunks.get(&c.src.name) else { return ("missing".into(), vec![]) };
    if r.key == c.key {
        let present = r.file.as_ref().is_none_or(|f| p.chunks().join(f).exists());
        if !present {
            return ("missing".into(), vec!["chunk file deleted".into()]);
        }
        if c.src.kind == Kind::App && r.state == "truncated" && r.slot_size < c.want {
            return ("stale".into(), vec!["slot too small (app code is translated whole)".into()]);
        }
        // Speed 31: blocks processes on the image had to translate themselves (.live files) that this chunk lacks:
        // rebuild it into its slot (they rank first, see hot::LIVE_RANK). Other training growth does not make a
        // chunk stale (that would grow the image past what each process needs free for its own code).
        let live: Vec<u64> = c.hot.iter().filter(|h| hot::is_live(h.1)).map(|h| h.0).collect();
        if live.len() as u64 >= r.live_seen + 32 {
            if let Some(f) = r.file.as_ref() {
                let have: HashSet<u64> = hot::read_descs(&p.chunks().join(f)).unwrap_or_default().into_iter().collect();
                let miss = live.iter().filter(|d| !have.contains(d)).count();
                if miss >= 32 {
                    return ("stale".into(), vec![format!("{miss} live-translated blocks not in the chunk")]);
                }
            }
        }
        return ("up-to-date".into(), vec![]);
    }
    let mut why = vec![];
    if r.ident != c.src.ident {
        why.push(match c.src.kind {
            Kind::Cache => "runtime update (library changed)".to_string(),
            Kind::Placed => "runtime update (file changed)".to_string(),
            Kind::App => "app changed".to_string(),
        });
    }
    if r.addr != c.src.addr {
        why.push("load address moved (placement / cache layout)".into());
    }
    if r.codegen != key::codegen() {
        why.push(format!("translator update (codegen {:#x} -> {:#x})", r.codegen, key::codegen()));
    }
    if why.is_empty() {
        why.push("key changed".into());
    }
    ("stale".into(), why)
}

// ---------------------------------------------------------------------------------------------------------------
// Building

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Progress {
    /// "idle" | "planning" | "building" | "assembling" | "done" | "cancelled" | "error"
    pub state: String,
    pub message: String,
    pub current: Vec<String>,
    pub chunks_done: usize,
    pub chunks_total: usize,
    pub chunks_skipped: usize,
    pub blocks: u64,
    pub mb_written: f64,
    pub elapsed_s: f64,
    pub eta_s: Option<f64>,
    pub workers: usize,
    pub pid: u32,
    pub updated: u64,
}

pub struct BuildOpts {
    pub workers: usize,
    /// relayout every chunk (fresh slots, fresh constant pool)
    pub full: bool,
    /// measurement: every chunk at slot 0 with the whole slab, written to aot/measure (no image)
    pub measure: bool,
    pub cancel: Arc<AtomicBool>,
    pub only: Option<Vec<String>>,
    /// Speed 32: rebuild the --only chunks even when up to date (a translator change that only affects some
    /// libraries' code, e.g. a MemoryReadCode substitution at an entry point)
    pub force: bool,
}

impl Default for BuildOpts {
    fn default() -> Self {
        let n = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(2);
        BuildOpts { workers: (n / 2).max(1), full: false, measure: false, cancel: Arc::new(AtomicBool::new(false)), only: None, force: false }
    }
}

struct Job {
    chunks: Vec<(String, u64, u64)>, // name, slot_off, slot_size
}

fn write_entries(path: &Path, c: &PlanChunk, statics: &[u64]) -> Result<()> {
    let mut b: Vec<u8> = Vec::with_capacity(8 * (4 + c.src.ranges.len() * 2 + c.hot.len() + statics.len()));
    let mut put = |v: u64| b.extend_from_slice(&v.to_le_bytes());
    put(c.src.ranges.len() as u64);
    for &(lo, hi) in &c.src.ranges {
        put(lo);
        put(hi);
    }
    put(c.hot.len() as u64);
    for &(d, _) in &c.hot {
        put(d);
    }
    put(statics.len() as u64);
    for &s in statics {
        put(s);
    }
    std::fs::write(path, b)?;
    Ok(())
}

/// Build what is stale or missing (all with opts.full), then assemble the image. Progress goes to aot/progress.json
/// (and to `on_progress`). An update whose kept chunks have filled the shared constant pool is redone as a full build
/// (a fresh pool): every update adds constants, so a long-lived image eventually fills it, and the launcher's
/// automatic update then failed for good ("the constant pool is nearly full: run a full rebuild").
pub fn build(p: &Paths, cfg: &Config, opts: &BuildOpts, on_progress: &mut dyn FnMut(&Progress)) -> Result<Progress> {
    match build_once(p, cfg, opts, on_progress) {
        Err(e) if !opts.full && !opts.measure && e.to_string().contains(POOL_FULL) => {
            eprintln!("x86sim-aot: {POOL_FULL}: rebuilding everything");
            let full = BuildOpts {
                workers: opts.workers,
                full: true,
                measure: false,
                cancel: opts.cancel.clone(),
                only: None,
                force: false,
            };
            build_once(p, cfg, &full, on_progress)
        }
        r => r,
    }
}

const POOL_FULL: &str = "the constant pool is nearly full";

fn build_once(p: &Paths, cfg: &Config, opts: &BuildOpts, on_progress: &mut dyn FnMut(&Progress)) -> Result<Progress> {
    let t0 = Instant::now();
    let mut prog = Progress { state: "planning".into(), pid: std::process::id(), workers: opts.workers, ..Default::default() };
    let publish = |prog: &mut Progress, on: &mut dyn FnMut(&Progress)| {
        prog.elapsed_s = t0.elapsed().as_secs_f64();
        prog.updated = now();
        let _ = write_json(&p.progress(), prog);
        on(prog);
    };
    publish(&mut prog, on_progress);
    let plan = plan(p, cfg)?;
    let cache = Cache::open(&cfg.runtime_root)?;
    let mut man = p.load_manifest();
    if man.cache_uuid != plan.cache_uuid || opts.full {
        // a new runtime keeps chunks whose library is unchanged (same key); slots stay as they are
        man.cache_uuid = plan.cache_uuid.clone();
    }
    if opts.full && !opts.measure {
        man.chunks.clear();
    }
    let mut todo: Vec<&PlanChunk> = plan
        .chunks
        .iter()
        .filter(|c| c.want > 0 || opts.measure)
        .filter(|c| opts.only.as_ref().is_none_or(|o| o.iter().any(|n| c.src.name.contains(n.as_str()))))
        .filter(|c| opts.measure || (opts.force && opts.only.is_some()) || chunk_state(p, &man, c).0 != "up-to-date")
        .collect();
    prog.chunks_total = todo.len();
    if todo.is_empty() && !opts.measure && plan.status(p).image_current {
        prog.state = "done".into();
        prog.chunks_skipped = plan.chunks.iter().filter(|c| c.want > 0).count();
        prog.message = format!("image {} is up to date ({} chunks unchanged)", plan.image_name, prog.chunks_skipped);
        publish(&mut prog, on_progress);
        return Ok(prog);
    }
    prog.chunks_skipped = plan.chunks.iter().filter(|c| c.want > 0).count().saturating_sub(todo.len());
    prog.state = "building".into();
    prog.message = format!("{} of {} chunks need rebuilding", todo.len(), todo.len() + prog.chunks_skipped);
    publish(&mut prog, on_progress);

    let slab = SLAB_MB << 20;
    let out_dir = if opts.measure { p.aot.join("measure") } else { p.chunks() };
    std::fs::create_dir_all(&out_dir)?;
    let work = p.aot.join("work");
    let _ = std::fs::remove_dir_all(&work);
    std::fs::create_dir_all(&work)?;

    // slots: keep assigned ones (incremental). Speed 33: a chunk whose key did not change (only training feedback,
    // e.g. .live blocks) is rebuilt in its own slot even when it was truncated (hottest first, so the slot drops the
    // coldest blocks) instead of being re-slotted at the end: feedback rebuilds no longer grow the slab. New chunks
    // go into the first free gap (slots of dropped / re-keyed chunks), then after the last slot; when the slab is
    // full the coldest library chunks (fewest profile hits per slot byte) are evicted: their record stays (same
    // key, no file: up to date, not in the image; their processes translate that library live).
    let reslot = |c: &PlanChunk, r: Option<&ChunkRec>| -> bool {
        match r {
            Some(r) if r.slot_size >= c.want && r.slot_size > 0 => false,
            Some(r) if r.slot_size > 0 && r.state != "truncated" => false,
            // Perf 22: a truncated library chunk rebuilt for feedback (.live blocks it lacks) moves to a slot its
            // hot set fits: in its own slot the rebuild dropped them again (the slot was sized for the first build's
            // training), so its processes translated the same blocks live on every start (Settings: 3.4K blocks a
            // launch + first page in chunks truncated this way; 410K blocks over the image).
            // (truncated: its slot held fewer blocks than the hot set has now, whatever the size estimate says)
            Some(r) if r.slot_size > 0 && r.key == c.key && c.src.kind != Kind::App => {
                (r.state == "truncated" && c.hot.len() as u64 > r.blocks) || c.est_hot + c.est_hot / 8 > r.slot_size
            }
            // Speed 35: the same library at the same address (only the translator / code-shaping flags changed, e.g. a
            // codegen bump) is rebuilt in its own slot too: a codegen bump keeps the image's layout and coverage
            Some(r) if r.slot_size > 0 && r.ident == c.src.ident && r.addr == c.src.addr && c.src.kind != Kind::App => false,
            _ => true,
        }
    };
    let mut slots: HashMap<String, (u64, u64)> = HashMap::new();
    let mut evicted: Vec<String> = vec![];
    let limit = slab - (8 << 20);
    // Speed 35: a full build whose training set outgrew the slab (every chunk is in todo, so nothing could be
    // evicted) leaves out the coldest library chunks (profile hits per slot byte) until the rest fits; they are
    // recorded as evicted (same key, no file), so a later update re-admits them when space frees. It leaves
    // FULL_LIVE_ROOM_MB of the slab free: the per-process code cache is min(image + 384, SLAB_MB) MB, and a slab packed
    // to 1336 MB left 8 MB for live translation (SpringBoard aborted "shared code cache full" in a loop).
    if opts.full && !opts.measure {
        let total: u64 = todo.iter().map(|c| c.want).sum();
        let limit = slab - (FULL_LIVE_ROOM_MB << 20);
        if total > limit {
            let heat_of = |c: &PlanChunk| c.hot.iter().map(|h| h.1 as u64).sum::<u64>() as f64 / c.want.max(1) as f64;
            let mut libs: Vec<usize> = (0..todo.len()).filter(|&i| todo[i].src.kind != Kind::App).collect();
            libs.sort_by(|&a, &b| heat_of(todo[a]).total_cmp(&heat_of(todo[b])));
            let mut over = total - limit;
            let mut drop: HashSet<usize> = HashSet::new();
            for i in libs {
                if over == 0 {
                    break;
                }
                over = over.saturating_sub(todo[i].want);
                drop.insert(i);
            }
            for &i in &drop {
                let c = todo[i];
                man.chunks.insert(
                    c.src.name.clone(),
                    ChunkRec {
                        name: c.src.name.clone(),
                        kind: Some(c.src.kind.clone()),
                        key: c.key.clone(),
                        ident: c.src.ident.clone(),
                        addr: c.src.addr,
                        codegen: key::codegen(),
                        hot: c.hot.len() as u64,
                        state: "evicted".into(),
                        built_at: now(),
                        ..Default::default()
                    },
                );
            }
            eprintln!("x86sim-aot: full build wants {} MB, slab holds {} MB: left out {} coldest library chunks", total >> 20, limit >> 20, drop.len());
            todo = todo.into_iter().enumerate().filter(|(i, _)| !drop.contains(i)).map(|(_, c)| c).collect();
            prog.chunks_total = todo.len();
            write_json(&p.manifest(), &man)?;
        }
    }
    if opts.measure {
        for c in &todo {
            slots.insert(c.src.name.clone(), (0, limit));
        }
    } else {
        let live_names: HashMap<&str, &PlanChunk> = plan.chunks.iter().filter(|c| c.want > 0).map(|c| (c.src.name.as_str(), c)).collect();
        let todo_names: HashSet<&str> = todo.iter().map(|c| c.src.name.as_str()).collect();
        // occupied: slots of chunks in this plan that stay (or are rebuilt in place)
        let mut occ: Vec<(u64, u64, String)> = vec![];
        for (n, r) in &man.chunks {
            if r.slot_size == 0 || !live_names.contains_key(n.as_str()) {
                continue;
            }
            let c = live_names[n.as_str()];
            if todo_names.contains(n.as_str()) {
                if !reslot(c, Some(r)) {
                    slots.insert(n.clone(), (r.slot_off, r.slot_size));
                    occ.push((r.slot_off, r.slot_size, n.clone()));
                }
            } else if r.key == c.key && r.file.is_some() {
                occ.push((r.slot_off, r.slot_size, n.clone()));
            }
        }
        // Slots that overlap (a chunk that left the image kept its record and slot, another chunk was later placed
        // there, then the first came back unchanged: assembly failed "slot overlaps the previous chunk" on every
        // update): keep the first by address; a later one being rebuilt gets a new slot, one that is not is evicted
        // (its record stays with no file: re-admitted into free space by a later update).
        occ.sort_by_key(|o| o.0);
        let mut end = 0u64;
        let mut clash: Vec<String> = vec![];
        occ.retain(|o| {
            if o.0 < end {
                clash.push(o.2.clone());
                return false;
            }
            end = o.0 + o.1;
            true
        });
        for n in &clash {
            if slots.remove(n).is_none() {
                evict_rec(&mut man, n);
            }
        }
        if !clash.is_empty() {
            eprintln!("x86sim-aot: {} chunks had overlapping slots: moved", clash.len());
        }
        let heat = |n: &str, size: u64| -> f64 {
            let h: u64 = live_names.get(n).map(|c| c.hot.iter().map(|h| h.1 as u64).sum()).unwrap_or(0);
            h as f64 / size.max(1) as f64
        };
        let fit = |occ: &mut Vec<(u64, u64, String)>, size: u64| -> Option<u64> {
            occ.sort_by_key(|o| o.0);
            let mut at = 0u64;
            for o in occ.iter() {
                if o.0 >= at + size {
                    return Some(at);
                }
                at = at.max(o.0 + o.1);
            }
            (at + size <= limit).then_some(at)
        };
        let mut need: Vec<&&PlanChunk> = todo.iter().filter(|c| !slots.contains_key(&c.src.name)).collect();
        need.sort_by_key(|c| std::cmp::Reverse(c.want));
        // RAM 2 (JIT): a library chunk that finds no room evicts only chunks colder than itself (rank per slot byte);
        // otherwise it stays out (lazy) until a full build. Before, any new chunk evicted the coldest, and each
        // feedback update traded more shared libraries for one program's: 420 chunks after the last full build, 66
        // a day of updates later (Foundation, libobjc, libdispatch out).
        let mut lazy: Vec<String> = vec![];
        for c in need {
            let size = c.want;
            let mine = heat(&c.src.name, size);
            loop {
                if let Some(at) = fit(&mut occ, size) {
                    slots.insert(c.src.name.clone(), (at, size));
                    occ.push((at, size, c.src.name.clone()));
                    break;
                }
                // evict the coldest library chunk that is not being built now
                let victim = occ
                    .iter()
                    .enumerate()
                    .filter(|(_, o)| !todo_names.contains(o.2.as_str()) && live_names.get(o.2.as_str()).is_some_and(|c| c.src.kind != Kind::App))
                    .min_by(|a, b| heat(&a.1 .2, a.1 .1).total_cmp(&heat(&b.1 .2, b.1 .1)))
                    .map(|(i, _)| i);
                let victim = victim.filter(|&i| c.src.kind == Kind::App || heat(&occ[i].2, occ[i].1) < mine);
                let Some(i) = victim else {
                    if c.src.kind != Kind::App {
                        lazy.push(c.src.name.clone());
                        break;
                    }
                    bail!("the slab is full ({} MB used) and nothing is left to evict: run a full rebuild (x86sim-aot build --full)", limit >> 20);
                };
                let (_, _, n) = occ.remove(i);
                evicted.push(n);
            }
        }
        if !lazy.is_empty() {
            eprintln!("x86sim-aot: slab full, {} library chunks stay lazy (colder than every chunk in the image): {}", lazy.len(), lazy.iter().take(8).cloned().collect::<Vec<_>>().join(", "));
            todo.retain(|c| !lazy.contains(&c.src.name));
            prog.chunks_total = todo.len();
        }
        // Speed 34: chunks evicted by an earlier update come back when space has freed (dropped / pruned /
        // re-keyed chunks left gaps): hottest per byte first, only into free space (never evicting for them), not
        // during an --only (app install) update.
        // Speed 35: not after a full build's trim, and never past FULL_LIVE_ROOM_MB below the slab end (re-admitted
        // chunks filled a trimmed full build back to 1336 MB).
        if opts.only.is_none() && evicted.is_empty() && !opts.full {
            let mut back: Vec<&PlanChunk> = plan
                .chunks
                .iter()
                .filter(|c| c.want > 0 && c.src.kind != Kind::App && !todo_names.contains(c.src.name.as_str()))
                .filter(|c| man.chunks.get(&c.src.name).is_some_and(|r| r.state == "evicted" && r.slot_size == 0 && r.key == c.key))
                .collect();
            back.sort_by(|a, b| heat(&b.src.name, b.want).total_cmp(&heat(&a.src.name, a.want)));
            let mut n_back = 0;
            for c in back {
                if let Some(at) = fit(&mut occ, c.want).filter(|&at| at + c.want <= slab - (FULL_LIVE_ROOM_MB << 20)) {
                    slots.insert(c.src.name.clone(), (at, c.want));
                    occ.push((at, c.want, c.src.name.clone()));
                    todo.push(c);
                    n_back += 1;
                }
            }
            if n_back > 0 {
                prog.chunks_total = todo.len();
                eprintln!("x86sim-aot: {n_back} evicted chunks re-admitted into freed space");
            }
        }
        // a chunk outside this image keeps no claim on its old slot once another chunk sits there (see above)
        let names: HashSet<&str> = occ.iter().map(|o| o.2.as_str()).collect();
        let lost: Vec<String> = man
            .chunks
            .iter()
            .filter(|(n, r)| r.file.is_some() && r.slot_size > 0 && !names.contains(n.as_str()) && !evicted.contains(n))
            .filter(|(_, r)| occ.iter().any(|o| o.0 < r.slot_off + r.slot_size && r.slot_off < o.0 + o.1))
            .map(|(n, _)| n.clone())
            .collect();
        for n in &lost {
            evict_rec(&mut man, n);
        }
    }
    if !evicted.is_empty() {
        let dir = p.aot.join("evicted");
        std::fs::create_dir_all(&dir)?;
        for n in &evicted {
            if let Some(r) = man.chunks.get_mut(n) {
                if let Some(f) = r.file.take() {
                    let _ = std::fs::rename(p.chunks().join(&f), dir.join(&f));
                }
                r.slot_size = 0;
                r.state = "evicted".into();
            }
        }
        eprintln!("x86sim-aot: slab full, evicted {} coldest chunks: {}", evicted.len(), evicted.iter().take(8).cloned().collect::<Vec<_>>().join(", "));
        write_json(&p.manifest(), &man)?;
    }

    // balance the chunks over the workers by slot size
    let mut w = opts.workers.clamp(1, 16).min(todo.len().max(1));
    let mut jobs: Vec<Job> = (0..w).map(|_| Job { chunks: vec![] }).collect();
    let mut load = vec![0u64; w];
    let mut order: Vec<&&PlanChunk> = todo.iter().collect();
    order.sort_by_key(|c| std::cmp::Reverse(slots[&c.src.name].1.min(c.est_full.max(c.est_hot))));
    for c in order {
        let i = (0..w).min_by_key(|&i| load[i]).unwrap();
        let (off, size) = slots[&c.src.name];
        load[i] += c.est_full.min(size);
        jobs[i].chunks.push((c.src.name.clone(), off, size));
    }

    // entries files (static discovery)
    let by_name: HashMap<&str, &PlanChunk> = plan.chunks.iter().map(|c| (c.src.name.as_str(), c)).collect();
    let placements: HashMap<String, discover::Placement> = discover::read_placement(&p.placement()).into_iter().map(|x| (x.key.clone(), x)).collect();
    let mut ent_paths: HashMap<String, PathBuf> = HashMap::new();
    for c in &todo {
        let statics = if cfg.scope == "hot" && !opts.measure && !whole_static(c) {
            vec![]
        } else {
            match c.src.kind {
                Kind::Cache => discover::cache_entries(&cache, &c.src),
                _ => match (placements.get(&c.src.name), &c.placed_path) {
                    (Some(pl), Some(path)) => discover::placed_entries(pl, path),
                    _ => vec![],
                },
            }
        };
        let statics = near_hot_first(statics, &c.hot);
        let ep = work.join(format!("{}.ent", key::name_id(&c.src.name)));
        write_entries(&ep, c, &statics)?;
        ent_paths.insert(c.src.name.clone(), ep);
    }

    // constant pool: the union of every kept chunk's pool; new constants from the largest pool end on, a disjoint
    // region per worker
    // Speed 35: chunks no longer in the plan (an uninstalled / replaced app's container) are not in the image
    let in_plan = |n: &str| plan.chunks.iter().any(|c| c.want > 0 && c.src.name == n);
    let kept: Vec<PathBuf> = if opts.full || opts.measure {
        vec![]
    } else {
        man.chunks.values().filter(|r| in_plan(&r.name) && !todo.iter().any(|c| c.src.name == r.name)).filter_map(|r| r.file.as_ref().map(|f| p.chunks().join(f))).collect()
    };
    // Speed 35: the end of the kept chunks' pools only (a codegen bump rebuilds every chunk in place: none kept)
    let pool_base = if opts.full || opts.measure {
        0
    } else {
        man.chunks.values().filter(|r| r.file.is_some() && in_plan(&r.name) && !todo.iter().any(|c| c.src.name == r.name)).map(|r| r.pool).max().unwrap_or(0)
    }
    .div_ceil(16)
        * 16;
    // each worker gets its own pool region after the kept chunks' pools: when they no longer all fit, fewer workers
    // (an update stays incremental), and only when not even one fits is the pool full (build() then redoes it all)
    let room = (POOL_TOTAL - (64 << 10)).saturating_sub(pool_base) / POOL_REGION;
    if (w as u64) > room {
        if room == 0 {
            bail!("{POOL_FULL}: run a full rebuild (x86sim-aot build --full)");
        }
        eprintln!("x86sim-aot: constant pool room for {room} of {w} workers");
        w = room as usize;
    }

    let repo = repo_root();
    let mut children: Vec<(Child, PathBuf, usize)> = vec![];
    for (i, j) in jobs.iter().enumerate() {
        if j.chunks.is_empty() {
            continue;
        }
        let jp = work.join(format!("w{i}.job"));
        let pp = work.join(format!("w{i}.progress"));
        let mut s = format!("progress {}\n", pp.display());
        for k in &kept {
            s += &format!("pool {}\n", k.display());
        }
        s += &format!("region {}\n", pool_base + POOL_REGION * i as u64);
        for (name, off, size) in &j.chunks {
            let c = by_name[name.as_str()];
            let out = out_dir.join(format!("{}.{}.aotc", key::name_id(name), c.key));
            s += &format!("chunk {} {} {} {} {}\n", name.replace(' ', "%20"), off, size, out.display(), ent_paths[name].display());
        }
        std::fs::write(&jp, s)?;
        let log = std::fs::File::create(work.join(format!("w{i}.log")))?;
        // capped and low priority: nice 19, idle IO class; one builder per core
        let mut cmd = Command::new("nice");
        cmd.args(["-n", "19", "ionice", "-c", "3"])
            .arg(repo.join("tests/arm64/run.sh"))
            .arg(repo.join(builder_exe(&cfg.runtime_root)))
            .current_dir(&repo)
            .env("A64_DPREFIX", &cfg.test_prefix)
            // Speed 23: the builder maps this runtime's cache (run.sh defaults to 27.0: another runtime's image
            // was 27.0 code under the other cache's UUID, and its processes jumped to garbage)
            .env("A64_RUNTIME", &cfg.runtime_root)
            .env("TIMEOUT", "86400")
            .env("X86SIM_A64_AOT_BUILD", "1")
            .env("X86SIM_A64_AOT_DEVICE_DATA", cfg.device.as_ref().map(|d| d.join("data")).unwrap_or_default())
            .env("X86SIM_A64_AOT_JOB", &jp)
            .env("X86SIM_A64_JITCACHE_DIR", &p.jc)
            .env("X86SIM_A64_CODECACHE_MB", SLAB_MB.to_string())
            .stdin(Stdio::null())
            .stdout(log.try_clone()?)
            .stderr(log);
        unsafe {
            use std::os::unix::process::CommandExt;
            cmd.pre_exec(|| {
                libc::setpgid(0, 0);
                Ok(())
            });
        }
        children.push((cmd.spawn().context("starting a builder")?, pp, i));
        std::thread::sleep(std::time::Duration::from_millis(1500)); // the first one starts the container
    }

    // follow the workers' progress files
    let mut offsets: HashMap<usize, u64> = HashMap::new();
    let mut current: HashMap<usize, String> = HashMap::new();
    let mut partial: HashMap<usize, (u64, u64)> = HashMap::new(); // blocks, used of the running chunk
    let mut done_blocks = 0u64;
    let mut done_bytes = 0u64;
    let mut done_est = 0u64;
    let total_est: u64 = todo.iter().map(|c| c.est_full.min(slots[&c.src.name].1)).sum();
    let mut measured: Vec<serde_json::Value> = vec![];
    let mut codegen_checked = false;
    let mut cancelled = false;
    loop {
        let mut alive = 0;
        for (ch, pp, i) in children.iter_mut() {
            if ch.try_wait()?.is_none() {
                alive += 1;
            }
            let Ok(f) = std::fs::File::open(&*pp) else { continue };
            let off = offsets.entry(*i).or_default();
            let mut r = std::io::BufReader::new(f);
            use std::io::Seek;
            r.seek(std::io::SeekFrom::Start(*off))?;
            let mut line = String::new();
            while r.read_line(&mut line)? > 0 {
                if !line.ends_with('\n') {
                    break; // partial line: read it next time
                }
                *off += line.len() as u64;
                let Ok(v) = serde_json::from_str::<serde_json::Value>(line.trim()) else {
                    line.clear();
                    continue;
                };
                let ev = v["event"].as_str().unwrap_or("");
                let name = v["name"].as_str().unwrap_or("").replace("%20", " ");
                match ev {
                    "start" => {
                        if let Some(cg) = v["codegen"].as_u64() {
                            if cg != key::codegen() && !codegen_checked {
                                for (ch, _, _) in children.iter_mut() {
                                    unsafe {
                                        libc::kill(-(ch.id() as i32), libc::SIGTERM);
                                    }
                                    let _ = ch.wait();
                                }
                                bail!("the translator reports codegen {cg:#x}, but {} reads {:#x}: was it rebuilt during the run? Start again", key::translator().display(), key::codegen());
                            }
                            codegen_checked = true;
                        }
                    }
                    "progress" => {
                        current.insert(*i, name.clone());
                        partial.insert(*i, (v["blocks"].as_u64().unwrap_or(0), v["used"].as_u64().unwrap_or(0)));
                    }
                    "chunk" => {
                        partial.remove(i);
                        current.remove(i);
                        let c = by_name[name.as_str()];
                        let blocks = v["blocks"].as_u64().unwrap_or(0);
                        let bytes = v["bytes"].as_u64().unwrap_or(0);
                        let used = v["used"].as_u64().unwrap_or(0);
                        let state = v["state"].as_str().unwrap_or("error");
                        done_blocks += blocks;
                        done_bytes += bytes;
                        done_est += c.est_full.min(slots[&name].1);
                        prog.chunks_done += 1;
                        if opts.measure {
                            measured.push(serde_json::json!({"name": name, "blocks": blocks, "bytes": bytes, "used": used,
                                "hot_used": v["hot_used"], "hot_blocks": v["hot_blocks"],
                                "code": c.src.code_bytes, "hot": c.hot.len(), "secs": v["secs"], "kind": c.src.kind}));
                            let _ = std::fs::remove_file(out_dir.join(format!("{}.{}.aotc", key::name_id(&name), c.key)));
                        } else if state == "done" || state == "empty" {
                            let (off, size) = slots[&name];
                            let file = (state == "done").then(|| format!("{}.{}.aotc", key::name_id(&name), c.key));
                            // drop the replaced chunk file
                            if let Some(old) = man.chunks.get(&name).and_then(|r| r.file.clone()) {
                                if Some(&old) != file.as_ref() {
                                    let _ = std::fs::remove_file(p.chunks().join(old));
                                }
                            }
                            man.chunks.insert(
                                name.clone(),
                                ChunkRec {
                                    name: name.clone(),
                                    kind: Some(c.src.kind.clone()),
                                    key: c.key.clone(),
                                    ident: c.src.ident.clone(),
                                    addr: c.src.addr,
                                    codegen: key::codegen(),
                                    slot_off: off,
                                    slot_size: size,
                                    used,
                                    blocks,
                                    hot: c.hot.len() as u64,
                                    file,
                                    bytes,
                                    state: if v["overflow"].as_bool() == Some(true) { "truncated".into() } else if state == "done" { "built".into() } else { "empty".into() },
                                    secs: v["secs"].as_f64().unwrap_or(0.0),
                                    pool: v["pool"].as_u64().unwrap_or(0),
                                    built_at: now(),
                                    live_seen: c.hot.iter().filter(|h| hot::is_live(h.1)).count() as u64,
                                },
                            );
                            write_json(&p.manifest(), &man)?; // resumable: every finished chunk is recorded
                        } else {
                            prog.message = format!("chunk {name} failed: {}", v["why"].as_str().unwrap_or(state));
                        }
                    }
                    _ => {}
                }
                line.clear();
            }
        }
        let pb: u64 = partial.values().map(|x| x.0).sum();
        let pu: u64 = partial.values().map(|x| x.1).sum();
        prog.blocks = done_blocks + pb;
        prog.mb_written = done_bytes as f64 / 1048576.0;
        let mut cur: Vec<String> = current.values().cloned().collect();
        cur.sort();
        prog.current = cur;
        let frac = (done_est + pu) as f64 / total_est.max(1) as f64;
        let el = t0.elapsed().as_secs_f64();
        prog.eta_s = (frac > 0.02).then(|| el / frac * (1.0 - frac).max(0.0));
        publish(&mut prog, on_progress);
        if opts.cancel.load(Ordering::Relaxed) {
            cancelled = true;
            break;
        }
        if alive == 0 {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(500));
    }
    if cancelled {
        for (ch, _, _) in children.iter_mut() {
            let pid = ch.id() as i32;
            unsafe {
                libc::kill(-pid, libc::SIGTERM);
            }
            let _ = ch.wait();
        }
    }
    shutdown_test_prefix(cfg);
    if cancelled {
        prog.state = "cancelled".into();
        prog.message = format!("cancelled after {} of {} chunks (resume picks up the rest)", prog.chunks_done, prog.chunks_total);
        publish(&mut prog, on_progress);
        return Ok(prog);
    }
    if opts.measure {
        let tot_bytes: u64 = measured.iter().map(|m| m["bytes"].as_u64().unwrap_or(0)).sum();
        let tot_code: u64 = measured.iter().map(|m| m["code"].as_u64().unwrap_or(0)).sum();
        if tot_code > 0 {
            man.static_ratio = Some(tot_bytes as f64 / tot_code as f64);
            write_json(&p.manifest(), &man)?;
        }
        write_json(&p.aot.join("measure.json"), &serde_json::json!({"scope": cfg.scope, "workers": w, "secs": t0.elapsed().as_secs_f64(),
            "bytes": tot_bytes, "blocks": done_blocks, "code": tot_code, "chunks": measured}))?;
        prog.state = "done".into();
        prog.message = format!("measured {} chunks: {:.0} MB, {} blocks", measured.len(), tot_bytes as f64 / 1048576.0, done_blocks);
        publish(&mut prog, on_progress);
        return Ok(prog);
    }
    if prog.chunks_done < prog.chunks_total {
        prog.state = "error".into();
        if prog.message.is_empty() || !prog.message.starts_with("chunk") {
            prog.message = format!("only {} of {} chunks finished: see {}", prog.chunks_done, prog.chunks_total, work.display());
        }
        publish(&mut prog, on_progress);
        return Ok(prog);
    }
    prog.state = "assembling".into();
    publish(&mut prog, on_progress);
    let img = assemble(p, &plan, &mut man)?;
    write_json(&p.manifest(), &man)?;
    let _ = std::fs::remove_dir_all(&work);
    prog.state = "done".into();
    prog.message = format!("image {} ({:.0} MB code, {} chunks, {} blocks)", img.file, img.code_size as f64 / 1048576.0, img.chunks, img.blocks);
    publish(&mut prog, on_progress);
    Ok(prog)
}

pub fn shutdown_test_prefix(cfg: &Config) {
    let darling = repo_root().join("darling-prefix/bin/darling");
    let _ = Command::new(darling).arg("shutdown").env("DPREFIX", &cfg.test_prefix).stdout(Stdio::null()).stderr(Stdio::null()).status();
}

// ---------------------------------------------------------------------------------------------------------------
// Assembly (A64CK01 chunks -> one A64JC06 image). Layout: PersistHeader (160 bytes: magic, uuid, build_id, code_size,
// n_blocks, prelude_size, n_relocs, n_fastmem, old_bases[9], const_pool_used, n_links), [chunk: u64 code_off],
// blocks (24 B), relocs (8 B), fastmem sites (24 B), links (16 B), code, constant pool.

const HDR: usize = 160;
const NB: usize = 9;

struct ChunkFile {
    data: memmap2::Mmap,
    code_off: u64,
    code_size: u64,
    n: [u64; 4], // blocks, relocs, fastmem, links
    prelude: u64,
    bases: [u64; NB],
    pool_used: u64,
    build: u64,
}

impl ChunkFile {
    fn open(path: &Path) -> Result<ChunkFile> {
        let f = std::fs::File::open(path).with_context(|| format!("opening {}", path.display()))?;
        let data = unsafe { memmap2::Mmap::map(&f)? };
        if data.len() < HDR + 8 || &data[..8] != b"A64CK01\0" {
            bail!("{} is not a chunk", path.display());
        }
        let g = |o: usize| u64::from_le_bytes(data[o..o + 8].try_into().unwrap());
        let mut bases = [0u64; NB];
        for (k, b) in bases.iter_mut().enumerate() {
            *b = g(72 + 8 * k);
        }
        let cf = ChunkFile {
            code_off: g(HDR),
            code_size: g(32),
            n: [g(40), g(56), g(64), g(152)],
            prelude: g(48),
            bases,
            pool_used: g(144),
            build: g(24),
            data,
        };
        if cf.code_off > cf.code_size || cf.pool_end() > cf.data.len() {
            bail!("{} is truncated", path.display());
        }
        Ok(cf)
    }
    fn sect(&self, i: usize) -> (usize, usize) {
        let sz = [24usize, 8, 24, 16];
        let mut o = HDR + 8;
        for k in 0..i {
            o += self.n[k] as usize * sz[k];
        }
        (o, self.n[i] as usize * sz[i])
    }
    fn code(&self) -> (usize, usize) {
        let (o, l) = self.sect(3);
        (o + l, (self.code_size - self.code_off) as usize)
    }
    fn pool_end(&self) -> usize {
        let (o, l) = self.code();
        o + l + self.pool_used as usize
    }
}

pub fn assemble(p: &Paths, plan: &Plan, man: &mut Manifest) -> Result<Image> {
    let mut recs: Vec<ChunkRec> = plan.built_records(man).into_iter().cloned().collect();
    recs.sort_by_key(|r| r.slot_off);
    let files: Vec<ChunkFile> = recs.iter().map(|r| ChunkFile::open(&p.chunks().join(r.file.as_ref().unwrap()))).collect::<Result<_>>()?;
    if files.is_empty() {
        bail!("nothing to pre-translate yet");
    }
    let f0 = &files[0];
    let cb = 0usize;
    let mut code_size = 0u64;
    let mut n = [0u64; 4];
    let mut pool: Vec<u8> = vec![];
    let mut last_end = 0u64;
    for (f, r) in files.iter().zip(&recs) {
        if f.prelude != f0.prelude {
            bail!("{}: prelude size differs", r.name);
        }
        for k in 1..=4 {
            if f.bases[k].wrapping_sub(f.bases[cb]) != f0.bases[k].wrapping_sub(f0.bases[cb]) {
                bail!("{}: prelude layout differs", r.name);
            }
        }
        for k in 0..NB {
            if (f.bases[k] == 0) != (f0.bases[k] == 0) {
                bail!("{}: reloc kinds differ", r.name);
            }
        }
        if f.build & 0x3_ffff != f0.build & 0x3_ffff {
            bail!("{}: codegen / flags differ", r.name);
        }
        if f.code_off < last_end {
            bail!("{}: slot overlaps the previous chunk", r.name);
        }
        last_end = f.code_size;
        code_size = code_size.max(f.code_size);
        for k in 0..4 {
            n[k] += f.n[k];
        }
        let (co, cl) = f.code();
        let fp = &f.data[co + cl..co + cl + f.pool_used as usize];
        if fp.len() > pool.len() {
            pool.resize(fp.len(), 0);
        }
        for i in (0..fp.len() / 16 * 16).step_by(16) {
            let s = &fp[i..i + 16];
            if s.iter().all(|&b| b == 0) {
                continue;
            }
            let d = &mut pool[i..i + 16];
            if d.iter().any(|&b| b != 0) && d != s {
                bail!("{}: constant pool conflict at {i:#x}", r.name);
            }
            d.copy_from_slice(s);
        }
    }
    let out = p.jc.join(&plan.image_name);
    let tmp = out.with_extension(format!("aot.tmp.{}", std::process::id()));
    let mut w = std::io::BufWriter::with_capacity(8 << 20, std::fs::File::create(&tmp)?);
    let mut hdr = f0.data[..HDR].to_vec();
    hdr[..8].copy_from_slice(b"A64JC06\0");
    let uuid = (0..16).map(|i| u8::from_str_radix(&plan.cache_uuid[2 * i..2 * i + 2], 16).unwrap_or(0)).collect::<Vec<_>>();
    hdr[8..24].copy_from_slice(&uuid);
    hdr[24..32].copy_from_slice(&plan.build.to_le_bytes());
    let put = |h: &mut Vec<u8>, o: usize, v: u64| h[o..o + 8].copy_from_slice(&v.to_le_bytes());
    put(&mut hdr, 32, code_size);
    put(&mut hdr, 40, n[0]);
    put(&mut hdr, 56, n[1]);
    put(&mut hdr, 64, n[2]);
    put(&mut hdr, 152, n[3]);
    put(&mut hdr, 144, pool.len() as u64);
    w.write_all(&hdr)?;
    for s in 0..4 {
        for f in &files {
            let (o, l) = f.sect(s);
            w.write_all(&f.data[o..o + l])?;
        }
    }
    // code: each chunk's bytes at its slot, absolute embeds rebased to the first chunk's bases, holes zero
    let mut at = 0u64;
    for f in &files {
        // slot headroom: a hole (sparse file; reads back as zeros) instead of written zeros
        if at < f.code_off {
            use std::io::Seek;
            w.seek(std::io::SeekFrom::Current((f.code_off - at) as i64))?;
            at = f.code_off;
        }
        let (co, cl) = f.code();
        let mut code = f.data[co..co + cl].to_vec();
        let (ro, rl) = f.sect(1);
        for e in f.data[ro..ro + rl].chunks_exact(8) {
            let off = u32::from_le_bytes(e[..4].try_into().unwrap()) as u64;
            let kind = e[4] as usize;
            if kind >= NB || off < f.code_off || off + 8 > f.code_size {
                continue;
            }
            let i = (off - f.code_off) as usize;
            let v = u64::from_le_bytes(code[i..i + 8].try_into().unwrap()).wrapping_add(f0.bases[kind].wrapping_sub(f.bases[kind]));
            code[i..i + 8].copy_from_slice(&v.to_le_bytes());
        }
        w.write_all(&code)?;
        at += cl as u64;
    }
    w.write_all(&pool)?;
    w.flush()?;
    drop(w);
    std::fs::rename(&tmp, &out)?;
    let size = std::fs::metadata(&out)?.len();
    // the old image's derived files (.map/.idx/.prelude of any layout) and images of other keys
    for e in std::fs::read_dir(&p.jc)?.flatten() {
        let n = e.file_name().to_string_lossy().into_owned();
        let ours = n.starts_with(&plan.image_name);
        let derived = ours && n != plan.image_name;
        let other_image = n.ends_with(".aot") && !ours && n.len() > 40 && n.as_bytes()[32] == b'-';
        let other_derived = !ours && n.len() > 40 && n.as_bytes().get(32) == Some(&b'-') && n.contains(".aot.");
        if derived || other_image || other_derived {
            let _ = std::fs::remove_file(e.path());
        }
    }
    let img = Image { file: plan.image_name.clone(), size, code_size, chunks: files.len(), blocks: n[0], built_at: now() };
    man.image = Some(img.clone());
    Ok(img)
}

/// Marks a chunk record evicted: same key, no slot, no file (up to date, not in the image; a later update re-admits it
/// into free space). Its chunk file stays until the chunk is rebuilt.
fn evict_rec(man: &mut Manifest, name: &str) {
    if let Some(r) = man.chunks.get_mut(name) {
        r.slot_off = 0;
        r.slot_size = 0;
        r.file = None;
        r.state = "evicted".into();
    }
}


/// Static entries closest to code that ran first. Calls through objc_msgSend / Swift witness tables / vtables are not
/// followed from the hot blocks (indirect), but the linker keeps a class's (a source file's) functions together, so
/// the functions next to ones a program ran are the likeliest to run next. Before, a slot filled after the hot blocks
/// took static entries in address order: whatever came first in the library. Settings with its own profile held out
/// of this machine's: 72.1% -> 73.2% of the blocks it ran in the image (no change once the shipped training has it).
fn near_hot_first(mut statics: Vec<u64>, hot: &[(u64, u32)]) -> Vec<u64> {
    if hot.is_empty() || statics.is_empty() {
        return statics;
    }
    let mut pcs: Vec<u64> = hot.iter().map(|h| h.0 & ((1 << 56) - 1)).collect();
    pcs.sort_unstable();
    let dist = |e: u64| {
        let i = pcs.partition_point(|&p| p < e);
        let a = if i < pcs.len() { pcs[i] - e } else { u64::MAX };
        let b = if i > 0 { e - pcs[i - 1] } else { u64::MAX };
        a.min(b)
    };
    statics.sort_by_cached_key(|&e| (dist(e), e));
    statics
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn config_follows_the_rename_move() {
        let t = std::env::temp_dir().join(format!("x86sim-aot-heal-{}", std::process::id()));
        let new_cache = t.join("cache/x86sim");
        std::fs::create_dir_all(new_cache.join("s15/train5")).unwrap();
        std::fs::create_dir_all(t.join("share/x86sim/var/device-a64-p")).unwrap();
        let c = Config {
            device: Some(t.join("share/x86code/var/device-a64-p")),
            training: vec![t.join("cache/x86code/s15/train5"), t.join("cache/x86code/gone")],
            test_prefix: t.join("cache/x86code/a64testprefix"),
            ..Config::default()
        }
        .healed();
        assert_eq!(c.device, Some(t.join("share/x86sim/var/device-a64-p")));
        assert_eq!(c.training, vec![new_cache.join("s15/train5"), t.join("cache/x86code/gone")]);
        // the prefix itself need not exist (Darling makes it), its directory must
        assert_eq!(c.test_prefix, scratch().join("a64testprefix"));
        let _ = std::fs::remove_dir_all(&t);
    }
}

/// Platforms 1: the builder process (tests/arm64/icstress*.sim) must be built for the runtime's platform: dyld_sim
/// refuses a main executable of another one ("built for platform iOS-simulator"), so a tvOS / watchOS image built
/// nothing. The platform is the runtime's SystemVersion.plist ProductName, as mksimdevice.py reads it.
fn builder_exe(runtime_root: &Path) -> &'static str {
    let sv = std::fs::read(runtime_root.join("System/Library/CoreServices/SystemVersion.plist")).unwrap_or_default();
    let sv = String::from_utf8_lossy(&sv);
    if sv.contains("Apple TVOS") || sv.contains("tvOS") {
        "tests/arm64/icstress-tvos.sim"
    } else if sv.contains("Watch OS") || sv.contains("watchOS") {
        "tests/arm64/icstress-watchos.sim"
    } else {
        "tests/arm64/icstress.sim"
    }
}
