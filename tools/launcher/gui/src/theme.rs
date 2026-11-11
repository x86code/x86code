//! Design system. Tokens: colour roles (a neutral ramp, one accent, status colours reserved for state and always paired
//! with a label), a type scale in Inter Regular/Medium/SemiBold, a 4 px spacing scale, radii and control heights.
//! Components: buttons, badges, cards, stat tiles, switches, segmented controls, nav items, fold headers, empty states.
//! Pages use only these, so every screen shares one look.
use eframe::egui::{self, Color32, FontFamily, FontId, Rect, RichText, Sense, Stroke};
use std::sync::Arc;

pub use egui_phosphor::regular as icon;

const fn rgb(h: u32) -> Color32 {
    Color32::from_rgb((h >> 16) as u8, (h >> 8) as u8, h as u8)
}

// ---- colour roles (dark). Contrast on CARD: INK 14.1, INK_2 6.8, INK_3 4.4, ACCENT_INK 6.6; white on ACCENT_FILL 4.7.
pub const WINDOW: Color32 = rgb(0x131416); // sidebar, inspector, top bar
pub const CANVAS: Color32 = rgb(0x18191b); // page background
pub const CARD: Color32 = rgb(0x1e1f22);
pub const RAISED: Color32 = rgb(0x26272b); // buttons, selected nav, tracks
pub const HOVER: Color32 = rgb(0x2d2e33);
pub const PRESSED: Color32 = rgb(0x35363c);
pub const WELL: Color32 = rgb(0x111214); // inputs, log, screen wells
pub const BORDER: Color32 = rgb(0x2a2b30);
pub const BORDER_STRONG: Color32 = rgb(0x393a40);
pub const INK: Color32 = rgb(0xededf0);
pub const INK_2: Color32 = rgb(0xa5a6ad);
pub const INK_3: Color32 = rgb(0x8b8c94);
pub const ACCENT: Color32 = rgb(0x3987e5);
pub const ACCENT_FILL: Color32 = rgb(0x2b70cf);
pub const ACCENT_HOVER: Color32 = rgb(0x3479d8);
pub const ACCENT_DOWN: Color32 = rgb(0x2563b8);
pub const ACCENT_INK: Color32 = rgb(0x6da7ec);
pub const GOOD: Color32 = rgb(0x22b35a);
pub const WARN: Color32 = rgb(0xfab219);
pub const CRIT: Color32 = rgb(0xd03b3b);
pub const CRIT_INK: Color32 = rgb(0xe66767);
pub const BEZEL: Color32 = rgb(0x050506);

// ---- type scale
pub const T_CAPTION: f32 = 11.0;
pub const T_SMALL: f32 = 12.0;
pub const T_BODY: f32 = 13.0;
pub const T_LG: f32 = 14.0;
pub const T_TITLE: f32 = 16.0;
pub const T_H1: f32 = 20.0;

// ---- spacing, radii, control heights
pub const S1: f32 = 4.0;
pub const S2: f32 = 8.0;
pub const S3: f32 = 12.0;
pub const S4: f32 = 16.0;
pub const S5: f32 = 24.0;
pub const S6: f32 = 32.0;
pub const R_SM: u8 = 4;
pub const R_MD: u8 = 6;
pub const R_LG: u8 = 10;
pub const H_MD: f32 = 28.0;
pub const H_SM: f32 = 24.0;

pub fn medium() -> FontFamily {
    FontFamily::Name("medium".into())
}
pub fn semibold() -> FontFamily {
    FontFamily::Name("semibold".into())
}
pub fn font(size: f32) -> FontId {
    FontId::new(size, FontFamily::Proportional)
}
pub fn font_m(size: f32) -> FontId {
    FontId::new(size, medium())
}
pub fn font_sb(size: f32) -> FontId {
    FontId::new(size, semibold())
}

