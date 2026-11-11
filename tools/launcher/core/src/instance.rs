//! Instances: every var/device-a64* dir is a phone with its own Darling prefix, state dir and frame ring, so several
//! can run side by side. The default phone (var/device-a64) keeps the default dirs (a64prefix, var/run-a64, the
//! default ring: the standalone simview and the round scripts keep working); device-a64<sfx> gets a64prefix-<sfx>,
//! run-a64<sfx> and its own ring. A running instance is found by facts, never by patterns: its launchd_sim's
//! command line names the device dir; its tree, darlingserver ancestor and mtlvk make up the instance's processes.
use crate::aot::{repo_root, scratch};
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

#[derive(Debug, Clone, Serialize)]
pub struct Instance {
    /// folder name (device-a64-ios272)
    pub id: String,
    pub dir: PathBuf,
    /// the name given at creation (else the folder)
    pub name: String,
    /// "iPhone 17 Pro"
    pub model: String,
    pub model_id: String,
    /// runtimes/ dir name
    pub runtime_dir: String,
    pub runtime_root: PathBuf,
    /// the runtime's dyld cache is on disk (a 0-byte RuntimeRoot after a data loss is not)
    pub runtime_present: bool,
    /// "iOS 27.2" (Platforms 1: "tvOS 27.2", "watchOS 27.2")
    pub ios: String,
    /// Platforms 1: "ios", "tvos" or "watchos" (the runtime's, else the model's)
    pub platform: String,
    pub build: String,
    pub screen: (u32, u32),
    pub scale: f32,
    pub ring: PathBuf,
    /// Models 2: a second integrated screen (iPhone Duo's inner one), else None
    pub inner: Option<InnerDisplay>,
    pub sock: PathBuf,
    pub state_dir: PathBuf,
    pub prefix: PathBuf,
    pub log_dir: PathBuf,
    pub is_default: bool,
    pub udid: String,
    /// when the phone's folder was made (unix seconds; 0 if the file system doesn't record it)
    pub created: u64,
}

/// Models 2: the second integrated display of a two-screen model (iPhone Duo: "LCD-1", screenID 3, 2007x2853,
/// nativeRotation 270), as host/simfb publishes it: its own frame ring (<ring>-<id>.ring) and touchscreen (simhid
/// "@<id> touch ..."). SpringBoard shows it when the hinge is open (host/simhid "hinge"/"fold"/"unfold").
#[derive(Clone, Debug, Serialize)]
pub struct InnerDisplay {
    pub id: u32,
    /// framebuffer size (the panel's native orientation)
    pub size: (u32, u32),
    /// degrees the panel is mounted at (270: its framebuffer is shown turned a quarter clockwise)
    pub rotation: u32,
    pub ring: PathBuf,
}

impl InnerDisplay {
    /// the size as the user sees it (upright)
    pub fn upright(&self) -> (u32, u32) {
        if self.rotation % 180 == 90 { (self.size.1, self.size.0) } else { self.size }
    }
}

/// The second "integrated" display of the model's device type (cli/lib/devicetype-<model>.json), if any
pub fn inner_display(model_id: &str, ring: &Path) -> Option<InnerDisplay> {
    let txt = std::fs::read_to_string(repo_root().join("cli/lib").join(format!("devicetype-{}.json", model_id.to_lowercase()))).ok()?;
    let v: serde_json::Value = serde_json::from_str(&txt).ok()?;
    let d = v["capabilities"]["displays"].as_array()?.iter().filter(|d| d["displayType"] == "integrated").nth(1)?.clone();
    let id = d["screenID"].as_u64()? as u32;
    let r = ring.to_string_lossy();
    Some(InnerDisplay {
        id,
        size: (d["width"].as_u64()? as u32, d["height"].as_u64()? as u32),
        rotation: d["nativeRotation"].as_u64().unwrap_or(0) as u32,
        ring: PathBuf::from(format!("{}-{id}.ring", r.strip_suffix(".ring").unwrap_or(&r))),
    })
}

impl Instance {
    /// The hinge angle host/simhid last set (<device>/data/hinge: degrees, 0 folded .. 180 flat); None for a
    /// one-screen phone or before simhid wrote it (the phone boots folded)
    pub fn hinge(&self) -> Option<f64> {
        self.inner.as_ref()?;
        Some(std::fs::read_to_string(self.dir.join("data/hinge")).ok().and_then(|s| s.trim().parse().ok()).unwrap_or(0.0))
    }

    /// Whether the inner screen is the one in use: SpringBoard swaps displays at its 85 degree swap boundary
    pub fn inner_active(&self) -> bool {
        self.hinge().is_some_and(|a| a >= 85.0)
    }
}

fn env_of(dir: &Path) -> HashMap<String, String> {
    std::fs::read_to_string(dir.join("sim.env"))
        .unwrap_or_default()
        .lines()
        .filter_map(|l| l.split_once('=').map(|(k, v)| (k.to_string(), v.to_string())))
        .collect()
}

