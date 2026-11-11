//! First-run setup (the AppImage's wizard, docs/RELEASE.md): host checks, the one privileged step (Darling into
//! /opt/x86sim, bin/darling setuid root), an iOS runtime (downloaded from Apple, or one already on disk linked in),
//! and the setup state. In a checkout (no X86SIM_APP) the same checks run against the repo's darling-prefix.
use crate::aot::{repo_root, scratch};
use anyhow::{Context, Result};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// The iOS build the wizard offers first (the runtime everything is tested on)
pub const DEFAULT_BUILD: &str = "24B8117";
pub const DEFAULT_VERSION: &str = "27.2";
/// free space a download needs: the 8 GB archive, the decrypted image and the ~23 GB unpacked tree side by side
pub const DOWNLOAD_NEED_GB: f64 = 45.0;
/// /opt/x86sim/darling: the install prefix the release's Darling is built with (build/release/build.sh)
pub const OPT_DARLING: &str = "/opt/x86sim/darling";

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
pub enum Level {
    Ok,
    Warn,
    Fail,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct Check {
    pub name: &'static str,
    pub level: Level,
    pub detail: String,
    /// what to do about it (empty when nothing)
    pub fix: String,
}

fn check(name: &'static str, level: Level, detail: impl Into<String>, fix: impl Into<String>) -> Check {
    Check { name, level, detail: detail.into(), fix: fix.into() }
}

/// Running from the AppImage (its AppRun sets X86SIM_APP to the payload copy in the data dir)
pub fn appimage() -> Option<PathBuf> {
    std::env::var_os("X86SIM_APP").map(PathBuf::from)
}

pub fn version() -> String {
    std::env::var("X86SIM_VERSION").unwrap_or_else(|_| format!("{} (checkout)", env!("CARGO_PKG_VERSION")))
}

fn on_path(cmd: &str) -> bool {
    std::env::var_os("PATH").is_some_and(|p| std::env::split_paths(&p).any(|d| d.join(cmd).is_file()))
}

fn read(p: &str) -> String {
    std::fs::read_to_string(p).unwrap_or_default()
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub enum DarlingState {
    /// installed, setuid root, the version this AppImage carries
    Ready,
    /// no bin/darling
    Missing,
    /// installed but not setuid root
    NotSetuid,
    /// installed from another AppImage version (an update brings a new Darling)
    Outdated { installed: String },
}

/// bin/darling of what boots: the data dir's darling-prefix (-> /opt/x86sim/darling in the AppImage)
pub fn darling_bin() -> PathBuf {
    repo_root().join("darling-prefix/bin/darling")
}

pub fn darling_state() -> DarlingState {
    let bin = darling_bin();
    let Ok(md) = std::fs::metadata(&bin) else { return DarlingState::Missing };
    if !userns() && (md.uid() != 0 || md.mode() & 0o4000 == 0) {
        return DarlingState::NotSetuid;
    }
    if let Ok(want) = std::env::var("X86SIM_DARLING_ID") {
        let have = std::fs::read_to_string(repo_root().join("darling-prefix/.x86sim-complete")).unwrap_or_default().trim().to_string();
        if have != want.trim() {
            return DarlingState::Outdated { installed: have };
        }
    }
    DarlingState::Ready
}

/// Darling runs without root, through a user namespace (the AppImage's userns mode, build/release/darling-userns.sh)
pub fn userns() -> bool {
    repo_root().join("darling-prefix/.x86sim-userns").exists()
}

/// The command the privileged step runs (shown to the user, also for running it by hand with sudo)
pub fn install_command(stage: &Path) -> Option<Vec<String>> {
    let app = appimage()?;
    let id = std::env::var("X86SIM_DARLING_ID").ok()?;
    Some(vec!["sh".into(), app.join("install-helper.sh").to_string_lossy().into(), "install".into(), stage.to_string_lossy().into(), id.trim().into()])
}

pub fn stage_dir() -> PathBuf {
    scratch().join("darling-stage")
}

/// The privileged step (blocking; run it on a thread): copy the AppImage's Darling tree out of the AppImage mount (root
/// can't read a user's FUSE mount) and install it with pkexec. Progress lines go to `say`.
pub fn install_darling(say: &dyn Fn(&str)) -> Result<()> {
    let src = std::env::var_os("X86SIM_DARLING_STAGE").map(PathBuf::from).context("not running from the AppImage")?;
    let stage = stage_dir();
    say("Copying Darling out of the AppImage…");
    let _ = std::fs::remove_dir_all(&stage);
    std::fs::create_dir_all(stage.parent().unwrap())?;
    let st = Command::new("cp").arg("-a").arg(&src).arg(&stage).status()?;
    anyhow::ensure!(st.success(), "copying {} failed", src.display());
    let cmd = install_command(&stage).context("no install helper")?;
    say("Waiting for your password (system dialog)…");
    let tool = if on_path("pkexec") { "pkexec" } else { anyhow::bail!("pkexec is not installed; run this in a terminal instead:\n  sudo {}", cmd.join(" ")) };
    let out = Command::new(tool).args(&cmd).stdin(Stdio::null()).output()?;
    let _ = std::fs::remove_dir_all(&stage);
    match out.status.code() {
        Some(0) => {}
        Some(126) | Some(127) => anyhow::bail!("not authorized (the password dialog was cancelled or refused)"),
        _ => anyhow::bail!("install failed: {}", String::from_utf8_lossy(&out.stderr).trim()),
    }
    anyhow::ensure!(darling_state() == DarlingState::Ready, "installed, but {} is not ready ({:?})", OPT_DARLING, darling_state());
    Ok(())
}

/// Host checks: CPU, kernel, memory, disk, GPU, tools. Cheap (a few file reads and one dlopen); run on a thread.
pub fn checks() -> Vec<Check> {
    let mut v = vec![];
    // CPU: the translator's code uses SSE4.1, POPCNT and CMPXCHG16B
    let cpu = read("/proc/cpuinfo");
    let flags: Vec<&str> = cpu.lines().find(|l| l.starts_with("flags")).map(|l| l.split_whitespace().collect()).unwrap_or_default();
    let missing: Vec<&str> = ["sse4_1", "popcnt", "cx16"].into_iter().filter(|f| !flags.contains(f)).collect();
    let model = cpu.lines().find(|l| l.starts_with("model name")).and_then(|l| l.split(':').nth(1)).unwrap_or("").trim().to_string();
    let cores = cpu.lines().filter(|l| l.starts_with("processor")).count();
    v.push(if std::env::consts::ARCH != "x86_64" {
        check("Processor", Level::Fail, format!("{} (x86-64 needed)", std::env::consts::ARCH), "x86Sim runs on 64-bit Intel and AMD processors.")
    } else if !missing.is_empty() {
        check("Processor", Level::Fail, format!("{model}: no {}", missing.join(", ")), "The translator needs SSE4.1, POPCNT and CMPXCHG16B (any x86-64 CPU since about 2009).")
    } else {
        check("Processor", if cores >= 4 { Level::Ok } else { Level::Warn }, format!("{model}, {cores} threads"), if cores >= 4 { "" } else { "4 or more threads recommended." })
    });
    // kernel: overlayfs (Darling's container), PROCMAP_QUERY (6.11+, faster darlingserver)
    let rel = read("/proc/sys/kernel/osrelease").trim().to_string();
    let mut it = rel.split(|c: char| !c.is_ascii_digit()).filter_map(|x| x.parse::<u32>().ok());
    let (maj, min) = (it.next().unwrap_or(0), it.next().unwrap_or(0));
    let overlay = read("/proc/filesystems").lines().any(|l| l.trim_end().ends_with("overlay")) || Path::new(&format!("/lib/modules/{rel}/kernel/fs/overlayfs")).exists() || Path::new(&format!("/usr/lib/modules/{rel}/kernel/fs/overlayfs")).exists();
    v.push(if !overlay {
        check("Linux kernel", Level::Fail, format!("{rel}: no overlayfs"), "Darling mounts each phone's system with overlayfs: use a kernel with CONFIG_OVERLAY_FS.")
    } else if (maj, min) < (5, 15) {
        check("Linux kernel", Level::Warn, rel, "Linux 5.15 or newer recommended (developed on 6.x and 7.x).")
    } else if (maj, min) < (6, 11) {
        check("Linux kernel", Level::Ok, format!("{rel} (6.11+ is a little faster)"), "")
    } else {
        check("Linux kernel", Level::Ok, rel, "")
    });
    // memory
    let kb: f64 = read("/proc/meminfo").lines().find(|l| l.starts_with("MemTotal:")).and_then(|l| l.split_whitespace().nth(1)).and_then(|x| x.parse().ok()).unwrap_or(0.0);
    let gb = kb / 1024.0 / 1024.0;
    v.push(match gb {
        g if g >= 15.0 => check("Memory", Level::Ok, format!("{g:.0} GB"), ""),
        g if g >= 7.5 => check("Memory", Level::Warn, format!("{g:.0} GB"), "A phone uses about 1-3 GB; 16 GB recommended."),
        g => check("Memory", Level::Fail, format!("{g:.1} GB"), "At least 8 GB needed."),
    });
    // disk: the data dir (runtimes) and the cache (AOT images, prefixes)
    let have_rt = crate::host::runtimes().iter().any(|r| r.present);
    let d = crate::host::disk(&repo_root());
    let need = if have_rt { 10.0 } else { DOWNLOAD_NEED_GB };
    v.push(check(
        "Disk space",
        if d.free_gb >= need { Level::Ok } else if d.free_gb >= need * 0.6 { Level::Warn } else { Level::Fail },
        format!("{:.0} GB free in {}", d.free_gb, repo_root().display()),
        if d.free_gb >= need { String::new() } else { format!("About {need:.0} GB needed{}.", if have_rt { "" } else { " to download and unpack iOS (30 GB once unpacked)" }) },
    ));
    // GPU: a Vulkan loader and a driver (ICD); software rendering otherwise
    let loader = unsafe { !libc::dlopen(c"libvulkan.so.1".as_ptr(), libc::RTLD_LAZY | libc::RTLD_LOCAL).is_null() };
    let mut icds: Vec<String> = vec![];
    let home_icd = std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/share/vulkan/icd.d"));
    for dir in [Some(PathBuf::from("/usr/share/vulkan/icd.d")), Some(PathBuf::from("/etc/vulkan/icd.d")), Some(PathBuf::from("/usr/local/share/vulkan/icd.d")), home_icd].into_iter().flatten() {
        for e in std::fs::read_dir(dir).into_iter().flatten().flatten() {
            let n = e.file_name().to_string_lossy().into_owned();
            if n.ends_with(".json") && !n.contains("lvp") {
                icds.push(n.trim_end_matches(".json").trim_end_matches(".x86_64").trim_end_matches("_icd").to_string());
            }
        }
    }
    icds.sort();
    icds.dedup();
    let dev = Path::new("/dev/nvidiactl").exists() || std::fs::read_dir("/dev/dri").into_iter().flatten().flatten().any(|e| e.file_name().to_string_lossy().starts_with("renderD"));
    v.push(if loader && !icds.is_empty() && dev {
        check("Graphics (Vulkan)", Level::Ok, format!("drivers: {}", icds.join(", ")), "")
    } else {
        let why = if !loader { "no Vulkan loader (libvulkan.so.1)" } else if icds.is_empty() { "no Vulkan driver" } else { "no GPU device node" };
        check("Graphics (Vulkan)", Level::Warn, why, "Install your GPU's Vulkan driver (NVIDIA's driver, or Mesa RADV / ANV) and vulkan-icd-loader. Without it phones draw in software: slow.")
    });
    // tools the scripts run
    let mut miss = vec![];
    for t in ["python3", "curl", "openssl", "setsid", "systemd-run"] {
        if !on_path(t) {
            miss.push(t);
        }
    }
    for t in ["ipsw", "7z"] {
        if !on_path(t) {
            miss.push(t);
        }
    }
    v.push(if miss.is_empty() {
        check("Programs", Level::Ok, "python3, curl, openssl, systemd, ipsw, 7-Zip", "")
    } else {
        check("Programs", Level::Fail, format!("missing: {}", miss.join(", ")), "Install them with your package manager (ipsw and 7-Zip come with the AppImage).")
    });
    // Python's dnspython (phones' DNS): the AppImage carries it
    let pylib = std::env::var("X86SIM_PYLIB").unwrap_or_default();
    let dns = Command::new("python3").args(["-c", &format!("import sys; sys.path.append({pylib:?}); import dns.resolver")]).stdin(Stdio::null()).stderr(Stdio::null()).status().is_ok_and(|s| s.success());
    if !dns {
        v.push(check("Python dnspython", Level::Warn, "not found", "Install python3-dnspython: phones' network name lookups need it."));
    }
    // the privileged step
    v.push(match darling_state() {
        DarlingState::Ready if userns() => check("Darling", Level::Ok, "runs without root (user namespace)", ""),
        DarlingState::Ready => check("Darling", Level::Ok, format!("installed ({})", darling_bin().display()), ""),
        DarlingState::Missing => check("Darling", Level::Fail, "not installed yet", "Install it below (asks for your password once)."),
        DarlingState::NotSetuid => check("Darling", Level::Fail, "bin/darling is not setuid root", "Install it below (asks for your password once)."),
        DarlingState::Outdated { installed } => check("Darling", Level::Warn, format!("an older build is installed ({})", if installed.is_empty() { "unknown" } else { &installed }), "Update it below (asks for your password once)."),
    });
    v
}

/// Links an iOS runtime that's already on disk (another checkout's runtimes/<dir>, or a previous install) into
/// runtimes/ instead of downloading it again. `src`: the runtimes/<dir> (with RuntimeRoot) or its RuntimeRoot.
/// Returns the dir name.
pub fn link_runtime(src: &Path) -> Result<String> {
    let src = if src.file_name().is_some_and(|n| n == "RuntimeRoot") { src.parent().unwrap().to_path_buf() } else { src.to_path_buf() };
    let src = src.canonicalize().with_context(|| format!("{} not found", src.display()))?;
    let rr = src.join("RuntimeRoot");
    anyhow::ensure!(crate::dyldcache::Cache::cache_dir(&rr).join(crate::dyldcache::CACHE_NAME).exists(), "{} has no simulator runtime (no RuntimeRoot with a dyld cache)", src.display());
    let name = src.file_name().unwrap().to_string_lossy().into_owned();
    // Platforms 1: tvOS / watchOS runtimes too (tvos-<version>-<build>-arm64, watchos-...)
    anyhow::ensure!(crate::sim::parse_runtime_dir(&name).is_some(), "{name}: expected a runtimes/ios-<version>-<build>-arm64 dir (or tvos-..., watchos-...)");
    let dst = repo_root().join("runtimes").join(&name);
    anyhow::ensure!(dst.symlink_metadata().is_err(), "runtimes/{name} already exists");
    std::fs::create_dir_all(repo_root().join("runtimes"))?;
    // relative: the scripts hand these paths to Darling as /Volumes/SystemRoot/<path>, where an absolute link target
    // would resolve against the container's own root (launchd_sim "No such file or directory")
    let base = repo_root().join("runtimes").canonicalize()?;
    std::os::unix::fs::symlink(relative(&src, &base), &dst)?;
    Ok(name)
}

/// `to` relative to the directory `from` (both absolute, canonical)
fn relative(to: &Path, from: &Path) -> PathBuf {
    let (t, f): (Vec<_>, Vec<_>) = (to.components().collect(), from.components().collect());
    let common = t.iter().zip(&f).take_while(|(a, b)| a == b).count();
    let mut r = PathBuf::new();
    for _ in common..f.len() {
        r.push("..");
    }
    for c in &t[common..] {
        r.push(c);
    }
    r
}

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct State {
    /// version that finished setup (or skipped it)
    pub done_version: String,
}

fn state_path() -> PathBuf {
    repo_root().join("setup.json")
}

pub fn load_state() -> State {
    std::fs::read(state_path()).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
}

pub fn mark_done() -> Result<()> {
    crate::aot::write_json(&state_path(), &State { done_version: version() })
}

/// Whether the launcher should open on the setup page: from the AppImage, until it was finished once, or whenever
/// something it can't run without is missing (Darling not installed / outdated, no iOS runtime)
pub fn needed() -> bool {
    if appimage().is_none() {
        return false;
    }
    load_state().done_version.is_empty() || darling_state() != DarlingState::Ready || !crate::host::runtimes().iter().any(|r| r.present)
}
