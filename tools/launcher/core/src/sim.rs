//! Sim control for the arm64 device: start / stop (cli/libexec/arm64/boot-a64.sh), show (simview on DISPLAY=:0) and
//! status (booted, home reached, CPU, PSS) read from /proc. Processes are found by exact checks (the darlingserver
//! of the sim's prefix and its descendants), never by pattern kills.
use crate::aot::{repo_root, scratch};
use anyhow::Result;
use serde::Serialize;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

pub fn sim_prefix() -> PathBuf {
    std::env::var("A64_DPREFIX").map(PathBuf::from).unwrap_or_else(|_| scratch().join("a64prefix"))
}

pub fn runtimes() -> Vec<(String, PathBuf)> {
    let dir = repo_root().join("runtimes");
    let mut v: Vec<(String, PathBuf)> = std::fs::read_dir(&dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| {
            let rr = e.path().join("RuntimeRoot");
            crate::dyldcache::Cache::cache_dir(&rr).join(crate::dyldcache::CACHE_NAME).exists().then(|| (runtime_label(&e.file_name().to_string_lossy()), rr))
        })
        .collect();
    v.sort();
    v
}

pub fn devices() -> Vec<(String, PathBuf)> {
    let dir = repo_root().join("var");
    let mut v: Vec<(String, PathBuf)> = std::fs::read_dir(&dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter(|e| e.file_name().to_string_lossy().starts_with("device-a64") && e.path().join("sim.env").exists())
        .map(|e| (device_label(&e.path()), e.path()))
        .collect();
    v.sort();
    v
}

/// Models 2: the device types a runtime is limited to (its profile's restrictedToDeviceTypes; empty: any model of
/// its supported families). iOS 27.2 24B91016s is the iPhone Duo's (iPhone19,4) build; 24B8117 lists the Duo as
/// unsupported. The profile is a binary plist whose strings are plain ASCII: the model ids in a profile with that
/// key are its restriction (a restricted profile has no unsupportedDeviceTypes).
pub fn runtime_restricted_to(runtime_root: &Path) -> Vec<String> {
    let Some(profile) = std::fs::canonicalize(runtime_root).ok().and_then(|r| r.parent().map(|p| p.join("profile.plist"))) else { return vec![] };
    let Ok(b) = std::fs::read(profile) else { return vec![] };
    if !b.windows(23).any(|w| w == b"restrictedToDeviceTypes") {
        return vec![];
    }
    let mut out = vec![];
    for pre in [&b"iPhone"[..], &b"iPad"[..]] {
        let mut i = 0;
        while let Some(p) = b[i..].windows(pre.len()).position(|w| w == pre) {
            let s = i + p;
            let mut e = s + pre.len();
            while e < b.len() && (b[e].is_ascii_digit() || b[e] == b',') {
                e += 1;
            }
            if e > s + pre.len() + 2 && b[s + pre.len()..e].contains(&b',') {
                out.push(String::from_utf8_lossy(&b[s..e]).into_owned());
            }
            i = e;
        }
    }
    out.sort();
    out.dedup();
    out
}

/// Whether a phone of `model_id` can run on this runtime (restriction only; families are not checked)
pub fn runtime_allows(runtime_root: &Path, model_id: &str) -> bool {
    let r = runtime_restricted_to(runtime_root);
    r.is_empty() || r.iter().any(|m| m == model_id)
}

/// The RuntimeRoot a device boots on: its `runtime` file (a runtimes/ dir name, device-a64.py create --ios), else 27.0
pub fn device_runtime(dev: &Path) -> PathBuf {
    let d = std::fs::read_to_string(dev.join("runtime")).map(|s| s.trim().to_string()).unwrap_or_default();
    let d = if d.is_empty() { "ios-27.2-24B8117-arm64".to_string() } else { d };
    repo_root().join("runtimes").join(d).join("RuntimeRoot")
}

/// Platforms 1: the runtimes/ dir prefixes ("ios", "tvos", "watchos"), as cli/libexec/arm64/runtime-fetch.py names them
pub const PLATFORMS: [&str; 3] = ["ios", "tvos", "watchos"];

/// Platforms 1: "ios" -> "iOS", "tvos" -> "tvOS", "watchos" -> "watchOS"
pub fn platform_name(platform: &str) -> &'static str {
    match platform {
        "tvos" => "tvOS",
        "watchos" => "watchOS",
        _ => "iOS",
    }
}