fn uid() -> u32 {
    unsafe { libc::getuid() }
}

/// The ring path this instance should publish frames to (unique per phone)
pub fn ring_for(id: &str) -> PathBuf {
    let tag = id.strip_prefix("device-").unwrap_or(id);
    PathBuf::from(format!("/run/user/{}/x86sim-{tag}-simfb.ring", uid()))
}

/// A name for a phone made without one: "" -> "Main phone", "-probe" -> "Probe", "b" -> "Phone B"
fn default_name(sfx: &str) -> String {
    let t = sfx.trim_start_matches('-').replace(['-', '_'], " ");
    let t = t.trim();
    if t.is_empty() {
        return "Main phone".into();
    }
    if t.len() <= 2 {
        return format!("Phone {}", t.to_uppercase());
    }
    let mut c = t.chars();
    c.next().map(|f| f.to_uppercase().collect::<String>() + c.as_str()).unwrap_or_default()
}

pub fn load(dir: &Path) -> Instance {
    let id = dir.file_name().unwrap_or_default().to_string_lossy().into_owned();
    let sfx = id.strip_prefix("device-a64").unwrap_or("");
    let is_default = sfx.is_empty();
    let env = env_of(dir);
    let name = std::fs::read_to_string(dir.join("name")).map(|s| s.trim().to_string()).ok().filter(|s| !s.is_empty()).unwrap_or_else(|| default_name(sfx));
    let model_id = env.get("SIMULATOR_MODEL_IDENTIFIER").cloned().unwrap_or_default();
    // <device>/model names the device type (device-a64.py create): models sharing an identifier (Apple TV 4K and its
    // "at 1080p" variant) are told apart by it
    let model_file = std::fs::read_to_string(dir.join("model")).map(|s| s.trim().to_string()).unwrap_or_default();
    let models = crate::sim::models();
    let model = models
        .iter()
        .find(|m| m.0 == model_file && m.1 == model_id)
        .or_else(|| models.iter().find(|m| m.1 == model_id))
        .map(|m| m.0.clone())
        .unwrap_or_else(|| if model_id.is_empty() { "iPhone".into() } else { model_id.clone() });
    let runtime_dir = std::fs::read_to_string(dir.join("runtime")).map(|s| s.trim().to_string()).ok().filter(|s| !s.is_empty()).unwrap_or_else(|| "ios-27.2-24B8117-arm64".into());
    let runtime_root = repo_root().join("runtimes").join(&runtime_dir).join("RuntimeRoot");
    let runtime_present = crate::dyldcache::Cache::cache_dir(&runtime_root).join(crate::dyldcache::CACHE_NAME).exists();
    let (ios, build, platform) = match crate::sim::parse_runtime_dir(&runtime_dir) {
        Some((p, v, b)) => (format!("{} {v}", crate::sim::platform_name(p)), b, p.to_string()),
        None => (runtime_dir.clone(), String::new(), crate::sim::model_platform(&model_id).to_string()),
    };
    let w = env.get("SIMULATOR_MAINSCREEN_WIDTH").and_then(|v| v.parse().ok()).unwrap_or(1206);
    let h = env.get("SIMULATOR_MAINSCREEN_HEIGHT").and_then(|v| v.parse().ok()).unwrap_or(2622);
    let scale = env.get("SIMULATOR_MAINSCREEN_SCALE").and_then(|v| v.parse().ok()).unwrap_or(3.0);
    // always the per-phone ring (sim.env may hold a ring copied from another phone; passing it on at start
    // kept that phone drawing into the other one's ring)
    let ring = ring_for(&id);
    let inner = inner_display(&model_id, &ring);
    let prefix_sfx = if is_default { String::new() } else if sfx.starts_with('-') { sfx.to_string() } else { format!("-{sfx}") };
    Instance {
        sock: dir.join("data/simhid.sock"),
        log_dir: dir.join("data/var/log"),
        state_dir: repo_root().join("var").join(format!("run-a64{sfx}")),
        prefix: scratch().join(format!("a64prefix{prefix_sfx}")),
        udid: env.get("SIMULATOR_UDID").cloned().unwrap_or_default(),
        id,
        dir: dir.to_path_buf(),
        name,
        model,
        model_id,
        runtime_dir,
        runtime_root,
        runtime_present,
        ios,
        build,
        platform,
        screen: (w, h),
        scale,
        ring,
        inner,
        is_default,
        created: std::fs::metadata(dir)
            .and_then(|m| m.created())
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_secs())
            .unwrap_or(0),
    }
}

