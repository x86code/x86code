//! Phones: a grid of cards for phones that can start (live screen, state, memory/CPU, Start/Stop), and a compact list of
//! phones waiting for an iOS version, grouped by version with one Download each. "Add phone" dialog.
use crate::theme::*;
use crate::{viewer, AddDialog, App, View};
use eframe::egui;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use x86sim_core::instance::Phase;

impl App {
    /// Starts downloading an iOS build (unless it already is). Shared by every Download button.
    pub fn download(&mut self, build: &str, label: &str) {
        if build.is_empty() {
            self.view = View::Ios;
            return;
        }
        if self.fetching.contains_key(build) {
            return;
        }
        match x86sim_core::host::fetch(build) {
            Ok(_) => {
                self.fetch_started.insert(build.to_string(), std::time::Instant::now());
                self.fetching.insert(build.to_string(), x86sim_core::host::Fetch { build: build.to_string(), phase: "starting".into(), ..Default::default() });
                self.say(format!("Downloading {label}. This takes a while (several GB)."));
            }
            Err(e) => self.say(format!("Couldn't start the download: {e:#}")),
        }
    }

    pub fn open_add_dialog(&mut self) {
        // the newest installed iOS (one limited to some models, the iPhone Duo's 27.2 build, only when one is chosen)
        // (Platforms 1: of the first model's platform: an iPhone, so iOS)
        let mp = self.models.first().map(|m| x86sim_core::sim::model_platform(&m.1)).unwrap_or("ios");
        let rt = self.runtimes.iter().rposition(|r| r.present && r.restricted_to.is_empty() && r.platform == mp).unwrap_or(0);
        self.add = Some(AddDialog { model: 0, last_model: 0, runtime: rt, name: String::new(), busy: Arc::new(Mutex::new(None)), working: false });
    }

