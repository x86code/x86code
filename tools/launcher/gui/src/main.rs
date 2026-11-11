//! x86Sim hub: every phone (var/device-a64*) as a card with its live screen, open one for its embedded screen with
//! touch and keyboard plus a fold-out panel (features, logs, performance, advanced); global pages for iOS versions,
//! pre-translation (AOT) and settings. Logic lives in x86sim-core; the GUI repaints only when a frame or a status
//! changes.
mod global;
mod home;
mod phone;
mod setup;
mod theme;
mod updater;
mod viewer;

use eframe::egui;
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use theme::*;
use x86sim_core::{host, instance, logs};

fn main() -> eframe::Result<()> {
    let opts = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default().with_inner_size([1280.0, 820.0]).with_min_inner_size([900.0, 600.0]).with_title("x86Sim").with_app_id("x86sim").with_decorations(false),
        ..Default::default()
    };
    eframe::run_native("x86Sim", opts, Box::new(|cc| Ok(Box::new(App::new(cc)))))
}

#[derive(Default)]
pub struct Shared {
    pub insts: Vec<instance::Instance>,
    pub status: HashMap<String, instance::Status>,
    pub monitor: instance::Monitor,
    pub polled: bool,
    pub fetches: Vec<host::Fetch>,
    /// bumped when the window changes the phone list itself (add, rename, delete): a poll that read the list before
    /// that doesn't write its older copy back over it
    pub insts_gen: u64,
}

#[derive(Clone, PartialEq)]
pub enum View {
    Home,
    Phone(String),
    Ios,
    Aot,
    Settings,
    Setup,
}

pub struct AddDialog {
    pub model: usize,
    /// the model the runtime choice was last matched to
    pub last_model: usize,
    pub runtime: usize,
    pub name: String,
    pub busy: Arc<Mutex<Option<Result<std::path::PathBuf, String>>>>,
    pub working: bool,
}

/// A phone dialog: rename, or confirm removing it.
pub enum Dialog {
    Rename { id: String, text: String },
    /// size: what it frees (measured in the background)
    Delete { id: String, paths: Vec<std::path::PathBuf>, size: Arc<Mutex<Option<u64>>> },
}

pub struct App {
    /// fresh phones already restarted once after a stalled first boot
    pub first_boot_retried: HashSet<String>,
    /// phones running at the last frame (a stop starts an automatic pre-translate update)
    was_running: HashSet<String>,
    pub dialog: Option<Dialog>,
    pub shared: Arc<Mutex<Shared>>,
    pub insts: Vec<instance::Instance>,
    pub status: HashMap<String, instance::Status>,
    pub view: View,
    pub viewers: HashMap<String, viewer::Viewer>,
    pub hub: host::HubSettings,
    pub updater: updater::Updater,
    pub open: HashSet<&'static str>,
    pub add: Option<AddDialog>,
    pub models: Vec<(String, String)>,
    pub message: String,
    pub message_at: Instant,
    pub logs: Option<(String, logs::Tail)>,
    pub log_filter: String,
    pub log_source: String,
    pub log_paused: bool,
    pub last_log_poll: Instant,
    pub settings: Option<(String, instance::BootSettings)>,
    pub aot: global::Aot,
    pub runtimes: Vec<host::Runtime>,
    pub catalogue: Arc<Mutex<Option<Vec<host::Catalogue>>>>,
    /// downloads in progress by build (the poller's view, plus ones just started)
    pub fetching: HashMap<String, host::Fetch>,
    pub fetch_started: HashMap<String, Instant>,
    pub hub_show_betas: bool,
    /// phones whose separate viewer window is open, and the GPU helper count (checked every few seconds, not per frame)
    pub simview_open: HashSet<String>,
    pub gpu_helpers: usize,
    pub sizes: Arc<Mutex<HashMap<std::path::PathBuf, u64>>>,
    pub measuring: bool,
    pub disk: host::Disk,
    pub last_slow: Instant,
    pub setup: setup::Setup,
    pub setup_checking: bool,
    pub ctx: egui::Context,
}