/// Puts phones in a hub sort order ("name" | "newest" | "oldest" | "model": newest model first | "ios": newest iOS
/// first); ties by name.
pub fn sort(v: &mut [Instance], by: &str) {
    let models = crate::sim::models();
    let model_rank = |i: &Instance| models.iter().position(|m| m.1 == i.model_id && m.0 == i.model).or_else(|| models.iter().position(|m| m.1 == i.model_id)).unwrap_or(usize::MAX);
    // version numbers, whatever the platform ("tvOS 27.2"); a platform's devices together (iOS, tvOS, watchOS)
    let ios = |i: &Instance| -> (std::cmp::Reverse<usize>, Vec<u32>) {
        let rank = crate::sim::PLATFORMS.iter().position(|p| *p == i.platform).unwrap_or(0);
        (std::cmp::Reverse(rank), i.ios.rsplit(' ').next().unwrap_or("").split('.').map(|n| n.parse().unwrap_or(0)).collect())
    };
    let name = |a: &Instance, b: &Instance| a.name.to_lowercase().cmp(&b.name.to_lowercase());
    v.sort_by(|a, b| {
        match by {
            "newest" => b.created.cmp(&a.created),
            "oldest" => a.created.cmp(&b.created),
            "model" => model_rank(a).cmp(&model_rank(b)),
            "ios" => ios(b).cmp(&ios(a)),
            _ => std::cmp::Ordering::Equal,
        }
        .then_with(|| name(a, b))
    });
}

pub fn list() -> Vec<Instance> {
    let mut v: Vec<Instance> = crate::sim::devices().into_iter().map(|d| load(&d.1)).collect();
    v.sort_by(|a, b| b.is_default.cmp(&a.is_default).then(a.name.to_lowercase().cmp(&b.name.to_lowercase())));
    v
}

/// A phone by folder (device-a64-qa), name ("QA", any case) or path.
pub fn find(key: &str) -> Option<Instance> {
    let k = key.trim();
    let all = list();
    let p = Path::new(k);
    if p.is_absolute() || k.contains('/') {
        let want = std::fs::canonicalize(p).unwrap_or_else(|_| p.to_path_buf());
        return all.into_iter().find(|i| std::fs::canonicalize(&i.dir).unwrap_or_else(|_| i.dir.clone()) == want);
    }
    all.iter()
        .find(|i| i.id == k)
        .or_else(|| all.iter().find(|i| i.name.eq_ignore_ascii_case(k)))
        .or_else(|| all.iter().find(|i| i.id.strip_prefix("device-a64-").is_some_and(|s| s.eq_ignore_ascii_case(k))))
        .cloned()
}

/// One line per phone for tools: what the hub shows on a card.
#[derive(Debug, Clone, Serialize)]
pub struct Summary {
    pub id: String,
    pub name: String,
    pub model: String,
    pub ios: String,
    pub installed: bool,
    /// "off" | "starting" | "running" | "stopping"
    pub state: String,
    pub home: bool,
    pub memory_mb: f64,
    pub cpu_pct: f64,
    pub processes: usize,
    pub uptime_s: Option<f64>,
    pub path: PathBuf,
}

/// Every phone's state; samples CPU over `sample_ms` (0: memory and state only).
pub fn summaries(sample_ms: u64) -> Vec<Summary> {
    let insts = list();
    let mut m = Monitor::default();
    let mut st = m.poll(&insts);
    if sample_ms > 0 {
        std::thread::sleep(std::time::Duration::from_millis(sample_ms));
        st = m.poll(&insts);
    }
    insts
        .iter()
        .zip(st)
        .map(|(i, s)| Summary {
            id: i.id.clone(),
            name: i.name.clone(),
            model: i.model.clone(),
            ios: i.ios.clone(),
            installed: i.runtime_present,
            state: format!("{:?}", s.phase).to_lowercase(),
            home: s.home,
            memory_mb: (s.pss_mb * 10.0).round() / 10.0,
            cpu_pct: s.cpu_pct.round(),
            processes: s.procs.len(),
            uptime_s: s.uptime_s.map(|u| u.round()),
            path: i.dir.clone(),
        })
        .collect()
}

/// Per-phone launcher settings (<device>/launcher.json): how it boots.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct BootSettings {
    /// X86SIM_METAL: all | backboardd | 0
    pub metal: String,
    /// X86SIM_MEM_MAX
    pub mem_max: String,
    /// A64_JOBS: std | full | slim | min
    pub jobs: String,
    /// A64_ENV extra K=V for launchd_sim
    pub extra_env: String,
    /// share one mtlvk between phones when one is up
    pub share_mtlvk: bool,
    /// the launcher's screen when drawn smaller than the phone: smooth (averaged) | sharp (every nth pixel) | full
    /// (the whole frame, scaled by the GPU). Applies at once, not at the next start.
    pub scaling: String,
}

impl Default for BootSettings {
    fn default() -> Self {
        BootSettings { metal: "all".into(), mem_max: "12G".into(), jobs: "std".into(), extra_env: String::new(), share_mtlvk: true, scaling: "smooth".into() }
    }
}