// ---- text roles
pub fn h1(t: impl Into<String>) -> RichText {
    RichText::new(t).size(T_H1).family(semibold()).color(INK)
}
pub fn title(t: impl Into<String>) -> RichText {
    RichText::new(t).size(T_LG).family(semibold()).color(INK)
}
pub fn body(t: impl Into<String>) -> RichText {
    RichText::new(t).size(T_BODY).color(INK)
}
pub fn strong(t: impl Into<String>) -> RichText {
    RichText::new(t).size(T_BODY).family(medium()).color(INK)
}
pub fn sub(t: impl Into<String>) -> RichText {
    RichText::new(t).size(T_BODY).color(INK_2)
}
pub fn muted(t: impl Into<String>) -> RichText {
    RichText::new(t).size(T_SMALL).color(INK_3)
}
pub fn overline(t: &str) -> RichText {
    RichText::new(t.to_uppercase()).size(10.5).family(semibold()).color(INK_3).extra_letter_spacing(0.6)
}

pub fn theme(ctx: &egui::Context) {
    use egui::{FontData, TextStyle};
    let mut fonts = egui::FontDefinitions::default();
    let fd = |b: &'static [u8]| Arc::new(FontData::from_static(b));
    fonts.font_data.insert("inter".into(), fd(include_bytes!("../assets/fonts/Inter-Regular.ttf")));
    fonts.font_data.insert("inter-medium".into(), fd(include_bytes!("../assets/fonts/Inter-Medium.ttf")));
    fonts.font_data.insert("inter-semibold".into(), fd(include_bytes!("../assets/fonts/Inter-SemiBold.ttf")));
    fonts.font_data.insert("phosphor".into(), Arc::new(egui_phosphor::Variant::Regular.font_data()));
    let fallback = fonts.families.get(&FontFamily::Proportional).cloned().unwrap_or_default();
    for (fam, face) in [(FontFamily::Proportional, "inter"), (medium(), "inter-medium"), (semibold(), "inter-semibold")] {
        let mut v = vec![face.to_string(), "phosphor".to_string()];
        v.extend(fallback.iter().cloned());
        fonts.families.insert(fam, v);
    }
    fonts.families.entry(FontFamily::Monospace).or_default().push("phosphor".into());
    ctx.set_fonts(fonts);

    ctx.set_theme(egui::Theme::Dark);
    ctx.style_mut(|s| {
        s.text_styles = [
            (TextStyle::Heading, font_sb(T_H1)),
            (TextStyle::Body, font(T_BODY)),
            (TextStyle::Button, font_m(T_BODY)),
            (TextStyle::Small, font(T_CAPTION)),
            (TextStyle::Monospace, FontId::new(11.5, FontFamily::Monospace)),
        ]
        .into();
        s.spacing.item_spacing = egui::vec2(S2, S2);
        s.spacing.button_padding = egui::vec2(10.0, 4.0);
        s.spacing.interact_size = egui::vec2(24.0, H_MD);
        s.spacing.combo_height = 320.0;
        s.spacing.slider_width = 180.0;
        s.spacing.menu_margin = egui::Margin::same(6);
        s.spacing.window_margin = egui::Margin::same(16);
        s.spacing.scroll = egui::style::ScrollStyle { bar_width: 6.0, floating_allocated_width: 0.0, ..egui::style::ScrollStyle::floating() };
        s.interaction.tooltip_delay = 0.35;
        let v = &mut s.visuals;
        v.panel_fill = CANVAS;
        v.window_fill = CARD;
        v.extreme_bg_color = WELL;
        v.faint_bg_color = rgb(0x1b1c1f);
        v.code_bg_color = WELL;
        v.override_text_color = None;
        v.hyperlink_color = ACCENT_INK;
        v.weak_text_color = Some(INK_3);
        v.selection.bg_fill = ACCENT.gamma_multiply(0.35);
        v.selection.stroke = Stroke::new(1.0_f32, ACCENT);
        v.window_corner_radius = R_LG.into();
        v.menu_corner_radius = 8.into();
        v.window_stroke = Stroke::new(1.0_f32, BORDER_STRONG);
        v.window_shadow = egui::Shadow { offset: [0, 8], blur: 28, spread: 0, color: Color32::from_black_alpha(110) };
        v.popup_shadow = egui::Shadow { offset: [0, 4], blur: 16, spread: 0, color: Color32::from_black_alpha(90) };
        v.slider_trailing_fill = true;
        v.handle_shape = egui::style::HandleShape::Circle;
        v.striped = false;
        v.text_cursor.stroke = Stroke::new(1.5_f32, ACCENT_INK);
        let r: egui::CornerRadius = R_MD.into();
        for w in [&mut v.widgets.noninteractive, &mut v.widgets.inactive, &mut v.widgets.hovered, &mut v.widgets.active, &mut v.widgets.open] {
            w.corner_radius = r;
            w.expansion = 0.0;
        }
        v.widgets.noninteractive.bg_fill = CARD;
        v.widgets.noninteractive.weak_bg_fill = CARD;
        v.widgets.noninteractive.bg_stroke = Stroke::new(1.0_f32, BORDER);
        v.widgets.noninteractive.fg_stroke = Stroke::new(1.0_f32, INK_2);
        v.widgets.inactive.bg_fill = RAISED;
        v.widgets.inactive.weak_bg_fill = RAISED;
        v.widgets.inactive.bg_stroke = Stroke::new(1.0_f32, BORDER_STRONG);
        v.widgets.inactive.fg_stroke = Stroke::new(1.0_f32, INK);
        v.widgets.hovered.bg_fill = HOVER;
        v.widgets.hovered.weak_bg_fill = HOVER;
        v.widgets.hovered.bg_stroke = Stroke::new(1.0_f32, rgb(0x46474e));
        v.widgets.hovered.fg_stroke = Stroke::new(1.0_f32, INK);
        v.widgets.active.bg_fill = PRESSED;
        v.widgets.active.weak_bg_fill = PRESSED;
        v.widgets.active.bg_stroke = Stroke::new(1.0_f32, ACCENT);
        v.widgets.active.fg_stroke = Stroke::new(1.0_f32, INK);
        v.widgets.open.bg_fill = PRESSED;
        v.widgets.open.weak_bg_fill = PRESSED;
        v.widgets.open.bg_stroke = Stroke::new(1.0_f32, BORDER_STRONG);
        v.widgets.open.fg_stroke = Stroke::new(1.0_f32, INK);
    });
}

