//! Global pages: iOS versions (downloaded / available), Pre-translate (the AOT image per iOS version), Settings and
//! host status.
use crate::theme::*;
use crate::App;
use eframe::egui;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use x86sim_core::{aot, host, sim};

#[derive(Default)]
pub struct AotShared {
    status: Option<Result<aot::Status, String>>,
    busy: bool,
}

pub struct Aot {
    pub runtime_root: Option<PathBuf>,
    pub device: Option<PathBuf>,
    pub jc: PathBuf,
    pub paths: aot::Paths,
    pub cfg: aot::Config,
    pub shared: Arc<Mutex<AotShared>>,
    pub child: Option<Child>,
    pub progress: Option<aot::Progress>,
    pub last_poll: Instant,
    pub cores: usize,
    pub max_cores: usize,
    pub filter: String,
    pub only_attention: bool,
    pub message: String,
    /// pid of the run whose failure `message` reports: a later successful run (ours or another's) clears it
    pub message_pid: Option<u32>,
    /// "Redo all" asked for confirmation
    pub confirm_redo: bool,
    /// Automatic update: when to look (after a phone stops, and at start) whether phones translated code the image
    /// lacks (their .live feedback); `auto_check`: a fresh status was asked for and is awaited
    pub auto_at: Option<Instant>,
    auto_check: bool,
    /// set each frame by the app: no new image goes in while a phone runs (it waits for the last one to stop)
    pub phones_running: bool,
}

impl Aot {
    pub fn new(rt: Option<PathBuf>) -> Aot {
        let jc = rt.as_deref().map(sim::jc_for).unwrap_or_else(aot::Paths::default_jc);
        let paths = aot::Paths::new(&jc);
        let cfg = paths.load_config();
        let max_cores = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(2);
        let a = Aot {
            runtime_root: rt,
            device: cfg.device.clone(),
            jc,
            paths,
            cfg,
            shared: Arc::new(Mutex::new(AotShared::default())),
            child: None,
            progress: None,
            last_poll: Instant::now() - Duration::from_secs(60),
            cores: (max_cores / 2).max(1),
            max_cores,
            filter: String::new(),
            only_attention: true,
            message: String::new(),
            message_pid: None,
            confirm_redo: false,
            auto_at: Some(Instant::now() + Duration::from_secs(20)),
            auto_check: false,
            phones_running: false,
        };
        if a.runtime_root.is_some() {
            a.refresh();
        }
        a
    }

    pub fn select(&mut self, rt: PathBuf, device: Option<PathBuf>) {
        self.jc = sim::jc_for(&rt);
        self.paths = aot::Paths::new(&self.jc);
        self.cfg = self.paths.load_config();
        if device.is_some() {
            self.device = device;
        } else if self.cfg.device.as_ref().is_some_and(|d| sim::device_runtime(d) == rt) {
            self.device = self.cfg.device.clone();
        } else {
            self.device = sim::devices().into_iter().map(|d| d.1).find(|d| sim::device_runtime(d) == rt);
        }
        self.runtime_root = Some(rt);
        self.progress = None;
        self.refresh();
    }

    fn effective_cfg(&self) -> aot::Config {
        let mut c = self.cfg.clone();
        if let Some(r) = &self.runtime_root {
            c.runtime_root = r.clone();
        }
        c.device = self.device.clone();
        c
    }

    pub fn refresh(&self) {
        let sh = self.shared.clone();
        if sh.lock().unwrap().busy {
            return;
        }
        sh.lock().unwrap().busy = true;
        let (paths, cfg) = (aot::Paths::new(&self.jc), self.effective_cfg());
        std::thread::spawn(move || {
            let r = aot::plan(&paths, &cfg).map(|p| p.status(&paths)).map_err(|e| format!("{e:#}"));
            let mut g = sh.lock().unwrap();
            g.status = Some(r);
            g.busy = false;
        });
    }

    /// A run of ours, or one started elsewhere (x86sim-aot, the MCP server) that is still alive.
    pub fn building(&self) -> bool {
        self.child.is_some() || self.external_run().is_some()
    }

    /// The pid of a live run this window didn't start (from progress.json).
    pub fn external_run(&self) -> Option<u32> {
        let p = self.progress.as_ref()?;
        (self.child.is_none() && matches!(p.state.as_str(), "planning" | "building" | "assembling") && aot_alive(p.pid) && pid_is_aot(p.pid)).then_some(p.pid)
    }

    /// Fold what phones translated themselves into the image soon (it is swapped in by a rename: running phones keep
    /// the one they mapped, the next start of an app gets the new one).
    pub fn want_auto(&mut self, after: Duration) {
        self.auto_at = Some(Instant::now() + after);
    }

    fn auto_tick(&mut self) {
        if self.auto_at.is_some_and(|t| Instant::now() >= t) && self.runtime_root.is_some() && !self.building() && !self.phones_running {
            self.auto_at = None;
            self.auto_check = true;
            self.refresh();
            return;
        }
        if !self.auto_check || self.shared.lock().unwrap().busy {
            return;
        }
        self.auto_check = false;
        let st = self.shared.lock().unwrap().status.clone();
        // only once there is an image (Setup or the Pre-translate page made one) and something to add to it
        if let Some(Ok(s)) = st {
            if s.image_present && s.stale + s.missing > 0 && !self.building() && !self.phones_running {
                self.start_build(false);
            }
        }
    }