pub fn settings_path(dir: &Path) -> PathBuf {
    dir.join("launcher.json")
}

pub fn load_settings(dir: &Path) -> BootSettings {
    std::fs::read(settings_path(dir)).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
}

pub fn save_settings(dir: &Path, s: &BootSettings) -> Result<()> {
    crate::aot::write_json(&settings_path(dir), s)
}

// ---- processes ----

#[derive(Debug, Clone, Default, Serialize)]
pub struct Proc {
    pub pid: u32,
    pub comm: String,
    pub cpu_pct: f64,
    pub pss_mb: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub enum Phase {
    Off,
    Starting,
    Running,
    Stopping,
}

#[derive(Debug, Clone, Serialize)]
pub struct Status {
    pub id: String,
    pub phase: Phase,
    pub home: bool,
    pub procs: Vec<Proc>,
    pub cpu_pct: f64,
    pub pss_mb: f64,
    /// seconds since launchd_sim started
    pub uptime_s: Option<f64>,
    /// the boot's launchd_sim start (unix seconds): frames older than it are another session's
    pub boot_time: Option<f64>,
    /// the dirs this boot really uses (a phone booted by hand with the default dirs)
    pub state_dir: PathBuf,
    pub prefix: PathBuf,
    pub mtlvk: bool,
    pub launchd_pid: Option<u32>,
    /// this phone has never reached its home screen (no <device>/.home-reached): a fresh device's first boot can stall
    /// on LaunchServices; the second boot works
    pub fresh: bool,
}

pub fn home_marker(dir: &Path) -> PathBuf {
    dir.join(".home-reached")
}

/// A fresh phone's first boot that sits idle without reaching home: restart it once.
pub fn first_boot_stalled(st: &Status) -> bool {
    st.fresh && st.phase == Phase::Starting && st.launchd_pid.is_some() && st.uptime_s.is_some_and(|u| u > 150.0) && st.cpu_pct < 30.0
}

fn read(p: &str) -> String {
    std::fs::read_to_string(p).unwrap_or_default()
}

struct ProcRow {
    comm: String,
    ppid: u32,
    cmd: String,
    ticks: u64,
    start_ticks: u64,
}

fn scan() -> HashMap<u32, ProcRow> {
    let mut m = HashMap::new();
    for e in std::fs::read_dir("/proc").into_iter().flatten().flatten() {
        let Ok(pid) = e.file_name().to_string_lossy().parse::<u32>() else { continue };
        let stat = read(&format!("/proc/{pid}/stat"));
        let Some(rest) = stat.rsplit(')').next() else { continue };
        let f: Vec<&str> = rest.split_whitespace().collect();
        let ppid = f.get(1).and_then(|x| x.parse().ok()).unwrap_or(0);
        let ticks = f.get(11).and_then(|x| x.parse::<u64>().ok()).unwrap_or(0) + f.get(12).and_then(|x| x.parse::<u64>().ok()).unwrap_or(0);
        let start_ticks = f.get(19).and_then(|x| x.parse::<u64>().ok()).unwrap_or(0);
        let comm = stat.split_once('(').and_then(|(_, r)| r.rsplit_once(')')).map(|(c, _)| c.to_string()).unwrap_or_default();
        let cmd = if matches!(comm.as_str(), "launchd_sim" | "darlingserver" | "mtlvk" | "boot-a64.sh") { read(&format!("/proc/{pid}/cmdline")).replace('\0', " ") } else { String::new() };
        m.insert(pid, ProcRow { comm, ppid, cmd, ticks, start_ticks });
    }
    m
}

fn btime() -> f64 {
    read("/proc/stat").lines().find_map(|l| l.strip_prefix("btime ")).and_then(|v| v.trim().parse().ok()).unwrap_or(0.0)
}

fn pss_mb(pid: u32) -> f64 {
    for l in read(&format!("/proc/{pid}/smaps_rollup")).lines() {
        if let Some(v) = l.strip_prefix("Pss:") {
            return v.trim().trim_end_matches("kB").trim().parse::<f64>().unwrap_or(0.0) / 1024.0;
        }
    }
    0.0
}

const PSS_EVERY: std::time::Duration = std::time::Duration::from_secs(12);

/// Samples CPU between calls (keeps the last ticks per pid).
#[derive(Default)]
pub struct Monitor {
    last: HashMap<u32, (u64, std::time::Instant)>,
    /// PSS per pid and when it was read: smaps_rollup walks every mapping (~1-10 ms for a phone process, ~130 ms for
    /// two phones), so it is re-read every PSS_EVERY while CPU is sampled every poll
    pss: HashMap<u32, (f64, std::time::Instant)>,
    home_seen: HashMap<String, u32>,
    pub stopping: HashMap<String, std::time::Instant>,
    pub starting: HashMap<String, std::time::Instant>,
}

impl Monitor {
    pub fn poll(&mut self, insts: &[Instance]) -> Vec<Status> {
        let procs = scan();
        let now = std::time::Instant::now();
        let hz = unsafe { libc::sysconf(libc::_SC_CLK_TCK) }.max(1) as f64;
        let bt = btime();
        let mut children: HashMap<u32, Vec<u32>> = HashMap::new();
        for (pid, r) in &procs {
            children.entry(r.ppid).or_default().push(*pid);
        }
        let mut out = vec![];
        let mut seen_pids = std::collections::HashSet::new();
        for inst in insts {
            let marker = format!("/Volumes/SystemRoot{}/data/var/run/launchd_bootstrap.plist", inst.dir.display());
            let launchd = procs.iter().find(|(_, r)| r.comm == "launchd_sim" && r.cmd.contains(&marker)).map(|(p, _)| *p);
            let mut pids = vec![];
            let mut prefix = inst.prefix.clone();
            if let Some(l) = launchd {
                let mut work = vec![l];
                while let Some(p) = work.pop() {
                    pids.push(p);
                    work.extend(children.get(&p).into_iter().flatten().copied());
                }
                // ancestors up to the darlingserver of this prefix
                let mut p = procs.get(&l).map(|r| r.ppid).unwrap_or(0);
                while p > 1 {
                    let Some(r) = procs.get(&p) else { break };
                    pids.push(p);
                    if r.comm == "darlingserver" {
                        if let Some(pre) = r.cmd.split_whitespace().nth(1) {
                            prefix = PathBuf::from(pre);
                        }
                        break;
                    }
                    p = r.ppid;
                }
            }
            // which state dir this boot uses: the one whose `device` file names this phone
            let mut state_dir = inst.state_dir.clone();
            if read(&format!("{}/device", state_dir.display())).trim() != inst.dir.to_string_lossy() {
                let def = repo_root().join("var/run-a64");
                if read(&format!("{}/device", def.display())).trim() == inst.dir.to_string_lossy() {
                    state_dir = def;
                }
            }
            let mtlvk_pid: Option<u32> = read(&format!("{}/mtlvk.pid", state_dir.display())).trim().parse().ok();
            let mtlvk = mtlvk_pid.is_some_and(|p| procs.get(&p).is_some_and(|r| r.comm == "mtlvk"));
            if launchd.is_some() {
                if let Some(p) = mtlvk_pid.filter(|_| mtlvk) {
                    pids.push(p);
                }
            }
            let booting = procs.values().any(|r| r.comm == "boot-a64.sh" && !r.cmd.is_empty() && {
                // few bash processes: reading their environ is cheap
                let pid = procs.iter().find(|(_, x)| std::ptr::eq(*x, r)).map(|(p, _)| *p).unwrap_or(0);
                read(&format!("/proc/{pid}/environ")).split('\0').any(|kv| kv == format!("A64_DEVICE={}", inst.dir.display()))
            });
            let mut plist = vec![];
            let (mut cpu, mut pss) = (0.0, 0.0);
            for p in &pids {
                if !seen_pids.insert(*p) {
                    continue;
                }
                let Some(r) = procs.get(p) else { continue };
                let c = match self.last.get(p) {
                    Some((t0, at)) if r.ticks >= *t0 => (r.ticks - t0) as f64 / hz / now.duration_since(*at).as_secs_f64().max(0.05) * 100.0,
                    _ => 0.0,
                };
                self.last.insert(*p, (r.ticks, now));
                let m = match self.pss.get(p) {
                    Some((v, at)) if now.duration_since(*at) < PSS_EVERY => *v,
                    _ => {
                        let v = pss_mb(*p);
                        self.pss.insert(*p, (v, now));
                        v
                    }
                };
                cpu += c;
                pss += m;
                plist.push(Proc { pid: *p, comm: r.comm.clone(), cpu_pct: c, pss_mb: m });
            }
            plist.sort_by(|a, b| b.pss_mb.partial_cmp(&a.pss_mb).unwrap_or(std::cmp::Ordering::Equal));
            let boot_time = launchd.and_then(|l| procs.get(&l)).map(|r| bt + r.start_ticks as f64 / hz);
            let uptime_s = boot_time.map(|b| (std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0) - b).max(0.0));
            let home = match launchd {
                Some(l) if self.home_seen.get(&inst.id) == Some(&l) => true,
                Some(l) => {
                    let ok = crate::ring::Ring::new(&inst.ring).home_frame(boot_time.unwrap_or(0.0) - 2.0);
                    if ok {
                        self.home_seen.insert(inst.id.clone(), l);
                        let m = home_marker(&inst.dir);
                        if !m.exists() {
                            let _ = std::fs::write(m, "");
                        }
                    }
                    ok
                }
                None => false,
            };
            let stopping = self.stopping.get(&inst.id).is_some_and(|t| t.elapsed().as_secs() < 60);
            let starting_hint = self.starting.get(&inst.id).is_some_and(|t| t.elapsed().as_secs() < 240);
            let phase = if stopping && (launchd.is_some() || booting) {
                Phase::Stopping
            } else if launchd.is_some() {
                self.stopping.remove(&inst.id);
                self.starting.remove(&inst.id);
                if home { Phase::Running } else { Phase::Starting }
            } else if booting || starting_hint {
                Phase::Starting
            } else {
                self.stopping.remove(&inst.id);
                Phase::Off
            };
            out.push(Status { id: inst.id.clone(), phase, home, procs: plist, cpu_pct: cpu, pss_mb: pss, uptime_s, boot_time, state_dir, prefix, mtlvk, launchd_pid: launchd, fresh: !home_marker(&inst.dir).exists() });
        }
        self.last.retain(|p, _| seen_pids.contains(p));
        self.pss.retain(|p, _| seen_pids.contains(p));
        out
    }
}