impl App {
    fn new(cc: &eframe::CreationContext) -> App {
        theme(&cc.egui_ctx);
        let shared = Arc::new(Mutex::new(Shared::default()));
        // status of every phone every 2 s; one repaint per poll
        let sh = shared.clone();
        let ctx = cc.egui_ctx.clone();
        // repaint only when something shown changed (state, memory to 64 MB, CPU to 5 %, uptime minutes, downloads)
        std::thread::spawn(move || {
            let mut last_sig = 0u64;
            let mut n = 0u64;
            loop {
                let gen0 = sh.lock().unwrap().insts_gen;
                let insts = instance::list();
                let sig;
                {
                    let mut g = sh.lock().unwrap();
                    let st = g.monitor.poll(&insts);
                    // downloads: every poll while one runs, else every third (another /proc scan)
                    let fetches = if !g.fetches.is_empty() || n % 3 == 0 { host::fetches() } else { vec![] };
                    n += 1;
                    let mut h = x86sim_core::key::Fnv64::new();
                    for i in &insts {
                        h.str(&i.id);
                        h.str(&i.name);
                        h.str(&i.ring.to_string_lossy());
                        h.u64(i.runtime_present as u64);
                    }
                    for s in &st {
                        h.u64(s.phase as u64 | (s.home as u64) << 4 | (s.fresh as u64) << 5);
                        h.u64((s.pss_mb / 64.0) as u64);
                        h.u64((s.cpu_pct / 5.0) as u64);
                        h.u64(s.uptime_s.map(|u| (u / 60.0) as u64 + 1).unwrap_or(0));
                        h.u64(s.procs.len() as u64);
                    }
                    for f in &fetches {
                        h.str(&f.build);
                        h.str(&f.phase);
                        h.u64(f.done_bytes >> 24);
                    }
                    sig = h.finish();
                    g.status = st.into_iter().map(|s| (s.id.clone(), s)).collect();
                    if g.insts_gen == gen0 {
                        g.insts = insts;
                    }
                    g.polled = true;
                    g.fetches = fetches;
                }
                if sig != last_sig {
                    last_sig = sig;
                    ctx.request_repaint();
                }
                std::thread::sleep(Duration::from_secs(2));
            }
        });
        let runtimes = host::runtimes();
        let catalogue = Arc::new(Mutex::new(None));
        let c2 = catalogue.clone();
        std::thread::spawn(move || {
            let v = host::catalogue(false);
            *c2.lock().unwrap() = Some(v);
        });
        let aot = global::Aot::new(runtimes.iter().find(|r| r.present && r.restricted_to.is_empty()).map(|r| r.root.clone()));
        // start view / open sections, for scripted screenshots: X86SIM_LAUNCHER_VIEW=ios|aot|settings|add|phone:<id>,
        // X86SIM_LAUNCHER_OPEN=features,logs,perf,adv
        let view = match std::env::var("X86SIM_LAUNCHER_VIEW").unwrap_or_default().as_str() {
            "ios" => View::Ios,
            "aot" => View::Aot,
            "settings" => View::Settings,
            "setup" => View::Setup,
            v if v.starts_with("phone:") => View::Phone(v[6..].to_string()),
            _ if x86sim_core::setup::needed() => View::Setup,
            _ => View::Home,
        };
        let mut open = HashSet::new();
        for k in std::env::var("X86SIM_LAUNCHER_OPEN").unwrap_or_default().split(',') {
            for key in ["features", "logs", "perf", "adv"] {
                if k == key {
                    open.insert(key);
                }
            }
        }
        let add_on_start = std::env::var("X86SIM_LAUNCHER_VIEW").is_ok_and(|v| v == "add");
        let mut app = App {
            dialog: None,
            first_boot_retried: HashSet::new(),
            was_running: HashSet::new(),
            shared,
            insts: instance::list(),
            status: HashMap::new(),
            view,
            viewers: HashMap::new(),
            hub: host::load_hub(),
            updater: Default::default(),
            open,
            add: None,
            models: x86sim_core::sim::models(),
            message: String::new(),
            message_at: Instant::now(),
            logs: None,
            log_filter: String::new(),
            log_source: String::new(),
            log_paused: false,
            last_log_poll: Instant::now(),
            settings: None,
            aot,
            runtimes,
            catalogue,
            fetching: HashMap::new(),
            fetch_started: HashMap::new(),
            hub_show_betas: false,
            simview_open: HashSet::new(),
            gpu_helpers: 0,
            sizes: Arc::new(Mutex::new(HashMap::new())),
            measuring: false,
            disk: host::disk(&x86sim_core::aot::scratch()),
            last_slow: Instant::now() - Duration::from_secs(60),
            setup: setup::Setup::default(),
            setup_checking: false,
            ctx: cc.egui_ctx.clone(),
        };
        if add_on_start {
            app.open_add_dialog();
        }
        app
    }

