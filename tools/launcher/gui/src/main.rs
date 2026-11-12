//! x86Sim hub: every phone (var/device-a64*) as a card with its live screen, open one for its embedded screen with
//! touch and keyboard plus a fold-out panel (features, logs, performance, advanced); global pages for iOS versions,
//! pre-translation (AOT) and settings. Logic lives in x86sim-core; the GUI repaints only when a frame or a status
//! changes.
mod global;
mod home;
mod omarchy;
mod phone;
mod remote;
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

/// The sidebar's width
pub const NAV_W: f32 = 192.0;

/// Under Hyprland the compositor owns the window frame: we ask it for server-side decorations, so a floating window
/// gets Omarchy's title bar (hyprbars) and a tiled one stays bare, like Omarchy's own apps. Elsewhere we draw our own.
pub fn compositor_decorates() -> bool {
    std::env::var_os("HYPRLAND_INSTANCE_SIGNATURE").is_some()
}

fn main() -> eframe::Result<()> {
    let opts = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default().with_inner_size([1280.0, 820.0]).with_min_inner_size([900.0, 600.0]).with_title("x86Sim").with_app_id("x86sim").with_decorations(compositor_decorates()),
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
    /// the build whose stopped download "Discard" asked to confirm
    pub confirm_discard: Option<String>,
    /// the GPU helper count (checked every few seconds, not per frame)
    pub gpu_helpers: usize,
    pub sizes: Arc<Mutex<HashMap<std::path::PathBuf, u64>>>,
    pub measuring: bool,
    pub disk: host::Disk,
    pub last_slow: Instant,
    pub setup: setup::Setup,
    pub setup_checking: bool,
    pub ctx: egui::Context,
    /// the `?` overlay
    pub help: bool,
    /// `q` asked to quit while devices run or work is in progress
    pub quit_confirm: bool,
    /// the device under the keyboard cursor on the Devices page (set while it is drawn)
    pub cursor_device: Option<String>,
}