// ---- start / stop ----

fn boot_script() -> PathBuf {
    repo_root().join("cli/libexec/arm64/boot-a64.sh")
}

pub fn boot_log(inst: &Instance) -> PathBuf {
    scratch().join(format!("launcher-boot-{}.log", inst.id))
}

/// A live mtlvk socket to share: this phone's own (a restart keeps it), else a running phone's, else one an off phone
/// left up because others still render through it (its lifetime is its clients', see `stop_gpu_helpers`).
fn shared_mtlvk(inst: &Instance, others: &[Status]) -> Option<PathBuf> {
    let live = |st: &Path| -> Option<PathBuf> {
        let pid: u32 = read(&format!("{}/mtlvk.pid", st.display())).trim().parse().ok()?;
        let comm = read(&format!("/proc/{pid}/comm"));
        let sock = st.join("mtlvk.sock");
        (comm.trim() == "mtlvk" && sock.exists()).then_some(sock)
    };
    if let Some(s) = live(&inst.state_dir) {
        return Some(s);
    }
    let others = || others.iter().filter(|s| s.id != inst.id);
    others().filter(|s| s.phase != Phase::Off).find_map(|s| live(&s.state_dir)).or_else(|| others().find_map(|s| live(&s.state_dir)))
}

/// Boots a phone in its own prefix / state dir / ring. `others`: the current statuses (to share a running mtlvk).
pub fn start(inst: &Instance, others: &[Status]) -> Result<u32> {
    anyhow::ensure!(inst.runtime_present, "{} is not downloaded", inst.ios);
    let s = load_settings(&inst.dir);
    let log = std::fs::File::create(boot_log(inst))?;
    let mut cmd = Command::new("setsid");
    cmd.arg(boot_script())
        .current_dir(repo_root())
        .env("A64_KEEP", "1")
        .env("X86SIM_METAL", &s.metal)
        .env("X86SIM_MEM_MAX", &s.mem_max)
        .env("A64_JOBS", &s.jobs)
        .env("SECS", "20")
        .env("A64_DEVICE", &inst.dir)
        .env("A64_STATE", &inst.state_dir)
        .env("A64_DPREFIX", &inst.prefix)
        .env_remove("A64_RUNTIME")
        .env_remove("X86SIM_A64_JITCACHE_DIR")
        .stdin(Stdio::null())
        .stdout(log.try_clone()?)
        .stderr(log);
    if !s.extra_env.trim().is_empty() {
        cmd.env("A64_ENV", s.extra_env.trim());
    }
    if !inst.is_default {
        let ring = ring_for(&inst.id);
        cmd.env("SIMFB_RING", format!("/Volumes/SystemRoot{}", ring.display()));
        cmd.env("SIMFB_RING_LINUX", format!("/dev/shm/{}", ring.file_name().unwrap_or_default().to_string_lossy()));
    }
    if s.share_mtlvk && s.metal != "0" {
        if let Some(sock) = shared_mtlvk(inst, others) {
            cmd.env("A64_MTLVK_SOCKET", sock);
        }
    }
    Ok(cmd.spawn().context("starting boot-a64.sh")?.id())
}