    pub fn say(&mut self, m: impl Into<String>) {
        self.message = m.into();
        self.message_at = Instant::now();
    }

    pub fn inst(&self, id: &str) -> Option<&instance::Instance> {
        self.insts.iter().find(|i| i.id == id)
    }

    pub fn phase(&self, id: &str) -> instance::Phase {
        self.status.get(id).map(|s| s.phase).unwrap_or(instance::Phase::Off)
    }

    pub fn viewer(&mut self, id: &str) -> Option<&mut viewer::Viewer> {
        if !self.viewers.contains_key(id) {
            let inst = self.inst(id)?.clone();
            self.viewers.insert(id.to_string(), viewer::Viewer::new(&inst, self.ctx.clone()));
        }
        let bt = self.status.get(id).and_then(|s| s.boot_time);
        // Models 2: a two-screen phone shows the screen SpringBoard uses: the inner one while the hinge is open
        let inst = self.inst(id)?;
        let (ring, screen, display) = match &inst.inner {
            Some(d) if inst.inner_active() => (d.ring.clone(), d.upright(), Some((d.id, d.rotation))),
            _ => (inst.ring.clone(), inst.screen, None),
        };
        let v = self.viewers.get_mut(id)?;
        v.set_ring(&ring);
        v.set_display(screen, display);
        v.set_boot_time(bt);
        Some(v)
    }

    pub fn start(&mut self, id: &str) {
        let Some(inst) = self.inst(id).cloned() else { return };
        let others: Vec<instance::Status> = self.status.values().cloned().collect();
        match instance::start(&inst, &others) {
            Ok(_) => {
                self.shared.lock().unwrap().monitor.starting.insert(id.to_string(), Instant::now());
                self.status.entry(id.to_string()).and_modify(|s| s.phase = instance::Phase::Starting);
                self.say(format!("Starting {}", inst.name));
                if self.hub.open_on_start {
                    self.view = View::Phone(id.to_string());
                }
            }
            Err(e) => self.say(format!("Couldn't start: {e:#}")),
        }
    }

    pub fn stop(&mut self, id: &str) {
        let Some(inst) = self.inst(id).cloned() else { return };
        let st = self.status.get(id).cloned();
        self.shared.lock().unwrap().monitor.stopping.insert(id.to_string(), Instant::now());
        self.status.entry(id.to_string()).and_modify(|s| s.phase = instance::Phase::Stopping);
        self.say(format!("Stopping {}", inst.name));
        std::thread::spawn(move || {
            let _ = instance::stop(&inst, st.as_ref());
        });
    }

    pub fn restart(&mut self, id: &str) {
        let Some(inst) = self.inst(id).cloned() else { return };
        let st = self.status.get(id).cloned();
        let others: Vec<instance::Status> = self.status.values().filter(|s| s.id != id).cloned().collect();
        let sh = self.shared.clone();
        sh.lock().unwrap().monitor.stopping.insert(id.to_string(), Instant::now());
        self.status.entry(id.to_string()).and_modify(|s| s.phase = instance::Phase::Stopping);
        self.say(format!("Restarting {}", inst.name));
        let id = id.to_string();
        std::thread::spawn(move || {
            let _ = instance::restart(&inst, st.as_ref(), &others);
            let mut g = sh.lock().unwrap();
            g.monitor.stopping.remove(&id);
            g.monitor.starting.insert(id, Instant::now());
        });
    }

    pub fn refresh_instances(&mut self) {
        self.insts = instance::list();
        self.runtimes = host::runtimes();
        // the poller's copy too, at once: otherwise the next sync shows its older list until the next poll (~2 s)
        let mut g = self.shared.lock().unwrap();
        g.insts = self.insts.clone();
        g.insts_gen += 1;
    }

