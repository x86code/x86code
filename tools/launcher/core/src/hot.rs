//! The training hot set: block descriptors recorded by training boots (`<uuid>-<build>.<exe>.bin` files, any build),
//! with the number of profiles each block appears in (hotter = more processes ran it). Cached in `<aot>/hot.bin`,
//! rebuilt when the set of training files changes. Speed 31: also `<uuid>-<build>.<exe>.live` (descriptors only: what a
//! process on the image translated itself, libarm64jit X86SIM_A64_AOT_LIVE=1).
use anyhow::Result;
use std::collections::HashMap;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

pub struct Hot {
    /// (descriptor, rank) sorted by descriptor; rank: see `rank` (higher = more worth a place in the shared image)
    pub blocks: Vec<(u64, u32)>,
    pub files: usize,
    /// Speed 31: descriptors from `.live` files (sorted): blocks processes on the image had to translate themselves.
    pub live: Vec<u64>,
    /// Speed 33: distinct sampled PCs (.cnt files) that weighed into the counts
    pub sampled: usize,
}

/// RAM 2 (JIT): a block's rank packs, from high to low bits: the number of distinct executables that ran it (bits
/// 24-31: a .bin and a .live of the same program count once, so repeated boots no longer inflate it), a flag for
/// blocks some process on the image translated itself (bit 23, .live) and sampled execution hits (bits 0-22,
/// X86SIM_A64_COUNT). Sharing decides first: a block in the image is one clean page-cache copy for every process
/// that runs it, a block left out is translated (time) and kept (private code + JIT metadata) by each of them.
/// Before, the flag was worth more than any sharing (LIVE_RANK = 1 << 20 added per block) and a full build that did
/// not fit left out whole libraries by summed rank per byte: the 2026-11-03 image had Foundation, libobjc,
/// libdispatch, CFNetwork and libsqlite3 out (every daemon translated them live) and UIKitCore, WebCore, VectorKit in.
pub const LIVE_RANK: u32 = 1 << 23;
const SAMPLE_MAX: u32 = LIVE_RANK - 1;
pub const fn rank(exes: u32, live: bool, samples: u32) -> u32 {
    (if exes > 255 { 255 } else { exes }) << 24 | if live { LIVE_RANK } else { 0 } | if samples > SAMPLE_MAX { SAMPLE_MAX } else { samples }
}
pub const fn is_live(r: u32) -> bool {
    r & LIVE_RANK != 0
}
pub const fn exes(r: u32) -> u32 {
    r >> 24
}

const PC_MASK: u64 = (1 << 56) - 1;

fn training_files(dirs: &[PathBuf], uuid: &str, until: Option<u64>) -> Vec<PathBuf> {
    use std::os::unix::fs::MetadataExt;
    let mut v = Vec::new();
    for d in dirs {
        let Ok(rd) = std::fs::read_dir(d) else { continue };
        for e in rd.flatten() {
            let n = e.file_name().to_string_lossy().into_owned();
            let new = until.is_some_and(|u| e.metadata().map(|m| m.mtime() as u64 > u).unwrap_or(false));
            if n.starts_with(uuid) && n.ends_with(".bin") && !new {
                v.push(e.path());
            }
        }
    }
    v.sort();
    v
}

pub fn read_descs(p: &Path) -> Option<Vec<u64>> {
    let mut f = std::fs::File::open(p).ok()?;
    let mut h = [0u8; 160];
    f.read_exact(&mut h).ok()?;
    let start = match &h[..8] {
        b"A64JC06\0" => 160,
        b"A64JC05\0" => 152,
        b"A64CK01\0" => 168, // chunk: u64 code_off after the header
        _ => return None,
    };
    let n = u64::from_le_bytes(h[40..48].try_into().unwrap()) as usize;
    if n > 1 << 26 {
        return None;
    }
    f.seek(SeekFrom::Start(start)).ok()?;
    let mut raw = vec![0u8; n * 24];
    f.read_exact(&mut raw).ok()?;
    Some((0..n).map(|i| u64::from_le_bytes(raw[i * 24..i * 24 + 8].try_into().unwrap())).collect())
}