// ---------------------------------------------------------------- buttons

#[derive(Clone, Copy, PartialEq)]
pub enum Kind {
    Danger,
    Primary,
    Secondary,
    Ghost,
}

/// The one button: consistent height per size, icon + label, hover/pressed/disabled/focus states.
pub struct Btn {
    kind: Kind,
    icon: Option<&'static str>,
    icon_col: Option<Color32>,
    text: String,
    h: f32,
    min_w: f32,
}

impl Btn {
    fn new(kind: Kind, text: impl Into<String>) -> Btn {
        Btn { kind, icon: None, icon_col: None, text: text.into(), h: H_MD, min_w: 0.0 }
    }
    pub fn primary(text: impl Into<String>) -> Btn {
        Btn::new(Kind::Primary, text)
    }
    pub fn secondary(text: impl Into<String>) -> Btn {
        Btn::new(Kind::Secondary, text)
    }
    /// Destructive confirm (remove, delete): red fill.
    pub fn danger(text: impl Into<String>) -> Btn {
        Btn::new(Kind::Danger, text)
    }
    pub fn ghost(text: impl Into<String>) -> Btn {
        Btn::new(Kind::Ghost, text)
    }
    /// Icon-only ghost button (square).
    pub fn tool(icon: &'static str) -> Btn {
        Btn::new(Kind::Ghost, "").icon(icon)
    }
    pub fn icon(mut self, i: &'static str) -> Btn {
        self.icon = Some(i);
        self
    }
    pub fn icon_color(mut self, c: Color32) -> Btn {
        self.icon_col = Some(c);
        self
    }
    pub fn small(mut self) -> Btn {
        self.h = H_SM;
        self
    }
    pub fn min_w(mut self, w: f32) -> Btn {
        self.min_w = w;
        self
    }
}