/// Platforms 1: the build Add-phone offers to download when no runtime of a platform is installed
pub fn platform_default_build(platform: &str) -> (&'static str, &'static str) {
    match platform {
        "tvos" => ("27.2", "24K150"),
        "watchos" => ("27.2", "24S118"),
        _ => (crate::setup::DEFAULT_VERSION, crate::setup::DEFAULT_BUILD),
    }
}

/// Platforms 1: (platform, version, build) of a runtimes/ dir name ("tvos-27.2-24K150-arm64"), None for other dirs
pub fn parse_runtime_dir(dir: &str) -> Option<(&'static str, String, String)> {
    let parts: Vec<&str> = dir.split('-').collect();
    if parts.len() < 3 {
        return None;
    }
    let p = PLATFORMS.iter().find(|p| **p == parts[0])?;
    Some((p, parts[1].to_string(), parts[2].to_string()))
}

fn rt_dir(runtime_root: &Path) -> String {
    runtime_root.parent().and_then(|p| p.file_name()).map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()
}

/// The JIT/AOT cache dir of a runtime, as boot-a64.sh picks it: 27.0 the default one, others $SCRATCH/jc-<build>
/// (tvOS / watchOS runtimes too)
pub fn jc_for(runtime_root: &Path) -> PathBuf {
    match parse_runtime_dir(&rt_dir(runtime_root)) {
        Some((_, _, build)) if build != "24A434" => scratch().join(format!("jc-{build}")),
        _ => crate::aot::Paths::default_jc(),
    }
}

/// "ios-27.2-24B8117-arm64" -> "iOS 27.2 (24B8117)"
fn runtime_label(dir: &str) -> String {
    match parse_runtime_dir(dir) {
        Some((p, ver, build)) => format!("{} {ver} ({build})", platform_name(p)),
        None => dir.to_string(),
    }
}

/// Platforms 1: a model's platform ("ios", "tvos", "watchos"): its devicetypes-a64.json entry's "platform" (by model
/// identifier), else from the identifier itself
pub fn model_platform(model_id: &str) -> &'static str {
    static M: std::sync::OnceLock<HashMap<String, String>> = std::sync::OnceLock::new();
    let m = M.get_or_init(|| {
        let txt = std::fs::read_to_string(repo_root().join("cli/lib/devicetypes-a64.json")).unwrap_or_default();
        let v: serde_json::Value = serde_json::from_str(&txt).unwrap_or_default();
        let mut out = HashMap::new();
        if let Some(o) = v.as_object() {
            for t in o.values() {
                if let (Some(id), Some(p)) = (t["model"].as_str(), t["platform"].as_str()) {
                    out.insert(id.to_string(), p.to_string());
                }
            }
        }
        out
    });
    match m.get(model_id).map(|s| s.as_str()) {
        Some("tvos") => "tvos",
        Some("watchos") => "watchos",
        Some(_) => "ios",
        None if model_id.starts_with("AppleTV") => "tvos",
        None if model_id.starts_with("Watch") => "watchos",
        None => "ios",
    }
}

/// The phone models a device can be made of (cli/lib/devicetypes-a64.json, from Xcode's device types): (name, model id)
pub fn models() -> Vec<(String, String)> {
    static M: std::sync::OnceLock<Vec<(String, String)>> = std::sync::OnceLock::new();
    M.get_or_init(load_models).clone()
}