fn signature(files: &[PathBuf]) -> u64 {
    use std::os::unix::fs::MetadataExt;
    let mut h = crate::key::Fnv64::new();
    for f in files {
        h.str(&f.to_string_lossy());
        if let Ok(m) = std::fs::metadata(f) {
            h.u64(m.len());
            h.u64(m.mtime() as u64);
        }
    }
    h.finish()
}

fn live_descs(dirs: &[PathBuf], uuid: &str) -> Vec<u64> {
    let mut v = Vec::new();
    for d in dirs {
        let Ok(rd) = std::fs::read_dir(d) else { continue };
        for e in rd.flatten() {
            let n = e.file_name().to_string_lossy().into_owned();
            if n.starts_with(uuid) && n.ends_with(".live") {
                v.extend(read_descs(&e.path()).unwrap_or_default());
            }
        }
    }
    v.sort_unstable();
    v.dedup();
    v
}

/// Speed 33: sampled execution counts (libarm64jit X86SIM_A64_COUNT=1: `<uuid>-<build>.<exe>.cnt`, "A64CNT1\0",
/// u64 n, n x {u64 pc, u32 hits, u32 0}), summed by guest PC over every file.
fn sample_counts(dirs: &[PathBuf], uuid: &str) -> HashMap<u64, u64> {
    let mut m: HashMap<u64, u64> = HashMap::new();
    for d in dirs {
        let Ok(rd) = std::fs::read_dir(d) else { continue };
        for e in rd.flatten() {
            let n = e.file_name().to_string_lossy().into_owned();
            if !(n.starts_with(uuid) && n.ends_with(".cnt")) {
                continue;
            }
            let Ok(b) = std::fs::read(e.path()) else { continue };
            if b.len() < 16 || &b[..8] != b"A64CNT1\0" {
                continue;
            }
            for r in b[16..].chunks_exact(16) {
                let pc = u64::from_le_bytes(r[..8].try_into().unwrap());
                *m.entry(pc).or_default() += u32::from_le_bytes(r[8..12].try_into().unwrap()) as u64;
            }
        }
    }
    m
}

/// Weight of one sampled hit (in rank's sample bits).
pub const SAMPLE_W: u32 = 1 << 10;

/// `<uuid>-<build>.<exe>.<ext>` -> exe (the key part has no dot)
fn exe_of(name: &str) -> Option<&str> {
    let i = name.find('.')?;
    let j = name.rfind('.')?;
    (j > i).then(|| &name[i + 1..j])
}

/// Descriptor -> number of executables that ran it, over .bin / .live files (each executable counted once).
fn merge_counts(files: &[PathBuf]) -> HashMap<u64, u32> {
    let mut per_exe: HashMap<String, Vec<u64>> = HashMap::new();
    for f in files {
        let n = f.file_name().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
        let exe = exe_of(&n).unwrap_or("?").to_string();
        if let Some(v) = read_descs(f) {
            per_exe.entry(exe).or_default().extend(v);
        }
    }
    let mut m: HashMap<u64, u32> = HashMap::new();
    for (_, mut v) in per_exe {
        v.sort_unstable();
        v.dedup();
        for d in v {
            *m.entry(d).or_default() += 1;
        }
    }
    m
}

// Shipped training (cli/libexec/arm64/training-<build>.x86t): the blocks programs ran on the machines that made the
// release, so a new install's first image already holds what apps run instead of learning it one launch at a time
// (Settings, with its own profile held out of this machine's 68: 72% of what it ran was in the image; with the
// shipped profiles, 97%). "X86TRN01", the dyld cache UUID (32 hex chars), u64 count, then per block: varint descriptor
// delta, varint number of programs that ran it. Addresses only: no code or content.
const TRN_MAGIC: &[u8; 8] = b"X86TRN01";

fn varint(out: &mut Vec<u8>, mut x: u64) {
    loop {
        let b = (x & 0x7f) as u8;
        x >>= 7;
        if x == 0 {
            out.push(b);
            return;
        }
        out.push(b | 0x80);
    }
}