/// Stops a phone: its container, then every GPU helper (mtlvk) no running phone uses any more: its own, unless another
/// phone shares it, and the one it shared if it was that one's last client (an mtlvk lives as long as its clients,
/// whichever phone started it). boot-a64.sh's A64_STOP_ONLY stops the container only, so every Stop left a ~370 MB
/// mtlvk behind. A restart keeps it (`restart`).
pub fn stop(inst: &Instance, st: Option<&Status>) -> Result<()> {
    let state_dir = st.map(|s| s.state_dir.clone()).unwrap_or_else(|| inst.state_dir.clone());
    stop_container(inst, st)?;
    stop_gpu_helper(&state_dir);
    stop_gpu_helpers();
    Ok(())
}

/// Ends the mtlvks of all phones' state dirs that no running container uses, sparing one started in the last 2 min (a
/// boot starts mtlvk before its container, whose darlingserver is what names the socket).
pub fn stop_gpu_helpers() {
    for i in list() {
        let Ok(pid) = read(&format!("{}/mtlvk.pid", i.state_dir.display())).trim().parse::<u32>() else { continue };
        if proc_age_s(pid).is_some_and(|a| a >= 120.0) {
            stop_gpu_helper(&i.state_dir);
        }
    }
}

/// Seconds since a process started (/proc/<pid>/stat field 22, in clock ticks since boot).
fn proc_age_s(pid: u32) -> Option<f64> {
    let stat = read(&format!("/proc/{pid}/stat"));
    let start: f64 = stat.rsplit(')').next()?.split_whitespace().nth(19)?.parse().ok()?;
    let up: f64 = read("/proc/uptime").split_whitespace().next()?.parse().ok()?;
    // SAFETY: plain libc call.
    let hz = unsafe { libc::sysconf(libc::_SC_CLK_TCK) } as f64;
    Some(up - start / hz)
}

