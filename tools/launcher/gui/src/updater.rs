//! Self-update (AppImage only): checks GitHub at start and every 6 hours (Settings > Updates), shows "Update to …" in
//! the sidebar footer, downloads and checks the new AppImage in the background, then offers a restart.
use crate::theme::*;
use crate::App;
use eframe::egui;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use x86sim_core::update::{self, Release};

#[derive(Default, Clone)]
pub enum Phase {
    #[default]
    Idle,
    Checking,
    UpToDate,
    Available(Release),
    Downloading(Release),
    /// installed: the path of the new AppImage
    Ready(Release, std::path::PathBuf),
    Failed(String),
}

#[derive(Default)]
pub struct Updater {
    pub phase: Arc<Mutex<Phase>>,
    pub done: Arc<AtomicU64>,
    last_check: Option<Instant>,
}

const EVERY: Duration = Duration::from_secs(6 * 3600);

impl Updater {
    pub fn supported() -> bool {
        update::running_appimage().is_some()
    }

    pub fn phase(&self) -> Phase {
        self.phase.lock().unwrap().clone()
    }

    /// Looks for a newer release in the background (now, or when the last check is older than 6 hours).
    pub fn check(&mut self, ctx: &egui::Context, force: bool, channel: &str) {
        if !Self::supported() || matches!(self.phase(), Phase::Checking | Phase::Downloading(_) | Phase::Ready(..)) {
            return;
        }
        if !force && self.last_check.is_some_and(|t| t.elapsed() < EVERY) {
            return;
        }
        self.last_check = Some(Instant::now());
        *self.phase.lock().unwrap() = Phase::Checking;
        let (ph, ctx, channel) = (self.phase.clone(), ctx.clone(), channel.to_string());
        std::thread::spawn(move || {
            let r = match update::check(&channel) {
                Ok(Some(rel)) => Phase::Available(rel),
                Ok(None) => Phase::UpToDate,
                Err(e) => Phase::Failed(format!("Couldn't check for updates: {e:#}")),
            };
            *ph.lock().unwrap() = r;
            ctx.request_repaint();
        });
    }

    pub fn download(&mut self, ctx: &egui::Context, rel: Release) {
        let Some(target) = update::running_appimage() else { return };
        *self.phase.lock().unwrap() = Phase::Downloading(rel.clone());
        self.done.store(0, Ordering::Relaxed);
        let (ph, done, ctx) = (self.phase.clone(), self.done.clone(), ctx.clone());
        std::thread::spawn(move || {
            // repaint while the download runs (progress)
            let tick = {
                let (ph, ctx) = (ph.clone(), ctx.clone());
                std::thread::spawn(move || {
                    while matches!(*ph.lock().unwrap(), Phase::Downloading(_)) {
                        ctx.request_repaint();
                        std::thread::sleep(Duration::from_millis(500));
                    }
                })
            };
            let r = match update::install(&rel, &target, done) {
                Ok(p) => Phase::Ready(rel, p),
                Err(e) => Phase::Failed(format!("Update failed: {e:#}")),
            };
            *ph.lock().unwrap() = r;
            let _ = tick.join();
            ctx.request_repaint();
        });
    }
}

