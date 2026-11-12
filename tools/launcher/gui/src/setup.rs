//! The setup page (first run from the AppImage, and Settings > Setup later): host checks, installing Darling (the one
//! password prompt), getting iOS (download from Apple, or link one already on disk), pre-translating (on by default) and
//! the first phone. Each step only shows what it needs; the logic is x86sim_core::setup.
use crate::global::{fetch_progress, list_row, note};
use crate::theme::*;
use crate::{App, View};
use eframe::egui;
use std::sync::{Arc, Mutex};
use x86sim_core::setup::{self, Check, DarlingState, Level};

#[derive(Default)]
pub struct Setup {
    pub checks: Arc<Mutex<Option<Vec<Check>>>>,
    /// Darling install: progress line while running, the result after
    pub install: Arc<Mutex<Option<Result<(), String>>>>,
    pub install_line: Arc<Mutex<String>>,
    pub installing: bool,
    pub runtime_path: String,
    /// pre-translate was started automatically once iOS was there (it is on by default; the user can still stop it)
    pub aot_auto: bool,
}

impl Setup {
    pub fn refresh(&self, ctx: &egui::Context) {
        let c = self.checks.clone();
        *c.lock().unwrap() = None;
        let ctx = ctx.clone();
        std::thread::spawn(move || {
            *c.lock().unwrap() = Some(setup::checks());
            ctx.request_repaint();
        });
    }
}

fn level_look(l: Level) -> (&'static str, egui::Color32, &'static str) {
    match l {
        Level::Ok => (icon::CHECK_CIRCLE, GOOD, "OK"),
        Level::Warn => (icon::WARNING, WARN, "Check"),
        Level::Fail => (icon::X_CIRCLE, CRIT, "Needed"),
    }
}

fn step_header(ui: &mut egui::Ui, n: usize, title_text: &str, done: bool) {
    ui.add_space(S4);
    ui.horizontal(|ui| {
        let (r, _) = ui.allocate_exact_size(egui::vec2(22.0, 22.0), egui::Sense::hover());
        ui.painter().circle_filled(r.center(), 11.0, if done { GOOD } else { ACCENT_FILL });
        let t = if done { icon::CHECK.to_string() } else { n.to_string() };
        ui.painter().text(r.center(), egui::Align2::CENTER_CENTER, t, font(12.0), egui::Color32::WHITE);
        ui.add_space(4.0);
        ui.label(title(title_text));
    });
    ui.add_space(S2);
}