    fn sync(&mut self) {
        let g = self.shared.lock().unwrap();
        if g.polled {
            // the poller's view of the phones is the truth (a boot rewrites sim.env: ring, model, name)
            self.insts = g.insts.clone();
            self.status = g.status.clone();
            // downloads: what runs, plus ones started in the last seconds that the poller hasn't seen yet
            let mut f: HashMap<String, host::Fetch> = g.fetches.iter().map(|f| (f.build.clone(), f.clone())).collect();
            self.fetch_started.retain(|_, t| t.elapsed() < Duration::from_secs(15));
            for (b, _) in self.fetch_started.iter() {
                f.entry(b.clone()).or_insert_with(|| host::Fetch { build: b.clone(), phase: "starting".into(), ..Default::default() });
            }
            let finished = self.fetching.keys().any(|b| !f.contains_key(b));
            self.fetching = f;
            if finished {
                self.runtimes = host::runtimes();
                self.insts = instance::list();
            }
        }
    }

    /// Hub shortcuts. Not while the phone's screen has the keyboard (keys go to the phone) or a text field is focused.
    fn shortcuts(&mut self, ctx: &egui::Context) {
        let phone_typing = matches!(&self.view, View::Phone(id) if self.viewers.get(id).is_some_and(|v| v.focused));
        if phone_typing || ctx.wants_keyboard_input() || self.add.is_some() || self.dialog.is_some() {
            return;
        }
        use egui::{Key, KeyboardShortcut, Modifiers};
        let sc = |m: Modifiers, k: Key| ctx.input_mut(|i| i.consume_shortcut(&KeyboardShortcut::new(m, k)));
        if sc(Modifiers::COMMAND, Key::Num1) {
            self.view = View::Home;
        } else if sc(Modifiers::COMMAND, Key::Num2) {
            self.view = View::Ios;
            self.runtimes = host::runtimes();
        } else if sc(Modifiers::COMMAND, Key::Num3) {
            self.view = View::Aot;
        } else if sc(Modifiers::COMMAND, Key::Num4) {
            self.view = View::Settings;
            self.last_slow = Instant::now() - Duration::from_secs(60);
        } else if sc(Modifiers::COMMAND, Key::N) {
            self.open_add_dialog();
        } else if let View::Phone(id) = self.view.clone() {
            if sc(Modifiers::COMMAND, Key::R) && self.phase(&id) != instance::Phase::Off {
                self.restart(&id);
            } else if sc(Modifiers::NONE, Key::Escape) {
                self.view = View::Home;
            }
        }
    }

    fn view_name(&self) -> &str {
        match &self.view {
            View::Home => "home",
            View::Phone(id) => id,
            View::Ios => "ios",
            View::Aot => "aot",
            View::Settings => "settings",
            View::Setup => "setup",
        }
    }

    fn running_summary(&self) -> (usize, f64) {
        let n = self.status.values().filter(|s| s.phase != instance::Phase::Off).count();
        let mb: f64 = self.status.values().map(|s| s.pss_mb).sum();
        (n, mb)
    }
}