fn load_models() -> Vec<(String, String)> {
    let txt = std::fs::read_to_string(repo_root().join("cli/lib/devicetypes-a64.json")).unwrap_or_default();
    let v: serde_json::Value = serde_json::from_str(&txt).unwrap_or_default();
    let mut out: Vec<(String, String)> = vec![];
    if let Some(m) = v.as_object() {
        for (name, t) in m {
            out.push((name.clone(), t["model"].as_str().unwrap_or("").to_string()));
        }
    }
    // newest to oldest, as cli/lib/devicetypes-a64.json lists them (serde_json's map is sorted by name, so the file's
    // own order is read from where each name sits in it), iPhones before iPads, then Apple TV, then Apple Watch
    let at = |name: &str| txt.find(&format!("\"{name}\": {{")).unwrap_or(usize::MAX);
    // models the runtime lists as unsupported (with a "note": the iPhone Duo) are appended at the end of the file: they
    // go right after the last model of their own generation ("iPhone19,4" after the other iPhone19s)
    let generation = |id: &str| id.split(',').next().unwrap_or("").to_string();
    let noted = |name: &str| v.get(name).is_some_and(|t| t.get("note").is_some());
    let pos = |m: &(String, String)| -> (usize, usize) {
        let own = at(&m.0);
        if !noted(&m.0) {
            return (own, 0);
        }
        let g = generation(&m.1);
        let last = out.iter().filter(|o| !noted(&o.0) && generation(&o.1) == g).map(|o| at(&o.0)).max();
        last.map(|l| (l, 1)).unwrap_or((own, 0))
    };
    let group = |m: &(String, String)| match v.get(&m.0).and_then(|t| t["platform"].as_str()) {
        Some("tvos") => 2,
        Some("watchos") => 3,
        _ if m.0.starts_with("iPhone") => 0,
        _ => 1,
    };
    let mut keyed: Vec<_> = out.iter().map(|m| ((group(m), pos(m)), m.clone())).collect();
    keyed.sort_by_key(|k| k.0);
    let out: Vec<_> = keyed.into_iter().map(|k| k.1).collect();
    out
}

/// "iPhone 17 Pro Max · Pro Max" from the device's sim.env (model) and name file (else the folder name)
fn device_label(dir: &Path) -> String {
    let folder = dir.file_name().unwrap_or_default().to_string_lossy().into_owned();
    let name = std::fs::read_to_string(dir.join("name")).map(|s| s.trim().to_string()).unwrap_or(folder);
    let env = std::fs::read_to_string(dir.join("sim.env")).unwrap_or_default();
    let model = env.lines().find_map(|l| l.strip_prefix("SIMULATOR_MODEL_IDENTIFIER=")).unwrap_or("");
    if model.is_empty() {
        return name;
    }
    let product = models().into_iter().find(|m| m.1 == model).map(|m| m.0).unwrap_or_else(|| model.to_string());
    if product == name {
        product
    } else {
        format!("{product} · {name}")
    }
}

/// New device of a model (cli/libexec/arm64/device-a64.py create): var/device-a64-<name>
pub fn create_device(model: &str, name: &str, runtime_root: &Path) -> Result<PathBuf> {
    let rt = runtime_root.parent().and_then(|p| p.file_name()).map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let mut cmd = Command::new("python3");
    cmd.arg(repo_root().join("cli/libexec/arm64/device-a64.py")).args(["create", "--model", model, "--ios", &rt]);
    if !name.trim().is_empty() {
        cmd.arg(name.trim());
    }
    let out = cmd.current_dir(repo_root()).stdin(Stdio::null()).output()?;
    anyhow::ensure!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr).trim());
    Ok(PathBuf::from(String::from_utf8_lossy(&out.stdout).trim()))
}

/// The device the arm64 sim was last booted with (boot-a64.sh writes var/run-a64/device)
pub fn booted_device() -> Option<PathBuf> {
    let s = std::fs::read_to_string(repo_root().join("var/run-a64/device")).ok()?;
    let p = PathBuf::from(s.trim());
    p.exists().then_some(p)
}

/// Boots a device in its own prefix / state dir / ring (crate::instance); the default device keeps the default dirs
pub fn start(device: &Path) -> Result<u32> {
    let inst = crate::instance::load(device);
    let others = crate::instance::Monitor::default().poll(&crate::instance::list());
    crate::instance::start(&inst, &others)
}

pub fn stop(device: &Path) -> Result<()> {
    let inst = crate::instance::load(device);
    let sts = crate::instance::Monitor::default().poll(std::slice::from_ref(&inst));
    crate::instance::stop(&inst, sts.first())
}

/// The standalone viewer's systemd unit for a phone (the main phone keeps the old name)
pub fn simview_unit(inst: &crate::instance::Instance) -> String {
    if inst.is_default {
        "x86sim-simview".into()
    } else {
        format!("x86sim-simview-{}", inst.id.strip_prefix("device-").unwrap_or(&inst.id))
    }
}