impl App {
    pub fn setup_page(&mut self, ui: &mut egui::Ui) {
        if self.setup.checks.lock().unwrap().is_none() && !self.setup_checking {
            self.setup_checking = true;
            self.setup.refresh(ui.ctx());
        }
        let mut recheck = false;
        let sub_text = match setup::appimage() {
            Some(_) => format!("x86Sim {}. Everything below runs once; data lives in {}.", setup::version(), x86sim_core::aot::repo_root().display()),
            None => format!("Checkout at {} (developer setup: see README.md).", x86sim_core::aot::repo_root().display()),
        };
        page_header(ui, "Setup", &sub_text, |ui| {
            recheck = ui.add(Btn::secondary("Check again").icon(icon::ARROW_CLOCKWISE)).clicked();
        });
        if recheck {
            self.setup.refresh(ui.ctx());
            self.refresh_instances();
        }

        // 1. this computer
        let checks = self.setup.checks.lock().unwrap().clone();
        let host_ok = checks.as_ref().is_some_and(|c| c.iter().filter(|c| c.name != "Darling").all(|c| c.level != Level::Fail));
        step_header(ui, 1, "This computer", host_ok);
        list_card(ui, |ui| match &checks {
            None => {
                ui.add_space(S3);
                ui.horizontal(|ui| {
                    ui.add_space(S4);
                    ui.spinner();
                    ui.label(muted("Checking…"));
                });
                ui.add_space(S3);
            }
            Some(cs) => {
                for (k, c) in cs.iter().filter(|c| c.name != "Darling").enumerate() {
                    if k > 0 {
                        hline(ui);
                    }
                    let (ic, col, st) = level_look(c.level);
                    list_row(ui, ic, c.name, &c.detail, |ui| {
                        badge(ui, st, col);
                    });
                    if !c.fix.is_empty() {
                        note(ui, &c.fix);
                    }
                }
            }
        });

        // 2. Darling
        let ds = setup::darling_state();
        let ready = ds == DarlingState::Ready;
        step_header(ui, 2, "Install the simulator host (Darling)", ready);
        let mut install = false;
        let res = self.setup.install.lock().unwrap().clone();
        let line = self.setup.install_line.lock().unwrap().clone();
        if self.setup.installing && res.is_some() {
            self.setup.installing = false;
            self.setup.refresh(ui.ctx());
        }
        list_card(ui, |ui| {
            let detail = match &ds {
                DarlingState::Ready if setup::userns() => "Ready, without root: it runs in a user namespace of your own. Nothing to install.".into(),
                DarlingState::Ready => format!("Installed in {}", setup::OPT_DARLING),
                DarlingState::Outdated { .. } => "This version of x86Sim brings a newer build.".into(),
                _ => format!("Copied to {} once, owned by root: its launcher must be setuid root to set up each phone's container.", setup::OPT_DARLING),
            };
            list_row(ui, icon::SHIELD_CHECK, "Darling", &detail, |ui| {
                if setup::appimage().is_some() && !ready && !self.setup.installing {
                    install = ui.add(Btn::primary(if matches!(ds, DarlingState::Outdated { .. }) { "Update" } else { "Install" }).icon(icon::LOCK_KEY)).on_hover_text("Asks for your password once (pkexec)").clicked();
                }
                if self.setup.installing {
                    ui.spinner();
                }
            });
            if self.setup.installing {
                note(ui, &line);
            } else if let Some(Err(e)) = &res {
                note(ui, &format!("Didn't install: {e}"));
            }
            if !ready {
                if let Some(cmd) = setup::install_command(&setup::stage_dir()) {
                    note(ui, &format!("Or in a terminal, after copying {} to {}: sudo {}", std::env::var("X86SIM_DARLING_STAGE").unwrap_or_default(), setup::stage_dir().display(), cmd.join(" ")));
                } else if setup::appimage().is_none() {
                    note(ui, "In a checkout: make darling-install (README.md, Setup step 3).");
                }
            }
        });
        if install {
            self.setup.installing = true;
            *self.setup.install.lock().unwrap() = None;
            let (r, l, ctx) = (self.setup.install.clone(), self.setup.install_line.clone(), ui.ctx().clone());
            std::thread::spawn(move || {
                let say = |s: &str| {
                    *l.lock().unwrap() = s.to_string();
                    ctx.request_repaint();
                };
                let out = setup::install_darling(&say).map_err(|e| format!("{e:#}"));
                *r.lock().unwrap() = Some(out);
                ctx.request_repaint();
            });
        }

        // 3. iOS
        let present: Vec<_> = self.runtimes.iter().filter(|r| r.present).cloned().collect();
        let have_rt = !present.is_empty();
        step_header(ui, 3, "Get iOS", have_rt);
        let mut fetch = false;
        let mut cancel = None;
        let mut link = false;
        list_card(ui, |ui| {
            let fetching = self.fetching.get(setup::DEFAULT_BUILD).cloned();
            let detail = if let Some(r) = present.first() {
                format!("iOS {} ({}) is ready", r.version, r.build)
            } else {
                "Apple's iOS simulator, downloaded straight from Apple (about 8 GB, 30 GB unpacked). Not redistributed: each computer gets its own copy.".into()
            };
            list_row(ui, icon::STACK, &format!("iOS {}", setup::DEFAULT_VERSION), &detail, |ui| {
                if !have_rt && fetching.is_none() {
                    let partial = self.runtimes.iter().find(|r| r.build == setup::DEFAULT_BUILD).and_then(x86sim_core::host::partial_download);
                    fetch = ui.add(Btn::primary(if partial.is_some() { "Resume download" } else { "Download" }).icon(icon::DOWNLOAD_SIMPLE)).clicked();
                }
            });
            if let Some(f) = &fetching {
                if fetch_progress(ui, f) {
                    cancel = Some(f.clone());
                }
            }
            if !have_rt && fetching.is_none() {
                egui::Frame::new().inner_margin(egui::Margin { left: 60, right: 16, top: 0, bottom: 12 }).show(ui, |ui| {
                    ui.label(muted("Already have it on disk (a checkout's runtimes/ios-27.2-24B8117-arm64)? Use it instead of downloading:"));
                    ui.horizontal(|ui| {
                        ui.add(egui::TextEdit::singleline(&mut self.setup.runtime_path).hint_text("/path/to/runtimes/ios-27.2-24B8117-arm64").desired_width(420.0));
                        link = ui.add_enabled(!self.setup.runtime_path.trim().is_empty(), Btn::secondary("Use this folder")).clicked();
                    });
                });
            }
        });
        if fetch {
            self.download(setup::DEFAULT_BUILD, &format!("iOS {}", setup::DEFAULT_VERSION));
        }
        if let Some(f) = cancel {
            x86sim_core::host::cancel_fetch(&f);
            self.fetching.remove(&f.build);
            self.fetch_started.remove(&f.build);
        }
        if link {
            match setup::link_runtime(std::path::Path::new(self.setup.runtime_path.trim())) {
                Ok(n) => {
                    self.say(format!("Using {n}"));
                    self.refresh_instances();
                    self.aot = crate::global::Aot::new(self.runtimes.iter().find(|r| r.present && r.restricted_to.is_empty()).map(|r| r.root.clone()));
                }
                Err(e) => self.say(format!("Can't use it: {e:#}")),
            }
        }

        // 4. pre-translate: part of setup, not a choice. It starts as soon as iOS and Darling are ready, on iOS's own
        // cache, even if a run was stopped before; afterwards the launcher keeps every version's image up to date.
        let built = !self.aot.building() && self.aot.paths.manifest().exists();
        if have_rt && ready && !built && !self.aot.building() && !self.setup.aot_auto {
            self.setup.aot_auto = true;
            if let Some(r) = present.first() {
                if self.aot.runtime_root.as_ref() != Some(&r.root) {
                    self.aot.select(r.root.clone(), None);
                }
            }
            self.aot.start_build(false);
        }
        step_header(ui, 4, "Pre-translate", built);
        let mut retry = false;
        list_card(ui, |ui| {
            let failed = !self.aot.building() && !built && !self.aot.message.is_empty();
            let detail = if built {
                "Done. New versions and updates are translated on their own.".to_string()
            } else if self.aot.building() {
                match self.aot.progress.as_ref().filter(|p| p.chunks_total > 0) {
                    Some(p) => format!("Translating iOS ahead of time: {} of {} parts. Devices already work meanwhile, just slower.", p.chunks_done, p.chunks_total),
                    None => "Getting ready to translate iOS ahead of time…".to_string(),
                }
            } else if failed {
                format!("It stopped: {}", self.aot.message)
            } else {
                "Translates iOS ahead of time, once, so devices and apps start fast. Starts on its own when iOS is here.".to_string()
            };
            list_row(ui, icon::LIGHTNING, "Faster starts", &detail, |ui| {
                if self.aot.building() {
                    ui.spinner();
                } else if failed {
                    retry = ui.add(Btn::secondary("Try again").icon(icon::ARROW_CLOCKWISE)).clicked();
                }
            });
        });
        if retry {
            self.setup.aot_auto = false;
        }

        // 5. first phone
        let phones = !self.insts.is_empty();
        step_header(ui, 5, "Your first phone", phones);
        let mut add = false;
        let mut finish = false;
        list_card(ui, |ui| {
            let detail = if phones { format!("{} phone{} made", self.insts.len(), if self.insts.len() == 1 { "" } else { "s" }) } else { "Pick a model (iPhone or iPad); each phone has its own apps and data.".into() };
            list_row(ui, icon::DEVICE_MOBILE, "Phone", &detail, |ui| {
                if phones {
                    finish = ui.add(Btn::primary("Done").icon(icon::CHECK)).clicked();
                } else {
                    add = ui.add_enabled(have_rt && ready, Btn::primary("Add phone").icon(icon::PLUS)).clicked();
                }
            });
        });
        if add {
            self.open_add_dialog();
        }
        ui.add_space(S4);
        if !phones && ui.add(Btn::ghost("Skip setup for now")).clicked() {
            finish = true;
        }
        if finish {
            let _ = setup::mark_done();
            self.view = View::Home;
        }
    }
}