impl eframe::App for App {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        // self-update: at start and every 6 hours (cheap when not due)
        if self.hub.check_updates {
            self.updater.check(ctx, false, &self.hub.channel);
        }
        // X86SIM_LAUNCHER_FPS=1: frames per second on stderr (idle cost checks)
        static FPS: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
        if *FPS.get_or_init(|| std::env::var_os("X86SIM_LAUNCHER_FPS").is_some()) {
            static N: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
            static T: Mutex<Option<Instant>> = Mutex::new(None);
            N.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            let mut t = T.lock().unwrap();
            let t0 = *t.get_or_insert_with(Instant::now);
            if t0.elapsed() >= Duration::from_secs(5) {
                eprintln!("frames/s {:.1} ({:?})", N.swap(0, std::sync::atomic::Ordering::Relaxed) as f64 / t0.elapsed().as_secs_f64(), self.view_name());
                *t = Some(Instant::now());
            }
        }
        self.sync();
        self.shortcuts(ctx);
        if self.last_slow.elapsed() > Duration::from_secs(10) {
            self.last_slow = Instant::now();
            self.disk = host::disk(&x86sim_core::aot::scratch());
            if self.view == View::Settings {
                self.gpu_helpers = host::mtlvk_pids().len();
                self.simview_open = self.insts.iter().filter(|i| self.status.get(&i.id).is_some_and(|s| s.phase != instance::Phase::Off) && x86sim_core::sim::simview_running_for(i)).map(|i| i.id.clone()).collect();
            }
            if self.view == View::Ios {
                self.runtimes = host::runtimes();
            }
            ctx.request_repaint_after(Duration::from_secs(10));
        }
        let running: HashSet<String> = self.status.values().filter(|s| s.phase != instance::Phase::Off).map(|s| s.id.clone()).collect();
        if self.was_running.iter().any(|id| !running.contains(id)) {
            // its .live feedback is written at exit
            self.aot.want_auto(Duration::from_secs(5));
        }
        self.aot.phones_running = !running.is_empty();
        self.was_running = running;
        self.aot.tick();
        if self.aot.building() {
            ctx.request_repaint_after(Duration::from_millis(500));
        }
        // a new phone's first boot can stall on iOS's app database (known; the second boot works): restart it once
        let stalled: Vec<String> = self.status.values().filter(|s| instance::first_boot_stalled(s) && !self.first_boot_retried.contains(&s.id)).map(|s| s.id.clone()).collect();
        for id in stalled {
            self.first_boot_retried.insert(id.clone());
            let name = self.inst(&id).map(|i| i.name.clone()).unwrap_or_default();
            self.restart(&id);
            self.say(format!("{name}'s first start stalled while it set up its apps. Restarting it once (this is expected for a new phone)."));
        }
        // thumbnails and the open phone's screen only: everything else sleeps
        let open_id = if let View::Phone(id) = &self.view { Some(id.clone()) } else { None };
        for (id, v) in self.viewers.iter_mut() {
            if Some(id) != open_id.as_ref() && !(self.view == View::Home && self.hub.thumbnails) {
                v.shared.mode.store(viewer::OFF, std::sync::atomic::Ordering::Relaxed);
            }
        }

        title_bar(ctx);
        let (nrun, mb) = self.running_summary();
        egui::SidePanel::left("nav")
            .resizable(false)
            .exact_width(212.0)
            .frame(egui::Frame::new().fill(WINDOW).inner_margin(egui::Margin { left: 10, right: 10, top: 16, bottom: 14 }))
            .show(ctx, |ui| {
                ui.horizontal(|ui| {
                    ui.add_space(6.0);
                    let (r, _) = ui.allocate_exact_size(egui::vec2(28.0, 28.0), egui::Sense::hover());
                    ui.painter().rect_filled(r, 7.0, ACCENT_FILL);
                    ui.painter().text(r.center(), egui::Align2::CENTER_CENTER, icon::DEVICE_MOBILE, font(17.0), egui::Color32::WHITE);
                    ui.add_space(2.0);
                    ui.vertical(|ui| {
                        ui.spacing_mut().item_spacing.y = 0.0;
                        ui.label(egui::RichText::new("x86Sim").size(T_LG).family(semibold()).color(INK));
                        ui.label(muted("iPhone simulator").size(T_CAPTION));
                    });
                });
                ui.add_space(S5);
                ui.spacing_mut().item_spacing.y = 2.0;
                let n = self.insts.len();
                let on_phones = matches!(self.view, View::Home | View::Phone(_));
                if nav_item(ui, icon::SQUARES_FOUR, "Phones", on_phones, &if n > 0 { n.to_string() } else { String::new() }, "Ctrl+1") {
                    self.view = View::Home;
                }
                if nav_item(ui, icon::DOWNLOAD_SIMPLE, "Versions", self.view == View::Ios, "", "Ctrl+2") {
                    self.view = View::Ios;
                    self.runtimes = host::runtimes();
                }
                if nav_item(ui, icon::LIGHTNING, "Pre-translate", self.view == View::Aot, if self.aot.building() { "•" } else { "" }, "Ctrl+3") {
                    self.view = View::Aot;
                }
                if nav_item(ui, icon::GEAR_SIX, "Settings", self.view == View::Settings, "", "Ctrl+4") {
                    self.view = View::Settings;
                    self.last_slow = Instant::now() - Duration::from_secs(60);
                }
                if nav_item(ui, icon::WRENCH, "Setup", self.view == View::Setup, "", "") {
                    self.view = View::Setup;
                    self.setup.refresh(ui.ctx());
                    self.setup_checking = true;
                    self.refresh_instances();
                }
                // footer: host status, pinned to the bottom
                let upd_h = match self.updater.phase() {
                    updater::Phase::Available(_) | updater::Phase::Ready(..) => 34.0,
                    updater::Phase::Downloading(_) => 30.0,
                    _ => 0.0,
                };
                let footer_h = 40.0 + upd_h + if self.aot.building() { 30.0 } else { 0.0 };
                ui.add_space((ui.available_height() - footer_h).max(S4));
                egui::Frame::new().inner_margin(egui::Margin::symmetric(8, 0)).show(ui, |ui| {
                    ui.set_width(ui.available_width());
                    ui.spacing_mut().item_spacing.y = 4.0;
                    self.update_footer(ui);
                    if self.aot.building() {
                        let frac = self.aot.progress.as_ref().map(|p| if p.chunks_total > 0 { p.chunks_done as f32 / p.chunks_total as f32 } else { 0.0 }).unwrap_or(0.0);
                        ui.label(muted(format!("Pre-translating · {:.0}%", frac * 100.0)));
                        ui.add(egui::ProgressBar::new(frac).desired_height(4.0).fill(ACCENT).corner_radius(2));
                        ui.add_space(4.0);
                    }
                    if nrun > 0 {
                        dot_label(ui, &format!("{nrun} running · {}", fmt_mb(mb)), GOOD);
                    } else {
                        dot_label(ui, "Nothing running", INK_3);
                    }
                    ui.label(muted(format!("{} free for caches", if self.disk.free_gb >= 1000.0 { format!("{:.1} TB", self.disk.free_gb / 1000.0) } else { format!("{:.0} GB", self.disk.free_gb) })));
                });
            });

