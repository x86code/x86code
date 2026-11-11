//! Platforms 1: painted hardware controls for the tool bar right of the screen. An Apple TV gets a Siri Remote (the
//! clickpad: four directions and select, held keys repeat as a remote's do; Back, TV, play / pause, mute, the volume
//! rocker); an Apple Watch gets its Digital Crown (drag or scroll on it to turn, click to press) and the side button.
use crate::theme::*;
use eframe::egui::{self, Align2, Color32, CornerRadius, FontId, Pos2, Rect, Sense, Stroke, StrokeKind, Vec2};

const BODY: Color32 = Color32::from_rgb(0x24, 0x25, 0x29); // the remote's aluminium, dark
const KEY: Color32 = Color32::from_rgb(0x16, 0x17, 0x1a); // its black buttons
const KEY_HOVER: Color32 = Color32::from_rgb(0x2a, 0x2b, 0x30);
const KEY_DOWN: Color32 = Color32::from_rgb(0x36, 0x37, 0x3d);
const RIM: Color32 = Color32::from_rgb(0x3a, 0x3b, 0x41);

/// A clickpad zone: the keyboard usage tvOS reads for it (arrows, return)
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Pad {
    Up,
    Down,
    Left,
    Right,
    Select,
}

impl Pad {
    pub fn usage(self) -> u32 {
        match self {
            Pad::Up => 0x52,
            Pad::Down => 0x51,
            Pad::Left => 0x50,
            Pad::Right => 0x4f,
            Pad::Select => 0x28,
        }
    }
    fn at(c: Pos2, r: f32, p: Pos2) -> Option<Pad> {
        let d = p - c;
        if d.length() > r {
            None
        } else if d.length() < r * 0.4 {
            Some(Pad::Select)
        } else if d.x.abs() > d.y.abs() {
            Some(if d.x > 0.0 { Pad::Right } else { Pad::Left })
        } else {
            Some(if d.y > 0.0 { Pad::Down } else { Pad::Up })
        }
    }
}

/// Key events of one frame: (usage, down)
pub type KeyEvents = Vec<(u32, bool)>;

/// The clickpad, `d` points across. A press sends its zone's key down and the release sends it up, so a held arrow
/// repeats on the TV; the wheel over it moves the focus a step a notch.
pub fn clickpad(ui: &mut egui::Ui, d: f32, live: bool) -> KeyEvents {
    let (rect, resp) = ui.allocate_exact_size(Vec2::splat(d), if live { Sense::click_and_drag() } else { Sense::hover() });
    let (c, r) = (rect.center(), d / 2.0);
    let held_id = resp.id.with("held");
    let mut held: Option<Pad> = ui.data(|m| m.get_temp(held_id)).flatten();
    let mut ev = KeyEvents::new();
    let hover = resp.hover_pos().and_then(|p| Pad::at(c, r, p));
    if live && resp.is_pointer_button_down_on() {
        if held.is_none() {
            held = resp.interact_pointer_pos().and_then(|p| Pad::at(c, r, p));
            if let Some(z) = held {
                ev.push((z.usage(), true));
            }
        }
    } else if let Some(z) = held.take() {
        ev.push((z.usage(), false));
    }
    ui.data_mut(|m| m.insert_temp(held_id, held));
    if live && resp.hovered() {
        let w = ui.ctx().input(|i| i.raw_scroll_delta);
        let acc_id = resp.id.with("wheel");
        let mut acc: Vec2 = ui.data(|m| m.get_temp(acc_id)).unwrap_or_default();
        acc += w;
        const NOTCH: f32 = 40.0;
        while acc.y.abs() >= NOTCH || acc.x.abs() >= NOTCH {
            let u = if acc.y <= -NOTCH { acc.y += NOTCH; Pad::Down } else if acc.y >= NOTCH { acc.y -= NOTCH; Pad::Up }
                else if acc.x <= -NOTCH { acc.x += NOTCH; Pad::Right } else { acc.x -= NOTCH; Pad::Left };
            ev.push((u.usage(), true));
            ev.push((u.usage(), false));
        }
        ui.data_mut(|m| m.insert_temp(acc_id, acc));
    }

    let p = ui.painter();
    p.circle_filled(c, r, KEY);
    p.circle_stroke(c, r - 0.5, Stroke::new(1.0_f32, RIM));
    let lit = held.or(hover.filter(|_| live));
    // the ring's four directions: a dot each, as on the remote; the one under the pointer brightens
    for (z, off) in [(Pad::Up, Vec2::new(0.0, -1.0)), (Pad::Down, Vec2::new(0.0, 1.0)), (Pad::Left, Vec2::new(-1.0, 0.0)), (Pad::Right, Vec2::new(1.0, 0.0))] {
        let on = lit == Some(z);
        let pos = c + off * r * 0.72;
        if on {
            p.circle_filled(pos, r * 0.2, if held == Some(z) { KEY_DOWN } else { KEY_HOVER });
        }
        p.circle_filled(pos, if on { 3.0 } else { 2.0 }, if on { INK } else { INK_3 });
    }
    // the centre (select): the touch surface's click
    let sel = lit == Some(Pad::Select);
    p.circle_filled(c, r * 0.4, if held == Some(Pad::Select) { KEY_DOWN } else if sel { KEY_HOVER } else { KEY });
    p.circle_stroke(c, r * 0.4, Stroke::new(1.0_f32, if sel { BORDER_STRONG } else { BORDER }));
    let tip = match hover {
        Some(Pad::Select) => "Select (Return, or a click on the screen)",
        Some(_) => "Move the focus (arrow keys; hold to repeat)",
        None => "Clickpad: a direction or the centre; the wheel over it moves the focus",
    };
    if live {
        resp.on_hover_text(tip);
    } else {
        resp.on_hover_text("Not running");
    }
    ev
}