/// Writes the shipped training file from the profiles (.bin, .live) in `dirs`; returns the number of blocks.
/// Only .live files: each is what one program ran in its last sessions. Old .bin files include whole-slab dumps (every
/// image block a process had registered), which made the set 6.7M blocks: past the budget, whole libraries went lazy
/// (Settings 94% covered against 97% from .live alone).
/// `merge`: earlier training files folded in (a block keeps the higher of the two program counts), so blocks
/// programs ran on other machines or in older sessions stay in.
pub fn write_shipped(dirs: &[PathBuf], uuid: &str, out: &Path, merge: &[PathBuf]) -> Result<usize> {
    // each program's newest .live in each dir: a cache dir keeps one per translator build it ran under, and the old
    // ones describe sessions long gone (all 22 builds of the dev cache: 6.3M blocks, against 3.6M for the current
    // ones). Several dirs (machines, installs) each add their newest: merge_counts unions a program's blocks, counted once.
    let mtime = |f: &PathBuf| std::fs::metadata(f).and_then(|m| m.modified()).ok();
    let mut files: Vec<PathBuf> = vec![];
    for d in dirs {
        let Ok(rd) = std::fs::read_dir(d) else { continue };
        // Platforms 1: a dir with no .live at all (a runtime that has no AOT image yet, so no process ran on one: tvOS /
        // watchOS's first training) gives each program's newest training .bin instead (a dir that has .live files
        // keeps leaving its .bins out: they describe sessions under older translator builds)
        let (mut newest, mut newest_bin): (HashMap<String, PathBuf>, HashMap<String, PathBuf>) = Default::default();
        for e in rd.flatten() {
            let n = e.file_name().to_string_lossy().into_owned();
            let m = if n.ends_with(".live") { &mut newest } else if n.ends_with(".bin") { &mut newest_bin } else { continue };
            if n.starts_with(uuid) {
                let (f, exe) = (e.path(), exe_of(&n).unwrap_or("?").to_string());
                if m.get(&exe).is_none_or(|g| mtime(&f) > mtime(g)) {
                    m.insert(exe, f);
                }
            }
        }
        if newest.is_empty() {
            newest = newest_bin;
        }
        files.extend(newest.into_values());
    }
    let mut m = merge_counts(&files);
    for f in merge {
        let old = read_shipped(f, uuid);
        anyhow::ensure!(!old.is_empty(), "{}: no training for dyld cache {uuid}", f.display());
        for (d, c) in old {
            let e = m.entry(d).or_default();
            *e = (*e).max(c);
        }
    }
    let mut v: Vec<(u64, u32)> = m.into_iter().collect();
    v.sort_unstable();
    let mut b = Vec::with_capacity(48 + v.len() * 3);
    b.extend_from_slice(TRN_MAGIC);
    b.extend_from_slice(uuid.as_bytes());
    b.extend_from_slice(&(v.len() as u64).to_le_bytes());
    let mut prev = 0u64;
    for &(d, c) in &v {
        varint(&mut b, d - prev);
        varint(&mut b, c as u64);
        prev = d;
    }
    std::fs::write(out, b)?;
    Ok(v.len())
}

/// The shipped training file's blocks (empty when missing or for another dyld cache).
pub fn read_shipped(p: &Path, uuid: &str) -> Vec<(u64, u32)> {
    let Ok(b) = std::fs::read(p) else { return vec![] };
    if b.len() < 48 || &b[..8] != TRN_MAGIC || &b[8..40] != uuid.as_bytes() {
        return vec![];
    }
    let n = u64::from_le_bytes(b[40..48].try_into().unwrap()) as usize;
    let mut v = Vec::with_capacity(n);
    let (mut i, mut prev) = (48usize, 0u64);
    let rd = |i: &mut usize| -> Option<u64> {
        let mut x = 0u64;
        for sh in (0..64).step_by(7) {
            let c = *b.get(*i)?;
            *i += 1;
            x |= ((c & 0x7f) as u64) << sh;
            if c & 0x80 == 0 {
                return Some(x);
            }
        }
        None
    };
    while v.len() < n {
        let (Some(dd), Some(c)) = (rd(&mut i), rd(&mut i)) else { break };
        prev += dd;
        v.push((prev, c as u32));
    }
    v
}