impl App {
    /// The sidebar footer's update line (nothing when up to date)
    pub fn update_footer(&mut self, ui: &mut egui::Ui) {
        if !self.hub.check_updates && !matches!(self.updater.phase(), Phase::Downloading(_) | Phase::Ready(..)) {
            return;
        }
        match self.updater.phase() {
            Phase::Available(rel) => {
                if ui.add(Btn::primary(format!("Update to {}", rel.tag)).icon(icon::DOWNLOAD_SIMPLE).small()).on_hover_text("Downloads the new AppImage and replaces this one; your devices and data stay").clicked() {
                    self.updater.download(ui.ctx(), rel);
                }
                ui.add_space(4.0);
            }
            Phase::Downloading(rel) => {
                let frac = if rel.asset_size > 0 { self.updater.done.load(Ordering::Relaxed) as f32 / rel.asset_size as f32 } else { 0.0 };
                ui.label(muted(format!("Downloading {} · {:.0}%", rel.tag, frac.min(1.0) * 100.0)));
                ui.add(egui::ProgressBar::new(frac.min(1.0)).desired_height(4.0).fill(ACCENT).corner_radius(2));
                ui.add_space(4.0);
            }
            Phase::Ready(rel, path) => {
                let running = self.status.values().any(|s| s.phase != x86sim_core::instance::Phase::Off);
                let tip = if running { "Restarts x86Sim; running devices keep running" } else { "Restarts x86Sim" };
                if ui.add(Btn::primary(format!("Restart for {}", rel.tag)).icon(icon::ARROW_CLOCKWISE).small()).on_hover_text(tip).clicked() {
                    match update::relaunch(&path) {
                        Ok(()) => ui.ctx().send_viewport_cmd(egui::ViewportCommand::Close),
                        Err(e) => self.say(format!("Couldn't restart: {e:#}")),
                    }
                }
                ui.add_space(4.0);
            }
            _ => {}
        }
    }

    /// Settings > Updates
    pub fn update_settings(&mut self, ui: &mut egui::Ui) -> bool {
        let mut save = false;
        section(ui, "Updates", |_| {});
        list_card(ui, |ui| {
            let supported = Updater::supported();
            let detail = if supported {
                format!("x86Sim {}. Looks for a new release when it starts and every 6 hours.", x86sim_core::setup::version())
            } else {
                "Only for the AppImage; a checkout updates with git.".to_string()
            };
            form_row(ui, "Check for updates", &detail, false, |ui| {
                ui.add_enabled_ui(supported, |ui| {
                    save |= toggle(ui, &mut self.hub.check_updates).changed();
                });
            });
            if supported {
                let chans = [("stable", "Stable"), ("pre", "Pre-release")];
                let cur = update::effective_channel(&self.hub.channel);
                let sel = chans.iter().position(|c| c.0 == cur);
                form_row(ui, "Channel", "Stable gets full releases only; Pre-release also gets test builds, which come out more often and may break things.", false, |ui| {
                    if let Some(i) = segmented(ui, &chans.map(|c| c.1), sel, true) {
                        if chans[i].0 != cur {
                            self.hub.channel = chans[i].0.into();
                            save = true;
                            // what was offered came from the other channel
                            if matches!(self.updater.phase(), Phase::Available(_) | Phase::UpToDate | Phase::Failed(_)) {
                                self.updater.check(ui.ctx(), true, &self.hub.channel);
                            }
                        }
                    }
                });
                let line = match self.updater.phase() {
                    Phase::Idle => String::new(),
                    Phase::Checking => "Checking…".into(),
                    Phase::UpToDate => "You have the newest version.".into(),
                    Phase::Available(r) => format!("{} is available.", r.tag),
                    Phase::Downloading(r) => format!("Downloading {}…", r.tag),
                    Phase::Ready(r, _) => format!("{} is installed; restart to use it.", r.tag),
                    Phase::Failed(e) => e,
                };
                form_row(ui, "Version", &line, true, |ui| {
                    let busy = matches!(self.updater.phase(), Phase::Checking | Phase::Downloading(_));
                    if ui.add_enabled(!busy, Btn::secondary("Check now")).on_hover_text("Look for a newer release now").on_disabled_hover_text("Already checking or updating").clicked() {
                        self.updater.check(ui.ctx(), true, &self.hub.channel);
                    }
                    if let Phase::Available(rel) = self.updater.phase() {
                        if ui.add(Btn::primary("Update")).on_hover_text("Downloads the new AppImage and replaces this one; your devices and data stay").clicked() {
                            self.updater.download(ui.ctx(), rel);
                        }
                    }
                });
            }
        });
        save
    }
}