impl egui::Widget for Btn {
    fn ui(self, ui: &mut egui::Ui) -> egui::Response {
        let small = self.h < H_MD;
        let ts = if small { T_SMALL } else { T_BODY };
        let is = if small { 14.0 } else { 15.0 };
        let enabled = ui.is_enabled();
        let p = ui.painter().clone();
        let tg = (!self.text.is_empty()).then(|| p.layout_no_wrap(self.text.clone(), font_m(ts), INK));
        let ig = self.icon.map(|i| p.layout_no_wrap(i.to_string(), font(is), INK));
        let pad = if tg.is_none() { 0.0 } else if small { 8.0 } else { 12.0 };
        let gap = if tg.is_some() && ig.is_some() { 6.0 } else { 0.0 };
        let content = tg.as_ref().map(|g| g.size().x).unwrap_or(0.0) + ig.as_ref().map(|g| g.size().x).unwrap_or(0.0) + gap;
        let w = if tg.is_none() { self.h } else { (content + 2.0 * pad).max(self.min_w) };
        let (rect, resp) = ui.allocate_exact_size(egui::vec2(w, self.h), Sense::click());
        if ui.is_rect_visible(rect) {
            let hov = resp.hovered() && enabled;
            let down = resp.is_pointer_button_down_on() && enabled;
            let (bg, stroke, fg, icol) = match self.kind {
                Kind::Primary if enabled => (if down { ACCENT_DOWN } else if hov { ACCENT_HOVER } else { ACCENT_FILL }, Stroke::NONE, Color32::WHITE, Color32::WHITE),
                Kind::Danger if enabled => (if down { rgb(0xa82f2f) } else if hov { rgb(0xc03636) } else { CRIT }, Stroke::NONE, Color32::WHITE, Color32::WHITE),
                Kind::Primary | Kind::Secondary | Kind::Danger => {
                    let bg = if !enabled { RAISED.gamma_multiply(0.6) } else if down { PRESSED } else if hov { HOVER } else { RAISED };
                    let st = Stroke::new(1.0_f32, if hov { rgb(0x46474e) } else { BORDER_STRONG });
                    let fg = if enabled { INK } else { INK_3 };
                    (bg, if enabled { st } else { Stroke::new(1.0_f32, BORDER) }, fg, if enabled { INK_2 } else { INK_3 })
                }
                Kind::Ghost => {
                    let bg = if down { PRESSED } else if hov { RAISED } else { Color32::TRANSPARENT };
                    let fg = if !enabled { INK_3.gamma_multiply(0.7) } else if hov { INK } else { INK_2 };
                    (bg, Stroke::NONE, fg, fg)
                }
            };
            let icol = if enabled { self.icon_col.unwrap_or(icol) } else { icol };
            p.rect(rect, R_MD, bg, stroke, egui::StrokeKind::Inside);
            if resp.has_focus() {
                p.rect_stroke(rect.expand(1.0), R_MD + 1, Stroke::new(1.5_f32, ACCENT), egui::StrokeKind::Outside);
            }
            let mut x = rect.center().x - content / 2.0;
            if let Some(g) = ig {
                let y = rect.center().y - g.size().y / 2.0;
                let gw = g.size().x;
                p.galley_with_override_text_color(egui::pos2(x, y), g, icol);
                x += gw + gap;
            }
            if let Some(g) = tg {
                let y = rect.center().y - g.size().y / 2.0;
                p.galley_with_override_text_color(egui::pos2(x, y), g, fg);
            }
        }
        if enabled {
            resp.on_hover_cursor(egui::CursorIcon::PointingHand)
        } else {
            resp
        }
    }
}

// ---------------------------------------------------------------- surfaces

pub fn card_frame() -> egui::Frame {
    egui::Frame::new().fill(CARD).stroke(Stroke::new(1.0_f32, BORDER)).corner_radius(R_LG).inner_margin(S4 as i8)
}

pub fn card<R>(ui: &mut egui::Ui, add: impl FnOnce(&mut egui::Ui) -> R) -> R {
    card_frame()
        .show(ui, |ui| {
            ui.set_width(ui.available_width());
            add(ui)
        })
        .inner
}

/// A card whose rows run edge to edge (lists): no inner margin, rows draw their own padding and dividers.
pub fn list_card<R>(ui: &mut egui::Ui, add: impl FnOnce(&mut egui::Ui) -> R) -> R {
    egui::Frame::new()
        .fill(CARD)
        .stroke(Stroke::new(1.0_f32, BORDER))
        .corner_radius(R_LG)
        .show(ui, |ui| {
            ui.set_width(ui.available_width());
            ui.spacing_mut().item_spacing.y = 0.0;
            add(ui)
        })
        .inner
}