        let view = self.view.clone();
        match view {
            View::Phone(id) => self.phone_view(ctx, &id),
            _ => {
                egui::CentralPanel::default().frame(egui::Frame::new().fill(CANVAS)).show(ctx, |ui| {
                    egui::ScrollArea::vertical().id_salt(match &view { View::Home => "home", View::Ios => "ios", View::Aot => "aot", View::Setup => "setup", _ => "settings" }).auto_shrink([false, false]).show(ui, |ui| {
                        // the page owns its margins so the scrollbar sits in the gutter, not on the content
                        egui::Frame::new().inner_margin(egui::Margin { left: S6 as i8, right: S6 as i8, top: S5 as i8, bottom: S6 as i8 }).show(ui, |ui| {
                            ui.set_width(ui.available_width());
                            match view {
                                View::Home => self.home(ui),
                                View::Ios => self.ios_page(ui),
                                View::Aot => self.aot_page(ui),
                                View::Settings => self.settings_page(ui),
                                View::Setup => self.setup_page(ui),
                                View::Phone(_) => {}
                            }
                        });
                    });
                });
            }
        }
        self.add_dialog(ctx);
        self.phone_dialog(ctx);
        if !self.message.is_empty() && self.message_at.elapsed() < Duration::from_secs(6) {
            egui::Area::new("toast".into()).anchor(egui::Align2::CENTER_BOTTOM, egui::vec2(106.0, -24.0)).order(egui::Order::Foreground).show(ctx, |ui| {
                egui::Frame::new()
                    .fill(RAISED)
                    .stroke(egui::Stroke::new(1.0_f32, BORDER_STRONG))
                    .corner_radius(8)
                    .shadow(egui::Shadow { offset: [0, 6], blur: 20, spread: 0, color: egui::Color32::from_black_alpha(120) })
                    .inner_margin(egui::Margin::symmetric(14, 9))
                    .show(ui, |ui| {
                        ui.horizontal(|ui| {
                            ui.label(egui::RichText::new(icon::INFO).size(15.0).color(INK_2));
                            ui.label(body(&self.message));
                        });
                    });
            });
            ctx.request_repaint_after(Duration::from_secs(6));
        }
    }
}