    pub fn tick(&mut self) {
        self.auto_tick();
        if let Some(c) = &mut self.child {
            if let Ok(Some(code)) = c.try_wait() {
                let pid = c.id();
                self.child = None;
                if !code.success() {
                    // the builder's own words (x86sim-aot: …), not just "failed"
                    let log = std::fs::read_to_string(aot::scratch().join("launcher-aot.log")).unwrap_or_default();
                    let last = log.lines().rev().find(|l| !l.trim().is_empty()).unwrap_or("").trim();
                    let last = last.strip_prefix("x86sim-aot: ").unwrap_or(last);
                    self.message = if last.is_empty() { format!("The run stopped ({code})") } else { last.to_string() };
                    self.message_pid = Some(pid);
                } else {
                    self.message.clear();
                    self.message_pid = None;
                }
                self.last_poll = Instant::now() - Duration::from_secs(1);
                self.progress = std::fs::read(self.paths.progress()).ok().and_then(|b| serde_json::from_slice(&b).ok());
                self.refresh();
            }
        }
        // progress.json: twice a second while a run is live (ours or another's), else every few seconds (a run
        // started from the command line or the MCP server shows up)
        let every = if self.building() { Duration::from_millis(500) } else { Duration::from_secs(4) };
        if self.last_poll.elapsed() > every {
            self.last_poll = Instant::now();
            self.progress = std::fs::read(self.paths.progress()).ok().and_then(|b| serde_json::from_slice(&b).ok());
            // a newer run finished cleanly (e.g. started from x86sim-aot or the MCP server): the old error is stale
            if let Some(p) = &self.progress {
                if p.state == "done" && !self.message.is_empty() && self.message_pid != Some(p.pid) {
                    self.message.clear();
                    self.message_pid = None;
                }
            }
        }
    }

    pub fn start_build(&mut self, full: bool) {
        let _ = self.paths.save_config(&self.effective_cfg());
        let exe = std::env::current_exe().ok().and_then(|p| p.parent().map(|d| d.join("x86sim-aot"))).unwrap_or_else(|| "x86sim-aot".into());
        let mut cmd = Command::new(exe);
        cmd.arg("--jc").arg(&self.jc);
        if let Some(d) = &self.device {
            cmd.arg("--device").arg(d);
        }
        cmd.arg(if full { "build" } else { "update" });
        if full {
            cmd.arg("--full");
        }
        cmd.args(["--workers", &self.cores.to_string()]);
        let log = std::fs::File::create(aot::scratch().join("launcher-aot.log")).ok();
        cmd.stdin(Stdio::null());
        match log {
            Some(l) => {
                cmd.stdout(l.try_clone().map(Stdio::from).unwrap_or(Stdio::null())).stderr(Stdio::from(l));
            }
            None => {
                cmd.stdout(Stdio::null()).stderr(Stdio::null());
            }
        }
        match cmd.spawn() {
            Ok(c) => {
                self.child = Some(c);
                self.message.clear();
            }
            Err(e) => self.message = format!("cannot start x86sim-aot: {e}"),
        }
    }

    /// Stops the run (ours or another's): x86sim-aot ends its builders and records what finished (resumable).
    fn cancel(&mut self) {
        let pid = self.child.as_ref().map(|c| c.id()).or_else(|| self.external_run());
        if let Some(pid) = pid {
            unsafe {
                libc_kill(pid as i32, 15);
            }
        }
    }
}

extern "C" {
    #[link_name = "kill"]
    fn libc_kill(pid: i32, sig: i32) -> i32;
}

/// "just now", "5 min ago", "3 h ago", "2 days ago"
fn ago(unix: u64) -> String {
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    let d = now.saturating_sub(unix);
    match d {
        0..=59 => "just now".into(),
        60..=3599 => format!("{} min ago", d / 60),
        3600..=86399 => format!("{} h ago", d / 3600),
        _ => format!("{} days ago", d / 86400),
    }
}

/// The pid is an x86sim-aot (a reused pid is not a run)
fn pid_is_aot(pid: u32) -> bool {
    std::fs::read_to_string(format!("/proc/{pid}/comm")).is_ok_and(|c| c.trim().starts_with("x86sim-aot"))
}

fn aot_alive(pid: u32) -> bool {
    pid != 0 && std::path::Path::new(&format!("/proc/{pid}")).exists()
}