/// A round remote button at `rect` (a glyph on black, like the Siri Remote's)
pub fn round_button(ui: &mut egui::Ui, rect: Rect, id: egui::Id, glyph: &str, tip: &str, live: bool) -> bool {
    let resp = ui.interact(rect, id, if live { Sense::click() } else { Sense::hover() });
    let fill = if !live { KEY } else if resp.is_pointer_button_down_on() { KEY_DOWN } else if resp.hovered() { KEY_HOVER } else { KEY };
    let p = ui.painter();
    p.circle_filled(rect.center(), rect.width() / 2.0, fill);
    p.circle_stroke(rect.center(), rect.width() / 2.0 - 0.5, Stroke::new(1.0_f32, RIM));
    p.text(rect.center(), Align2::CENTER_CENTER, glyph, FontId::proportional(17.0), if live { INK } else { INK_3 });
    let clicked = resp.clicked();
    resp.on_hover_text(if live { tip } else { "Not running" });
    clicked
}

/// The volume rocker: a pill with + above and − below; Some(true) for up
pub fn rocker(ui: &mut egui::Ui, rect: Rect, id: egui::Id, live: bool) -> Option<bool> {
    let half = |top: bool| if top { Rect::from_min_max(rect.min, Pos2::new(rect.max.x, rect.center().y)) } else { Rect::from_min_max(Pos2::new(rect.min.x, rect.center().y), rect.max) };
    let cr = CornerRadius::same((rect.width() / 2.0) as u8);
    ui.painter().rect_filled(rect, cr, KEY);
    let mut out = None;
    for top in [true, false] {
        let r = half(top);
        let resp = ui.interact(r, id.with(top), if live { Sense::click() } else { Sense::hover() });
        if live && (resp.hovered() || resp.is_pointer_button_down_on()) {
            let shade = if resp.is_pointer_button_down_on() { KEY_DOWN } else { KEY_HOVER };
            let cr = if top { CornerRadius { nw: cr.nw, ne: cr.ne, sw: 0, se: 0 } } else { CornerRadius { nw: 0, ne: 0, sw: cr.sw, se: cr.se } };
            ui.painter().rect_filled(r, cr, shade);
        }
        ui.painter().text(r.center(), Align2::CENTER_CENTER, if top { "+" } else { "−" }, FontId::proportional(18.0), if live { INK } else { INK_3 });
        if resp.clicked() {
            out = Some(top);
        }
        resp.on_hover_text(if !live { "Not running" } else if top { "Volume up (F3)" } else { "Volume down (F4)" });
    }
    ui.painter().rect_stroke(rect, cr, Stroke::new(1.0_f32, RIM), StrokeKind::Inside);
    out
}

