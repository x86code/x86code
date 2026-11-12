//! Host side: iOS versions (downloaded / in Apple's catalogue, fetched with cli/x86sim runtime), disk use of the
//! scratch dir and the caches, hub-wide settings.
use crate::aot::{repo_root, scratch};
use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

#[derive(Debug, Clone, Serialize)]
pub struct Runtime {
    /// runtimes/ dir name
    pub dir: String,
    /// Platforms 1: "ios", "tvos" or "watchos" (the dir's prefix)
    pub platform: String,
    pub version: String,
    pub build: String,
    pub root: PathBuf,
    /// dyld cache on disk: boots
    pub present: bool,
    /// a dir exists but is incomplete (data loss / interrupted download)
    pub partial: bool,
    pub jc: PathBuf,
    /// Models 2: model ids this runtime is limited to (empty: any), see sim::runtime_restricted_to
    pub restricted_to: Vec<String>,
}

impl Runtime {
    /// "iOS 27.2", "tvOS 27.2", "watchOS 27.2"
    pub fn label(&self) -> String {
        format!("{} {}", crate::sim::platform_name(&self.platform), self.version)
    }
}

pub fn runtimes() -> Vec<Runtime> {
    let mut v: Vec<Runtime> = std::fs::read_dir(repo_root().join("runtimes"))
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| {
            let dir = e.file_name().to_string_lossy().into_owned();
            let (platform, version, build) = crate::sim::parse_runtime_dir(&dir)?;
            let root = e.path().join("RuntimeRoot");
            let present = crate::dyldcache::Cache::cache_dir(&root).join(crate::dyldcache::CACHE_NAME).exists();
            Some(Runtime { jc: crate::sim::jc_for(&root), platform: platform.to_string(), version, build, restricted_to: crate::sim::runtime_restricted_to(&root), dir, root, present, partial: !present })
        })
        .collect();
    // within a version a runtime limited to some models (the iPhone Duo's 27.2 build) after the general one
    // Platforms 1: iOS, then tvOS, then watchOS
    let rank = |p: &str| crate::sim::PLATFORMS.iter().position(|x| *x == p).unwrap_or(0);
    v.sort_by(|a, b| rank(&a.platform).cmp(&rank(&b.platform)).then(a.version.cmp(&b.version)).then(a.restricted_to.is_empty().cmp(&b.restricted_to.is_empty()).reverse()).then(a.build.cmp(&b.build)));
    v
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Catalogue {
    pub version: String,
    pub build: String,
    pub name: String,
    pub gb: f64,
    /// Platforms 1: "ios", "tvos" or "watchos" (from the name: "tvOS 27.2 Simulator Runtime"); absent in older caches
    #[serde(default = "ios")]
    pub platform: String,
}

fn ios() -> String {
    "ios".into()
}

/// Apple's catalogue (network; `x86sim runtime list all`: iOS, tvOS and watchOS), cached in scratch
pub fn catalogue(refresh: bool) -> Vec<Catalogue> {
    // Platforms 1: a new file name, so a cache of the iOS-only list is not taken for the whole catalogue
    let cache = scratch().join("launcher-runtimes-all.json");
    if !refresh {
        if let Some(v) = std::fs::read(&cache).ok().and_then(|b| serde_json::from_slice(&b).ok()) {
            return v;
        }
    }
    let out = Command::new(repo_root().join("cli/x86sim")).args(["runtime", "list", "all"]).stdin(Stdio::null()).output();
    let mut v = vec![];
    if let Ok(o) = out {
        for l in String::from_utf8_lossy(&o.stdout).lines() {
            // "{build:12} {name:42} {size:4.1f} GB{mark}"
            let f: Vec<&str> = l.split_whitespace().collect();
            if f.len() < 4 {
                continue;
            }
            let build = f[0].to_string();
            let gb_i = f.iter().position(|x| *x == "GB").unwrap_or(f.len());
            let gb = gb_i.checked_sub(1).and_then(|i| f.get(i)).and_then(|x| x.parse().ok()).unwrap_or(0.0);
            let name = f[1..gb_i.saturating_sub(1)].join(" ");
            let version = name.split_whitespace().find(|w| w.starts_with("27")).unwrap_or("").to_string();
            let platform = if name.starts_with("tvOS") { "tvos" } else if name.starts_with("watchOS") { "watchos" } else if name.starts_with("visionOS") { "xros" } else { "ios" }.to_string();
            v.push(Catalogue { version, build, name, gb, platform });
        }
    }
    if !v.is_empty() {
        let _ = crate::aot::write_json(&cache, &v);
    }
    v
}

pub fn fetch_log(build: &str) -> PathBuf {
    scratch().join(format!("launcher-fetch-{build}.log"))
}