impl App {
    // ---------------- iOS / tvOS / watchOS versions ----------------
    pub fn ios_page(&mut self, ui: &mut egui::Ui) {
        let mut check = false;
        let checking = self.catalogue.lock().unwrap().is_none();
        page_header(ui, "Versions", "Each device runs one version: iOS for iPhone and iPad, tvOS for Apple TV, watchOS for Apple Watch.", |ui| {
            check = ui.add_enabled(!checking, Btn::secondary(if checking { "Checking…" } else { "Check for updates" }).icon(icon::ARROW_CLOCKWISE)).on_hover_text("Ask Apple for its current list").clicked();
        });
        if check {
            let c = self.catalogue.clone();
            *c.lock().unwrap() = None;
            let ctx = ui.ctx().clone();
            std::thread::spawn(move || {
                let v = host::catalogue(true);
                *c.lock().unwrap() = Some(v);
                ctx.request_repaint();
            });
        }
        let cat = self.catalogue.lock().unwrap().clone();
        let runtimes = self.runtimes.clone();
        let insts = self.insts.clone();
        let phones_on = |dir: &str| insts.iter().filter(|i| i.runtime_dir == dir).count();
        let phones_need = |build: &str| insts.iter().filter(|i| i.build == build && !i.runtime_present).count();
        section(ui, "On this computer", |_| {});
        let mut fetch: Option<(String, String)> = None;
        let mut cancel: Option<host::Fetch> = None;
        let mut discard: Option<host::Runtime> = None;
        let mut aot_rt = None;
        list_card(ui, |ui| {
            if runtimes.is_empty() {
                empty_state(ui, icon::STACK, "No version yet", "Download one below to start a device.", |_| {});
            }
            for (k, r) in runtimes.iter().enumerate() {
                if k > 0 {
                    hline(ui);
                }
                let fetching = self.fetching.get(&r.build).cloned();
                let partial = host::partial_download(r);
                let n = phones_on(&r.dir);
                let size = self.sizes.lock().unwrap().get(&r.jc).copied();
                let mut line = format!("Build {} · {} device{}", r.build, n, if n == 1 { "" } else { "s" });
                if let Some(b) = size {
                    line += &format!(" · {:.1} GB translated code", b as f64 / 1e9);
                }
                // a badge only for what needs attention: the section says these are installed, the progress row below
                // that one is downloading
                let warn = if fetching.is_some() || r.present { None } else if partial.is_some() { Some("Stopped") } else { Some("Files missing") };
                list_row(ui, icon::STACK, &r.label(), &line, |ui| {
                    if r.present {
                        if ui.add(Btn::secondary("Pre-translate").icon(icon::LIGHTNING)).on_hover_text("Get this version's apps ready ahead of time").clicked() {
                            aot_rt = Some(r.root.clone());
                        }
                    } else if fetching.is_none() {
                        let label = if partial.is_some() { "Resume" } else { "Download" };
                        if ui.add(Btn::primary(label).icon(icon::DOWNLOAD_SIMPLE)).clicked() {
                            fetch = Some((r.build.clone(), r.label()));
                        }
                        if partial.is_some() && ui.add(Btn::ghost("Discard")).on_hover_text("Delete what was downloaded").clicked() {
                            self.confirm_discard = Some(r.build.clone());
                        }
                    }
                    if let Some(w) = warn {
                        ui.add_space(S2);
                        badge(ui, w, WARN);
                    }
                });
                if let Some(f) = &fetching {
                    if fetch_progress(ui, f) {
                        cancel = Some(f.clone());
                    }
                } else if partial.is_some() && self.confirm_discard.as_deref() == Some(r.build.as_str()) {
                    // deleting gigabytes of download asks first, in the row (as "Redo all" does on Pre-translate)
                    egui::Frame::new().inner_margin(egui::Margin { left: 60, right: 16, top: 0, bottom: 12 }).show(ui, |ui| {
                        egui::Frame::new().fill(RAISED).corner_radius(R_MD).inner_margin(egui::Margin::symmetric(12, 8)).show(ui, |ui| {
                            ui.set_width(ui.available_width());
                            ui.horizontal(|ui| {
                                ui.spacing_mut().item_spacing.x = S2;
                                ui.label(egui::RichText::new(icon::WARNING_CIRCLE).size(15.0).color(WARN));
                                ui.label(body(format!("Discard the {:.1} GB downloaded so far?", partial.unwrap_or(0) as f64 / 1e9)));
                                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                                    if ui.add(Btn::danger("Discard").small()).clicked() {
                                        self.confirm_discard = None;
                                        discard = Some(r.clone());
                                    }
                                    if ui.add(Btn::secondary("Keep").small()).clicked() {
                                        self.confirm_discard = None;
                                    }
                                });
                            });
                        });
                    });
                } else if let Some(b) = partial {
                    let total = cat.as_ref().and_then(|c| c.iter().find(|c| c.build == r.build)).map(|c| c.gb);
                    note(ui, &match total {
                        Some(gb) => format!("Download stopped at {:.1} of {gb:.1} GB. Resume picks up where it stopped.", b as f64 / 1e9),
                        None => format!("Download stopped at {:.1} GB. Resume picks up where it stopped.", b as f64 / 1e9),
                    });
                } else if !r.present {
                    note(ui, "Its files are missing. Download it again to start devices on this version.");
                }
            }
        });
        ui.add_space(S5);
        let betas = self.hub_show_betas;
        let mut show_betas = betas;
        section(ui, "Available from Apple", |ui| {
            ui.label(sub("Show betas"));
            toggle(ui, &mut show_betas);
        });
        if show_betas != betas {
            self.hub_show_betas = show_betas;
        }
        list_card(ui, |ui| match &cat {
            None => {
                egui::Frame::new().inner_margin(16).show(ui, |ui| {
                    ui.horizontal(|ui| {
                        ui.spinner();
                        ui.label(sub("Asking Apple…"));
                    });
                });
            }
            Some(v) if v.is_empty() => {
                egui::Frame::new().inner_margin(16).show(ui, |ui| {
                    ui.horizontal(|ui| {
                        ui.label(egui::RichText::new(icon::WIFI_SLASH).size(16.0).color(INK_3));
                        ui.label(sub("Couldn't reach Apple. Check the connection, then Check for updates."));
                    });
                });
            }
            Some(v) => {
                let is_beta = |c: &host::Catalogue| c.name.contains("beta") || c.name.contains("Release Candidate");
                let mut v: Vec<&host::Catalogue> = v.iter().filter(|c| !runtimes.iter().any(|r| r.build == c.build)).collect();
                // newest first; releases before betas of the same version
                v.sort_by(|a, b| ver_key(&b.version).cmp(&ver_key(&a.version)).then(is_beta(a).cmp(&is_beta(b))).then(b.build.cmp(&a.build)));
                let hidden = v.iter().filter(|c| is_beta(c) && phones_need(&c.build) == 0).count();
                let v: Vec<&host::Catalogue> = v.into_iter().filter(|c| show_betas || !is_beta(c) || phones_need(&c.build) > 0).collect();
                if v.is_empty() {
                    egui::Frame::new().inner_margin(16).show(ui, |ui| {
                        ui.horizontal(|ui| {
                            ui.label(egui::RichText::new(icon::CHECK_CIRCLE).size(16.0).color(GOOD));
                            ui.label(sub("You have every release Apple offers."));
                        });
                    });
                }
                for (k, c) in v.iter().enumerate() {
                    if k > 0 {
                        hline(ui);
                    }
                    let fetching = self.fetching.get(&c.build).cloned();
                    let short = c.name.trim_end_matches(" Simulator Runtime").trim().replace("Release Candidate", "RC");
                    let t = if !short.is_empty() { short } else if c.version.is_empty() { c.build.clone() } else { format!("{} {}", x86sim_core::sim::platform_name(&c.platform), c.version) };
                    let need = phones_need(&c.build);
                    let mut detail = format!("Build {} · {:.1} GB download", c.build, c.gb);
                    if need > 0 {
                        detail += &format!(" · {need} device{} need{} it", if need == 1 { "" } else { "s" }, if need == 1 { "s" } else { "" });
                    }
                    list_row(ui, icon::CLOUD_ARROW_DOWN, &t, &detail, |ui| {
                        if fetching.is_none() {
                            let b = if need > 0 { Btn::primary("Download") } else { Btn::secondary("Download") };
                            if ui.add(b.icon(icon::DOWNLOAD_SIMPLE)).clicked() {
                                fetch = Some((c.build.clone(), t.clone()));
                            }
                        }
                    });
                    if let Some(f) = &fetching {
                        if fetch_progress(ui, f) {
                            cancel = Some(f.clone());
                        }
                    }
                }
                if !show_betas && hidden > 0 {
                    hline(ui);
                    egui::Frame::new().inner_margin(egui::Margin::symmetric(16, 10)).show(ui, |ui| {
                        ui.label(muted(format!("{hidden} betas and release candidates hidden")));
                    });
                }
            }
        });
        if let Some((b, l)) = fetch {
            self.download(&b, &l);
        }
        if let Some(f) = cancel {
            host::cancel_fetch(&f);
            self.fetching.remove(&f.build);
            self.fetch_started.remove(&f.build);
            self.say("Download stopped. Resume picks up where it stopped.");
            self.runtimes = host::runtimes();
        }
        if let Some(r) = discard {
            match host::discard_download(&r) {
                Ok(()) => self.say(format!("Discarded the stopped {} download", r.label())),
                Err(e) => self.say(format!("Couldn't discard it: {e:#}")),
            }
            self.runtimes = host::runtimes();
        }
        if let Some(rt) = aot_rt {
            self.aot.select(rt, None);
            self.view = crate::View::Aot;
        }
        ui.add_space(S5);
    }

    // ---------------- Pre-translate ----------------
    pub fn aot_page(&mut self, ui: &mut egui::Ui) {
        page_header(ui, "Pre-translate", "Get apps ready ahead of time so they open fast. One cache per version.", |_| {});
        let present: Vec<host::Runtime> = self.runtimes.iter().filter(|r| r.present).cloned().collect();
        if present.is_empty() {
            card(ui, |ui| empty_state(ui, icon::LIGHTNING, "Nothing to pre-translate yet", "Download a version first.", |_| {}));
            return;
        }
        let building = self.aot.building();
        let page_w = ui.available_width();
        ui.horizontal_wrapped(|ui| {
            ui.spacing_mut().item_spacing = egui::vec2(S2, S2);
            // two versions with one label (iOS 27.2 and the iPhone Duo's 27.2 build) are told apart by their build
            let labels: Vec<String> = present.iter().map(|r| {
                if present.iter().filter(|o| o.label() == r.label()).count() > 1 { format!("{} ({})", r.label(), r.build) } else { r.label() }
            }).collect();
            let sel = present.iter().position(|r| Some(&r.root) == self.aot.runtime_root.as_ref());
            // more versions than fit as segments (a narrow window, many versions): a list instead of a clipped row
            let seg_w: f32 = labels.iter().map(|l| ui.painter().layout_no_wrap(l.clone(), font_m(T_SMALL), INK).size().x + 20.0).sum::<f32>() + 4.0;
            let mut pick = None;
            let as_segments = seg_w <= page_w;
            if as_segments {
                pick = segmented(ui, &labels.iter().map(|s| s.as_str()).collect::<Vec<_>>(), sel, !building);
            } else {
                ui.add_enabled_ui(!building, |ui| {
                    egui::ComboBox::from_id_salt("aotver").icon(caret).width(220.0_f32.min(ui.available_width() - S2)).selected_text(body(sel.map(|i| labels[i].clone()).unwrap_or_default())).show_ui(ui, |ui| {
                        for (i, l) in labels.iter().enumerate() {
                            if ui.selectable_label(sel == Some(i), l).clicked() {
                                pick = Some(i);
                            }
                        }
                    });
                });
            }
            if let Some(i) = pick {
                self.aot.select(present[i].root.clone(), None);
            }
            if sel.is_none() {
                self.aot.select(present[0].root.clone(), None);
            }
            // "Apps from" and its list move to a second row when the first has no room (a combo box doesn't wrap itself)
            if page_w - if as_segments { seg_w } else { 250.0 } < 290.0 {
                ui.end_row();
            } else {
                ui.add_space(S2);
            }
            ui.label(sub("Apps from"));
            let phones: Vec<(String, PathBuf)> = self.insts.iter().filter(|i| Some(&i.runtime_root) == self.aot.runtime_root.as_ref()).map(|i| (i.name.clone(), i.dir.clone())).collect();
            let cur = phones.iter().find(|p| Some(&p.1) == self.aot.device.as_ref()).map(|p| p.0.clone()).unwrap_or("System only".into());
            egui::ComboBox::from_id_salt("aotdev").icon(caret)
                .width(180.0)
                .selected_text(body(cur))
                .show_ui(ui, |ui| {
                    for (n, d) in &phones {
                        if ui.selectable_label(Some(d) == self.aot.device.as_ref(), n).clicked() {
                            self.aot.device = Some(d.clone());
                            self.aot.refresh();
                        }
                    }
                })
                .response
                .on_hover_text("Which device's apps and feature choices to follow");
        });
        ui.add_space(S4);
        let (status, busy) = {
            let g = self.aot.shared.lock().unwrap();
            (g.status.clone(), g.busy)
        };
        let st_ok = status.as_ref().and_then(|s| s.as_ref().ok()).cloned();
        let need = st_ok.as_ref().map(|s| s.stale + s.missing).unwrap_or(0);

        // ---- status + actions
        card(ui, |ui| {
            ui.horizontal(|ui| {
                let (head, col, line) = match (&st_ok, &status) {
                    (_, _) if building => (
                        "Pre-translating",
                        ACCENT,
                        self.aot.progress.as_ref().filter(|p| p.chunks_total > 0).map(|p| format!("{} of {} parts done", p.chunks_done, p.chunks_total)).unwrap_or_else(|| "Getting ready…".into()),
                    ),
                    (Some(s), _) if s.total == 0 => ("Nothing to translate yet", INK_3, "Start a device on this version first: it learns what's used.".to_string()),
                    (Some(s), _) if s.image_current && need == 0 => ("Ready", GOOD, format!("All {} parts are ready", s.total)),
                    (Some(s), _) if need == 0 => ("Almost ready", WARN, "Every part is translated; it needs putting together".to_string()),
                    (Some(s), _) if s.image_present => ("Needs an update", WARN, format!("{need} of {} parts to redo", s.total)),
                    (Some(s), _) => ("Not started", INK_3, format!("{} parts to translate", s.total)),
                    (None, Some(Err(_))) => ("Couldn't check", CRIT, String::new()),
                    _ => ("Checking…", INK_3, String::new()),
                };
                let (r, _) = ui.allocate_exact_size(egui::vec2(36.0, 36.0), egui::Sense::hover());
                ui.painter().rect_filled(r, 8.0, RAISED);
                ui.painter().text(r.center(), egui::Align2::CENTER_CENTER, icon::LIGHTNING, font(18.0), if col == INK_3 { INK_2 } else { col });
                ui.add_space(4.0);
                ui.vertical(|ui| {
                    ui.spacing_mut().item_spacing.y = 1.0;
                    ui.label(title(head));
                    if !line.is_empty() {
                        ui.label(muted(line));
                    }
                });
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    ui.spacing_mut().item_spacing.x = S2;
                    if busy {
                        ui.spinner();
                    } else if ui.add(Btn::tool(icon::ARROW_CLOCKWISE)).on_hover_text("Check again").clicked() {
                        self.aot.refresh();
                    }
                    if building {
                        let tip = if self.aot.external_run().is_some() { "Stop the run started outside this window" } else { "Stop; Continue picks up the rest" };
                        if ui.add(Btn::secondary("Cancel").icon(icon::X)).on_hover_text(tip).clicked() {
                            self.aot.cancel();
                        }
                    } else {
                        let empty = st_ok.as_ref().is_some_and(|s| s.total == 0);
                        if ui.add_enabled(!empty, Btn::secondary("Redo all")).on_hover_text("Translate every part again, from scratch").clicked() {
                            self.aot.confirm_redo = true;
                        }
                        let resumable = self.aot.progress.as_ref().is_some_and(|p| p.state == "cancelled" || p.state == "error");
                        let current = st_ok.as_ref().is_some_and(|s| s.image_current);
                        let (label, ic, tip) = if empty {
                            ("Start", icon::LIGHTNING, "Nothing to translate yet")
                        } else if resumable && need > 0 {
                            ("Continue", icon::PLAY, "Pick up where the last run stopped")
                        } else if need > 0 && st_ok.as_ref().is_some_and(|s| s.up_to_date > 0) {
                            ("Update", icon::ARROW_CLOCKWISE, "Translate only what changed")
                        } else if need == 0 && st_ok.is_some() && !current && !empty {
                            ("Finish", icon::CHECK, "Put the translated parts together")
                        } else if need == 0 && st_ok.is_some() {
                            ("Up to date", icon::CHECK, "Nothing to do")
                        } else {
                            ("Start", icon::LIGHTNING, "Translate now")
                        };
                        let can = !empty && (need > 0 || st_ok.as_ref().is_some_and(|s| !s.image_current));
                        if ui.add_enabled(can, Btn::primary(label).icon(ic)).on_hover_text(tip).clicked() {
                            self.aot.start_build(false);
                        }
                    }
                });
            });
            if self.aot.confirm_redo && !building {
                ui.add_space(S3);
                egui::Frame::new().fill(RAISED).corner_radius(R_MD).inner_margin(egui::Margin::symmetric(12, 8)).show(ui, |ui| {
                    ui.set_width(ui.available_width());
                    ui.horizontal(|ui| {
                        ui.label(egui::RichText::new(icon::WARNING_CIRCLE).size(15.0).color(WARN));
                        ui.label(body(format!("Translate all {} parts again? This takes a while and uses {} cores.", st_ok.as_ref().map(|s| s.total).unwrap_or(0), self.aot.cores)));
                        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                            if ui.add(Btn::primary("Redo all").small()).on_hover_text("Start over now").clicked() {
                                self.aot.confirm_redo = false;
                                self.aot.start_build(true);
                            }
                            if ui.add(Btn::secondary("Cancel").small()).clicked() {
                                self.aot.confirm_redo = false;
                            }
                        });
                    });
                });
            }
            if !self.aot.message.is_empty() {
                ui.add_space(S2);
                ui.label(egui::RichText::new(&self.aot.message).size(T_SMALL).color(CRIT_INK));
            }
            if let Some(p) = &self.aot.progress {
                let live = building;
                let nothing = p.state == "done" && p.chunks_total == 0;
                if !live && p.state == "done" {
                    // the last run, in one line (a run that found every part current says so)
                    ui.add_space(S3);
                    hline(ui);
                    ui.add_space(S2);
                    ui.horizontal(|ui| {
                        ui.label(egui::RichText::new(icon::CHECK_CIRCLE).size(15.0).color(GOOD));
                        let t = if nothing {
                            "Last run: nothing to do, every part was already up to date".to_string()
                        } else {
                            format!("Last run translated {} part{} in {}", p.chunks_done, if p.chunks_done == 1 { "" } else { "s" }, fmt_s(p.elapsed_s))
                        };
                        ui.label(sub(t)).on_hover_text(&p.message);
                        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                            ui.label(muted(ago(p.updated)));
                        });
                    });
                } else if live || matches!(p.state.as_str(), "done" | "cancelled" | "error") {
                    ui.add_space(S4);
                    let frac = if p.chunks_total > 0 { p.chunks_done as f32 / p.chunks_total as f32 } else { 0.0 };
                    let col = match p.state.as_str() {
                        "done" => GOOD,
                        "error" => CRIT,
                        "cancelled" => WARN,
                        _ => ACCENT,
                    };
                    ui.horizontal(|ui| {
                        ui.label(egui::RichText::new(format!("{:.0}%", frac * 100.0)).size(T_TITLE).family(semibold()).color(INK));
                        let what = match p.state.as_str() {
                            "planning" => "Looking at what changed…".to_string(),
                            "assembling" => "Putting it together…".to_string(),
                            _ => format!("{} of {} parts", p.chunks_done, p.chunks_total),
                        };
                        ui.label(muted(what));
                        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                            if live {
                                ui.label(muted(match p.eta_s {
                                    Some(e) => format!("about {} left", fmt_s(e)),
                                    None => format!("{} so far", fmt_s(p.elapsed_s)),
                                }));
                            } else {
                                let t = match p.state.as_str() {
                                    "done" => format!("Finished {}", ago(p.updated)),
                                    "cancelled" => format!("Stopped {}", ago(p.updated)),
                                    _ => format!("Failed {}", ago(p.updated)),
                                };
                                ui.label(muted(t)).on_hover_text(&p.message);
                            }
                        });
                    });
                    ui.add(egui::ProgressBar::new(frac).desired_height(6.0).fill(col).corner_radius(3).animate(false));
                    if live && !p.current.is_empty() {
                        let names: Vec<&str> = p.current.iter().map(|c| c.rsplit('/').next().unwrap_or(c)).collect();
                        ui.add(egui::Label::new(muted(format!("Working on {}", names.join(", ")))).truncate()).on_hover_text(p.current.join("\n"));
                    }
                    if !live && p.state == "error" && !p.message.is_empty() {
                        ui.add(egui::Label::new(egui::RichText::new(&p.message).size(T_SMALL).color(CRIT_INK)).wrap());
                    }
                }
            }
        });
        ui.add_space(S3);
        match &status {
            None => {}
            Some(Err(e)) => {
                card(ui, |ui| ui.label(egui::RichText::new(e).size(T_SMALL).color(CRIT_INK)));
            }
            Some(Ok(s)) if s.total == 0 => {}
            Some(Ok(s)) => {
                // how many are ready and how many to redo is the card's own line; only the size is new here
                let mut t = format!("The translated code takes {}.", fmt_mb(s.chunks.iter().map(|c| c.slot_mb).sum::<f64>().max(0.0)));
                if s.dropped > 0 {
                    t += &format!(" {} more parts get ready the first time they're used.", s.dropped);
                }
                ui.label(muted(t));
            }
        }
        ui.add_space(S5);

        // ---- options
        section(ui, "Options", |_| {});
        list_card(ui, |ui| {
            form_row(ui, "How much", "Common and More follow what your devices use (until one has run, they cover everything); Everything covers every app and framework.", false, |ui| {
                let scopes = [("hot", "Common"), ("loaded", "More"), ("all", "Everything")];
                let sel = scopes.iter().position(|s| self.aot.cfg.scope == s.0);
                if let Some(i) = segmented(ui, &scopes.map(|s| s.1), sel, !building) {
                    self.aot.cfg.scope = scopes[i].0.into();
                    let _ = self.aot.paths.save_config(&self.aot.effective_cfg());
                    self.aot.refresh();
                }
            });
            form_row(ui, "Speed", "CPU cores to use while translating.", false, |ui| {
                ui.label(sub(format!("{} cores", self.aot.cores)));
                ui.add_enabled(!building, egui::Slider::new(&mut self.aot.cores, 1..=self.aot.max_cores).show_value(false));
            });
            form_row(ui, "Skip turned-off features", "Leave out what the device has turned off.", true, |ui| {
                let mut f = self.aot.cfg.follow_features;
                if ui.add_enabled_ui(!building, |ui| toggle(ui, &mut f)).inner.changed() {
                    self.aot.cfg.follow_features = f;
                    let _ = self.aot.paths.save_config(&self.aot.effective_cfg());
                    self.aot.refresh();
                }
            });
        });
        ui.add_space(S5);

        // ---- parts
        let Some(Ok(s)) = &status else { return };
        if s.total == 0 {
            return;
        }
        section(ui, "Parts", |ui| {
            ui.label(sub("Only what needs work"));
            toggle(ui, &mut self.aot.only_attention);
            ui.add_space(S3);
            search(ui, &mut self.aot.filter, "Search", 220.0);
        });
        list_card(ui, |ui| {
            let w = ui.available_width();
            let (st_w, size_w) = (110.0, 80.0);
            let name_w = ((w - st_w - size_w - 32.0) * 0.5).max(160.0);
            let (hr, _) = ui.allocate_exact_size(egui::vec2(w, 32.0), egui::Sense::hover());
            let hf = table_head();
            let x0 = hr.left() + 16.0;
            ui.painter().text(egui::pos2(x0, hr.center().y), egui::Align2::LEFT_CENTER, "STATUS", hf.clone(), INK_3);
            ui.painter().text(egui::pos2(x0 + st_w, hr.center().y), egui::Align2::LEFT_CENTER, "NAME", hf.clone(), INK_3);
            ui.painter().text(egui::pos2(x0 + st_w + name_w + size_w, hr.center().y), egui::Align2::RIGHT_CENTER, "SIZE", hf.clone(), INK_3);
            ui.painter().text(egui::pos2(x0 + st_w + name_w + size_w + 24.0, hr.center().y), egui::Align2::LEFT_CENTER, "NOTE", hf, INK_3);
            let mut shown = 0;
            let f = self.aot.filter.to_lowercase();
            for c in &s.chunks {
                if self.aot.only_attention && c.state == "up-to-date" {
                    continue;
                }
                if !f.is_empty() && !c.name.to_lowercase().contains(&f) {
                    continue;
                }
                shown += 1;
                if shown > 400 {
                    break;
                }
                let (t, col) = match c.state.as_str() {
                    "up-to-date" => ("Ready", GOOD),
                    "stale" => ("Out of date", WARN),
                    _ => ("Missing", INK_3),
                };
                let (r, resp) = ui.allocate_exact_size(egui::vec2(w, 30.0), egui::Sense::hover());
                let p = ui.painter();
                p.hline(r.x_range(), r.top(), egui::Stroke::new(1.0_f32, BORDER));
                if resp.hovered() {
                    p.rect_filled(r.shrink2(egui::vec2(1.0, 0.0)), 0.0, egui::Color32::from_rgb(0x22, 0x23, 0x26));
                }
                let cy = r.center().y;
                if col == INK_3 {
                    p.circle_stroke(egui::pos2(x0 + 4.0, cy), 3.0, egui::Stroke::new(1.3_f32, INK_3));
                } else {
                    p.circle_filled(egui::pos2(x0 + 4.0, cy), 3.5, col);
                }
                p.text(egui::pos2(x0 + 14.0, cy), egui::Align2::LEFT_CENTER, t, font(T_SMALL), INK_2);
                let short = c.name.rsplit('/').next().unwrap_or(&c.name);
                let g = galley_trunc(ui, short, font_m(T_SMALL), INK, name_w - 12.0);
                p.galley(egui::pos2(x0 + st_w, cy - g.size().y / 2.0), g, INK);
                p.text(egui::pos2(x0 + st_w + name_w + size_w, cy), egui::Align2::RIGHT_CENTER, format!("{:.1} MB", c.slot_mb), font(T_SMALL), INK_2);
                let nx = x0 + st_w + name_w + size_w + 24.0;
                let g = galley_trunc(ui, &c.reasons.join("; "), font(T_SMALL), INK_3, r.right() - nx - 16.0);
                p.galley(egui::pos2(nx, cy - g.size().y / 2.0), g, INK_3);
                resp.on_hover_text(format!("{}\n{}", c.name, c.reasons.join("\n")));
            }
            if shown == 0 {
                egui::Frame::new().inner_margin(16).show(ui, |ui| {
                    ui.horizontal(|ui| {
                        if self.aot.only_attention && f.is_empty() {
                            ui.label(egui::RichText::new(icon::CHECK_CIRCLE).size(16.0).color(GOOD));
                            ui.label(sub("Everything is ready"));
                        } else {
                            ui.label(sub("Nothing matches"));
                        }
                    });
                });
            }
        });
        ui.add_space(S5);
    }

    // ---------------- Settings / host ----------------
    pub fn settings_page(&mut self, ui: &mut egui::Ui) {
        page_header(ui, "Settings", "", |_| {});
        let mut save = false;
        section(ui, "Hub", |_| {});
        list_card(ui, |ui| {
            form_row(ui, "Live previews", "Show each running device's screen on the Devices page.", false, |ui| {
                save |= toggle(ui, &mut self.hub.thumbnails).changed();
            });
            form_row(ui, "Open a device when it starts", "Jump to its screen after pressing Start.", false, |ui| {
                save |= toggle(ui, &mut self.hub.open_on_start).changed();
            });
            form_row(ui, "Card size", "How large devices appear on the Devices page.", true, |ui| {
                save |= ui.add(egui::Slider::new(&mut self.hub.card_w, 200.0..=360.0).show_value(false)).drag_stopped();
            });
        });
        ui.add_space(S5);
        save |= self.update_settings(ui);
        if save {
            let _ = host::save_hub(&self.hub);
        }
        ui.add_space(S5);
        // what runs and the memory it takes are the sidebar's footer, on every page; here what only this page shows
        let gpu = self.gpu_helpers;
        let free = if self.disk.free_gb >= 1000.0 { format!("{:.1} TB", self.disk.free_gb / 1000.0) } else { format!("{:.0} GB", self.disk.free_gb) };
        section(ui, "This computer", |_| {});
        list_card(ui, |ui| {
            let sizes = self.sizes.lock().unwrap().clone();
            let last = sizes.is_empty();
            form_row(ui, "GPU helpers", "mtlvk runs the devices' Metal calls on Vulkan; one helper may serve several devices", false, |ui| {
                ui.label(body(match gpu { 0 => "None running".to_string(), 1 => "1 running".to_string(), n => format!("{n} running") }));
            });
            form_row(ui, "Disk use", &format!("{free} free where caches and device data live, {}", aot::scratch().display()), last, |ui| {
                if ui.add_enabled(!self.measuring, Btn::secondary(if self.measuring { "Measuring…" } else { "Measure" }).icon(icon::HARD_DRIVES)).on_hover_text("Add up what each cache and device takes on disk").on_disabled_hover_text("Adding up the folders…").clicked() {
                    self.measuring = true;
                    let sizes = self.sizes.clone();
                    let mut dirs: Vec<PathBuf> = self.runtimes.iter().map(|r| r.jc.clone()).collect();
                    dirs.extend(self.insts.iter().map(|i| i.prefix.clone()));
                    dirs.extend(self.insts.iter().map(|i| i.dir.clone()));
                    let ctx = ui.ctx().clone();
                    std::thread::spawn(move || {
                        for d in dirs {
                            let s = host::dir_size(&d);
                            sizes.lock().unwrap().insert(d, s);
                            ctx.request_repaint();
                        }
                    });
                }
            });
            if !sizes.is_empty() {
                self.measuring = false;
                let mut v: Vec<(&PathBuf, &u64)> = sizes.iter().collect();
                v.sort_by(|a, b| b.1.cmp(a.1));
                let max = v.first().map(|x| *x.1).unwrap_or(1).max(1) as f32;
                ui.add_space(4.0);
                for (p, b) in v {
                    let name = p.file_name().unwrap_or_default().to_string_lossy().into_owned();
                    let what = if name.starts_with("jc-") || name == "jitcache" { "Translated code" } else if name.starts_with("a64prefix") { "System files" } else { "Device data" };
                    let (r, resp) = ui.allocate_exact_size(egui::vec2(ui.available_width(), 28.0), egui::Sense::hover());
                    let pt = ui.painter();
                    let x0 = r.left() + 16.0;
                    let name_w = (r.width() * 0.3).clamp(130.0, 220.0);
                    let what_w = (r.width() * 0.22).clamp(110.0, 160.0);
                    let g = galley_trunc(ui, &name, font_m(T_SMALL), INK, name_w - S3);
                    pt.galley(egui::pos2(x0, r.center().y - g.size().y / 2.0), g, INK);
                    pt.text(egui::pos2(x0 + name_w, r.center().y), egui::Align2::LEFT_CENTER, what, font(T_SMALL), INK_3);
                    let bx = x0 + name_w + what_w;
                    let bar = egui::Rect::from_min_size(egui::pos2(bx, r.center().y - 2.0), egui::vec2((r.right() - 16.0 - 80.0 - bx).max(24.0), 4.0));
                    pt.rect_filled(bar, 2.0, RAISED);
                    pt.rect_filled(egui::Rect::from_min_size(bar.min, egui::vec2((*b as f32 / max * bar.width()).max(2.0), 4.0)), 2.0, ACCENT);
                    pt.text(egui::pos2(r.right() - 16.0, r.center().y), egui::Align2::RIGHT_CENTER, format!("{:.1} GB", *b as f64 / 1e9), font(T_SMALL), INK_2);
                    resp.on_hover_text(p.display().to_string());
                }
                ui.add_space(8.0);
            }
        });
        ui.add_space(S5);
    }
}