    pub fn home(&mut self, ui: &mut egui::Ui) {
        let n = self.insts.len();
        let mut add = false;
        let sorts = [("name", "Name"), ("newest", "Newest first"), ("oldest", "Oldest first"), ("model", "Model"), ("ios", "Version")];
        let mut sort = self.hub.sort.clone();
        // no subtitle: the count is on the nav item, what runs in the sidebar's footer
        page_header(ui, "Devices", "", |ui| {
            add = ui.add(Btn::primary("Add device").icon(icon::PLUS).key("n")).on_hover_text("Add an iPhone, iPad, Apple TV or Apple Watch").clicked();
            if n > 1 {
                let cur = sorts.iter().find(|s| s.0 == sort).map(|s| s.1).unwrap_or("Name");
                egui::ComboBox::from_id_salt("phonesort").icon(caret).width(150.0).selected_text(body(format!("Sort: {cur}"))).show_ui(ui, |ui| {
                    for (k, label) in sorts {
                        if ui.selectable_label(sort == k, label).clicked() {
                            sort = k.to_string();
                        }
                    }
                })
                .response
                .on_hover_text("Sort the devices by");
            }
        });
        if sort != self.hub.sort {
            self.hub.sort = sort;
            let _ = x86sim_core::host::save_hub(&self.hub);
        }
        x86sim_core::instance::sort(&mut self.insts, &self.hub.sort);
        if add {
            self.open_add_dialog();
        }
        if self.insts.is_empty() {
            card(ui, |ui| {
                empty_state(ui, icon::DEVICE_MOBILE, "No devices yet", "Add an iPhone, iPad, Apple TV or Apple Watch to get started. Each has its own apps, data and settings.", |ui| {
                    if ui.add(Btn::primary("Add device").icon(icon::PLUS).key("n")).clicked() {
                        add = true;
                    }
                });
            });
            if add {
                self.open_add_dialog();
            }
            return;
        }

        let ready: Vec<String> = self.insts.iter().filter(|i| i.runtime_present).map(|i| i.id.clone()).collect();
        if !ready.is_empty() {
            let gap = S4;
            let target = self.hub.card_w;
            let avail = ui.available_width();
            let cols = ((avail + gap) / (target + gap)).floor().max(1.0) as usize;
            let w = ((avail - gap * (cols as f32 - 1.0)) / cols as f32).min(target * 1.25).floor();
            nav::set_stride(cols);
            for row in ready.chunks(cols) {
                ui.horizontal_top(|ui| {
                    ui.spacing_mut().item_spacing.x = gap;
                    for id in row {
                        self.card(ui, id, w);
                    }
                });
                ui.add_space(gap);
            }
        }

        // phones whose iOS isn't installed: one compact group per version
        let mut groups: Vec<(String, String, Vec<String>)> = vec![]; // (ios, build, ids)
        for i in self.insts.iter().filter(|i| !i.runtime_present) {
            match groups.iter_mut().find(|g| g.0 == i.ios && g.1 == i.build) {
                Some(g) => g.2.push(i.id.clone()),
                None => groups.push((i.ios.clone(), i.build.clone(), vec![i.id.clone()])),
            }
        }
        if groups.is_empty() {
            return;
        }
        if !ready.is_empty() {
            ui.add_space(S3);
        }
        section(ui, "Waiting for a download", |_| {});
        let cat = self.catalogue.lock().unwrap().clone().unwrap_or_default();
        let mut open = None;
        let mut fetch = None;
        list_card(ui, |ui| {
            for (gi, (ios, build, ids)) in groups.iter().enumerate() {
                if gi > 0 {
                    hline(ui);
                }
                let dl = self.fetching.get(build).cloned();
                let fetching = dl.is_some();
                let gb = cat.iter().find(|c| &c.build == build).map(|c| c.gb);
                egui::Frame::new().inner_margin(egui::Margin { left: 16, right: 16, top: 14, bottom: 10 }).show(ui, |ui| {
                    ui.set_width(ui.available_width());
                    ui.horizontal(|ui| {
                        let (r, _) = ui.allocate_exact_size(egui::vec2(32.0, 32.0), egui::Sense::hover());
                        ui.painter().rect(r, radius(), pal().raised, egui::Stroke::new(1.0_f32, pal().border), egui::StrokeKind::Inside);
                        ui.painter().text(r.center(), egui::Align2::CENTER_CENTER, icon::CLOUD_ARROW_DOWN, ifont(16.0), pal().ink_2);
                        ui.add_space(4.0);
                        ui.vertical(|ui| {
                            ui.spacing_mut().item_spacing.y = 1.0;
                            ui.label(strong(format!("{ios} isn't installed")));
                            let need = format!("{} device{} need{} it", ids.len(), if ids.len() == 1 { "" } else { "s" }, if ids.len() == 1 { "s" } else { "" });
                            let line = if let Some(f) = &dl {
                                fetch_line(f)
                            } else if let Some(gb) = gb {
                                format!("{need} · {gb:.1} GB download")
                            } else {
                                need
                            };
                            ui.label(muted(line));
                        });
                        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                            if fetching {
                                busy(ui, "");
                                ui.ctx().request_repaint_after(Duration::from_secs(2));
                            } else if ui.add(Btn::secondary("Download").icon(icon::DOWNLOAD_SIMPLE)).on_hover_text(format!("Build {build}")).clicked() {
                                fetch = Some((build.clone(), ios.clone()));
                            }
                        });
                    });
                });
                for id in ids {
                    let Some(inst) = self.inst(id).cloned() else { continue };
                    let row = nav::row(egui::Id::new(("waiting", id)));
                    let (rect, resp) = ui.allocate_exact_size(egui::vec2(ui.available_width(), 30.0), egui::Sense::click());
                    if row.current {
                        self.cursor_device = Some(id.clone());
                        nav::mark(ui, rect.shrink2(egui::vec2(8.0, 1.0)), radius_sm());
                    }
                    if row.activate {
                        open = Some(id.clone());
                    }
                    let p = ui.painter();
                    if resp.hovered() {
                        p.rect_filled(rect.shrink2(egui::vec2(8.0, 1.0)), radius_sm(), pal().hover);
                    }
                    let x0 = rect.left() + 16.0 + 32.0 + 12.0;
                    p.text(egui::pos2(x0, rect.center().y), egui::Align2::LEFT_CENTER, icon::DEVICE_MOBILE, ifont(14.0), pal().ink_3);
                    let name = galley_trunc(ui, &inst.name, font_m(T_BODY), pal().ink, 220.0);
                    let nw = name.size().x;
                    p.galley(egui::pos2(x0 + 22.0, rect.center().y - name.size().y / 2.0), name, pal().ink);
                    if !same_name(&inst.name, &inst.model) {
                        p.text(egui::pos2(x0 + 22.0 + nw + 10.0, rect.center().y), egui::Align2::LEFT_CENTER, short_model(&inst.model), font(T_SMALL), pal().ink_3);
                    }
                    p.text(rect.right_center() - egui::vec2(20.0, 0.0), egui::Align2::RIGHT_CENTER, icon::CARET_RIGHT, ifont(13.0), if resp.hovered() { pal().ink_2 } else { pal().ink_3 });
                    if resp.on_hover_cursor(egui::CursorIcon::PointingHand).clicked() {
                        nav::select(egui::Id::new(("waiting", id)));
                        open = Some(id.clone());
                    }
                }
                ui.add_space(6.0);
            }
        });
        if let Some((b, l)) = fetch {
            self.download(&b, &l);
        }
        if let Some(id) = open {
            self.view = View::Phone(id);
        }
    }

    fn card(&mut self, ui: &mut egui::Ui, id: &str, w: f32) {
        let Some(inst) = self.inst(id).cloned() else { return };
        let st = self.status.get(id).cloned();
        let phase = st.as_ref().map(|s| s.phase).unwrap_or(Phase::Off);
        let thumbs = self.hub.thumbnails;
        let mut open = false;
        let row_id = egui::Id::new(("card", id));
        let row = nav::row(row_id);
        if row.current {
            self.cursor_device = Some(id.to_string());
        }
        if row.activate {
            open = true;
        }
        let pal = crate::theme::pal();
        let frame = egui::Frame::new().fill(if row.current { pal.focus_fill } else { pal.card }).stroke(egui::Stroke::new(1.0_f32, if row.current { pal.focus_border } else { pal.border })).corner_radius(radius());
        // the whole card opens the device; its sense is registered before the Start/Stop button inside, so the
        // button (on top) keeps its own clicks
        let resp = ui.scope_builder(egui::UiBuilder::new().id_salt(("card-ui", id)).sense(egui::Sense::click()), |ui| {
            frame.show(ui, |ui| {
            ui.set_width(w);
            ui.vertical(|ui| {
            ui.spacing_mut().item_spacing.y = 0.0;
            // the screen, in a well
            let well_h = (w * 1.12).round();
            let (well, _) = ui.allocate_exact_size(egui::vec2(w, well_h), egui::Sense::hover());
            ui.painter().rect_filled(well.shrink(1.0), egui::CornerRadius { nw: radius_inner(), ne: radius_inner(), sw: 0, se: 0 }, pal.well);
            ui.painter().hline(well.x_range(), well.bottom(), egui::Stroke::new(1.0_f32, pal.border));
            let live = matches!(phase, Phase::Running | Phase::Starting) && thumbs;
            // no state on the screen: the dot below says it once
            let placeholder = "";
            let inner = well.shrink2(egui::vec2(S4, S4));
            let mut child = ui.new_child(egui::UiBuilder::new().max_rect(inner).layout(egui::Layout::top_down(egui::Align::Center)));
            if let Some(v) = self.viewer(id) {
                // Platforms 1: centred in the well whatever its shape (a TV is wide, a phone tall)
                let (sw, sh) = (v.screen.0.max(1) as f32, v.screen.1.max(1) as f32);
                let fit = ((inner.width() - 10.0) / sw).min((inner.height() - 10.0) / sh).max(0.01);
                child.add_space(((inner.height() - (sh * fit + 10.0)) / 2.0).max(0.0));
                v.show(&mut child, inner.size(), live, placeholder, false, viewer::THUMB);
            }
            // two lines: state, name and the one action; then what it is and, running, what it takes
            egui::Frame::new().inner_margin(egui::Margin { left: 12, right: 10, top: 9, bottom: 10 }).show(ui, |ui| {
                ui.set_width(w - 22.0);
                let (label, col) = phase_look(phase, true);
                ui.spacing_mut().item_spacing.y = 2.0;
                // the name beside the one action; the details below at the card's full width
                ui.allocate_ui_with_layout(egui::vec2(w - 22.0, H_SM), egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    ui.spacing_mut().item_spacing.x = 6.0;
                    // s acts on the card under the keyboard cursor, so only that card shows it
                    let k = if row.current { "s" } else { "" };
                    match phase {
                        Phase::Off => {
                            if ui.add(Btn::secondary("Start").icon(icon::PLAY).key(k).small()).on_hover_text("Start this device").clicked() {
                                self.start(id);
                            }
                        }
                        Phase::Running | Phase::Starting => {
                            if ui.add(Btn::secondary("Stop").icon(icon::STOP).icon_color(pal.crit_ink).key(k).small()).on_hover_text("Shut this device down. Its apps and data are kept.").clicked() {
                                self.stop(id);
                            }
                        }
                        Phase::Stopping => {
                            ui.add_enabled(false, Btn::secondary("Stopping…").small());
                        }
                    }
                    ui.with_layout(egui::Layout::left_to_right(egui::Align::Center), |ui| {
                        let (r, dr) = ui.allocate_exact_size(egui::vec2(8.0, 16.0), egui::Sense::hover());
                        dot(ui.painter(), r.center(), col);
                        let up = st.as_ref().and_then(|s| s.uptime_s).map(|u| format!(" · up for {}", fmt_uptime(u))).unwrap_or_default();
                        dr.on_hover_text(format!("{label}{up}"));
                        if x86sim_core::instance::needs_restart(&inst, st.as_ref()) {
                            ui.label(egui::RichText::new(icon::ARROW_CLOCKWISE).family(icons()).size(13.0).color(pal.warn)).on_hover_text("Settings changed: restart to apply");
                        }
                        ui.add(egui::Label::new(title(&inst.name)).truncate().selectable(false));
                    });
                });
                let mut line = device_line(&inst.name, &inst.model, &inst.ios);
                match &st {
                    Some(s) if phase != Phase::Off && s.pss_mb >= 1.0 => line += &format!(" · {} · {:.0}%", fmt_mb(s.pss_mb), s.cpu_pct),
                    _ if phase != Phase::Off && phase != Phase::Running => line += &format!(" · {}", label.to_lowercase()),
                    _ => {}
                }
                ui.add(egui::Label::new(muted(line)).truncate().selectable(false));
            });
            });
            })
        });
        let card = resp.response.on_hover_cursor(egui::CursorIcon::PointingHand);
        if card.clicked() {
            open = true;
        }
        card.context_menu(|ui| {
            ui.set_width(220.0);
            ui.spacing_mut().item_spacing.y = 0.0;
            if menu_row(ui, icon::ARROW_SQUARE_OUT, "Open", "", true, false).clicked() {
                open = true;
                ui.close();
            }
            match phase {
                Phase::Off => {
                    if menu_row(ui, icon::PLAY, "Start", "", true, false).clicked() {
                        self.start(id);
                        ui.close();
                    }
                }
                Phase::Stopping => {}
                _ => {
                    if menu_row(ui, icon::ARROW_CLOCKWISE, "Restart", "", true, false).clicked() {
                        self.restart(id);
                        ui.close();
                    }
                    if menu_row(ui, icon::STOP, "Stop", "", true, false).clicked() {
                        self.stop(id);
                        ui.close();
                    }
                }
            }
            ui.add_space(2.0);
            ui.separator();
            ui.add_space(2.0);
            self.phone_menu_items(ui, &inst, phase);
        });
        if card.hovered() && !row.current {
            ui.painter().rect_stroke(card.rect, radius(), egui::Stroke::new(1.0_f32, pal.border_hover), egui::StrokeKind::Inside);
        }
        if row.current {
            // scroll the cursor's card into view after a move
            nav::mark_scroll(ui, card.rect);
        }
        if open {
            nav::select(row_id);
            self.view = View::Phone(id.to_string());
        }
    }

    pub fn add_dialog(&mut self, ctx: &egui::Context) {
        let Some(mut d) = self.add.take() else { return };
        let mut close = false;
        let mut create = false;
        if let Some(r) = d.busy.lock().unwrap().take() {
            d.working = false;
            match r {
                Ok(p) => {
                    self.refresh_instances();
                    let id = p.file_name().unwrap_or_default().to_string_lossy().into_owned();
                    self.say("Device added");
                    self.view = View::Phone(id);
                    return;
                }
                Err(e) => self.say(format!("Couldn't add it: {e}")),
            }
        }
        let modal = modal("add-phone").show(ctx, |ui| {
                ui.set_width(400.0);
                ui.spacing_mut().item_spacing.y = 4.0;
                ui.label(dialog_title("Add a device"));
                ui.label(sub("It gets its own apps, data and settings."));
                ui.add_space(S5);
                let fw = ui.available_width();
                ui.label(egui::RichText::new("Model").size(T_SMALL).family(medium()).color(pal().ink_2));
                egui::ComboBox::from_id_salt("addmodel").icon(caret).width(fw).height(360.0).selected_text(body(self.models.get(d.model).map(|m| m.0.clone()).unwrap_or_default())).show_ui(ui, |ui| {
                    for (i, m) in self.models.iter().enumerate() {
                        ui.selectable_value(&mut d.model, i, &m.0);
                    }
                });
                ui.add_space(S3);
                // Platforms 1: an Apple TV takes a tvOS runtime, an Apple Watch a watchOS one
                let mid = self.models.get(d.model).map(|m| m.1.clone()).unwrap_or_default();
                let mp = x86sim_core::sim::model_platform(&mid);
                let pname = x86sim_core::sim::platform_name(mp);
                ui.label(egui::RichText::new(format!("{pname} version")).size(T_SMALL).family(medium()).color(pal().ink_2));
                // Models 2: a runtime limited to some models (iOS 27.2 24B91016s: iPhone Duo) is picked for them and
                // greyed out for the others
                let fits = |r: &x86sim_core::host::Runtime| r.platform == mp && (r.restricted_to.is_empty() || r.restricted_to.contains(&mid));
                if d.model != d.last_model {
                    d.last_model = d.model;
                    if let Some(i) = self.runtimes.iter().position(|r| r.present && r.platform == mp && r.restricted_to.contains(&mid)) {
                        d.runtime = i;
                    } else if !self.runtimes.get(d.runtime).is_some_and(fits) {
                        d.runtime = self.runtimes.iter().rposition(|r| r.present && r.platform == mp && r.restricted_to.is_empty()).unwrap_or(usize::MAX);
                    }
                }
                let label = |r: &x86sim_core::host::Runtime| {
                    let only = if r.restricted_to.is_empty() { String::new() } else { format!(" ({}) · {} only", r.build, r.restricted_to.join(", ")) };
                    if r.present { format!("{}{only}", r.label()) } else { format!("{}{only} · not installed", r.label()) }
                };
                let have = self.runtimes.iter().any(|r| r.present && fits(r));
                if have {
                    egui::ComboBox::from_id_salt("addrt").icon(caret).width(fw).selected_text(body(self.runtimes.get(d.runtime).filter(|r| fits(r)).map(label).unwrap_or("Pick one".into()))).show_ui(ui, |ui| {
                        for (i, r) in self.runtimes.iter().enumerate().filter(|(_, r)| r.platform == mp) {
                            ui.add_enabled_ui(r.present && fits(r), |ui| {
                                ui.selectable_value(&mut d.runtime, i, label(r));
                            });
                        }
                    });
                } else {
                    // none of this platform installed: offer its default build
                    let (ver, build) = x86sim_core::sim::platform_default_build(mp);
                    let what = format!("{pname} {ver}");
                    ui.horizontal(|ui| {
                        if let Some(f) = self.fetching.get(build) {
                            busy(ui, &format!("{what}: {}", fetch_line(f)));
                        } else {
                            ui.label(muted(format!("{pname} isn't installed yet.")));
                            if ui.add(Btn::secondary(format!("Download {what}")).icon(icon::DOWNLOAD_SIMPLE)).clicked() {
                                self.download(build, &what);
                            }
                        }
                    });
                }
                ui.add_space(S3);
                ui.label(egui::RichText::new("Name").size(T_SMALL).family(medium()).color(pal().ink_2));
                let r = ui.add(egui::TextEdit::singleline(&mut d.name).hint_text(egui::RichText::new("Optional, e.g. Test device").color(pal().ink_3)).desired_width(fw).margin(egui::Margin::symmetric(8, 6)));
                if r.lost_focus() && ui.input(|i| i.key_pressed(egui::Key::Enter)) && self.runtimes.get(d.runtime).is_some_and(|r| r.present && fits(r)) && !d.working {
                    create = true;
                }
                ui.add_space(S3);
                ui.label(muted(format!("The first start takes a few minutes while {pname} sets itself up.")));
                ui.add_space(S5);
                ui.horizontal(|ui| {
                    if d.working {
                        busy(ui, "Setting it up…");
                    }
                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        let ok = self.runtimes.get(d.runtime).is_some_and(|r| r.present && fits(r)) && !d.working;
                        if ui.add_enabled(ok, Btn::primary("Add device").key("Enter").min_w(96.0)).on_disabled_hover_text(if d.working { "Setting it up…" } else { "Pick an installed version first" }).clicked() {
                            create = true;
                        }
                        if ui.add_enabled(!d.working, Btn::secondary("Cancel").key("Esc").min_w(80.0)).clicked() {
                            close = true;
                        }
                    });
                });
            });
        if modal.should_close() && !d.working {
            close = true;
        }
        if create {
            if let (Some(m), Some(r)) = (self.models.get(d.model).cloned(), self.runtimes.get(d.runtime).cloned()) {
                d.working = true;
                let busy = d.busy.clone();
                let name = d.name.clone();
                let ctx = ctx.clone();
                std::thread::spawn(move || {
                    let r = x86sim_core::sim::create_device(&m.0, &name, &r.root).map_err(|e| format!("{e:#}"));
                    *busy.lock().unwrap() = Some(r);
                    ctx.request_repaint();
                });
            }
        }
        if !close {
            self.add = Some(d);
        }
    }
}

/// "Downloading · 23%" / "Unpacking…": one line for a download in progress
pub fn fetch_line(f: &x86sim_core::host::Fetch) -> String {
    match (f.phase.as_str(), f.pct) {
        ("downloading", Some(p)) => format!("Downloading · {p:.0}%"),
        ("decrypting", _) => "Downloaded · decrypting…".into(),
        ("unpacking", _) => "Unpacking…".into(),
        _ => "Downloading…".into(),
    }
}