pub fn simview_running_for(inst: &crate::instance::Instance) -> bool {
    Command::new("systemctl").args(["--user", "is-active", "--quiet", &simview_unit(inst)]).status().is_ok_and(|s| s.success())
}

/// The standalone viewer (simview, with its console pane) for one phone: its ring, input socket and logs, on the
/// display this process runs on (DISPLAY / WAYLAND_DISPLAY), as a systemd user service.
pub fn show_phone(inst: &crate::instance::Instance) -> Result<()> {
    if simview_running_for(inst) {
        return Ok(());
    }
    let mut cmd = Command::new("systemd-run");
    cmd.args(["--user", "--unit", &simview_unit(inst), "--collect"]);
    // the user manager's environment carries the desktop session's DISPLAY / WAYLAND_DISPLAY: override both, so the
    // window opens where this hub is (an X-only hub, e.g. on Xvfb, gets GTK's X11 backend)
    let display = std::env::var("DISPLAY").unwrap_or_default();
    let wayland = std::env::var("WAYLAND_DISPLAY").unwrap_or_default();
    cmd.args(["-E", &format!("DISPLAY={display}"), "-E", &format!("WAYLAND_DISPLAY={wayland}")]);
    if wayland.is_empty() {
        cmd.args(["-E", "GDK_BACKEND=x11"]);
    }
    if let Ok(v) = std::env::var("XDG_RUNTIME_DIR") {
        cmd.args(["-E", &format!("XDG_RUNTIME_DIR={v}")]);
    }
    cmd.args(["-E", "SIMVIEW_FOLLOW=0"])
        .args(["-E", &format!("SIMFB_RING_LINUX={}", inst.ring.display())])
        .args(["-E", &format!("SIMHID_SOCKET={}", inst.sock.display())])
        .args(["-E", &format!("SIMULATOR_MAINSCREEN_WIDTH={}", inst.screen.0)])
        .args(["-E", &format!("SIMULATOR_MAINSCREEN_HEIGHT={}", inst.screen.1)])
        .args(["-p", &format!("WorkingDirectory={}", repo_root().display())])
        .args(["/usr/bin/python3", "cli/libexec/simview.py"])
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    anyhow::ensure!(cmd.status()?.success(), "systemd-run simview failed");
    Ok(())
}

pub fn simview_running() -> bool {
    Command::new("systemctl").args(["--user", "is-active", "--quiet", "x86sim-simview"]).status().is_ok_and(|s| s.success())
}

