//! One phone: a top bar (breadcrumb with a phone switcher, state, Start/Stop/Restart), its screen (touch + keyboard)
//! with a vertical tool bar right of it (Home, Lock, volume, Siri, screenshot, gesture help), and the inspector: Overview, then fold-out Features,
//! Logs, Performance, Advanced.
use crate::theme::*;
use crate::{remote, viewer, App, View};
use eframe::egui;
use std::time::{Duration, Instant};
use x86sim_core::{features, instance, instance::Phase, logs};

/// Enter pressed while no text field has it (a dialog's confirm)
fn ui_enter(ctx: &egui::Context) -> bool {
    !ctx.wants_keyboard_input() && ctx.input_mut(|i| i.consume_key(egui::Modifiers::NONE, egui::Key::Enter))
}

/// Room right of a watch's case for its crown, which stands off the case's edge
const WATCH_EDGE: f32 = 22.0;
/// Width of the tool bar right of the screen (Platforms 1: an Apple TV's holds the remote)
fn toolbar_w(platform: &str) -> f32 {
    if platform == "tvos" { 116.0 } else { 46.0 }
}
const GESTURES: &str ="Click the screen to tap, drag to swipe.\nDrag in from an edge for system gestures (Home, Control Center, back).\nCtrl + drag to pinch, Shift + drag to scroll with two fingers.\nF1 Home · F2 Lock · F3/F4 volume";
const GESTURES_TV: &str = "The keyboard is the remote: arrow keys move, Return selects, Esc goes back.\nClick the screen or the clickpad's centre to select; the wheel over either moves the focus.\nF1 TV (home) · F2 play / pause · F3/F4 volume";
const GESTURES_WATCH: &str = "Click the screen to tap, drag to swipe.\nThe mouse wheel (over the screen or the crown) or a drag on the crown turns it; a click on the crown presses it.\nF1 presses the crown (watch face / apps) · F2 the side button (sleep / wake)";

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

        egui::TopBottomPanel::top("phone-head").frame(egui::Frame::new().fill(pal().canvas).inner_margin(egui::Margin { left: 16, right: 16, top: 10, bottom: 10 })).show(ctx, |ui| {
            ui.horizontal(|ui| {
                ui.set_min_height(32.0);
                // the actions first, at the right; the breadcrumb then has what they leave, and its model line is
                // cut to fit (drawn after it, the buttons covered a long model name at narrow widths)
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    ui.spacing_mut().item_spacing.x = S2;
                    self.phone_menu(ui, &inst, phase);
                    match phase {
                        // not installed: the Download action lives in the screen area's empty state
                        Phase::Off if !inst.runtime_present => {}
                        Phase::Off => {
                            if ui.add(Btn::primary("Start").icon(icon::PLAY).key("s").min_w(84.0)).on_hover_text("Start this device").clicked() {
                                self.start(id);
                            }
                        }
                        Phase::Stopping => {
                            ui.add_enabled(false, Btn::secondary("Stopping…").min_w(84.0));
                        }
                        _ => {
                            if ui.add(Btn::secondary("Stop").icon(icon::STOP).icon_color(pal().crit_ink).key("s").min_w(84.0)).on_hover_text("Shut this device down. Its apps and data are kept.").clicked() {
                                self.stop(id);
                            }
                            if instance::needs_restart(&inst, st.as_ref()) {
                                if ui.add(Btn::primary("Restart to apply").icon(icon::ARROW_CLOCKWISE).key("r")).on_hover_text("Feature or start settings changed since this device started").clicked() {
                                    self.restart(id);
                                }
                            } else if ui.add(Btn::secondary("Restart").icon(icon::ARROW_CLOCKWISE).key("r")).on_hover_text("Stop and start again").clicked() {
                                self.restart(id);
                            }
                        }
                    }
                    ui.add_space(S1);
                    ui.with_layout(egui::Layout::left_to_right(egui::Align::Center), |ui| {
                        ui.spacing_mut().item_spacing.x = 4.0;
                        if ui.add(Btn::ghost("Devices").icon(icon::CARET_LEFT).key("Esc")).on_hover_text("Back to all devices").clicked() {
                            self.view = View::Home;
                        }
                        ui.label(egui::RichText::new("/").size(T_TITLE).color(pal().ink_3));
                        let (label, col) = phase_look(phase, inst.runtime_present);
                        let badge_w = ui.painter().layout_no_wrap(label.to_string(), font_m(T_SMALL), pal().ink_2).size().x + 30.0;
                        // the phone's name doubles as a switcher; a long one is cut so the state stays in view
                        let name_room = (ui.available_width() - badge_w - 60.0).max(80.0);
                        let name = galley_trunc(ui, &inst.name, font_sb(T_TITLE), pal().ink, name_room);
                        let cut = name.elided;
                        let shown = if cut { format!("{}…", name.text().trim_end_matches('…').trim_end()) } else { inst.name.clone() };
                        let txt = egui::RichText::new(shown).size(T_TITLE).family(semibold()).color(pal().ink);
                        let others: Vec<(String, String, Phase, bool)> = self.insts.iter().map(|i| (i.id.clone(), i.name.clone(), self.phase(&i.id), i.runtime_present)).collect();
                        let mut go = None;
                        let (sw, _) = egui::containers::menu::MenuButton::from_button(egui::Button::new(txt).frame_when_inactive(false)).ui(ui, |ui| {
                            ui.set_width(260.0);
                            ui.spacing_mut().item_spacing.y = 0.0;
                            for (oid, name, ph, present) in &others {
                                let (r, resp) = ui.allocate_exact_size(egui::vec2(260.0, 30.0), egui::Sense::click());
                                let p = ui.painter();
                                if resp.hovered() {
                                    p.rect_filled(r, radius_sm(), pal().hover);
                                }
                                if oid == id {
                                    p.text(r.left_center() + egui::vec2(8.0, 0.0), egui::Align2::LEFT_CENTER, icon::CHECK, ifont(13.0), pal().ink);
                                }
                                let g = galley_trunc(ui, name, font_m(T_BODY), pal().ink, 150.0);
                                p.galley(egui::pos2(r.left() + 28.0, r.center().y - g.size().y / 2.0), g, pal().ink);
                                let state = match ph {
                                    Phase::Running => "Running",
                                    Phase::Starting => "Starting",
                                    Phase::Stopping => "Stopping",
                                    Phase::Off if !present => "Not installed",
                                    Phase::Off => "Off",
                                };
                                p.text(r.right_center() - egui::vec2(10.0, 0.0), egui::Align2::RIGHT_CENTER, state, font(T_SMALL), pal().ink_3);
                                if *ph == Phase::Running {
                                    let w = ui.painter().layout_no_wrap(state.into(), font(T_SMALL), pal().ink_3).size().x;
                                    ui.painter().circle_filled(r.right_center() - egui::vec2(18.0 + w, 0.0), 3.0, pal().good);
                                }
                                if resp.on_hover_cursor(egui::CursorIcon::PointingHand).clicked() {
                                    go = Some(oid.clone());
                                    ui.close();
                                }
                            }
                        });
                        sw.on_hover_text(if cut { format!("{} · switch to another device", inst.name) } else { "Switch to another device".to_string() });
                        if let Some(g) = go {
                            self.view = View::Phone(g);
                        }
                        ui.add_space(6.0);
                        // model and version: here and nowhere else on the page, in the room left before the state badge.
                        // The compact model name; the full one on hover (and on the badge when there is no room at all)
                        let full = format!("{} · {}", inst.model, inst.ios);
                        let line = device_line(&inst.name, &inst.model, &inst.ios);
                        let room = ui.available_width() - badge_w - 8.0 - 4.0;
                        let shown = room >= 64.0;
                        if shown {
                            let g = galley_trunc(ui, &line, font(T_BODY), pal().ink_3, room);
                            let (r, resp) = ui.allocate_exact_size(g.size(), egui::Sense::hover());
                            ui.painter().galley(r.min, g, pal().ink_3);
                            resp.on_hover_text(&full);
                            ui.add_space(8.0);
                        }
                        let b = badge(ui, label, col);
                        if !shown {
                            b.on_hover_text(full);
                        }
                    });
                });
            });
        });

        // the inspector may take at most ~40% of the page: dragged wide (or a narrow window) it left a landscape screen
        // (Apple TV) a 200-point strip between it and the remote
        let content_w = ctx.content_rect().width() - crate::NAV_W;
        let side_max = (content_w * 0.42).clamp(340.0, 720.0);
        egui::SidePanel::right("phone-side")
            .resizable(true)
            .default_width(392.0_f32.min(side_max))
            .width_range(340.0..=side_max)
            .frame(egui::Frame::new().fill(pal().window).inner_margin(egui::Margin { left: 16, right: 12, top: 16, bottom: 12 }))
            .show(ctx, |ui| {
                egui::ScrollArea::vertical().auto_shrink([false, false]).show(ui, |ui| {
                    ui.set_width(ui.available_width() - 4.0);
                    self.side_panel(ui, &inst, st.as_ref());
                });
            });

        egui::CentralPanel::default().frame(egui::Frame::new().fill(pal().canvas).inner_margin(egui::Margin { left: 24, right: 24, top: 20, bottom: 16 })).show(ctx, |ui| {
            if !inst.runtime_present {
                let busy = self.fetching.contains_key(&inst.build);
                let h = ui.available_height();
                ui.add_space((h / 2.0 - 110.0).max(0.0));
                let mut dl = false;
                empty_state(ui, icon::CLOUD_ARROW_DOWN, &format!("{} isn't installed", inst.ios), "Download it to start this device. Its apps and data are kept.", |ui| {
                    if busy {
                        let line = self.fetching.get(&inst.build).map(crate::home::fetch_line).unwrap_or_default();
                        crate::theme::busy(ui, &line);
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
            // the state is the header's badge; the screen only says what the badge can't
            let placeholder = if phase == Phase::Running { "Waiting for the screen…" } else { "" };
            // the screen and, to its right, the tools (as Simulator's side buttons): centred together
            let watch = inst.platform == "watchos";
            let edge = if watch { WATCH_EDGE } else { 0.0 };
            let avail = ui.available_size() - egui::vec2(toolbar_w(&inst.platform) + S3 + edge, 0.0);
            let rid = egui::Id::new(("screen-row", id));
            let w: f32 = ui.data(|d| d.get_temp(rid)).unwrap_or(avail.x);
            let r = ui.horizontal_top(|ui| {
                ui.add_space(((ui.available_width() - w) / 2.0).max(0.0));
                let start = ui.cursor().min.x;
                let case = self.viewer(id).map(|v| v.show(ui, avail, live, placeholder, true, viewer::FULL));
                // Platforms 1: a watch's crown and side button stand off its case's right edge, as on the watch
                if let (true, Some(case)) = (watch, case) {
                    ui.add_space(edge);
                    self.watch_controls(ui, id, live, case);
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
        let btn = egui::Button::new(egui::RichText::new(icon::DOTS_THREE).family(icons()).size(16.0).color(pal().ink_2)).min_size(egui::vec2(H_MD, H_MD)).frame_when_inactive(false);
        let (resp, _) = egui::containers::menu::MenuButton::from_button(btn).ui(ui, |ui| {
            ui.set_width(220.0);
            ui.spacing_mut().item_spacing.y = 0.0;
            self.phone_menu_items(ui, inst, phase);
        });
        resp.on_hover_text("More: own window, rename, remove");
    }

    pub fn phone_menu_items(&mut self, ui: &mut egui::Ui, inst: &instance::Instance, phase: Phase) {
        // its screen in a window of its own (simview); an open one is raised, not opened twice
        if menu_row(ui, icon::APP_WINDOW, "Open in own window", "o", phase != Phase::Off, false).on_disabled_hover_text("Start it first").clicked() {
            match x86sim_core::sim::show_phone(inst) {
                Ok(()) => self.say(format!("Opened {} in its own window", inst.name)),
                Err(e) => self.say(format!("Couldn't open the window: {e:#}")),
            }
            ui.close();
        }
        if menu_row(ui, icon::PENCIL_SIMPLE, "Rename…", "F2", true, false).clicked() {
            self.dialog = Some(crate::Dialog::Rename { id: inst.id.clone(), text: inst.name.clone() });
            ui.close();
        }
        let off = phase == Phase::Off;
        let can = off && !inst.is_default;
        let r = menu_row(ui, icon::TRASH, "Remove device…", "Del", can, true);
        let r = if inst.is_default { r.on_disabled_hover_text("The main phone stays") } else if !off { r.on_disabled_hover_text("Stop it first") } else { r };
        if r.clicked() {
            self.ask_remove(inst, ui.ctx());
            ui.close();
        }
    }

    /// Opens the remove confirmation, measuring what it frees in the background.
    pub fn ask_remove(&mut self, inst: &instance::Instance, ctx: &egui::Context) {
        let paths = instance::delete_plan(inst);
        let size = std::sync::Arc::new(std::sync::Mutex::new(None));
        let (s2, p2, ctx) = (size.clone(), paths.clone(), ctx.clone());
        std::thread::spawn(move || {
            let n: u64 = p2.iter().map(|p| if p.is_dir() { x86sim_core::host::dir_size(p) } else { p.metadata().map(|m| m.len()).unwrap_or(0) }).sum();
            *s2.lock().unwrap() = Some(n);
            ctx.request_repaint();
        });
        self.dialog = Some(crate::Dialog::Delete { id: inst.id.clone(), paths, size });
    }

    /// Rename / remove dialogs.
    pub fn phone_dialog(&mut self, ctx: &egui::Context) {
        let Some(d) = self.dialog.take() else { return };
        let mut keep = true;
        match d {
            crate::Dialog::Rename { id, mut text } => {
                let Some(inst) = self.inst(&id).cloned() else { return };
                let mut save = false;
                let m = modal("rename-phone").show(ctx, |ui| {
                    ui.set_width(360.0);
                    ui.spacing_mut().item_spacing.y = 4.0;
                    ui.label(dialog_title("Rename device"));
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
                        if ui.add_enabled(!text.trim().is_empty(), Btn::primary("Rename").key("Enter").min_w(88.0)).clicked() {
                            save = true;
                        }
                        if ui.add(Btn::secondary("Cancel").key("Esc").min_w(80.0)).clicked() {
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
                let m = modal("delete-phone").show(ctx, |ui| {
                    ui.set_width(420.0);
                    ui.spacing_mut().item_spacing.y = 4.0;
                    ui.add(egui::Label::new(dialog_title(format!("Remove {}?", inst.name))).wrap());
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
                        if ui.add(Btn::danger("Remove").key("Enter").min_w(88.0)).clicked() {
                            go = true;
                        }
                        if ui.add(Btn::secondary("Cancel").key("Esc").min_w(80.0)).clicked() {
                            keep = false;
                        }
                    });
                });
                if m.should_close() {
                    keep = false;
                }
                if ui_enter(ctx) {
                    go = true;
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
    /// command (no orientation or motion events), so they are not offered. Platforms 1: an Apple TV gets a Siri Remote
    /// and an Apple Watch its Digital Crown and side button (remote.rs), above the same Save Screen and help.
    fn screen_toolbar(&mut self, ui: &mut egui::Ui, id: &str, live: bool) {
        let name = self.inst(id).map(|i| i.name.clone()).unwrap_or_else(|| id.to_string());
        let hinge = self.inst(id).filter(|i| i.inner.is_some()).map(|i| i.inner_active());
        let platform = self.inst(id).map(|i| i.platform.clone()).unwrap_or_default();
        let w = toolbar_w(&platform);
        ui.vertical(|ui| {
            ui.set_width(w);
            ui.spacing_mut().item_spacing.y = S2;
            if platform == "tvos" {
                ui.vertical_centered(|ui| self.tv_remote(ui, id, live));
            }
            // the tools stand beside the screen as a device's side buttons do: no box around them
            {
                ui.vertical_centered(|ui| {
                    ui.spacing_mut().item_spacing.y = 2.0;
                    fn tool_btn(ui: &mut egui::Ui, live: bool, ic: &'static str, tip: &str) -> bool {
                        ui.add_enabled(live, Btn::ghost("").icon(ic)).on_hover_text(tip).on_disabled_hover_text("Not running").clicked()
                    }
                    let tool = |ui: &mut egui::Ui, ic: &'static str, tip: &str| tool_btn(ui, live, ic, tip);
                    if platform != "tvos" && platform != "watchos" {
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
                        if let (Some(b), Some(v)) = (press, self.viewer(id)) {
                            v.press(b);
                        }
                        // a gap, not a rule, between the device's buttons and the launcher's own tools
                        ui.add_space(S3);
                    }
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
                    ui.add(Btn::tool(icon::INFO)).on_hover_text(match platform.as_str() {
                        "tvos" => GESTURES_TV,
                        "watchos" => GESTURES_WATCH,
                        _ => GESTURES,
                    });
                });
            }
        });
    }

    /// Platforms 1: the Siri Remote. Clickpad (arrows / select as the keyboard's keys, held keys repeat); Back
    /// (consumer 0x46, Menu Escape: one level back; 0x40 closed the app), TV (0x60: the home screen), play / pause
    /// (0xcd), mute (0xe2), the volume rocker. No power or Siri button: holding power put the TV to sleep, which the
    /// simulator declines (WORKAROUNDS.md).
    fn tv_remote(&mut self, ui: &mut egui::Ui, id: &str, live: bool) {
        let (mut keys, mut press, mut usage, mut vol) = (vec![], None, None, None);
        remote::body(ui, |ui| {
            ui.spacing_mut().item_spacing.y = 14.0;
            keys = remote::clickpad(ui, 88.0, live);
            let (d, gap_x, gap_y) = (38.0_f32, 12.0_f32, 10.0_f32);
            let (grid, _) = ui.allocate_exact_size(egui::vec2(2.0 * d + gap_x, 3.0 * d + 2.0 * gap_y), egui::Sense::hover());
            let cell = |col: f32, row: f32| egui::Rect::from_min_size(grid.min + egui::vec2(col * (d + gap_x), row * (d + gap_y)), egui::vec2(d, d));
            let bid = egui::Id::new(("remote", id));
            if remote::round_button(ui, cell(0.0, 0.0), bid.with("back"), icon::CARET_LEFT, "Back (Esc)", live) {
                press = Some("menu");
            }
            if remote::round_button(ui, cell(1.0, 0.0), bid.with("tv"), icon::TELEVISION_SIMPLE, "TV: the home screen (F1)", live) {
                press = Some("tv");
            }
            if remote::round_button(ui, cell(0.0, 1.0), bid.with("play"), icon::PLAY_PAUSE, "Play / pause (F2)", live) {
                press = Some("playpause");
            }
            if remote::round_button(ui, cell(0.0, 2.0), bid.with("mute"), icon::SPEAKER_SLASH, "Mute", live) {
                usage = Some(0xe2);
            }
            let rock = egui::Rect::from_min_max(cell(1.0, 1.0).min, cell(1.0, 2.0).max);
            vol = remote::rocker(ui, rock, bid.with("vol"), live);
        });
        if let Some(v) = self.viewer(id) {
            for (u, down) in keys {
                v.key(down, u);
            }
            if let Some(b) = press {
                v.press(b);
            }
            if let Some(u) = usage {
                v.tap_usage(0x0c, u);
            }
            if let Some(up) = vol {
                v.press(if up { "volup" } else { "voldown" });
            }
        }
    }

    /// Platforms 1: the watch's right edge, placed as on an Apple Watch: the Digital Crown in the upper part of the case
    /// (drag / scroll to turn, click to press: the watch face or the app grid), the long side button below it (sleep /
    /// wake). Sized from the case's height. No volume buttons on a watch.
    fn watch_controls(&mut self, ui: &mut egui::Ui, id: &str, live: bool, case: egui::Rect) {
        let h = case.height();
        let x = case.right();
        let crown_h = (h * 0.15).clamp(24.0, 72.0);
        let crown_w = (h * 0.045).clamp(9.0, 22.0).min(WATCH_EDGE);
        let crown_c = case.top() + h * 0.30;
        let crown = egui::Rect::from_min_size(egui::pos2(x, crown_c - crown_h / 2.0), egui::vec2(crown_w, crown_h));
        let side_h = (h * 0.27).clamp(36.0, 130.0);
        let side_c = case.top() + h * 0.62;
        let side = egui::Rect::from_min_size(egui::pos2(x - 1.0, side_c - side_h / 2.0), egui::vec2((crown_w * 0.45).max(5.0), side_h));
        let bid = egui::Id::new(("watch-edge", id));
        let ev = remote::crown(ui, crown, bid.with("crown"), live);
        let pressed = remote::side_button(ui, side, bid.with("side"), live);
        if let Some(v) = self.viewer(id) {
            match ev {
                Some(remote::CrownEvent::Turn(d)) => v.crown(d),
                Some(remote::CrownEvent::Press) => v.press("home"),
                None => {}
            }
            if pressed {
                v.press("side");
            }
        }
    }

    fn side_panel(&mut self, ui: &mut egui::Ui, inst: &instance::Instance, st: Option<&instance::Status>) {
        let phase = st.map(|s| s.phase).unwrap_or(Phase::Off);
        let id = inst.id.clone();
        let on = phase != Phase::Off;
        // ---- Overview (always shown; live numbers only while it runs)
        if on {
            stat_row(ui, pal().card, &[
                ("Memory", fmt_mb(st.map(|s| s.pss_mb).unwrap_or(0.0)), ""),
                ("CPU", format!("{:.0}%", st.map(|s| s.cpu_pct).unwrap_or(0.0)), ""),
                ("Up for", st.and_then(|s| s.uptime_s).map(fmt_uptime).unwrap_or("–".into()), ""),
            ]);
            // the GPU helper apart from the phone's own memory: one helper may serve several devices
            if let Some(g) = st.and_then(|s| s.gpu.as_ref()) {
                ui.add_space(S1);
                let shared = if g.users > 1 { format!(", shared by {} devices", g.users) } else { String::new() };
                ui.label(muted(format!("+ {} for the GPU helper{shared}", fmt_mb(g.pss_mb))))
                    .on_hover_text("mtlvk runs every Metal call on Vulkan. It is not in this device's memory; the total in the sidebar counts it once.");
            }
            ui.add_space(S3);
        }
        ui.spacing_mut().item_spacing.y = 2.0;
        let lw = 84.0;
        // model, version and state are the header's; here only what it doesn't show
        kv_text(ui, lw, "Screen", format!("{} × {} pixels", inst.screen.0, inst.screen.1));
        if let Some(s) = st.filter(|_| on) {
            kv_text(ui, lw, "Processes", s.procs.len().to_string());
        }
        let prof = features::load(&inst.dir);
        let off: Vec<String> = features::defs().features.iter().filter(|f| !prof.enabled(&f.id)).map(|f| f.title.clone()).collect();
        // Platforms 1: the feature toggles are iPhone / iPad jobs (wallpaper, Search, Siri, Maps...): an Apple TV or
        // Apple Watch runs its own job set, so neither the summary nor the section is shown for them
        let ios = inst.platform == "ios";
        ui.spacing_mut().item_spacing.y = S2;
        ui.add_space(S3);
        hline(ui);

        // ---- Features: the set in one place. Folded, the header says which set and how many are off (which ones on
        // hover); open, the segment and the switches below say it themselves
        if ios {
            let preset = features::preset_of(&prof).map(|p| match p.as_str() { "full" => "Full set", "lean" => "Lean set", "minimal" => "Minimal set", _ => "Custom" });
            let (summary, tip) = if self.open.contains("features") {
                (String::new(), String::new())
            } else {
                let t = match (preset, off.len()) {
                    (Some(p), 0) => p.to_string(),
                    (Some(p), n) => format!("{p} · {n} off"),
                    (None, 0) => "Everything on".to_string(),
                    (None, n) => format!("Custom · {n} off"),
                };
                (t, if off.is_empty() { String::new() } else { format!("Off: {}", off.join(", ")) })
            };
            if self.fold_section(ui, "features", "Features", &summary, &tip) {
                self.features_section(ui, inst, phase);
            }
            hline(ui);
        }

        // ---- Logs
        let nlines = self.logs.as_ref().filter(|l| l.0 == id).map(|l| l.1.lines.len()).unwrap_or(0);
        let summary = if self.open.contains("logs") && nlines > 0 { format!("{nlines} lines") } else { String::new() };
        if self.fold_section(ui, "logs", "Logs", &summary, "") {
            self.logs_section(ui, inst, st);
        } else {
            self.logs = None;
        }
        hline(ui);

        // ---- Performance
        // no summary: memory and CPU are the tiles at the top
        if self.fold_section(ui, "perf", "Performance", "", "") {
            self.perf_section(ui, &id, st);
        }
        hline(ui);

        // ---- Advanced
        if self.fold_section(ui, "adv", "Advanced", "", "") {
            self.advanced_section(ui, inst, st);
        }
    }

    fn fold_section(&mut self, ui: &mut egui::Ui, key: &'static str, title_text: &str, summary: &str, tip: &str) -> bool {
        let open = self.open.contains(key);
        let hint = match key { "features" => "f", "logs" => "l", "perf" => "p", _ => "a" };
        if fold(ui, title_text, summary, tip, hint, open) != open {
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
            dot_label(ui, &format!("Saving about {saving} MB"), pal().good);
        }
        let st = self.status.get(&inst.id).cloned();
        if (changed || instance::needs_restart(inst, st.as_ref())) && phase != Phase::Off {
            ui.add_space(S1);
            egui::Frame::new().fill(pal().raised).stroke(egui::Stroke::new(1.0_f32, pal().border)).corner_radius(radius()).inner_margin(egui::Margin::symmetric(10, 6)).show(ui, |ui| {
                ui.set_width(ui.available_width());
                ui.horizontal(|ui| {
                    ui.label(egui::RichText::new(icon::WARNING_CIRCLE).family(icons()).size(14.0).color(pal().warn));
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
            let rest = rest.max(80.0);
            search(ui, &mut self.log_filter, if rest < 190.0 { "Filter" } else { "Filter text or process" }, rest).on_hover_text("Show only lines with this text, or from this process");
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
                                "System" => "One log per system service and app",
                                "Translator" => "The ARM translator, one log per process",
                                "Boot" => "Starting the device",
                                "Graphics" => "The GPU helper",
                                _ => "Memory clean-up",
                            });
                        });
                    }
                })
                .response
                .on_hover_text("Which logs to show");
            let (ic, tip) = if self.log_paused { (icon::PLAY, "Follow new lines again") } else { (icon::PAUSE, "Pause: stop following new lines") };
            if ui.add(Btn::tool(ic)).on_hover_text(tip).clicked() {
                self.log_paused = !self.log_paused;
            }
            if ui.add(Btn::tool(icon::TRASH)).on_hover_text("Clear the lines shown here (the log files stay)").clicked() {
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
            egui::Frame::new().fill(pal().well).stroke(egui::Stroke::new(1.0_f32, pal().border)).corner_radius(radius()).inner_margin(egui::Margin::symmetric(0, 4)).show(ui, |ui| {
                ui.set_width(ui.available_width());
                ui.spacing_mut().item_spacing.y = 0.0;
                let h = 18.0;
                let mono = egui::FontId::monospace(T_SMALL);
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
                            ui.painter().rect_filled(r, 0.0, pal().hover);
                        }
                        let (time, msg) = logs::split_time(&l.text);
                        let mut x = r.left() + 10.0;
                        if let Some(t) = time {
                            ui.painter().text(egui::pos2(x, r.center().y), egui::Align2::LEFT_CENTER, t, mono.clone(), pal().ink_3);
                        }
                        x += tw;
                        let g = galley_trunc(ui, &l.source, mono.clone(), pal().cyan, srcw - 8.0);
                        ui.painter().galley(egui::pos2(x, r.center().y - g.size().y / 2.0), g, pal().cyan);
                        x += srcw;
                        let low = msg.to_ascii_lowercase();
                        let col = if low.contains("error") || low.contains("fail") || low.contains("crash") { pal().crit_ink } else if low.contains("warn") { pal().warn } else { pal().ink };
                        let g = galley_trunc(ui, msg, mono.clone(), col, r.right() - x - 8.0);
                        ui.painter().galley(egui::pos2(x, r.center().y - g.size().y / 2.0), g, col);
                        resp.on_hover_ui(|ui| {
                            ui.set_max_width(520.0);
                            ui.label(muted(&l.source));
                            ui.label(egui::RichText::new(&l.text).monospace().size(T_SMALL).color(pal().ink));
                        });
                    }
                });
            });
        }
        ui.add_space(S3);
    }

    fn perf_section(&mut self, ui: &mut egui::Ui, id: &str, st: Option<&instance::Status>) {
        let Some(s) = st.filter(|s| s.phase != Phase::Off) else {
            ui.label(muted("Start the device to see what it uses."));
            ui.add_space(S3);
            return;
        };
        let fps = self.viewers.get(id).map(|v| v.fps()).unwrap_or(0);
        // the process count is in the overview above; here only the screen's rate, then who uses what
        kv_text(ui, 104.0, "Screen updates", if fps > 0 { format!("{fps} fps") } else { "Idle".to_string() });
        ui.add_space(S2);
        let top: Vec<_> = s.procs.iter().take(25).collect();
        let max = s.procs.first().map(|p| p.pss_mb).unwrap_or(1.0).max(1.0);
        egui::Frame::new().fill(pal().card).stroke(egui::Stroke::new(1.0_f32, pal().border)).corner_radius(radius()).inner_margin(egui::Margin::symmetric(10, 6)).show(ui, |ui| {
            ui.set_width(ui.available_width());
            ui.spacing_mut().item_spacing.y = 0.0;
            let w = ui.available_width();
            let (cpu_w, mem_w, bar_w) = (40.0, 58.0, 56.0);
            let name_w = w - cpu_w - mem_w - bar_w - 16.0;
            let (hr, _) = ui.allocate_exact_size(egui::vec2(w, 22.0), egui::Sense::hover());
            let hf = table_head();
            let p = ui.painter();
            p.text(hr.left_center(), egui::Align2::LEFT_CENTER, "process", hf.clone(), pal().ink_3);
            p.text(egui::pos2(hr.right() - cpu_w - 8.0, hr.center().y), egui::Align2::RIGHT_CENTER, "memory", hf.clone(), pal().ink_3);
            p.text(egui::pos2(hr.right(), hr.center().y), egui::Align2::RIGHT_CENTER, "cpu", hf, pal().ink_3);
            for pr in top {
                let (r, resp) = ui.allocate_exact_size(egui::vec2(w, 22.0), egui::Sense::hover());
                let p = ui.painter();
                p.hline(r.x_range(), r.top(), egui::Stroke::new(1.0_f32, pal().border));
                let g = galley_trunc(ui, &pr.comm, font(T_SMALL), pal().ink, name_w);
                p.galley(egui::pos2(r.left(), r.center().y - g.size().y / 2.0), g, pal().ink);
                let bx = r.left() + name_w + 8.0;
                let track = egui::Rect::from_min_size(egui::pos2(bx, r.center().y - 2.0), egui::vec2(bar_w, 4.0));
                p.rect_filled(track, 0.0, pal().raised);
                p.rect_filled(egui::Rect::from_min_size(track.min, egui::vec2(((pr.pss_mb / max) as f32 * bar_w).max(2.0), 4.0)), 0.0, pal().blue);
                p.text(egui::pos2(r.right() - cpu_w - 8.0, r.center().y), egui::Align2::RIGHT_CENTER, format!("{:.0} MB", pr.pss_mb), font(T_SMALL), pal().ink_2);
                p.text(egui::pos2(r.right(), r.center().y), egui::Align2::RIGHT_CENTER, format!("{:.0}%", pr.cpu_pct), font(T_SMALL), if pr.cpu_pct > 50.0 { pal().orange } else { pal().ink_2 });
                resp.on_hover_text(format!("{} · pid {}", pr.comm, pr.pid));
            }
            if s.procs.len() > 25 {
                ui.add_space(6.0);
                ui.label(muted(format!("and {} smaller ones", s.procs.len() - 25)));
            }
            // the GPU helper: on its own line, not counted in the phone's memory (it may serve other phones too)
            if let Some(g) = &s.gpu {
                ui.add_space(4.0);
                let (r, resp) = ui.allocate_exact_size(egui::vec2(w, 22.0), egui::Sense::hover());
                let p = ui.painter();
                p.hline(r.x_range(), r.top(), egui::Stroke::new(1.0_f32, pal().border_strong));
                let name = if g.users > 1 { format!("GPU helper (mtlvk) · shared by {}", g.users) } else { "GPU helper (mtlvk)".to_string() };
                let gl = galley_trunc(ui, &name, font(T_SMALL), pal().ink_2, name_w + bar_w);
                p.galley(egui::pos2(r.left(), r.center().y - gl.size().y / 2.0), gl, pal().ink_2);
                p.text(egui::pos2(r.right() - cpu_w - 8.0, r.center().y), egui::Align2::RIGHT_CENTER, format!("{:.0} MB", g.pss_mb), font(T_SMALL), pal().ink_3);
                p.text(egui::pos2(r.right(), r.center().y), egui::Align2::RIGHT_CENTER, format!("{:.0}%", g.cpu_pct), font(T_SMALL), pal().ink_3);
                resp.on_hover_text(format!("Runs every Metal call on Vulkan for the devices that share it (pid {}). Not part of this device's memory above.", g.pid));
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
                ui.label(egui::RichText::new(label).size(T_SMALL).family(medium()).color(pal().ink_2));
                ui.label(egui::RichText::new(icon::INFO).family(icons()).size(12.0).color(pal().ink_3)).on_hover_text(tip);
            });
        };
        field(ui, "Screen scaling", "How the screen is shrunk when it is drawn smaller than the device (a small window, the side panel). Smooth averages the pixels; Sharp keeps every nth one (least CPU, but text and edges shimmer); Full sends the whole frame and lets the GPU scale it. Applies at once.");
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
        if ui.add(egui::TextEdit::singleline(&mut s.mem_max).hint_text(egui::RichText::new("No cap").color(pal().ink_3)).desired_width(120.0).margin(egui::Margin::symmetric(8, 6))).lost_focus() {
            save = true;
        }
        ui.add_space(S1);
        ui.horizontal(|ui| {
            ui.spacing_mut().item_spacing.x = 4.0;
            ui.label(egui::RichText::new("Share the GPU helper").size(T_SMALL).family(medium()).color(pal().ink_2));
            ui.label(egui::RichText::new(icon::INFO).family(icons()).size(12.0).color(pal().ink_3)).on_hover_text("A64_MTLVK_SOCKET: use one mtlvk for all running devices instead of starting another");
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                if toggle(ui, &mut s.share_mtlvk).changed() {
                    save = true;
                }
            });
        });
        field(ui, "Extra environment", "A64_ENV: KEY=value pairs for launchd_sim, e.g. X86SIM_A64_TRACE=1");
        if ui.add(egui::TextEdit::singleline(&mut s.extra_env).font(egui::TextStyle::Monospace).hint_text(egui::RichText::new("KEY=value …").color(pal().ink_3)).desired_width(ui.available_width()).margin(egui::Margin::symmetric(8, 6))).lost_focus() {
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
        ui.label(overline("paths"));
        ui.add_space(2.0);
        ui.spacing_mut().item_spacing.y = 0.0;
        let row = |ui: &mut egui::Ui, k: &str, v: String| {
            kv(ui, 84.0, k, |ui| {
                ui.add(egui::Label::new(egui::RichText::new(&v).monospace().size(T_SMALL).color(pal().ink_2)).truncate().selectable(true)).on_hover_text(&v);
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
        ui.horizontal_wrapped(|ui| {
            if ui.add(Btn::secondary("Pre-translate this version").icon(icon::LIGHTNING).small()).on_hover_text("Open Pre-translate for this device's version and apps").clicked() {
                self.aot.select(inst.runtime_root.clone(), Some(inst.dir.clone()));
                self.view = View::Aot;
            }
        });
        ui.add_space(S3);
    }
}