/// A list row: icon tile, title + detail, trailing controls (right to left).
pub(crate) fn list_row(ui: &mut egui::Ui, ic: &str, title_text: &str, detail: &str, trailing: impl FnOnce(&mut egui::Ui)) {
    egui::Frame::new().inner_margin(egui::Margin::symmetric(16, 12)).show(ui, |ui| {
        ui.set_width(ui.available_width());
        ui.horizontal(|ui| {
            let (r, _) = ui.allocate_exact_size(egui::vec2(32.0, 32.0), egui::Sense::hover());
            ui.painter().rect_filled(r, 8.0, RAISED);
            ui.painter().text(r.center(), egui::Align2::CENTER_CENTER, ic, font(17.0), INK_2);
            ui.add_space(4.0);
            // the text wraps before the trailing buttons (room for about two) instead of running under them
            let text_w = (ui.available_width() - 200.0).max(160.0);
            ui.vertical(|ui| {
                ui.set_max_width(text_w);
                ui.spacing_mut().item_spacing.y = 1.0;
                ui.add(egui::Label::new(strong(title_text)).wrap());
                ui.add(egui::Label::new(muted(detail)).wrap());
            });
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), trailing);
        });
    });
}

/// A muted note under a list row, aligned with its title.
pub(crate) fn note(ui: &mut egui::Ui, text: &str) {
    egui::Frame::new().inner_margin(egui::Margin { left: 60, right: 16, top: 0, bottom: 12 }).show(ui, |ui| {
        ui.add(egui::Label::new(muted(text)).wrap());
    });
}

