//! One phone: a top bar (breadcrumb with a phone switcher, state, Start/Stop/Restart), its screen (touch + keyboard)
//! with a vertical tool bar right of it (Home, Lock, volume, Siri, screenshot, gesture help), and the inspector: Overview, then fold-out Features,
//! Logs, Performance, Advanced.
use crate::theme::*;
use crate::{viewer, App, View};
use eframe::egui;
use std::time::{Duration, Instant};
use x86sim_core::{features, instance, instance::Phase, logs};

/// Width of the tool bar right of the screen
const TOOLBAR_W: f32 = 46.0;
const GESTURES: &str ="Click the screen to tap, drag to swipe.\nDrag in from an edge for system gestures (Home, Control Center, back).\nCtrl + drag to pinch, Shift + drag to scroll with two fingers.\nF1 Home · F2 Lock · F3/F4 volume";

impl App {
    pub fn phone_view(&mut self, ctx: &egui::Context, id: &str) {
        let Some(inst) = self.inst(id).cloned() else {
            self.view = View::Home;
            return;
        };
        let st = self.status.get(id).cloned();
        let phase = st.as_ref().map(|s| s.phase).unwrap_or(Phase::Off);
        if self.settings.as_ref().map(|s| s.0.as_str()) != Some(id) {
            self.settings = Some((id.to_string(), instance::load_settings(&inst.dir)));
        }

        egui::TopBottomPanel::top("phone-head").frame(egui::Frame::new().fill(CANVAS).inner_margin(egui::Margin { left: 16, right: 16, top: 10, bottom: 10 })).show(ctx, |ui| {
            ui.horizontal(|ui| {
                ui.set_min_height(32.0);
                ui.spacing_mut().item_spacing.x = 4.0;
                if ui.add(Btn::ghost("Phones").icon(icon::CARET_LEFT)).on_hover_text("Back to all phones (Esc)").clicked() {
                    self.view = View::Home;
                }
                ui.label(egui::RichText::new("/").size(T_TITLE).color(BORDER_STRONG));
                // the phone's name doubles as a switcher
                let txt = egui::RichText::new(format!("{}  {}", inst.name, icon::CARET_UP_DOWN)).size(T_TITLE).family(semibold()).color(INK);
                let others: Vec<(String, String, Phase, bool)> = self.insts.iter().map(|i| (i.id.clone(), i.name.clone(), self.phase(&i.id), i.runtime_present)).collect();
                let mut go = None;
                egui::containers::menu::MenuButton::from_button(egui::Button::new(txt).frame_when_inactive(false)).ui(ui, |ui| {
                    ui.set_width(260.0);
                    ui.spacing_mut().item_spacing.y = 0.0;
                    for (oid, name, ph, present) in &others {
                        let (r, resp) = ui.allocate_exact_size(egui::vec2(260.0, 30.0), egui::Sense::click());
                        let p = ui.painter();
                        if resp.hovered() {
                            p.rect_filled(r, R_SM, RAISED);
                        }
                        if oid == id {
                            p.text(r.left_center() + egui::vec2(8.0, 0.0), egui::Align2::LEFT_CENTER, icon::CHECK, font(13.0), INK);
                        }
                        let g = galley_trunc(ui, name, font_m(T_BODY), INK, 150.0);
                        p.galley(egui::pos2(r.left() + 28.0, r.center().y - g.size().y / 2.0), g, INK);
                        let state = match ph {
                            Phase::Running => "Running",
                            Phase::Starting => "Starting",
                            Phase::Stopping => "Stopping",
                            Phase::Off if !present => "No iOS",
                            Phase::Off => "Off",
                        };
                        p.text(r.right_center() - egui::vec2(10.0, 0.0), egui::Align2::RIGHT_CENTER, state, font(T_SMALL), INK_3);
                        if *ph == Phase::Running {
                            let w = ui.painter().layout_no_wrap(state.into(), font(T_SMALL), INK_3).size().x;
                            ui.painter().circle_filled(r.right_center() - egui::vec2(18.0 + w, 0.0), 3.5, GOOD);
                        }
                        if resp.on_hover_cursor(egui::CursorIcon::PointingHand).clicked() {
                            go = Some(oid.clone());
                            ui.close();
                        }
                    }
                });
                if let Some(g) = go {
                    self.view = View::Phone(g);
                }
                ui.add_space(6.0);
                ui.label(muted(format!("{} · {}", inst.model, inst.ios)).size(T_BODY));
                ui.add_space(8.0);
                let (label, col) = phase_look(phase, inst.runtime_present);
                badge(ui, label, col);
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    ui.spacing_mut().item_spacing.x = S2;
                    self.phone_menu(ui, &inst, phase);
                    match phase {
                        // not installed: the Download action lives in the screen area's empty state
                        Phase::Off if !inst.runtime_present => {}
                        Phase::Off => {
                            if ui.add(Btn::primary("Start").icon(icon::PLAY).min_w(84.0)).clicked() {
                                self.start(id);
                            }
                        }
                        Phase::Stopping => {
                            ui.add_enabled(false, Btn::secondary("Stopping…").min_w(84.0));
                        }
                        _ => {
                            if ui.add(Btn::secondary("Stop").icon(icon::STOP).icon_color(CRIT_INK).min_w(84.0)).clicked() {
                                self.stop(id);
                            }
                            if instance::needs_restart(&inst, st.as_ref()) {
                                if ui.add(Btn::primary("Restart to apply").icon(icon::ARROW_CLOCKWISE)).on_hover_text("Feature or start settings changed since this phone started").clicked() {
                                    self.restart(id);
                                }
                            } else if ui.add(Btn::secondary("Restart").icon(icon::ARROW_CLOCKWISE)).on_hover_text("Ctrl+R").clicked() {
                                self.restart(id);
                            }
                        }
                    }
                });
            });
        });

        egui::SidePanel::right("phone-side")
            .resizable(true)
            .default_width(392.0)
            .width_range(340.0..=720.0)
            .frame(egui::Frame::new().fill(WINDOW).inner_margin(egui::Margin { left: 16, right: 12, top: 16, bottom: 12 }))
            .show(ctx, |ui| {
                egui::ScrollArea::vertical().auto_shrink([false, false]).show(ui, |ui| {
                    ui.set_width(ui.available_width() - 4.0);
                    self.side_panel(ui, &inst, st.as_ref());
                });
            });

        egui::CentralPanel::default().frame(egui::Frame::new().fill(CANVAS).inner_margin(egui::Margin { left: 24, right: 24, top: 20, bottom: 16 })).show(ctx, |ui| {
            if !inst.runtime_present {
                let busy = self.fetching.contains_key(&inst.build);
                let h = ui.available_height();
                ui.add_space((h / 2.0 - 110.0).max(0.0));
                let mut dl = false;
                empty_state(ui, icon::CLOUD_ARROW_DOWN, &format!("{} isn't installed", inst.ios), "Download it to start this phone. Its apps and data are kept.", |ui| {
                    if busy {
                        let line = self.fetching.get(&inst.build).map(crate::home::fetch_line).unwrap_or_default();
                        ui.horizontal(|ui| {
                            ui.spinner();
                            ui.label(sub(line));
                        });
                        ui.ctx().request_repaint_after(Duration::from_secs(2));
                    } else {
                        dl = ui.add(Btn::primary(format!("Download {}", inst.ios)).icon(icon::DOWNLOAD_SIMPLE)).clicked();
                    }
                });
                if dl {
                    let (b, l) = (inst.build.clone(), inst.ios.clone());
                    self.download(&b, &l);
                }
                return;
            }
            let live = matches!(phase, Phase::Running | Phase::Starting);
            let placeholder = match phase {
                Phase::Off => "Off",
                Phase::Starting => "Starting…",
                Phase::Stopping => "Stopping…",
                Phase::Running => "Waiting for the screen…",
            };
            // the screen and, to its right, the tools (as Simulator's side buttons): centred together
            let avail = ui.available_size() - egui::vec2(TOOLBAR_W + S3, 0.0);
            let rid = egui::Id::new(("screen-row", id));
            let w: f32 = ui.data(|d| d.get_temp(rid)).unwrap_or(avail.x);
            let r = ui.horizontal_top(|ui| {
                ui.add_space(((ui.available_width() - w) / 2.0).max(0.0));
                let start = ui.cursor().min.x;
                if let Some(v) = self.viewer(id) {
                    v.show(ui, avail, live, placeholder, true, viewer::FULL);
                }
                ui.add_space(S3);
                self.screen_toolbar(ui, id, live);
                ui.min_rect().right() - start
            });
            ui.data_mut(|d| d.insert_temp(rid, r.inner));
        });
    }

    /// The "⋯" menu of a phone: rename, remove.
    pub fn phone_menu(&mut self, ui: &mut egui::Ui, inst: &instance::Instance, phase: Phase) {
        let btn = egui::Button::new(egui::RichText::new(icon::DOTS_THREE).size(16.0).color(INK_2)).min_size(egui::vec2(H_MD, H_MD)).frame_when_inactive(false);
        let (resp, _) = egui::containers::menu::MenuButton::from_button(btn).ui(ui, |ui| {
            ui.set_width(220.0);
            ui.spacing_mut().item_spacing.y = 0.0;
            self.phone_menu_items(ui, inst, phase);
        });
        resp.on_hover_text("More");
    }

    pub fn phone_menu_items(&mut self, ui: &mut egui::Ui, inst: &instance::Instance, phase: Phase) {
        if menu_row(ui, icon::PENCIL_SIMPLE, "Rename…", "", true, false).clicked() {
            self.dialog = Some(crate::Dialog::Rename { id: inst.id.clone(), text: inst.name.clone() });
            ui.close();
        }
        let off = phase == Phase::Off;
        let can = off && !inst.is_default;
        let r = menu_row(ui, icon::TRASH, "Remove phone…", "", can, true);
        let r = if inst.is_default { r.on_disabled_hover_text("The main phone stays") } else if !off { r.on_disabled_hover_text("Stop it first") } else { r };
        if r.clicked() {
            let paths = instance::delete_plan(inst);
            let size = std::sync::Arc::new(std::sync::Mutex::new(None));
            let (s2, p2, ctx) = (size.clone(), paths.clone(), ui.ctx().clone());
            std::thread::spawn(move || {
                let n: u64 = p2.iter().map(|p| if p.is_dir() { x86sim_core::host::dir_size(p) } else { p.metadata().map(|m| m.len()).unwrap_or(0) }).sum();
                *s2.lock().unwrap() = Some(n);
                ctx.request_repaint();
            });
            self.dialog = Some(crate::Dialog::Delete { id: inst.id.clone(), paths, size });
            ui.close();
        }
    }

    /// Rename / remove dialogs.
    pub fn phone_dialog(&mut self, ctx: &egui::Context) {
        let Some(d) = self.dialog.take() else { return };
        let mut keep = true;
        match d {
            crate::Dialog::Rename { id, mut text } => {
                let Some(inst) = self.inst(&id).cloned() else { return };
                let mut save = false;
                let m = egui::Modal::new("rename-phone".into()).backdrop_color(egui::Color32::from_black_alpha(150)).frame(modal_frame()).show(ctx, |ui| {
                    ui.set_width(360.0);
                    ui.spacing_mut().item_spacing.y = 4.0;
                    ui.label(egui::RichText::new("Rename phone").size(T_TITLE + 1.0).family(semibold()).color(INK));
                    ui.add_space(S3);
                    let r = ui.add(egui::TextEdit::singleline(&mut text).desired_width(ui.available_width()).margin(egui::Margin::symmetric(8, 6)));
                    if !r.has_focus() && !r.lost_focus() {
                        r.request_focus();
                    }
                    if r.lost_focus() && ui.input(|i| i.key_pressed(egui::Key::Enter)) {
                        save = true;
                    }
                    ui.add_space(S5);
                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        if ui.add_enabled(!text.trim().is_empty(), Btn::primary("Rename").min_w(88.0)).clicked() {
                            save = true;
                        }
                        if ui.add(Btn::secondary("Cancel").min_w(80.0)).clicked() {
                            keep = false;
                        }
                    });
                });
                if m.should_close() {
                    keep = false;
                }
                if save && !text.trim().is_empty() {
                    keep = false;
                    match instance::rename(&inst, &text) {
                        Ok(()) => {
                            self.refresh_instances();
                            self.say(format!("Renamed to {}", text.trim()));
                        }
                        Err(e) => self.say(format!("Couldn't rename: {e:#}")),
                    }
                }
                if keep {
                    self.dialog = Some(crate::Dialog::Rename { id, text });
                }
            }
            crate::Dialog::Delete { id, paths, size } => {
                let Some(inst) = self.inst(&id).cloned() else { return };
                let mut go = false;
                let m = egui::Modal::new("delete-phone".into()).backdrop_color(egui::Color32::from_black_alpha(150)).frame(modal_frame()).show(ctx, |ui| {
                    ui.set_width(420.0);
                    ui.spacing_mut().item_spacing.y = 4.0;
                    ui.label(egui::RichText::new(format!("Remove {}?", inst.name)).size(T_TITLE + 1.0).family(semibold()).color(INK));
                    ui.label(sub("Its apps, data and settings are deleted. This can't be undone."));
                    ui.add_space(S2);
                    let frees = match *size.lock().unwrap() {
                        None => "Measuring what it frees…".to_string(),
                        Some(b) if b < 1 << 20 => "Frees less than 1 MB.".to_string(),
                        Some(b) => format!("Frees {}.", fmt_mb(b as f64 / 1048576.0)),
                    };
                    ui.label(muted(frees)).on_hover_text(paths.iter().map(|p| p.display().to_string()).collect::<Vec<_>>().join("\n"));
                    ui.add_space(S5);
                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        if ui.add(Btn::danger("Remove").min_w(88.0)).clicked() {
                            go = true;
                        }
                        if ui.add(Btn::secondary("Cancel").min_w(80.0)).clicked() {
                            keep = false;
                        }
                    });
                });
                if m.should_close() {
                    keep = false;
                }
                if go {
                    keep = false;
                    let st = self.status.get(&id).cloned();
                    match instance::delete(&inst, st.as_ref()) {
                        Ok(()) => {
                            self.viewers.remove(&id);
                            if self.view == View::Phone(id.clone()) {
                                self.view = View::Home;
                            }
                            self.refresh_instances();
                            self.shared.lock().unwrap().insts.retain(|i| i.id != id);
                            self.say(format!("Removed {}", inst.name));
                        }
                        Err(e) => self.say(format!("Couldn't remove it: {e:#}")),
                    }
                }
                if keep {
                    self.dialog = Some(crate::Dialog::Delete { id, paths, size });
                }
            }
        }
    }

    /// The tools, a vertical bar right of the screen: the hardware buttons Simulator has (Home, side button, volume,
    /// Siri), Save Screen, the hinge of a two-screen phone, gesture help. Simulator's rotate and shake have no simhid
    /// command (no orientation or motion events), so they are not offered.
    fn screen_toolbar(&mut self, ui: &mut egui::Ui, id: &str, live: bool) {
        let name = self.inst(id).map(|i| i.name.clone()).unwrap_or_else(|| id.to_string());
        let hinge = self.inst(id).filter(|i| i.inner.is_some()).map(|i| i.inner_active());
        egui::Frame::new().fill(CARD).stroke(egui::Stroke::new(1.0_f32, BORDER)).corner_radius(8).inner_margin(4).show(ui, |ui| {
            ui.set_width(TOOLBAR_W - 10.0);
            ui.vertical_centered(|ui| {
                ui.spacing_mut().item_spacing.y = 2.0;
                fn tool_btn(ui: &mut egui::Ui, live: bool, ic: &'static str, tip: &str) -> bool {
                    ui.add_enabled(live, Btn::ghost("").icon(ic)).on_hover_text(tip).on_disabled_hover_text("Not running").clicked()
                }
                let tool = |ui: &mut egui::Ui, ic: &'static str, tip: &str| tool_btn(ui, live, ic, tip);
                let sep = |ui: &mut egui::Ui| {
                    let (r, _) = ui.allocate_exact_size(egui::vec2(TOOLBAR_W - 10.0, 9.0), egui::Sense::hover());
                    ui.painter().hline(r.x_range().shrink(6.0), r.center().y, egui::Stroke::new(1.0_f32, BORDER));
                };
                let mut press = None;
                if tool(ui, icon::HOUSE, "Home (F1)") {
                    press = Some("home");
                }
                if tool(ui, icon::LOCK, "Lock: the side button (F2)") {
                    press = Some("lock");
                }
                if tool(ui, icon::SPEAKER_HIGH, "Volume up (F3)") {
                    press = Some("volup");
                }
                if tool(ui, icon::SPEAKER_LOW, "Volume down (F4)") {
                    press = Some("voldown");
                }
                if tool(ui, icon::MICROPHONE, "Siri: holds the side button") {
                    if let Some(v) = self.viewer(id) {
                        v.hold("lock", 2500);
                    }
                }
                if let Some(b) = press {
                    if let Some(v) = self.viewer(id) {
                        v.press(b);
                    }
                }
                sep(ui);
                if tool(ui, icon::CAMERA, "Save a screenshot to Pictures") {
                    let r = self.viewer(id).map(|v| v.screenshot(&name));
                    match r {
                        Some(Ok(f)) => self.say(format!("Screenshot saved: {}", f.display())),
                        Some(Err(e)) => self.say(format!("Couldn't save a screenshot: {e}")),
                        None => {}
                    }
                }
                // Models 2: a two-screen phone (iPhone Duo) opens and closes like one: the hinge
                if let Some(open) = hinge {
                    let (ic, tip) = if open { (icon::DEVICE_MOBILE, "Fold: close the phone, the outer screen") } else { (icon::BOOK_OPEN, "Unfold: open the phone flat, the inner screen") };
                    if tool(ui, ic, tip) {
                        if let Some(v) = self.viewer(id) {
                            v.hinge(if open { 0.0 } else { 180.0 });
                        }
                    }
                }
                sep(ui);
                ui.add(Btn::tool(icon::INFO)).on_hover_text(GESTURES);
            });
        });
    }

    fn side_panel(&mut self, ui: &mut egui::Ui, inst: &instance::Instance, st: Option<&instance::Status>) {
        let phase = st.map(|s| s.phase).unwrap_or(Phase::Off);
        let id = inst.id.clone();
        let on = phase != Phase::Off;
        // ---- Overview (always shown; live numbers only while it runs)
        if on {
            stat_row(ui, CARD, &[
                ("Memory", fmt_mb(st.map(|s| s.pss_mb).unwrap_or(0.0)), ""),
                ("CPU", format!("{:.0}%", st.map(|s| s.cpu_pct).unwrap_or(0.0)), ""),
                ("Up for", st.and_then(|s| s.uptime_s).map(fmt_uptime).unwrap_or("–".into()), ""),
            ]);
            ui.add_space(S3);
        }
        ui.spacing_mut().item_spacing.y = 2.0;
        let lw = 84.0;
        kv_text(ui, lw, "Model", &inst.model);
        kv_text(ui, lw, "iOS", if inst.runtime_present { inst.ios.clone() } else { format!("{} · not installed", inst.ios) });
        kv_text(ui, lw, "Screen", format!("{} × {} pixels", inst.screen.0, inst.screen.1));
        if let Some(s) = st.filter(|_| on) {
            kv_text(ui, lw, "Processes", format!("{}{}", s.procs.len(), if s.mtlvk { " · GPU helper on" } else { "" }));
        }
        let prof = features::load(&inst.dir);
        let off: Vec<String> = features::defs().features.iter().filter(|f| !prof.enabled(&f.id)).map(|f| f.title.clone()).collect();
        kv(ui, lw, "Features", |ui| {
            let preset = features::preset_of(&prof).map(|p| match p.as_str() { "full" => "Full set", "lean" => "Lean set", "minimal" => "Minimal set", _ => "Custom" }.to_string());
            let t = match (preset, off.len()) {
                (Some(p), 0) => p,
                (Some(p), n) => format!("{p} · {n} off"),
                (None, 0) => "Everything on".to_string(),
                (None, n) => format!("Custom · {n} off"),
            };
            let r = ui.label(egui::RichText::new(t).size(T_SMALL).color(INK));
            if !off.is_empty() {
                r.on_hover_text(format!("Off: {}", off.join(", ")));
            }
        });
        ui.spacing_mut().item_spacing.y = S2;
        ui.add_space(S3);
        hline(ui);

        // ---- Features
        let preset = features::preset_of(&prof).map(|p| match p.as_str() { "full" => "Full", "lean" => "Lean", "minimal" => "Minimal", _ => "Custom" }).unwrap_or("Custom");
        if self.fold_section(ui, "features", "Features", preset) {
            self.features_section(ui, inst, phase);
        }
        hline(ui);

        // ---- Logs
        let nlines = self.logs.as_ref().filter(|l| l.0 == id).map(|l| l.1.lines.len()).unwrap_or(0);
        let summary = if self.open.contains("logs") && nlines > 0 { format!("{nlines} lines") } else { String::new() };
        if self.fold_section(ui, "logs", "Logs", &summary) {
            self.logs_section(ui, inst, st);
        } else {
            self.logs = None;
        }
        hline(ui);

        // ---- Performance
        let summary = if on { format!("{} · {:.0}% CPU", fmt_mb(st.map(|s| s.pss_mb).unwrap_or(0.0)), st.map(|s| s.cpu_pct).unwrap_or(0.0)) } else { String::new() };
        if self.fold_section(ui, "perf", "Performance", &summary) {
            self.perf_section(ui, &id, st);
        }
        hline(ui);

        // ---- Advanced
        if self.fold_section(ui, "adv", "Advanced", "") {
            self.advanced_section(ui, inst, st);
        }
    }

    fn fold_section(&mut self, ui: &mut egui::Ui, key: &'static str, title_text: &str, summary: &str) -> bool {
        let open = self.open.contains(key);
        if fold(ui, title_text, summary, open) != open {
            if open {
                self.open.remove(key);
            } else {
                self.open.insert(key);
            }
        }
        let now = self.open.contains(key);
        if now {
            ui.add_space(2.0);
        }
        now
    }

    fn features_section(&mut self, ui: &mut egui::Ui, inst: &instance::Instance, phase: Phase) {
        let dev = inst.dir.clone();
        let prof = features::load(&dev);
        let cur = features::preset_of(&prof);
        let presets = [("full", "Full"), ("lean", "Lean"), ("minimal", "Minimal")];
        let mut changed = false;
        ui.label(muted("Turn off what you don't use to save memory."));
        ui.add_space(S1);
        let sel = presets.iter().position(|p| cur.as_deref() == Some(p.0));
        if let Some(i) = segmented(ui, &presets.map(|p| p.1), sel, true) {
            let _ = features::apply_preset(&dev, presets[i].0);
            changed = true;
        }
        ui.add_space(S2);
        let mut saving = 0u64;
        for f in features::list(&dev) {
            let mut on = f.enabled;
            // "What it is. Off: what you lose." -> what it is while on; what you lose while off
            let (what, lose) = match f.desc.find("Off:") {
                Some(i) => (f.desc[..i].trim().to_string(), f.desc[i + 4..].trim().to_string()),
                None => (f.desc.clone(), String::new()),
            };
            let what = if !on && !lose.is_empty() {
                format!("Off: {lose}")
            } else if what.is_empty() {
                format!("When off: {lose}")
            } else {
                what
            };
            ui.horizontal(|ui| {
                ui.vertical(|ui| {
                    ui.set_width(ui.available_width() - 104.0);
                    ui.spacing_mut().item_spacing.y = 1.0;
                    ui.label(strong(&f.title));
                    ui.add(egui::Label::new(muted(what)).wrap());
                });
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    if toggle(ui, &mut on).changed() {
                        let _ = features::set(&dev, &f.id, on);
                        changed = true;
                    }
                    if f.cost_mb > 0 {
                        ui.label(muted(format!("{} MB", f.cost_mb)));
                    }
                });
            })
            .response
            .on_hover_text(&f.tech);
            if !on && f.default {
                saving += f.cost_mb;
            }
            ui.add_space(S1);
        }

        if saving > 0 {
            dot_label(ui, &format!("Saving about {saving} MB"), GOOD);
        }
        let st = self.status.get(&inst.id).cloned();
        if (changed || instance::needs_restart(inst, st.as_ref())) && phase != Phase::Off {
            ui.add_space(S1);
            egui::Frame::new().fill(CARD).stroke(egui::Stroke::new(1.0_f32, BORDER)).corner_radius(R_MD).inner_margin(egui::Margin::symmetric(10, 6)).show(ui, |ui| {
                ui.set_width(ui.available_width());
                ui.horizontal(|ui| {
                    ui.label(egui::RichText::new(icon::WARNING_CIRCLE).size(15.0).color(WARN));
                    ui.label(body("Restart to apply"));
                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        if ui.add(Btn::secondary("Restart now").small()).clicked() {
                            self.restart(&inst.id);
                        }
                    });
                });
            });
        }
        ui.add_space(S3);
    }

    fn logs_section(&mut self, ui: &mut egui::Ui, inst: &instance::Instance, st: Option<&instance::Status>) {
        // one tail per phone and boot (a restart can change the dirs; older files are the last boot's)
        let boot = st.and_then(|s| s.boot_time);
        if self.logs.as_ref().map(|l| l.0.as_str()) != Some(&inst.id) || self.logs.as_ref().is_some_and(|l| boot.is_some() && l.1.since != boot) {
            let mut t = logs::Tail::new(instance::log_sources(inst, st));
            t.since = boot;
            self.logs = Some((inst.id.clone(), t));
            self.last_log_poll = Instant::now() - Duration::from_secs(5);
        }
        if !self.log_paused && self.last_log_poll.elapsed() > Duration::from_millis(1000) {
            self.last_log_poll = Instant::now();
            if let Some((_, t)) = &mut self.logs {
                t.poll();
            }
            ui.ctx().request_repaint_after(Duration::from_millis(1000));
        }
        ui.horizontal(|ui| {
            ui.spacing_mut().item_spacing.x = 6.0;
            let rest = ui.available_width() - 116.0 - 2.0 * H_MD - 3.0 * 6.0 - 4.0;
            search(ui, &mut self.log_filter, "Filter text or process", rest.max(80.0));
            let groups = self.logs.as_ref().map(|l| l.1.groups()).unwrap_or_default();
            egui::ComboBox::from_id_salt("logsrc")
                .icon(caret)
                .width(116.0)
                .selected_text(egui::RichText::new(if self.log_source.is_empty() { "All logs".to_string() } else { self.log_source.clone() }).size(T_SMALL))
                .show_ui(ui, |ui| {
                    ui.selectable_value(&mut self.log_source, String::new(), "All logs");
                    for g in logs::GROUPS {
                        let has = groups.contains(&g);
                        ui.add_enabled_ui(has || self.log_source == g, |ui| {
                            ui.selectable_value(&mut self.log_source, g.to_string(), g).on_hover_text(match g {
                                "System" => "One log per iOS service and app",
                                "Translator" => "The ARM translator, one log per process",
                                "Boot" => "Starting the phone",
                                "Graphics" => "The GPU helper",
                                _ => "Memory clean-up",
                            });
                        });
                    }
                })
                .response
                .on_hover_text("Which logs to show");
            let (ic, tip) = if self.log_paused { (icon::PLAY, "Follow") } else { (icon::PAUSE, "Pause") };
            if ui.add(Btn::tool(ic)).on_hover_text(tip).clicked() {
                self.log_paused = !self.log_paused;
            }
            if ui.add(Btn::tool(icon::TRASH)).on_hover_text("Clear").clicked() {
                if let Some((_, t)) = &mut self.logs {
                    t.lines.clear();
                }
            }
        });
        ui.add_space(S1);
        let f = self.log_filter.to_lowercase();
        let src = self.log_source.clone();
        let paused = self.log_paused;
        if let Some((_, t)) = &self.logs {
            let rows: Vec<&logs::Line> = t.lines.iter().filter(|l| (src.is_empty() || l.group == src) && (f.is_empty() || l.text.to_lowercase().contains(&f) || l.source.to_lowercase().contains(&f))).collect();
            egui::Frame::new().fill(WELL).stroke(egui::Stroke::new(1.0_f32, BORDER)).corner_radius(R_MD).inner_margin(egui::Margin::symmetric(0, 4)).show(ui, |ui| {
                ui.set_width(ui.available_width());
                ui.spacing_mut().item_spacing.y = 0.0;
                let h = 18.0;
                let mono = egui::FontId::monospace(11.0);
                egui::ScrollArea::vertical().id_salt(("logscroll", &inst.id)).max_height(400.0).min_scrolled_height(400.0).stick_to_bottom(!paused).auto_shrink([false, false]).show_rows(ui, h, rows.len().max(1), |ui, range| {
                    if rows.is_empty() {
                        ui.add_space(8.0);
                        ui.horizontal(|ui| {
                            ui.add_space(10.0);
                            ui.label(muted(if f.is_empty() && src.is_empty() { "Nothing yet" } else { "Nothing matches" }));
                        });
                        return;
                    }
                    let srcw = 96.0;
                    let tw = 60.0;
                    for l in &rows[range.start.min(rows.len())..range.end.min(rows.len())] {
                        let (r, resp) = ui.allocate_exact_size(egui::vec2(ui.available_width(), h), egui::Sense::hover());
                        if resp.hovered() {
                            ui.painter().rect_filled(r, 0.0, egui::Color32::from_rgb(0x1b, 0x1c, 0x1f));
                        }
                        let (time, msg) = logs::split_time(&l.text);
                        let mut x = r.left() + 10.0;
                        if let Some(t) = time {
                            ui.painter().text(egui::pos2(x, r.center().y), egui::Align2::LEFT_CENTER, t, mono.clone(), INK_3);
                        }
                        x += tw;
                        let g = galley_trunc(ui, &l.source, mono.clone(), INK_2, srcw - 8.0);
                        ui.painter().galley(egui::pos2(x, r.center().y - g.size().y / 2.0), g, INK_2);
                        x += srcw;
                        let low = msg.to_ascii_lowercase();
                        let col = if low.contains("error") || low.contains("fail") || low.contains("crash") { CRIT_INK } else if low.contains("warn") { WARN } else { INK };
                        let g = galley_trunc(ui, msg, mono.clone(), col, r.right() - x - 8.0);
                        ui.painter().galley(egui::pos2(x, r.center().y - g.size().y / 2.0), g, col);
                        resp.on_hover_ui(|ui| {
                            ui.set_max_width(520.0);
                            ui.label(muted(&l.source));
                            ui.label(egui::RichText::new(&l.text).monospace().size(11.0).color(INK));
                        });
                    }
                });
            });
        }
        ui.add_space(S3);
    }

    fn perf_section(&mut self, ui: &mut egui::Ui, id: &str, st: Option<&instance::Status>) {
        let Some(s) = st.filter(|s| s.phase != Phase::Off) else {
            ui.label(muted("Start the phone to see what it uses."));
            ui.add_space(S3);
            return;
        };
        let fps = self.viewers.get(id).map(|v| v.fps()).unwrap_or(0);
        let (fv, fnote) = if fps > 0 { (fps.to_string(), "fps") } else { ("Idle".to_string(), "") };
        stat_row(ui, CARD, &[("Processes", s.procs.len().to_string(), ""), ("Screen updates", fv, fnote)]);
        ui.add_space(S2);
        let top: Vec<_> = s.procs.iter().take(25).collect();
        let max = s.procs.first().map(|p| p.pss_mb).unwrap_or(1.0).max(1.0);
        egui::Frame::new().fill(CARD).stroke(egui::Stroke::new(1.0_f32, BORDER)).corner_radius(R_MD).inner_margin(egui::Margin::symmetric(10, 6)).show(ui, |ui| {
            ui.set_width(ui.available_width());
            ui.spacing_mut().item_spacing.y = 0.0;
            let w = ui.available_width();
            let (cpu_w, mem_w, bar_w) = (40.0, 58.0, 56.0);
            let name_w = w - cpu_w - mem_w - bar_w - 16.0;
            let (hr, _) = ui.allocate_exact_size(egui::vec2(w, 22.0), egui::Sense::hover());
            let hf = font_sb(10.5);
            let p = ui.painter();
            p.text(hr.left_center(), egui::Align2::LEFT_CENTER, "PROCESS", hf.clone(), INK_3);
            p.text(egui::pos2(hr.right() - cpu_w - 8.0, hr.center().y), egui::Align2::RIGHT_CENTER, "MEMORY", hf.clone(), INK_3);
            p.text(egui::pos2(hr.right(), hr.center().y), egui::Align2::RIGHT_CENTER, "CPU", hf, INK_3);
            for pr in top {
                let (r, resp) = ui.allocate_exact_size(egui::vec2(w, 22.0), egui::Sense::hover());
                let p = ui.painter();
                p.hline(r.x_range(), r.top(), egui::Stroke::new(1.0_f32, BORDER));
                let g = galley_trunc(ui, &pr.comm, font(T_SMALL), INK, name_w);
                p.galley(egui::pos2(r.left(), r.center().y - g.size().y / 2.0), g, INK);
                let bx = r.left() + name_w + 8.0;
                let track = egui::Rect::from_min_size(egui::pos2(bx, r.center().y - 2.0), egui::vec2(bar_w, 4.0));
                p.rect_filled(track, 2.0, RAISED);
                p.rect_filled(egui::Rect::from_min_size(track.min, egui::vec2(((pr.pss_mb / max) as f32 * bar_w).max(2.0), 4.0)), 2.0, ACCENT);
                p.text(egui::pos2(r.right() - cpu_w - 8.0, r.center().y), egui::Align2::RIGHT_CENTER, format!("{:.0} MB", pr.pss_mb), font(T_SMALL), INK_2);
                p.text(egui::pos2(r.right(), r.center().y), egui::Align2::RIGHT_CENTER, format!("{:.0}%", pr.cpu_pct), font(T_SMALL), if pr.cpu_pct > 50.0 { WARN } else { INK_2 });
                resp.on_hover_text(format!("{} · pid {}", pr.comm, pr.pid));
            }
            if s.procs.len() > 25 {
                ui.add_space(6.0);
                ui.label(muted(format!("and {} smaller ones", s.procs.len() - 25)));
            }
        });
        ui.add_space(S3);
    }

    fn advanced_section(&mut self, ui: &mut egui::Ui, inst: &instance::Instance, st: Option<&instance::Status>) {
        let Some((_, s)) = &mut self.settings else { return };
        let mut save = false;
        let field = |ui: &mut egui::Ui, label: &str, tip: &str| {
            ui.add_space(S1);
            ui.horizontal(|ui| {
                ui.spacing_mut().item_spacing.x = 4.0;
                ui.label(egui::RichText::new(label).size(T_SMALL).family(medium()).color(INK_2));
                ui.label(egui::RichText::new(icon::INFO).size(12.0).color(INK_3)).on_hover_text(tip);
            });
        };
        field(ui, "Screen scaling", "How the screen is shrunk when it is drawn smaller than the phone (a small window, the side panel). Smooth averages the pixels; Sharp keeps every nth one (least CPU, but text and edges shimmer); Full sends the whole frame and lets the GPU scale it. Applies at once.");
        let opts = [("smooth", "Smooth"), ("sharp", "Sharp"), ("full", "Full resolution")];
        let sel = opts.iter().position(|o| o.0 == s.scaling);
        let mut scaled = false;
        if let Some(i) = segmented(ui, &opts.map(|o| o.1), sel, true) {
            s.scaling = opts[i].0.into();
            scaled = true;
        }
        ui.add_space(S2);
        ui.label(muted("The rest apply at the next start."));
        field(ui, "Graphics", "X86SIM_METAL: GPU for everything (all), only the system (backboardd), or software rendering (0).");
        let opts = [("all", "GPU"), ("backboardd", "System only"), ("0", "Software")];
        let sel = opts.iter().position(|o| o.0 == s.metal);
        if let Some(i) = segmented(ui, &opts.map(|o| o.1), sel, true) {
            s.metal = opts[i].0.into();
            save = true;
        }
        field(ui, "Background services", "A64_JOBS: which background services boot. Standard is right for daily use; Full adds widgets; Slim and Minimal are for tests.");
        let opts = [("std", "Standard"), ("full", "Full"), ("slim", "Slim"), ("min", "Minimal")];
        let sel = opts.iter().position(|o| o.0 == s.jobs);
        if let Some(i) = segmented(ui, &opts.map(|o| o.1), sel, true) {
            s.jobs = opts[i].0.into();
            save = true;
        }
        field(ui, "Memory cap", "X86SIM_MEM_MAX for this phone's processes (systemd MemoryMax), e.g. 6G. Empty: no cap.");
        if ui.add(egui::TextEdit::singleline(&mut s.mem_max).hint_text(egui::RichText::new("No cap").color(INK_3)).desired_width(120.0).margin(egui::Margin::symmetric(8, 6))).lost_focus() {
            save = true;
        }
        ui.add_space(S1);
        ui.horizontal(|ui| {
            ui.spacing_mut().item_spacing.x = 4.0;
            ui.label(egui::RichText::new("Share the GPU helper").size(T_SMALL).family(medium()).color(INK_2));
            ui.label(egui::RichText::new(icon::INFO).size(12.0).color(INK_3)).on_hover_text("A64_MTLVK_SOCKET: use one mtlvk for all running phones instead of starting another");
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                if toggle(ui, &mut s.share_mtlvk).changed() {
                    save = true;
                }
            });
        });
        field(ui, "Extra environment", "A64_ENV: KEY=value pairs for launchd_sim, e.g. X86SIM_A64_TRACE=1");
        if ui.add(egui::TextEdit::singleline(&mut s.extra_env).font(egui::TextStyle::Monospace).hint_text(egui::RichText::new("KEY=value …").color(INK_3)).desired_width(ui.available_width()).margin(egui::Margin::symmetric(8, 6))).lost_focus() {
            save = true;
        }
        if save || scaled {
            let _ = instance::save_settings(&inst.dir, s);
            if scaled {
                let sc = crate::viewer::scaling_of(&s.scaling);
                if let Some(v) = self.viewers.get(&inst.id) {
                    v.shared.scaling.store(sc, std::sync::atomic::Ordering::Relaxed);
                }
            }
            self.say(if save { "Saved. Applies at the next start." } else { "Saved." });
        }
        ui.add_space(S3);
        ui.label(overline("Paths"));
        ui.add_space(2.0);
        ui.spacing_mut().item_spacing.y = 0.0;
        let row = |ui: &mut egui::Ui, k: &str, v: String| {
            kv(ui, 84.0, k, |ui| {
                ui.add(egui::Label::new(egui::RichText::new(&v).monospace().size(11.0).color(INK_2)).truncate().selectable(true)).on_hover_text(&v);
            });
        };
        row(ui, "Device", inst.dir.display().to_string());
        row(ui, "State", st.map(|s| s.state_dir.clone()).unwrap_or(inst.state_dir.clone()).display().to_string());
        row(ui, "Prefix", st.map(|s| s.prefix.clone()).unwrap_or(inst.prefix.clone()).display().to_string());
        row(ui, "Frame ring", inst.ring.display().to_string());
        row(ui, "Input", inst.sock.display().to_string());
        row(ui, "Runtime", inst.runtime_root.display().to_string());
        row(ui, "Cache", x86sim_core::sim::jc_for(&inst.runtime_root).display().to_string());
        row(ui, "UDID", inst.udid.clone());
        row(ui, "Model id", inst.model_id.clone());
        ui.spacing_mut().item_spacing.y = S2;
        ui.add_space(S3);
        ui.horizontal(|ui| {
            if ui.add(Btn::secondary("Own window").icon(icon::APP_WINDOW).small()).on_hover_text("This phone's screen in a separate window, with its buttons beside it (simview)").clicked() {
                match x86sim_core::sim::show_phone(inst) {
                    Ok(()) => self.say(format!("Opened {} in its own window", inst.name)),
                    Err(e) => self.say(format!("Couldn't open the window: {e:#}")),
                }
            }
            if ui.add(Btn::secondary("Pre-translate this iOS").icon(icon::LIGHTNING).small()).clicked() {
                self.aot.select(inst.runtime_root.clone(), Some(inst.dir.clone()));
                self.view = View::Aot;
            }
        });
        ui.add_space(S3);
    }
}