impl App {
    fn new(cc: &eframe::CreationContext) -> App {
        // the saved Appearance before the first frame, so it never flashes the other look
        theme::set_appearance(&cc.egui_ctx, theme::Appearance::parse(&host::load_hub().appearance));
        omarchy::watch(cc.egui_ctx.clone());
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
                    let fetches = if !g.fetches.is_empty() || n.is_multiple_of(3) { host::fetches() } else { vec![] };
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
                        h.u64(s.gpu.as_ref().map(|g| (g.pss_mb / 64.0) as u64 + ((g.users as u64) << 32)).unwrap_or(u64::MAX));
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
            confirm_discard: None,
            gpu_helpers: 0,
            sizes: Arc::new(Mutex::new(HashMap::new())),
            measuring: false,
            disk: host::disk(&x86sim_core::aot::scratch()),
            last_slow: Instant::now() - Duration::from_secs(60),
            setup: setup::Setup::default(),
            setup_checking: false,
            ctx: cc.egui_ctx.clone(),
            help: false,
            quit_confirm: false,
            cursor_device: None,
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
            for b in self.fetch_started.keys() {
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

    /// The Setup page, re-checked each time it opens (nav item, Ctrl+5)
    fn open_setup(&mut self, ctx: &egui::Context) {
        self.view = View::Setup;
        self.setup.refresh(ctx);
        self.setup_checking = true;
        self.refresh_instances();
    }

    /// Keyboard first: every main action has a key (`?` lists them). Not while the phone's screen has the keyboard
    /// (keys go to the phone), a text field is focused or a dialog is open. The page keys (j / k, Enter) move the
    /// row cursor, which the page draws and acts on.
    fn shortcuts(&mut self, ctx: &egui::Context) {
        use egui::{Key, KeyboardShortcut, Modifiers};
        let key = |k: Key| ctx.input_mut(|i| i.consume_key(Modifiers::NONE, k));
        let ctrl = |k: Key| ctx.input_mut(|i| i.consume_shortcut(&KeyboardShortcut::new(Modifiers::COMMAND, k)));
        let question = || ctx.input_mut(|i| i.consume_key(Modifiers::SHIFT, Key::Questionmark) || i.consume_key(Modifiers::NONE, Key::Questionmark) || i.consume_key(Modifiers::SHIFT, Key::Slash));
        if self.help {
            if key(Key::Escape) || question() || key(Key::Q) {
                self.help = false;
            }
            nav::begin_frame(0, 0, false);
            return;
        }
        if self.quit_confirm {
            if key(Key::Enter) || key(Key::Q) || key(Key::Y) {
                ctx.send_viewport_cmd(egui::ViewportCommand::Close);
            } else if key(Key::Escape) || key(Key::N) {
                self.quit_confirm = false;
            }
            nav::begin_frame(0, 0, false);
            return;
        }
        let phone_typing = matches!(&self.view, View::Phone(id) if self.viewers.get(id).is_some_and(|v| v.focused));
        if phone_typing || ctx.wants_keyboard_input() || self.add.is_some() || self.dialog.is_some() {
            nav::begin_frame(0, 0, false);
            return;
        }
        if question() {
            self.help = true;
        } else if key(Key::Q) {
            self.quit();
        } else if key(Key::Num1) || ctrl(Key::Num1) {
            self.view = View::Home;
        } else if key(Key::Num2) || ctrl(Key::Num2) {
            self.view = View::Ios;
            self.runtimes = host::runtimes();
        } else if key(Key::Num3) || ctrl(Key::Num3) {
            self.view = View::Aot;
        } else if key(Key::Num4) || ctrl(Key::Num4) {
            self.view = View::Settings;
            self.last_slow = Instant::now() - Duration::from_secs(60);
        } else if key(Key::Num5) || ctrl(Key::Num5) {
            self.open_setup(ctx);
        } else if key(Key::N) || ctrl(Key::N) {
            self.open_add_dialog();
        } else if key(Key::Slash) {
            nav::want_search();
        }
        // the device the keys act on: the open one, else the one under the cursor
        let target = match &self.view {
            View::Phone(id) => Some(id.clone()),
            View::Home => self.cursor_device.clone(),
            _ => None,
        };
        if let Some(id) = target {
            let phase = self.phase(&id);
            let present = self.inst(&id).is_some_and(|i| i.runtime_present);
            if key(Key::S) {
                match phase {
                    instance::Phase::Off if present => self.start(&id),
                    instance::Phase::Running | instance::Phase::Starting => self.stop(&id),
                    _ => {}
                }
            } else if key(Key::R) || ctrl(Key::R) {
                if phase != instance::Phase::Off {
                    self.restart(&id);
                }
            } else if key(Key::O) {
                if phase != instance::Phase::Off {
                    if let Some(inst) = self.inst(&id).cloned() {
                        match x86sim_core::sim::show_phone(&inst) {
                            Ok(()) => self.say(format!("Opened {} in its own window", inst.name)),
                            Err(e) => self.say(format!("Couldn't open the window: {e:#}")),
                        }
                    }
                }
            } else if key(Key::F2) {
                if let Some(inst) = self.inst(&id).cloned() {
                    self.dialog = Some(Dialog::Rename { id: inst.id.clone(), text: inst.name.clone() });
                }
            } else if key(Key::Delete) {
                if let Some(inst) = self.inst(&id).cloned() {
                    if phase == instance::Phase::Off && !inst.is_default {
                        self.ask_remove(&inst, ctx);
                    }
                }
            }
        }
        let mut dx = 0;
        let mut dy = 0;
        let mut enter = false;
        match self.view.clone() {
            View::Phone(_) => {
                if key(Key::Escape) {
                    self.view = View::Home;
                }
                // the inspector's folds
                for (k, sec) in [(Key::F, "features"), (Key::L, "logs"), (Key::P, "perf"), (Key::A, "adv")] {
                    if key(k) && !self.open.remove(sec) {
                        self.open.insert(sec);
                    }
                }
            }
            View::Aot => {
                if key(Key::C) && self.aot.building() {
                    self.aot.cancel();
                }
            }
            _ => {}
        }
        if !matches!(self.view, View::Phone(_)) {
            if key(Key::J) || key(Key::ArrowDown) {
                dy += 1;
            }
            if key(Key::K) || key(Key::ArrowUp) {
                dy -= 1;
            }
            if self.view == View::Home {
                if key(Key::L) || key(Key::ArrowRight) {
                    dx += 1;
                }
                if key(Key::H) || key(Key::ArrowLeft) {
                    dx -= 1;
                }
            }
            if key(Key::Enter) {
                enter = true;
            }
            if key(Key::Escape) {
                nav::clear();
            }
        }
        nav::begin_frame(dx, dy, enter);
    }

    /// `q`: closes at once when nothing is going on; asks first while devices run or work is in progress (they
    /// carry on without the window, but a stray key shouldn't take it away).
    fn quit(&mut self) {
        let running = self.status.values().any(|s| s.phase != instance::Phase::Off);
        if running || !self.fetching.is_empty() || self.aot.child.is_some() || self.add.as_ref().is_some_and(|a| a.working) {
            self.quit_confirm = true;
        } else {
            self.ctx.send_viewport_cmd(egui::ViewportCommand::Close);
        }
    }

    /// What `q` asks and what `?` lists.
    fn quit_dialog(&mut self, ctx: &egui::Context) {
        if !self.quit_confirm {
            return;
        }
        let n = self.status.values().filter(|s| s.phase != instance::Phase::Off).count();
        let mut what = vec![];
        if n > 0 {
            what.push(format!("{n} device{} keep{} running", if n == 1 { "" } else { "s" }, if n == 1 { "s" } else { "" }));
        }
        if !self.fetching.is_empty() {
            what.push("the download continues".to_string());
        }
        if self.aot.child.is_some() {
            what.push("pre-translating continues".to_string());
        }
        if self.add.as_ref().is_some_and(|a| a.working) {
            what.push("the device being set up is kept".to_string());
        }
        let m = modal("quit").show(ctx, |ui| {
            ui.set_width(360.0);
            ui.spacing_mut().item_spacing.y = 4.0;
            ui.label(dialog_title("Quit x86Sim?"));
            ui.label(sub(format!("Without the window, {}.", what.join("; "))));
            ui.add_space(S4);
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                if ui.add(Btn::primary("Quit").key("Enter").min_w(88.0)).clicked() {
                    ctx.send_viewport_cmd(egui::ViewportCommand::Close);
                }
                if ui.add(Btn::secondary("Stay").key("Esc").min_w(80.0)).clicked() {
                    self.quit_confirm = false;
                }
            });
        });
        if m.should_close() {
            self.quit_confirm = false;
        }
    }