/// Page title row: title + optional subtitle on the left, actions on the right.
pub fn page_header(ui: &mut egui::Ui, title: &str, sub_text: &str, actions: impl FnOnce(&mut egui::Ui)) {
    ui.horizontal(|ui| {
        ui.vertical(|ui| {
            ui.spacing_mut().item_spacing.y = 2.0;
            ui.label(h1(title));
            if !sub_text.is_empty() {
                ui.label(sub(sub_text));
            }
        });
        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), actions);
    });
    ui.add_space(S5);
}

/// Section heading inside a page (14 semibold) with optional trailing actions.
pub fn section(ui: &mut egui::Ui, text: &str, actions: impl FnOnce(&mut egui::Ui)) {
    ui.horizontal(|ui| {
        ui.set_min_height(H_MD);
        ui.label(title(text));
        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), actions);
    });
    ui.add_space(S2);
}

/// Status: coloured dot + neutral label on a quiet pill. The colour never carries meaning alone.
pub fn badge(ui: &mut egui::Ui, text: &str, col: Color32) -> egui::Response {
    let g = ui.painter().layout_no_wrap(text.to_string(), font_m(T_SMALL), INK_2);
    let size = egui::vec2(g.size().x + 8.0 + 6.0 + 16.0, 22.0);
    let (rect, resp) = ui.allocate_exact_size(size, Sense::hover());
    let p = ui.painter();
    p.rect_filled(rect, 11.0, RAISED);
    let c = egui::pos2(rect.left() + 11.0, rect.center().y);
    if col == INK_3 {
        p.circle_stroke(c, 3.0, Stroke::new(1.3_f32, INK_3));
    } else {
        p.circle_filled(c, 3.5, col);
    }
    p.galley(egui::pos2(rect.left() + 20.0, rect.center().y - g.size().y / 2.0), g, INK_2);
    resp
}

/// Bare dot + label (for dense rows).
pub fn dot_label(ui: &mut egui::Ui, text: &str, col: Color32) {
    ui.horizontal(|ui| {
        ui.spacing_mut().item_spacing.x = 6.0;
        let (r, _) = ui.allocate_exact_size(egui::vec2(8.0, 14.0), Sense::hover());
        if col == INK_3 {
            ui.painter().circle_stroke(r.center(), 3.0, Stroke::new(1.3_f32, INK_3));
        } else {
            ui.painter().circle_filled(r.center(), 3.5, col);
        }
        ui.label(RichText::new(text).size(T_SMALL).color(INK_2));
    });
}

/// Stat tile: label, value (semibold, ink), optional note. Equal widths in a row.
pub fn stat(ui: &mut egui::Ui, w: f32, label: &str, value: &str, note: &str, fill: Color32) {
    egui::Frame::new().fill(fill).stroke(Stroke::new(1.0_f32, BORDER)).corner_radius(8).inner_margin(egui::Margin::symmetric(12, 10)).show(ui, |ui| {
        ui.set_width(w - 24.0 - 2.0); // margins + the 1 px stroke on each side
        ui.vertical(|ui| {
            ui.spacing_mut().item_spacing.y = 2.0;
            ui.label(muted(label));
            ui.horizontal(|ui| {
                ui.spacing_mut().item_spacing.x = 6.0;
                ui.label(RichText::new(value).size(18.0).family(semibold()).color(INK));
                if !note.is_empty() {
                    ui.label(muted(note));
                }
            });
        });
    });
}

pub fn stat_row(ui: &mut egui::Ui, fill: Color32, items: &[(&str, String, &str)]) {
    let gap = S2;
    let n = items.len().max(1) as f32;
    let w = ((ui.available_width() - gap * (n - 1.0)) / n).floor();
    ui.horizontal(|ui| {
        ui.spacing_mut().item_spacing.x = gap;
        for (l, v, note) in items {
            stat(ui, w, l, v, note, fill);
        }
    });
}

/// Label / value rows with a fixed label column.
pub fn kv(ui: &mut egui::Ui, label_w: f32, label: &str, add: impl FnOnce(&mut egui::Ui)) {
    ui.horizontal(|ui| {
        ui.set_min_height(22.0);
        let (r, _) = ui.allocate_exact_size(egui::vec2(label_w, 18.0), Sense::hover());
        ui.painter().text(r.left_center(), egui::Align2::LEFT_CENTER, label, font(T_SMALL), INK_3);
        add(ui);
    });
}