/// Stop, then start with the same GPU helper (it stays up across the restart).
pub fn restart(inst: &Instance, st: Option<&Status>, others: &[Status]) -> Result<u32> {
    stop_container(inst, st)?;
    start(inst, others)
}

/// Ends the mtlvk a boot started in `state_dir` if no running container uses its socket (a darlingserver's
/// environment names the socket its phone renders through).
pub fn stop_gpu_helper(state_dir: &Path) {
    let Ok(pid) = read(&format!("{}/mtlvk.pid", state_dir.display())).trim().parse::<u32>() else { return };
    if read(&format!("/proc/{pid}/comm")).trim() != "mtlvk" {
        return;
    }
    let sock = state_dir.join("mtlvk.sock");
    let want = format!("X86SIM_MTLVK_SOCKET={}", sock.display());
    let used = std::fs::read_dir("/proc").into_iter().flatten().flatten().any(|e| {
        let p = e.path();
        read(&format!("{}/comm", p.display())).trim() == "darlingserver" && read(&format!("{}/environ", p.display())).split('\0').any(|kv| kv == want)
    });
    if used {
        return;
    }
    unsafe {
        libc::kill(pid as i32, libc::SIGTERM);
    }
    for _ in 0..20 {
        if read(&format!("/proc/{pid}/comm")).trim() != "mtlvk" {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    if read(&format!("/proc/{pid}/comm")).trim() == "mtlvk" {
        unsafe {
            libc::kill(pid as i32, libc::SIGKILL);
        }
    }
    let _ = std::fs::remove_file(state_dir.join("mtlvk.pid"));
    let _ = std::fs::remove_file(sock);
}

/// Stops a phone's container only (the dirs the running boot really uses, from its status).
fn stop_container(inst: &Instance, st: Option<&Status>) -> Result<()> {
    let state_dir = st.map(|s| s.state_dir.clone()).unwrap_or_else(|| inst.state_dir.clone());
    let prefix = st.map(|s| s.prefix.clone()).unwrap_or_else(|| inst.prefix.clone());
    let out = Command::new(boot_script())
        .current_dir(repo_root())
        .env("A64_STOP_ONLY", "1")
        .env("A64_KEEP_MTLVK", "1")
        .env("A64_DEVICE", &inst.dir)
        .env("A64_STATE", &state_dir)
        .env("A64_DPREFIX", &prefix)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .output()?;
    anyhow::ensure!(out.status.success(), "stop failed: {}", String::from_utf8_lossy(&out.stderr).trim());
    Ok(())
}

/// Log sources of a phone: its job logs, the per-process translator logs of its prefix, the boot's state files.
pub fn log_sources(inst: &Instance, st: Option<&Status>) -> Vec<crate::logs::Src> {
    use crate::logs::Src;
    let (state_dir, prefix) = match st {
        Some(s) => (s.state_dir.clone(), s.prefix.clone()),
        None => (inst.state_dir.clone(), inst.prefix.clone()),
    };
    vec![
        Src::Dir("System", inst.log_dir.clone()),
        Src::Dir("Translator", prefix.join("private/var/tmp/x86sim-a64")),
        Src::File("Boot", "start", boot_log(inst)),
        Src::File("Boot", "launchd_sim", state_dir.join("lsim.out")),
        Src::File("Boot", "launchd", state_dir.join("launchd.log")),
        Src::File("Boot", "pre-translate", state_dir.join("aot-status.txt")),
        Src::File("Graphics", "mtlvk", state_dir.join("mtlvk.log")),
        Src::File("Memory", "jetsam", state_dir.join("jetsam.log")),
    ]
}

// ---- rename / delete ----

/// Gives a phone a new display name (<device>/name).
pub fn rename(inst: &Instance, name: &str) -> Result<()> {
    let n = name.trim();
    anyhow::ensure!(!n.is_empty(), "the name is empty");
    anyhow::ensure!(n.chars().count() <= 60, "the name is too long");
    std::fs::write(inst.dir.join("name"), format!("{n}\n"))?;
    Ok(())
}

fn darlingserver_uses(prefix: &Path) -> bool {
    let want = prefix.to_string_lossy();
    std::fs::read_dir("/proc").into_iter().flatten().flatten().any(|e| {
        let p = e.path();
        read(&format!("{}/comm", p.display())).trim() == "darlingserver" && read(&format!("{}/cmdline", p.display())).split('\0').nth(1) == Some(want.as_ref())
    })
}

/// What `delete` removes (for the confirmation and the MCP/CLI): the device dir and, when they are this phone's own,
/// its Darling prefix, state dir, frame ring and boot log.
pub fn delete_plan(inst: &Instance) -> Vec<PathBuf> {
    let mut v = vec![inst.dir.clone()];
    let sfx = inst.id.strip_prefix("device-a64").unwrap_or("");
    if inst.is_default || sfx.is_empty() {
        return v;
    }
    let own_prefix = scratch().join(format!("a64prefix{}", if sfx.starts_with('-') { sfx.to_string() } else { format!("-{sfx}") }));
    if inst.prefix == own_prefix && inst.prefix.exists() {
        v.push(inst.prefix.clone());
    }
    let own_state = repo_root().join("var").join(format!("run-a64{sfx}"));
    if inst.state_dir == own_state && inst.state_dir.exists() {
        v.push(inst.state_dir.clone());
    }
    let ring = ring_for(&inst.id);
    if ring.exists() {
        v.push(ring.clone());
    }
    let link = PathBuf::from("/dev/shm").join(ring.file_name().unwrap_or_default());
    if link.symlink_metadata().is_ok() {
        v.push(link);
    }
    if boot_log(inst).exists() {
        v.push(boot_log(inst));
    }
    v
}

/// Removes a phone that is off. The default phone (its dirs are the scripts' defaults) is never removed, nor a dir a
/// running container uses.
pub fn delete(inst: &Instance, st: Option<&Status>) -> Result<()> {
    anyhow::ensure!(!inst.is_default, "the main phone can't be removed");
    anyhow::ensure!(st.is_none_or(|s| s.phase == Phase::Off && s.launchd_pid.is_none()), "stop {} first", inst.name);
    anyhow::ensure!(inst.dir.starts_with(repo_root().join("var")) && inst.id.starts_with("device-a64") && inst.id != "device-a64", "not a phone dir: {}", inst.dir.display());
    let plan = delete_plan(inst);
    for p in &plan {
        anyhow::ensure!(!(p.is_dir() && p.file_name().is_some_and(|n| n.to_string_lossy().starts_with("a64prefix")) && darlingserver_uses(p)), "{} is in use", p.display());
    }
    // the state dir's `device` file must name this phone (another boot may have borrowed it)
    for p in &plan {
        if p.file_name().is_some_and(|n| n.to_string_lossy().starts_with("run-a64")) {
            let dev = read(&format!("{}/device", p.display()));
            anyhow::ensure!(dev.trim().is_empty() || dev.trim() == inst.dir.to_string_lossy(), "{} belongs to {}", p.display(), dev.trim());
        }
    }
    for p in &plan {
        let r = if p.symlink_metadata().is_ok_and(|m| m.is_dir()) { std::fs::remove_dir_all(p) } else { std::fs::remove_file(p) };
        r.with_context(|| format!("removing {}", p.display()))?;
    }
    Ok(())
}

/// Feature or boot settings changed after this boot started (by the hub, the CLI or the MCP server): a restart
/// applies them.
pub fn needs_restart(inst: &Instance, st: Option<&Status>) -> bool {
    let Some(boot) = st.filter(|s| s.phase != Phase::Off).and_then(|s| s.boot_time) else { return false };
    let mtime = |p: PathBuf| std::fs::metadata(p).and_then(|m| m.modified()).ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map(|d| d.as_secs_f64());
    [crate::features::profile_path(&inst.dir), settings_path(&inst.dir)].into_iter().filter_map(mtime).any(|t| t > boot + 1.0)
}

#[cfg(test)]
mod models2_tests {
    #[test]
    fn duo_inner_display() {
        let d = super::inner_display("iPhone19,4", std::path::Path::new("/run/user/1/x86sim-a64-d-simfb.ring")).expect("Duo has an inner screen");
        assert_eq!((d.id, d.size, d.rotation, d.upright()), (3, (2007, 2853), 270, (2853, 2007)));
        assert_eq!(d.ring, std::path::PathBuf::from("/run/user/1/x86sim-a64-d-simfb-3.ring"));
        assert!(super::inner_display("iPhone18,3", std::path::Path::new("/x.ring")).is_none());
    }
}