/// Downloads a runtime (x86sim runtime fetch BUILD) in the background; progress in fetch_log
pub fn fetch(build: &str) -> Result<u32> {
    let log = std::fs::File::create(fetch_log(build))?;
    let c = Command::new("setsid").arg(repo_root().join("cli/x86sim")).args(["runtime", "fetch", build]).current_dir(repo_root()).stdin(Stdio::null()).stdout(log.try_clone()?).stderr(log).spawn()?;
    Ok(c.id())
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct Disk {
    pub total_gb: f64,
    pub free_gb: f64,
}

pub fn disk(p: &Path) -> Disk {
    let c = std::ffi::CString::new(p.to_string_lossy().as_bytes()).unwrap_or_default();
    let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
    if unsafe { libc::statvfs(c.as_ptr(), &mut st) } != 0 {
        return Disk::default();
    }
    let bs = st.f_frsize as f64;
    Disk { total_gb: st.f_blocks as f64 * bs / 1e9, free_gb: st.f_bavail as f64 * bs / 1e9 }
}

/// Bytes under a dir (walk; symlinks not followed)
pub fn dir_size(p: &Path) -> u64 {
    let mut total = 0;
    let mut work = vec![p.to_path_buf()];
    while let Some(d) = work.pop() {
        for e in std::fs::read_dir(&d).into_iter().flatten().flatten() {
            let Ok(md) = e.metadata() else { continue };
            if md.is_dir() {
                work.push(e.path());
            } else if md.is_file() {
                total += md.len();
            }
        }
    }
    total
}

pub fn mtlvk_pids() -> Vec<u32> {
    std::fs::read_dir("/proc")
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| e.file_name().to_string_lossy().parse::<u32>().ok())
        .filter(|p| std::fs::read_to_string(format!("/proc/{p}/comm")).map(|c| c.trim() == "mtlvk").unwrap_or(false))
        .collect()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct HubSettings {
    /// show live thumbnails on the home view
    pub thumbnails: bool,
    /// open the phone's view when it starts
    pub open_on_start: bool,
    /// home view card width
    pub card_w: f32,
    /// order of the phones on the home view: "name" | "newest" | "oldest" | "model" | "ios"
    pub sort: String,
    /// look for a newer x86Sim release (AppImage only) at start and every few hours
    pub check_updates: bool,
    /// release channel: "" (the running version's: pre-release builds follow pre-releases) | "stable" | "pre"
    pub channel: String,
    /// "system" (the Omarchy theme, else the desktop's light or dark preference) | "dark" | "light"
    pub appearance: String,
}

impl Default for HubSettings {
    fn default() -> Self {
        HubSettings { thumbnails: true, open_on_start: false, card_w: 250.0, sort: "name".into(), check_updates: true, channel: String::new(), appearance: "system".into() }
    }
}

pub fn hub_path() -> PathBuf {
    scratch().join("launcher-hub.json")
}

pub fn load_hub() -> HubSettings {
    std::fs::read(hub_path()).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
}

pub fn save_hub(s: &HubSettings) -> Result<()> {
    crate::aot::write_json(&hub_path(), s)
}

// ---- downloads ----

/// A running download (x86sim runtime fetch BUILD): found by its command line, so one started before the hub opened
/// (or from a terminal) shows too.
#[derive(Debug, Clone, Default, Serialize)]
pub struct Fetch {
    pub build: String,
    /// the process group leader (setsid by `fetch`), or the runtime-fetch.py process
    pub pid: u32,
    /// "starting" | "downloading" | "decrypting" | "unpacking"
    pub phase: String,
    pub pct: Option<f32>,
    pub done_bytes: u64,
    pub total_bytes: u64,
    /// bytes per second (curl's current speed)
    pub speed: u64,
    pub eta_s: Option<u64>,
}

fn proc_read(pid: u32, f: &str) -> String {
    std::fs::read_to_string(format!("/proc/{pid}/{f}")).unwrap_or_default()
}

/// "7900M" -> bytes
fn curl_size(s: &str) -> Option<u64> {
    let s = s.trim();
    let (n, mul) = match s.chars().last()? {
        'k' => (&s[..s.len() - 1], 1u64 << 10),
        'M' => (&s[..s.len() - 1], 1 << 20),
        'G' => (&s[..s.len() - 1], 1 << 30),
        'T' => (&s[..s.len() - 1], 1 << 40),
        _ => (s, 1),
    };
    n.parse::<f64>().ok().map(|v| (v * mul as f64) as u64)
}

/// "1:49:00" / "--:--:--" -> seconds
fn curl_time(s: &str) -> Option<u64> {
    let p: Vec<u64> = s.split(':').map(|x| x.parse().ok()).collect::<Option<_>>()?;
    Some(p.iter().fold(0, |a, v| a * 60 + v))
}

/// Downloads in progress (runtime-fetch.py fetch BUILD processes), with progress from curl's meter in the log.
pub fn fetches() -> Vec<Fetch> {
    let mut out: Vec<Fetch> = vec![];
    let mut groups: std::collections::HashMap<u32, Vec<String>> = std::collections::HashMap::new(); // pgid -> comms
    let mut found: Vec<(u32, u32, String)> = vec![]; // pid, pgid, build
    for e in std::fs::read_dir("/proc").into_iter().flatten().flatten() {
        let Ok(pid) = e.file_name().to_string_lossy().parse::<u32>() else { continue };
        let stat = proc_read(pid, "stat");
        let Some(rest) = stat.rsplit(')').next() else { continue };
        let pgid: u32 = rest.split_whitespace().nth(2).and_then(|x| x.parse().ok()).unwrap_or(0);
        let comm = proc_read(pid, "comm").trim().to_string();
        groups.entry(pgid).or_default().push(comm.clone());
        if comm.starts_with("python") {
            let args: Vec<String> = proc_read(pid, "cmdline").split('\0').map(String::from).collect();
            if let Some(i) = args.iter().position(|a| a.ends_with("arm64/runtime-fetch.py")) {
                if args.get(i + 1).map(String::as_str) == Some("fetch") {
                    if let Some(b) = args.get(i + 2) {
                        found.push((pid, pgid, b.clone()));
                    }
                }
            }
        }
    }
    for (pid, pgid, build) in found {
        let comms = groups.get(&pgid).cloned().unwrap_or_default();
        let has = |c: &str| comms.iter().any(|x| x == c);
        let phase = if has("curl") {
            "downloading"
        } else if has("ipsw") {
            "decrypting"
        } else if has("7z") || comms.iter().filter(|c| c.starts_with("python")).count() > 1 {
            "unpacking"
        } else {
            "starting"
        };
        let mut f = Fetch { build: build.clone(), pid: if pgid > 1 { pgid } else { pid }, phase: phase.into(), ..Default::default() };
        if phase == "downloading" {
            // curl's meter: the last \r-separated record of the log
            let log = std::fs::read(fetch_log(&build)).unwrap_or_default();
            let tail = String::from_utf8_lossy(&log[log.len().saturating_sub(4096)..]).into_owned();
            // a resumed download's meter counts only the rest
            let resumed: u64 = String::from_utf8_lossy(&log[..log.len().min(16384)])
                .split("Resuming transfer from byte position ")
                .nth(1)
                .and_then(|r| r.split_whitespace().next())
                .and_then(|n| n.parse().ok())
                .unwrap_or(0);
            if let Some(rec) = tail.rsplit(['\r', '\n']).find(|r| r.split_whitespace().next().is_some_and(|w| w.parse::<u32>().is_ok())) {
                let w: Vec<&str> = rec.split_whitespace().collect();
                if w.len() >= 12 {
                    f.total_bytes = curl_size(w[1]).unwrap_or(0) + resumed;
                    f.done_bytes = curl_size(w[3]).unwrap_or(0) + resumed;
                    f.pct = (f.total_bytes > 0).then(|| f.done_bytes as f32 / f.total_bytes as f32 * 100.0);
                    f.speed = curl_size(w[11]).unwrap_or(0);
                    f.eta_s = curl_time(w[10]);
                }
            }
        }
        out.push(f);
    }
    out
}

/// Stops a download (its whole process group). What was downloaded stays: Download again resumes it.
pub fn cancel_fetch(f: &Fetch) {
    unsafe {
        if libc::getpgid(f.pid as i32) == f.pid as i32 {
            libc::kill(-(f.pid as i32), libc::SIGTERM);
        } else {
            libc::kill(f.pid as i32, libc::SIGTERM);
        }
    }
}

/// A download that stopped part way (no RuntimeRoot yet): runtimes/<dir>/download/runtime.aar and its size
pub fn partial_download(r: &Runtime) -> Option<u64> {
    if r.present {
        return None;
    }
    let dir = repo_root().join("runtimes").join(&r.dir);
    if dir.join("RuntimeRoot").symlink_metadata().is_ok() {
        return None;
    }
    std::fs::metadata(dir.join("download/runtime.aar")).ok().map(|m| m.len())
}

/// Removes a stopped download: only a runtimes/ dir that never got a RuntimeRoot (the files the download made).
pub fn discard_download(r: &Runtime) -> Result<()> {
    let dir = repo_root().join("runtimes").join(&r.dir);
    anyhow::ensure!(!r.present && dir.join("RuntimeRoot").symlink_metadata().is_err(), "{} is installed, not a stopped download", r.dir);
    anyhow::ensure!(!fetches().iter().any(|f| f.build == r.build), "it is still downloading");
    for e in std::fs::read_dir(&dir)?.flatten() {
        let n = e.file_name().to_string_lossy().into_owned();
        anyhow::ensure!(matches!(n.as_str(), "download" | "decrypted" | "bundle" | "extracted"), "{} has other files ({n}); left alone", dir.display());
    }
    std::fs::remove_dir_all(&dir)?;
    Ok(())
}