pub fn kv_text(ui: &mut egui::Ui, label_w: f32, label: &str, value: impl Into<String>) {
    let v = value.into();
    kv(ui, label_w, label, |ui| {
        ui.add(egui::Label::new(RichText::new(v).size(T_SMALL).color(INK)).truncate());
    });
}

/// Settings-style row: title + description on the left, control on the right, hairline below unless last.
pub fn form_row(ui: &mut egui::Ui, label: &str, desc: &str, last: bool, control: impl FnOnce(&mut egui::Ui)) {
    egui::Frame::new().inner_margin(egui::Margin::symmetric(16, 12)).show(ui, |ui| {
        ui.set_width(ui.available_width());
        ui.horizontal(|ui| {
            ui.set_min_height(H_MD);
            ui.vertical(|ui| {
                ui.spacing_mut().item_spacing.y = 2.0;
                ui.label(strong(label));
                if !desc.is_empty() {
                    ui.label(muted(desc));
                }
            });
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), control);
        });
    });
    if !last {
        hline_inset(ui, 16.0);
    }
}

/// Empty state: icon, title, text, then whatever actions the caller adds.
pub fn empty_state(ui: &mut egui::Ui, ic: &str, title_text: &str, text: &str, actions: impl FnOnce(&mut egui::Ui)) {
    ui.vertical_centered(|ui| {
        ui.add_space(S2);
        let (r, _) = ui.allocate_exact_size(egui::vec2(44.0, 44.0), Sense::hover());
        ui.painter().circle_filled(r.center(), 22.0, RAISED);
        ui.painter().text(r.center(), egui::Align2::CENTER_CENTER, ic, font(22.0), INK_2);
        ui.add_space(S2);
        ui.label(title(title_text));
        if !text.is_empty() {
            ui.label(sub(text));
        }
        ui.add_space(S3);
        actions(ui);
        ui.add_space(S2);
    });
}

// ---------------------------------------------------------------- controls

/// Switch. Accent when on.
pub fn toggle(ui: &mut egui::Ui, on: &mut bool) -> egui::Response {
    let size = egui::vec2(34.0, 20.0);
    let (rect, mut resp) = ui.allocate_exact_size(size, Sense::click());
    if resp.clicked() {
        *on = !*on;
        resp.mark_changed();
    }
    let t = ui.ctx().animate_bool_responsive(resp.id, *on);
    let enabled = ui.is_enabled();
    let off = if resp.hovered() { rgb(0x46474e) } else { rgb(0x3a3b41) };
    let mut bg = off.lerp_to_gamma(ACCENT_FILL, t);
    if !enabled {
        bg = bg.gamma_multiply(0.5);
    }
    let p = ui.painter();
    p.rect_filled(rect, 10.0, bg);
    let x = egui::lerp((rect.left() + 10.0)..=(rect.right() - 10.0), t);
    p.circle_filled(egui::pos2(x, rect.center().y), 8.0, if enabled { Color32::WHITE } else { INK_3 });
    if enabled {
        resp.on_hover_cursor(egui::CursorIcon::PointingHand)
    } else {
        resp
    }
}

/// Segmented control; returns the clicked index.
pub fn segmented(ui: &mut egui::Ui, items: &[&str], sel: Option<usize>, enabled: bool) -> Option<usize> {
    let mut out = None;
    let p = ui.painter().clone();
    let gs: Vec<_> = items.iter().map(|l| p.layout_no_wrap(l.to_string(), font_m(T_SMALL), INK)).collect();
    let pad = 10.0;
    let w: f32 = gs.iter().map(|g| g.size().x + 2.0 * pad).sum::<f32>() + 4.0;
    let (rect, _) = ui.allocate_exact_size(egui::vec2(w, H_MD), Sense::hover());
    p.rect(rect, R_MD, WELL, Stroke::new(1.0_f32, BORDER), egui::StrokeKind::Inside);
    let mut x = rect.left() + 2.0;
    for (i, g) in gs.into_iter().enumerate() {
        let iw = g.size().x + 2.0 * pad;
        let r = Rect::from_min_size(egui::pos2(x, rect.top() + 2.0), egui::vec2(iw, H_MD - 4.0));
        let resp = ui.interact(r, ui.id().with(("seg", items[i], i)), if enabled { Sense::click() } else { Sense::hover() });
        let on = sel == Some(i);
        if on {
            p.rect(r, R_SM, if enabled { HOVER } else { RAISED }, Stroke::new(1.0_f32, rgb(0x404148)), egui::StrokeKind::Inside);
        } else if resp.hovered() && enabled {
            p.rect_filled(r, R_SM, RAISED);
        }
        let col = if !enabled { INK_3 } else if on || resp.hovered() { INK } else { INK_2 };
        p.galley_with_override_text_color(egui::pos2(r.center().x - g.size().x / 2.0, r.center().y - g.size().y / 2.0), g, col);
        if enabled && resp.on_hover_cursor(egui::CursorIcon::PointingHand).clicked() {
            out = Some(i);
        }
        x += iw;
    }
    out
}