/// The remote's body: a rounded aluminium slab around its controls
pub fn body<R>(ui: &mut egui::Ui, add: impl FnOnce(&mut egui::Ui) -> R) -> R {
    egui::Frame::new().fill(BODY).stroke(Stroke::new(1.0_f32, RIM)).corner_radius(22).inner_margin(egui::Margin::symmetric(10, 14)).show(ui, add).inner
}

pub enum CrownEvent {
    Turn(f32),
    Press,
}

/// The Digital Crown at `rect` (seen from the front: a knurled cylinder standing off the case's right edge, its ribs
/// rolling as it turns). Dragging it up or down or the wheel over it turns it (positive: content towards the bottom,
/// as host/simhid "crown"); a click without a drag presses it.
pub fn crown(ui: &mut egui::Ui, rect: Rect, id: egui::Id, live: bool) -> Option<CrownEvent> {
    let resp = ui.interact(rect, id, if live { Sense::click_and_drag() } else { Sense::hover() });
    let phase_id = id.with("phase");
    let mut phase: f32 = ui.data(|m| m.get_temp(phase_id)).unwrap_or(0.0);
    let mut ev = None;
    if live {
        let dy = resp.drag_delta().y;
        if dy != 0.0 {
            phase += dy;
            ev = Some(CrownEvent::Turn(dy * 3.0));
        }
        if resp.hovered() {
            let w = ui.ctx().input(|i| i.raw_scroll_delta.y);
            if w != 0.0 {
                phase -= w * 0.3;
                ev = Some(CrownEvent::Turn(-w * 1.2));
            }
        }
        if resp.clicked() {
            ev = Some(CrownEvent::Press);
        }
    }
    ui.data_mut(|m| m.insert_temp(phase_id, phase));
    let p = ui.painter();
    let down = live && resp.is_pointer_button_down_on();
    let hot = live && resp.hovered();
    let metal = if down { KEY_DOWN } else if hot { Color32::from_rgb(0x3c, 0x3d, 0x43) } else { Color32::from_rgb(0x30, 0x31, 0x36) };
    // the stem joining it to the case, then the cylinder, rounded at its outer end
    let stem = Rect::from_min_max(Pos2::new(rect.left() - 2.0, rect.center().y - rect.height() * 0.3), Pos2::new(rect.left() + 3.0, rect.center().y + rect.height() * 0.3));
    p.rect_filled(stem, CornerRadius::ZERO, Color32::from_rgb(0x1c, 0x1d, 0x20));
    let body = Rect::from_min_max(Pos2::new(rect.left() + 2.0, rect.top()), rect.max);
    let cr = CornerRadius { nw: 2, sw: 2, ne: 5, se: 5 };
    p.rect_filled(body, cr, metal);
    let gap = (body.height() / 9.0).max(3.0);
    let clip = p.with_clip_rect(body.shrink(1.5));
    let mut y = body.top() + phase.rem_euclid(gap);
    while y < body.bottom() {
        clip.line_segment([Pos2::new(body.left() + 1.0, y), Pos2::new(body.right() - 1.0, y)], Stroke::new(1.0_f32, RIM));
        y += gap;
    }
    p.rect_stroke(body, cr, Stroke::new(1.0_f32, if hot { BORDER_STRONG } else { RIM }), StrokeKind::Inside);
    resp.on_hover_text(if live { "Digital Crown: drag or scroll on it to turn, click to press (F1)" } else { "Not running" });
    ev
}

/// The side button at `rect`: a long flat key flush with the case's right edge, below the crown
pub fn side_button(ui: &mut egui::Ui, rect: Rect, id: egui::Id, live: bool) -> bool {
    let resp = ui.interact(rect, id, if live { Sense::click() } else { Sense::hover() });
    let hot = live && resp.hovered();
    let fill = if live && resp.is_pointer_button_down_on() { KEY_DOWN } else if hot { Color32::from_rgb(0x4a, 0x4b, 0x52) } else { Color32::from_rgb(0x3a, 0x3b, 0x41) };
    let cr = CornerRadius { nw: 1, sw: 1, ne: (rect.width() / 2.0) as u8, se: (rect.width() / 2.0) as u8 };
    ui.painter().rect_filled(rect, cr, fill);
    ui.painter().rect_stroke(rect, cr, Stroke::new(1.0_f32, if hot { INK_3 } else { BORDER_STRONG }), StrokeKind::Inside);
    let c = resp.clicked();
    resp.on_hover_text(if live { "Side button: sleep / wake the screen (F2)" } else { "Not running" });
    c
}