/// The window's own title bar (the app is undecorated: tiling compositors such as Hyprland draw none): drag to move,
/// double-click to maximize, and minimize / maximize / close buttons on the right.
fn title_bar(ctx: &egui::Context) {
    const H: f32 = 40.0;
    // no frame stroke and no panel separator: either leaves a 1 px gap above the content; one bottom rule instead
    egui::TopBottomPanel::top("title-bar")
        .exact_height(H)
        .show_separator_line(false)
        .frame(egui::Frame::new().fill(WINDOW).inner_margin(0).outer_margin(0))
        .show(ctx, |ui| {
            ui.spacing_mut().item_spacing = egui::Vec2::ZERO;
            let rect = ui.max_rect();
            ui.painter().hline(rect.x_range(), rect.bottom() - 0.5, egui::Stroke::new(1.0_f32, BORDER));
            // the whole bar drags the window; the buttons, added after, take their clicks first
            let bar = ui.interact(rect, egui::Id::new("title-bar-drag"), egui::Sense::click_and_drag());
            let maximized = ctx.input(|i| i.viewport().maximized.unwrap_or(false));
            // the window manager must get the move request on the press itself (winit drag_window), not once egui
            // has seen the pointer travel; and not over the three buttons on the right
            let buttons_left = rect.right() - 3.0 * 46.0;
            let press = ctx.input(|i| {
                i.pointer.button_pressed(egui::PointerButton::Primary) && i.pointer.interact_pos().is_some_and(|p| rect.contains(p) && p.x < buttons_left)
            });
            if bar.double_clicked() && bar.interact_pointer_pos().is_some_and(|p| p.x < buttons_left) {
                ctx.send_viewport_cmd(egui::ViewportCommand::Maximized(!maximized));
            } else if press {
                ctx.send_viewport_cmd(egui::ViewportCommand::StartDrag);
            }
            ui.painter().text(
                rect.left_center() + egui::vec2(S4, 0.0),
                egui::Align2::LEFT_CENTER,
                "x86Sim",
                egui::FontId::new(T_BODY, medium()),
                INK_2,
            );
            // buttons: close, maximize/restore, minimize (right to left)
            let bw = 46.0;
            let mut x = rect.right();
            // icons are drawn, not font glyphs (the UI font has no ✕ / ❐)
            #[derive(PartialEq, Clone, Copy)]
            enum Icon { Close, Max, Restore, Min }
            let mut button = |icon: Icon, hover: egui::Color32, id: &str| -> bool {
                x -= bw;
                let r = egui::Rect::from_min_size(egui::pos2(x, rect.top()), egui::vec2(bw, rect.height()));
                let resp = ui.interact(r, egui::Id::new(id), egui::Sense::click());
                if resp.hovered() {
                    ui.painter().rect_filled(r, 0.0, hover);
                }
                let ink = if resp.hovered() && icon == Icon::Close { egui::Color32::WHITE } else { INK_2 };
                let st = egui::Stroke::new(1.2_f32, ink);
                let c = r.center();
                let h = 5.0;
                let p = ui.painter();
                match icon {
                    Icon::Close => {
                        p.line_segment([c + egui::vec2(-h, -h), c + egui::vec2(h, h)], st);
                        p.line_segment([c + egui::vec2(-h, h), c + egui::vec2(h, -h)], st);
                    }
                    Icon::Max => {
                        p.rect_stroke(egui::Rect::from_center_size(c, egui::vec2(2.0 * h, 2.0 * h)), 1.0, st, egui::StrokeKind::Inside);
                    }
                    Icon::Restore => {
                        p.rect_stroke(egui::Rect::from_center_size(c + egui::vec2(-1.5, 1.5), egui::vec2(1.6 * h, 1.6 * h)), 1.0, st, egui::StrokeKind::Inside);
                        p.line_segment([c + egui::vec2(-h + 1.5, -h), c + egui::vec2(h, -h)], st);
                        p.line_segment([c + egui::vec2(h, -h), c + egui::vec2(h, h - 1.5)], st);
                    }
                    Icon::Min => {
                        p.line_segment([c + egui::vec2(-h, 0.0), c + egui::vec2(h, 0.0)], st);
                    }
                }
                resp.on_hover_cursor(egui::CursorIcon::PointingHand).clicked()
            };
            if button(Icon::Close, CRIT, "title-close") {
                ctx.send_viewport_cmd(egui::ViewportCommand::Close);
            }
            if button(if maximized { Icon::Restore } else { Icon::Max }, HOVER, "title-max") {
                ctx.send_viewport_cmd(egui::ViewportCommand::Maximized(!maximized));
            }
            if button(Icon::Min, HOVER, "title-min") {
                ctx.send_viewport_cmd(egui::ViewportCommand::Minimized(true));
            }
        });
}