pub fn nav_item(ui: &mut egui::Ui, ic: &str, label: &str, on: bool, trailing: &str, shortcut: &str) -> bool {
    let w = ui.available_width();
    let (rect, resp) = ui.allocate_exact_size(egui::vec2(w, 30.0), Sense::click());
    let p = ui.painter();
    if on {
        p.rect_filled(rect, R_MD, RAISED);
    } else if resp.hovered() {
        p.rect_filled(rect, R_MD, rgb(0x1c1d20));
    }
    let col = if on || resp.hovered() { INK } else { INK_2 };
    p.text(rect.left_center() + egui::vec2(10.0, 0.0), egui::Align2::LEFT_CENTER, ic, font(16.0), if on { INK } else { INK_3 });
    p.text(rect.left_center() + egui::vec2(34.0, 0.0), egui::Align2::LEFT_CENTER, label, font_m(T_BODY), col);
    if !trailing.is_empty() {
        p.text(rect.right_center() - egui::vec2(10.0, 0.0), egui::Align2::RIGHT_CENTER, trailing, font(T_SMALL), INK_3);
    }
    let resp = resp.on_hover_cursor(egui::CursorIcon::PointingHand);
    let resp = if shortcut.is_empty() { resp } else { resp.on_hover_text(shortcut) };
    resp.clicked()
}

/// Fold-out section header: chevron, title, summary at the right. Returns the new open state.
pub fn fold(ui: &mut egui::Ui, title_text: &str, summary: &str, open: bool) -> bool {
    let w = ui.available_width();
    let (rect, resp) = ui.allocate_exact_size(egui::vec2(w, 40.0), Sense::click());
    let p = ui.painter();
    if resp.hovered() {
        p.rect_filled(rect.shrink2(egui::vec2(0.0, 4.0)), R_MD, rgb(0x1c1d20));
    }
    let chev = if open { icon::CARET_DOWN } else { icon::CARET_RIGHT };
    p.text(rect.left_center() + egui::vec2(8.0, 0.0), egui::Align2::LEFT_CENTER, chev, font(12.0), INK_3);
    p.text(rect.left_center() + egui::vec2(26.0, 0.0), egui::Align2::LEFT_CENTER, title_text, font_sb(T_BODY), INK);
    if !summary.is_empty() {
        p.text(rect.right_center() - egui::vec2(8.0, 0.0), egui::Align2::RIGHT_CENTER, summary, font(T_SMALL), INK_3);
    }
    if resp.on_hover_cursor(egui::CursorIcon::PointingHand).clicked() {
        !open
    } else {
        open
    }
}

pub fn hline(ui: &mut egui::Ui) {
    hline_inset(ui, 0.0);
}

pub fn hline_inset(ui: &mut egui::Ui, inset: f32) {
    let (r, _) = ui.allocate_exact_size(egui::vec2(ui.available_width(), 1.0), Sense::hover());
    ui.painter().hline((r.left() + inset)..=(r.right() - inset), r.center().y, Stroke::new(1.0_f32, BORDER));
}

/// Caret for combo boxes (instead of egui's filled triangle).
pub fn caret(ui: &egui::Ui, rect: Rect, _v: &egui::style::WidgetVisuals, open: bool) {
    let ic = if open { icon::CARET_UP } else { icon::CARET_DOWN };
    ui.painter().text(rect.center(), egui::Align2::CENTER_CENTER, ic, font(12.0), INK_3);
}