    fn help_overlay(&mut self, ctx: &egui::Context) {
        if !self.help {
            return;
        }
        let page: &[(&str, &str)] = match &self.view {
            View::Home => &[("h / l  j / k", "move between devices"), ("Enter", "open the device"), ("s", "start / stop it"), ("r", "restart it"), ("o", "its screen in its own window"), ("F2", "rename it"), ("Delete", "remove it (when off)"), ("Esc", "drop the cursor")],
            View::Phone(_) => &[("click the screen", "keys go to the device; click outside to get them back"), ("s", "start / stop"), ("r", "restart"), ("o", "its screen in its own window"), ("f  l  p  a", "features, logs, performance, advanced"), ("F2", "rename"), ("Delete", "remove (when off)"), ("F1 – F4", "the device's buttons (see the i tool)"), ("Esc", "back to all devices")],
            View::Ios => &[("j / k", "move between versions"), ("Enter", "download, resume or pre-translate the version"), ("/", "search"), ("Esc", "drop the cursor")],
            View::Aot => &[("Enter", "start, update or finish (the cursor on the status)"), ("c", "cancel the run"), ("j / k", "move between options"), ("/", "search the parts")],
            View::Settings | View::Setup => &[("j / k", "move between rows"), ("Enter", "flip the switch, press the button, step the choice"), ("Esc", "drop the cursor")],
        };
        let m = modal("help").show(ctx, |ui| {
            ui.set_width(440.0);
            ui.spacing_mut().item_spacing.y = 2.0;
            ui.label(dialog_title("Keys"));
            ui.add_space(S3);
            let group = |ui: &mut egui::Ui, name: &str, rows: &[(&str, &str)]| {
                ui.label(overline(name));
                ui.add_space(2.0);
                for (k, what) in rows {
                    ui.horizontal(|ui| {
                        let (r, _) = ui.allocate_exact_size(egui::vec2(150.0, 18.0), egui::Sense::hover());
                        ui.painter().text(r.left_center(), egui::Align2::LEFT_CENTER, *k, font(T_SMALL), pal().ink);
                        ui.label(muted(*what));
                    });
                }
                ui.add_space(S3);
            };
            group(ui, "everywhere", &[("1 – 5", "devices, versions, pre-translate, settings, setup"), ("n", "add a device"), ("?", "this list"), ("q", "quit"), ("Tab", "move between controls")]);
            group(ui, "this page", page);
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                if ui.add(Btn::secondary("Close").key("Esc")).clicked() {
                    self.help = false;
                }
            });
        });
        if m.should_close() {
            self.help = false;
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
        // each phone's own processes, and every GPU helper once (a shared one serves several phones)
        let sts: Vec<_> = self.status.values().filter(|s| s.phase != instance::Phase::Off).collect();
        (sts.len(), instance::total_mb(&sts))
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
        theme::poll(ctx);
        self.sync();
        self.cursor_device = None;
        self.shortcuts(ctx);
        if self.last_slow.elapsed() > Duration::from_secs(10) {
            self.last_slow = Instant::now();
            self.disk = host::disk(&x86sim_core::aot::scratch());
            if self.view == View::Settings {
                self.gpu_helpers = host::mtlvk_pids().len();
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
        self.was_running = running;
        // the versions to keep pre-translated: a new or removed one is checked soon
        let present: Vec<std::path::PathBuf> = self.runtimes.iter().filter(|r| r.present).map(|r| r.root.clone()).collect();
        if present != self.aot.runtimes {
            if !self.aot.runtimes.is_empty() {
                self.aot.want_auto(Duration::from_secs(5));
            }
            self.aot.runtimes = present;
        }
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
            self.say(format!("{name}'s first start stalled while it set up its apps. Restarting it once (this is expected for a new device)."));
        }
        // thumbnails and the open phone's screen only: everything else sleeps
        let open_id = if let View::Phone(id) = &self.view { Some(id.clone()) } else { None };
        for (id, v) in self.viewers.iter_mut() {
            if Some(id) != open_id.as_ref() && !(self.view == View::Home && self.hub.thumbnails) {
                v.shared.mode.store(viewer::OFF, std::sync::atomic::Ordering::Relaxed);
            }
        }

        // under Hyprland the compositor draws the frame (see compositor_decorates); elsewhere our own title bar
        if !compositor_decorates() {
            title_bar(ctx);
        }
        let (nrun, mb) = self.running_summary();
        egui::SidePanel::left("nav")
            .resizable(false)
            .exact_width(NAV_W)
            .frame(egui::Frame::new().fill(pal().window).inner_margin(egui::Margin { left: 8, right: 8, top: 10, bottom: 12 }))
            .show(ctx, |ui| {
                ui.spacing_mut().item_spacing.y = 1.0;
                let n = self.insts.len();
                let on_phones = matches!(self.view, View::Home | View::Phone(_));
                if nav_item(ui, icon::SQUARES_FOUR, "Devices", on_phones, &if n > 0 { n.to_string() } else { String::new() }, "1") {
                    self.view = View::Home;
                }
                if nav_item(ui, icon::DOWNLOAD_SIMPLE, "Versions", self.view == View::Ios, "", "2") {
                    self.view = View::Ios;
                    self.runtimes = host::runtimes();
                }
                if nav_item(ui, icon::LIGHTNING, "Pre-translate", self.view == View::Aot, if self.aot.building() { "•" } else { "" }, "3") {
                    self.view = View::Aot;
                }
                if nav_item(ui, icon::GEAR_SIX, "Settings", self.view == View::Settings, "", "4") {
                    self.view = View::Settings;
                    self.last_slow = Instant::now() - Duration::from_secs(60);
                }
                if nav_item(ui, icon::WRENCH, "Setup", self.view == View::Setup, "", "5") {
                    self.open_setup(ui.ctx());
                }
                // footer: what runs and what it takes, pinned to the bottom (free disk is on Settings, with disk use)
                let upd_h = match self.updater.phase() {
                    updater::Phase::Available(_) | updater::Phase::Ready(..) => 34.0,
                    updater::Phase::Downloading(_) => 30.0,
                    _ => 0.0,
                };
                let footer_h = 48.0 + upd_h + if self.aot.building() { 30.0 } else { 0.0 };
                ui.add_space((ui.available_height() - footer_h).max(S4));
                egui::Frame::new().inner_margin(egui::Margin::symmetric(8, 0)).show(ui, |ui| {
                    ui.set_width(ui.available_width());
                    ui.spacing_mut().item_spacing.y = 4.0;
                    self.update_footer(ui);
                    if self.aot.building() {
                        let frac = self.aot.progress.as_ref().map(|p| if p.chunks_total > 0 { p.chunks_done as f32 / p.chunks_total as f32 } else { 0.0 }).unwrap_or(0.0);
                        ui.label(muted(format!("Pre-translating · {:.0}%", frac * 100.0)));
                        progress(ui, Some(frac), pal().accent);
                        ui.add_space(4.0);
                    }
                    if nrun > 0 {
                        dot_label(ui, &format!("{nrun} running · {}", fmt_mb(mb)), pal().good);
                    } else {
                        dot_label(ui, "Nothing running", pal().ink_3);
                    }
                    ui.add_space(2.0);
                    ui.horizontal(|ui| {
                        ui.spacing_mut().item_spacing.x = 6.0;
                        ui.label(muted("?"));
                        ui.label(muted("keys"));
                        ui.add_space(6.0);
                        ui.label(muted("q"));
                        ui.label(muted("quit"));
                    });
                });
            });

        let view = self.view.clone();
        match view {
            View::Phone(id) => self.phone_view(ctx, &id),
            _ => {
                egui::CentralPanel::default().frame(egui::Frame::new().fill(pal().canvas)).show(ctx, |ui| {
                    egui::ScrollArea::vertical().id_salt(match &view { View::Home => "home", View::Ios => "ios", View::Aot => "aot", View::Setup => "setup", _ => "settings" }).auto_shrink([false, false]).show(ui, |ui| {
                        // the page owns its margins so the scrollbar sits in the gutter, not on the content
                        egui::Frame::new().inner_margin(egui::Margin { left: S5 as i8, right: S5 as i8, top: S4 as i8, bottom: S5 as i8 }).show(ui, |ui| {
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
        nav::end_frame();
        self.add_dialog(ctx);
        self.phone_dialog(ctx);
        self.quit_dialog(ctx);
        self.help_overlay(ctx);
        if !self.message.is_empty() && self.message_at.elapsed() < Duration::from_secs(6) {
            egui::Area::new("toast".into()).anchor(egui::Align2::CENTER_BOTTOM, egui::vec2(NAV_W / 2.0, -20.0)).order(egui::Order::Foreground).show(ctx, |ui| {
                // a flyout as Omarchy's: the canvas with Hyprland's active border, no shadow
                egui::Frame::new()
                    .fill(pal().canvas)
                    .stroke(egui::Stroke::new(1.0_f32, pal().active))
                    .corner_radius(radius())
                    .inner_margin(egui::Margin::symmetric(12, 8))
                    .show(ui, |ui| {
                        ui.set_max_width((ui.ctx().content_rect().width() - NAV_W - 2.0 * S6).clamp(240.0, 560.0));
                        ui.horizontal(|ui| {
                            ui.label(egui::RichText::new(icon::INFO).family(icons()).size(15.0).color(pal().ink_2));
                            ui.add(egui::Label::new(body(&self.message)).wrap());
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
        .frame(egui::Frame::new().fill(pal().window).inner_margin(0).outer_margin(0))
        .show(ctx, |ui| {
            ui.spacing_mut().item_spacing = egui::Vec2::ZERO;
            let rect = ui.max_rect();
            ui.painter().hline(rect.x_range(), rect.bottom() - 0.5, egui::Stroke::new(1.0_f32, pal().border));
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
                pal().ink_2,
            );
            // buttons: close, maximize/restore, minimize (right to left)
            let bw = 46.0;
            let mut x = rect.right();
            // icons are drawn, not font glyphs (the UI font has no ✕ / ❐)
            #[derive(PartialEq, Clone, Copy)]
            enum Icon { Close, Max, Restore, Min }
            let mut button = |icon: Icon, hover: egui::Color32, id: &str, tip: &str| -> bool {
                x -= bw;
                let r = egui::Rect::from_min_size(egui::pos2(x, rect.top()), egui::vec2(bw, rect.height()));
                let resp = ui.interact(r, egui::Id::new(id), egui::Sense::click());
                if resp.hovered() {
                    ui.painter().rect_filled(r, 0.0, hover);
                }
                let ink = if resp.hovered() { pal().ink } else { pal().ink_2 };
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
                resp.on_hover_cursor(egui::CursorIcon::PointingHand).on_hover_text(tip).clicked()
            };
            if button(Icon::Close, egui::Color32::from_rgba_unmultiplied(pal().crit.r(), pal().crit.g(), pal().crit.b(), 90), "title-close", "Close the launcher (running devices keep running)") {
                ctx.send_viewport_cmd(egui::ViewportCommand::Close);
            }
            if button(if maximized { Icon::Restore } else { Icon::Max }, pal().hover, "title-max", if maximized { "Restore" } else { "Maximize" }) {
                ctx.send_viewport_cmd(egui::ViewportCommand::Maximized(!maximized));
            }
            if button(Icon::Min, pal().hover, "title-min", "Minimize") {
                ctx.send_viewport_cmd(egui::ViewportCommand::Minimized(true));
            }
        });
}