/// simview with the console pane on DISPLAY=:0 (a systemd user service, as the round scripts run it)
pub fn show() -> Result<()> {
    if simview_running() {
        return Ok(());
    }
    let st = Command::new("systemd-run")
        .args(["--user", "--unit", "x86sim-simview", "--collect", "-E", "DISPLAY=:0", "-E", "SIMFB_RING_LINUX=/dev/shm/x86sim-a64-simfb.ring", "-p"])
        .arg(format!("WorkingDirectory={}", repo_root().display()))
        .args(["/usr/bin/python3", "cli/libexec/simview.py"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()?;
    anyhow::ensure!(st.success(), "systemd-run simview failed");
    Ok(())
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct SimStatus {
    pub booted: bool,
    /// the booted device (None when stopped)
    pub device: Option<PathBuf>,
    pub home: bool,
    pub springboard_pid: Option<u32>,
    pub procs: usize,
    pub cpu_pct: f64,
    pub pss_mb: f64,
    pub pss_anon_mb: f64,
    pub simview: bool,
}

fn read(p: &str) -> String {
    std::fs::read_to_string(p).unwrap_or_default()
}

/// The sim's processes: the darlingserver of its prefix, all its descendants, and mtlvk.
pub fn sim_pids() -> Vec<(u32, String)> {
    let prefix = sim_prefix();
    let mut ppid: HashMap<u32, Vec<u32>> = HashMap::new();
    let mut comm: HashMap<u32, String> = HashMap::new();
    let mut root = None;
    let mut extra = vec![];
    for e in std::fs::read_dir("/proc").into_iter().flatten().flatten() {
        let Ok(pid) = e.file_name().to_string_lossy().parse::<u32>() else { continue };
        let c = read(&format!("/proc/{pid}/comm")).trim().to_string();
        let stat = read(&format!("/proc/{pid}/stat"));
        let pp = stat.rsplit(')').next().and_then(|r| r.split_whitespace().nth(1)).and_then(|x| x.parse().ok()).unwrap_or(0);
        ppid.entry(pp).or_default().push(pid);
        if c == "darlingserver" {
            let args = read(&format!("/proc/{pid}/cmdline"));
            if args.split('\0').nth(1) == Some(prefix.to_string_lossy().as_ref()) {
                root = Some(pid);
            }
        }
        if c == "mtlvk" {
            extra.push(pid);
        }
        comm.insert(pid, c);
    }
    let mut out = vec![];
    if let Some(r) = root {
        let mut work = vec![r];
        while let Some(p) = work.pop() {
            out.push((p, comm.get(&p).cloned().unwrap_or_default()));
            work.extend(ppid.get(&p).into_iter().flatten().copied());
        }
        out.extend(extra.into_iter().map(|p| (p, "mtlvk".to_string())));
    }
    out
}

fn cpu_ticks(pid: u32) -> u64 {
    let s = read(&format!("/proc/{pid}/stat"));
    let f: Vec<&str> = s.rsplit(')').next().unwrap_or("").split_whitespace().collect();
    f.get(11).and_then(|x| x.parse::<u64>().ok()).unwrap_or(0) + f.get(12).and_then(|x| x.parse::<u64>().ok()).unwrap_or(0)
}

/// Sim status; samples CPU over `sample_ms`.
pub fn status(sample_ms: u64) -> SimStatus {
    let pids = sim_pids();
    let mut st = SimStatus { simview: simview_running(), ..Default::default() };
    if pids.is_empty() {
        return st;
    }
    st.booted = pids.iter().any(|(_, c)| c == "launchd_sim");
    st.springboard_pid = pids.iter().find(|(_, c)| c == "SpringBoard").map(|p| p.0);
    st.procs = pids.len();
    let t0: u64 = pids.iter().map(|p| cpu_ticks(p.0)).sum();
    std::thread::sleep(std::time::Duration::from_millis(sample_ms));
    let t1: u64 = pids.iter().map(|p| cpu_ticks(p.0)).sum();
    let hz = unsafe { libc::sysconf(libc::_SC_CLK_TCK) }.max(1) as f64;
    st.cpu_pct = (t1.saturating_sub(t0)) as f64 / hz / (sample_ms as f64 / 1000.0) * 100.0;
    for (p, _) in &pids {
        for l in read(&format!("/proc/{p}/smaps_rollup")).lines() {
            let mut it = l.split_whitespace();
            match (it.next(), it.next().and_then(|v| v.parse::<f64>().ok())) {
                (Some("Pss:"), Some(v)) => st.pss_mb += v / 1024.0,
                (Some("Pss_Anon:"), Some(v)) => st.pss_anon_mb += v / 1024.0,
                _ => {}
            }
        }
    }
    // Home once seen stays true for that SpringBoard: an open app (a dark one fails the frame test) is still running.
    static HOME_SB: std::sync::Mutex<Option<u32>> = std::sync::Mutex::new(None);
    let mut seen = HOME_SB.lock().unwrap();
    st.home = match st.springboard_pid {
        Some(sb) if *seen == Some(sb) => true,
        Some(sb) if home_frame() => {
            *seen = Some(sb);
            true
        }
        _ => false,
    };
    if st.booted {
        st.device = booted_device();
    }
    st
}

/// framecheck's home test on the arm64 frame ring
pub fn home_frame() -> bool {
    Command::new("python3")
        .arg(repo_root().join("cli/libexec/framecheck.py"))
        .arg("/dev/shm/x86sim-a64-simfb.ring")
        .arg("home")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

/// Stop and start again, keeping the phone's GPU helper.
pub fn restart(device: &Path) -> Result<u32> {
    let inst = crate::instance::load(device);
    let all = crate::instance::list();
    let sts = crate::instance::Monitor::default().poll(&all);
    let st = sts.iter().find(|s| s.id == inst.id);
    let others: Vec<_> = sts.iter().filter(|s| s.id != inst.id).cloned().collect();
    crate::instance::restart(&inst, st, &others)
}