/// `shipped`: the release's training file (see read_shipped), counted like the local profiles.
pub fn load(dirs: &[PathBuf], uuid: &str, cache_file: &Path, until: Option<u64>, shipped: Option<&Path>) -> Result<Hot> {
    let bins = training_files(dirs, uuid, until);
    let mut lives: Vec<PathBuf> = Vec::new();
    for d in dirs {
        let Ok(rd) = std::fs::read_dir(d) else { continue };
        for e in rd.flatten() {
            let n = e.file_name().to_string_lossy().into_owned();
            if n.starts_with(uuid) && n.ends_with(".live") {
                lives.push(e.path());
            }
        }
    }
    lives.sort();
    let mut all = bins.clone();
    all.extend(lives.iter().cloned());
    // "R2J1": the rank format (a hot.bin of the old per-file counts is never reused)
    let mut sig_files = all.clone();
    sig_files.extend(shipped.map(Path::to_path_buf));
    let sig = signature(&sig_files) ^ 0x5232_4a31_0000_0001;
    let cached = std::fs::read(cache_file).ok().and_then(|b| {
        if b.len() < 16 || u64::from_le_bytes(b[..8].try_into().unwrap()) != sig {
            return None;
        }
        let n = u64::from_le_bytes(b[8..16].try_into().unwrap()) as usize;
        (b.len() == 16 + n * 12).then(|| {
            (0..n)
                .map(|i| {
                    let o = 16 + i * 12;
                    (u64::from_le_bytes(b[o..o + 8].try_into().unwrap()), u32::from_le_bytes(b[o + 8..o + 12].try_into().unwrap()))
                })
                .collect::<Vec<(u64, u32)>>()
        })
    });
    let live = live_descs(dirs, uuid);
    let cnt = sample_counts(dirs, uuid);
    let blocks = match cached {
        Some(b) => b,
        None => {
            // descriptors per executable (its .bin files and its .live), then one count per executable
            let mut m = merge_counts(&all);
            if let Some(sp) = shipped {
                for (d, c) in read_shipped(sp, uuid) {
                    *m.entry(d).or_default() += c;
                }
            }
            let mut blocks: Vec<(u64, u32)> = m.into_iter().collect();
            blocks.sort_unstable();
            let mut out = Vec::with_capacity(16 + blocks.len() * 12);
            out.extend_from_slice(&sig.to_le_bytes());
            out.extend_from_slice(&(blocks.len() as u64).to_le_bytes());
            for (d, c) in &blocks {
                out.extend_from_slice(&d.to_le_bytes());
                out.extend_from_slice(&c.to_le_bytes());
            }
            if let Some(p) = cache_file.parent() {
                std::fs::create_dir_all(p)?;
            }
            std::fs::write(cache_file, out)?;
            blocks
        }
    };
    let blocks = blocks
        .into_iter()
        .map(|(d, n)| {
            let s = cnt.get(&(d & PC_MASK)).map(|&h| h.min((SAMPLE_MAX / SAMPLE_W) as u64) as u32 * SAMPLE_W).unwrap_or(0);
            (d, rank(n, live.binary_search(&d).is_ok(), s))
        })
        .collect();
    Ok(Hot { blocks, files: bins.len(), sampled: cnt.len(), live })
}

impl Hot {
    /// Hot descriptors whose PC is in the ranges, hottest first (then by PC).
    pub fn in_ranges(&self, ranges: &[(u64, u64)]) -> Vec<(u64, u32)> {
        // descriptors sort by PC first only when the FPCR bits are zero (the usual case); scan with the PC mask
        let mut v = Vec::new();
        for &(lo, hi) in ranges {
            let i = self.blocks.partition_point(|&(d, _)| d < lo);
            for &(d, c) in &self.blocks[i..] {
                if d >= hi {
                    break;
                }
                v.push((d, c));
            }
        }
        // blocks with FPCR bits set (rare): match by PC
        for &(d, c) in self.blocks.iter().rev() {
            if d <= PC_MASK {
                break;
            }
            let pc = d & PC_MASK;
            if ranges.iter().any(|&(lo, hi)| pc >= lo && pc < hi) {
                v.push((d, c));
            }
        }
        v.sort_unstable_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
        v
    }
}