/// "27.2" -> (27, 2, 0) for sorting
fn ver_key(v: &str) -> (u32, u32, u32) {
    let mut it = v.split('.').map(|x| x.parse().unwrap_or(0));
    (it.next().unwrap_or(0), it.next().unwrap_or(0), it.next().unwrap_or(0))
}

/// A download's progress under its row: bar, amount, speed, time left, Cancel. Returns true when Cancel is clicked.
pub(crate) fn fetch_progress(ui: &mut egui::Ui, f: &host::Fetch) -> bool {
    let mut cancel = false;
    egui::Frame::new().inner_margin(egui::Margin { left: 60, right: 16, top: 0, bottom: 12 }).show(ui, |ui| {
        ui.set_width(ui.available_width());
        ui.spacing_mut().item_spacing.y = 6.0;
        let gb = |b: u64| b as f64 / 1e9;
        let (line, frac) = match f.phase.as_str() {
            "downloading" if f.total_bytes > 0 => {
                let mut l = format!("{:.1} of {:.1} GB", gb(f.done_bytes), gb(f.total_bytes));
                if f.speed > 0 {
                    l += &format!(" · {:.0} MB/s", f.speed as f64 / 1e6);
                }
                if let Some(e) = f.eta_s {
                    l += &format!(" · about {} left", fmt_s(e as f64));
                }
                (l, Some(f.pct.unwrap_or(0.0) / 100.0))
            }
            "downloading" => ("Downloading…".to_string(), None),
            "decrypting" => ("Downloaded. Decrypting…".to_string(), None),
            "unpacking" => ("Unpacking. Almost done…".to_string(), None),
            _ => ("Asking Apple for the download…".to_string(), None),
        };
        ui.horizontal(|ui| {
            ui.label(sub(line));
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                cancel = ui.add(Btn::secondary("Cancel").icon(icon::X).small()).on_hover_text("Stop the download; what's downloaded is kept").clicked();
            });
        });
        match frac {
            Some(x) => ui.add(egui::ProgressBar::new(x).desired_height(4.0).fill(ACCENT).corner_radius(2).animate(false)),
            None => ui.add(egui::ProgressBar::new(0.0).desired_height(4.0).fill(ACCENT).corner_radius(2).animate(true)),
        };
    });
    ui.ctx().request_repaint_after(Duration::from_secs(1));
    cancel
}