/// Single-line text, truncated with an ellipsis to `max_w`.
pub fn galley_trunc(ui: &egui::Ui, text: &str, f: FontId, col: Color32, max_w: f32) -> Arc<egui::Galley> {
    let mut job = egui::text::LayoutJob::simple_singleline(text.to_string(), f, col);
    job.wrap = egui::text::TextWrapping::truncate_at_width(max_w.max(1.0));
    ui.painter().layout_job(job)
}

/// A search field with a leading magnifier.
pub fn search(ui: &mut egui::Ui, text: &mut String, hint: &str, w: f32) -> egui::Response {
    let r = ui.add(egui::TextEdit::singleline(text).hint_text(RichText::new(hint).color(INK_3)).desired_width(w - 34.0 - 2.0).margin(egui::Margin { left: 26, right: 8, top: 6, bottom: 6 }).vertical_align(egui::Align::Center));
    ui.painter().text(r.rect.left_center() + egui::vec2(9.0, 0.0), egui::Align2::LEFT_CENTER, icon::MAGNIFYING_GLASS, font(13.0), INK_3);
    r
}


pub fn fmt_s(s: f64) -> String {
    if s >= 3600.0 {
        format!("{}h {:02}m", (s / 3600.0) as u64, (s as u64 % 3600) / 60)
    } else if s >= 60.0 {
        format!("{}m {:02}s", (s / 60.0) as u64, s as u64 % 60)
    } else {
        format!("{s:.0}s")
    }
}

/// Uptime at minute resolution ("<1 min", "12 min", "2 h 05 min"): it changes once a minute, so the hub
/// doesn't repaint every second to show it.
pub fn fmt_uptime(s: f64) -> String {
    let m = (s / 60.0) as u64;
    match m {
        0 => "<1 min".into(),
        1..=59 => format!("{m} min"),
        _ => format!("{} h {:02} min", m / 60, m % 60),
    }
}

pub fn fmt_mb(mb: f64) -> String {
    if mb >= 1000.0 {
        format!("{:.1} GB", mb / 1024.0)
    } else {
        format!("{mb:.0} MB")
    }
}

/// Label and colour of a phone's state.
pub fn phase_look(phase: x86sim_core::instance::Phase, runtime_present: bool) -> (&'static str, Color32) {
    use x86sim_core::instance::Phase;
    match phase {
        Phase::Running => ("Running", GOOD),
        Phase::Starting => ("Starting", WARN),
        Phase::Stopping => ("Stopping", WARN),
        Phase::Off if !runtime_present => ("Version not installed", WARN),
        Phase::Off => ("Off", INK_3),
    }
}

/// The frame of every modal dialog.
pub fn modal_frame() -> egui::Frame {
    egui::Frame::new()
        .fill(CARD)
        .stroke(Stroke::new(1.0_f32, BORDER_STRONG))
        .corner_radius(12)
        .inner_margin(24)
        .shadow(egui::Shadow { offset: [0, 12], blur: 40, spread: 0, color: Color32::from_black_alpha(140) })
}

/// A menu row: icon, label, optional shortcut hint on the right. Returns true when clicked.
pub fn menu_row(ui: &mut egui::Ui, ic: &str, label: &str, hint: &str, enabled: bool, danger: bool) -> egui::Response {
    let w = ui.available_width().max(200.0);
    let (r, resp) = ui.allocate_exact_size(egui::vec2(w, 30.0), if enabled { Sense::click() } else { Sense::hover() });
    let p = ui.painter();
    if enabled && resp.hovered() {
        p.rect_filled(r, R_SM, RAISED);
    }
    let col = if !enabled { INK_3 } else if danger { CRIT_INK } else { INK };
    p.text(r.left_center() + egui::vec2(10.0, 0.0), egui::Align2::LEFT_CENTER, ic, font(14.0), if enabled && !danger { INK_2 } else { col });
    p.text(r.left_center() + egui::vec2(32.0, 0.0), egui::Align2::LEFT_CENTER, label, font(T_BODY), col);
    if !hint.is_empty() {
        p.text(r.right_center() - egui::vec2(10.0, 0.0), egui::Align2::RIGHT_CENTER, hint, font(T_SMALL), INK_3);
    }
    if enabled {
        resp.on_hover_cursor(egui::CursorIcon::PointingHand)
    } else {
        resp
    }
}
