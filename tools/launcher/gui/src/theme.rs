//! Design system. Every colour is a role of the live Omarchy theme (omarchy.rs): a neutral ramp from the theme's
//! background and foreground, its accent used sparingly, status colours picked from its red / yellow / green by
//! contrast and always paired with a label. Controls use Omarchy's own language (shell.toml [controls]): a
//! foreground-tinted fill at a low alpha with a thin foreground border, no brand fills. Corners follow Hyprland's
//! rounding, surfaces are flat (no shadows, no gradients), nothing animates, the type is the system monospace font.
//! Components: buttons, badges, cards, stat tiles, switches, segmented controls, nav items, fold headers, empty
//! states, a keyboard cursor over rows (`nav`). Pages use only these, so every screen shares one look.
use crate::omarchy;
use eframe::egui::{self, Color32, FontFamily, FontId, Rect, RichText, Sense, Stroke};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, RwLock};

pub use egui_phosphor::regular as icon;

const fn rgb(h: u32) -> Color32 {
    Color32::from_rgb((h >> 16) as u8, (h >> 8) as u8, h as u8)
}

// ---------------------------------------------------------------- the palette

/// The colour roles, filled from the theme at start and at every theme switch. Read with `pal()`.
#[derive(Clone, Copy, Debug)]
pub struct Palette {
    pub window: Color32,       // sidebar, inspector, title bar (dark_background)
    pub canvas: Color32,       // page background (background)
    pub card: Color32,         // cards and dialogs: flat on the canvas, told apart by their border
    pub raised: Color32,       // idle control fill (foreground at normal-fill-alpha)
    pub hover: Color32,        // hover fill (hover-cursor-fill-alpha)
    pub pressed: Color32,      // pressed fill (pressed-fill-alpha)
    pub selected: Color32,     // the chosen state's fill (selected-fill-alpha)
    pub well: Color32,         // inputs, log, screen wells (darker_background)
    pub border: Color32,       // hairlines between rows, card edges
    pub border_strong: Color32, // control borders (normal-border at normal-border-alpha)
    pub border_hover: Color32, // hovered control borders
    pub ink: Color32,          // foreground
    pub ink_2: Color32,        // secondary text
    pub ink_3: Color32,        // tertiary text, icons at rest
    pub accent: Color32,       // the theme's accent: progress, selection stroke
    pub accent_ink: Color32,   // the accent as text (the foreground when the accent can't be read)
    pub on_accent: Color32,    // text on an accent fill: the background or the foreground, whichever reads better
    pub accent_hover: Color32,
    pub accent_down: Color32,
    pub hilite: Color32,       // the chosen item's text: the current page, a hovered menu row ([menu] selected-text)
    pub hilite_fill: Color32,  // a hovered menu row ([menu] selected-background at its alpha)
    pub popup: Color32,        // menus, dropdowns, tooltips, dialogs ([popups] background)
    pub popup_border: Color32, // their edge ([popups] border: Hyprland's active border)
    pub toast: Color32,        // a passing message ([notifications] background)
    pub toast_border: Color32,
    // the theme's other hues, each readable on the background (else secondary text): logs, meters, statuses
    pub blue: Color32,
    pub cyan: Color32,
    pub magenta: Color32,
    pub orange: Color32,
    pub good: Color32,
    pub warn: Color32,
    pub crit: Color32,
    pub crit_ink: Color32,
    pub bezel: Color32,        // a device's case
    pub selection: Color32,    // text selection
    pub active: Color32,       // Hyprland's active border: the phone screen holding the keyboard, popup borders
    pub scrim: Color32,        // behind modal dialogs
    pub focus_fill: Color32,   // the keyboard cursor's row
    pub focus_border: Color32,
    pub radius: u8,            // Hyprland's window rounding
    pub omarchy: bool,         // following a live Omarchy theme (else the built-in default)
    pub light: bool,
}

fn lum(c: Color32) -> f32 {
    let ch = |v: u8| {
        let v = v as f32 / 255.0;
        if v <= 0.03928 { v / 12.92 } else { ((v + 0.055) / 1.055).powf(2.4) }
    };
    0.2126 * ch(c.r()) + 0.7152 * ch(c.g()) + 0.0722 * ch(c.b())
}

/// WCAG contrast ratio
pub fn contrast(a: Color32, b: Color32) -> f32 {
    let (x, y) = (lum(a) + 0.05, lum(b) + 0.05);
    if x > y { x / y } else { y / x }
}

fn mix(a: Color32, b: Color32, t: f32) -> Color32 {
    let l = |x: u8, y: u8| (x as f32 + (y as f32 - x as f32) * t).round() as u8;
    Color32::from_rgb(l(a.r(), b.r()), l(a.g(), b.g()), l(a.b(), b.b()))
}

fn alpha(c: Color32, a: f32) -> Color32 {
    Color32::from_rgba_unmultiplied(c.r(), c.g(), c.b(), (a.clamp(0.0, 1.0) * 255.0).round() as u8)
}

/// The first candidate readable against `bg` (a status colour must be seen, whatever the theme calls it).
fn pick(cands: &[Option<Color32>], bg: Color32, min: f32, fallback: Color32) -> Color32 {
    cands.iter().flatten().copied().find(|c| contrast(*c, bg) >= min).unwrap_or(fallback)
}

impl Palette {
    /// The built-in look when Omarchy isn't there: a neutral dark with Omarchy's documented fallback accent.
    pub fn default_dark() -> Palette {
        let bg = rgb(0x15171a);
        let fg = rgb(0xd6d8dc);
        Palette::derive(bg, rgb(0x101214), rgb(0x0b0c0e), fg, rgb(0xffd60a), rgb(0x2b3440), rgb(0xa0a6ad), [Some(rgb(0xe06c75)), None], [Some(rgb(0xe5c07b)), None], [Some(rgb(0x98c379)), None], &Alphas::default(), 6, false, false)
    }

    /// The built-in light look: the same calm greys, inverted, with a darker amber so the accent stays visible.
    pub fn default_light() -> Palette {
        let bg = rgb(0xf6f6f7);
        let fg = rgb(0x1d1f23);
        Palette::derive(bg, rgb(0xededef), rgb(0xe4e4e7), fg, rgb(0xb98500), rgb(0xcfd6e0), rgb(0x6b7078), [Some(rgb(0xc0392b)), None], [Some(rgb(0x9a6700)), None], [Some(rgb(0x2e7d43)), None], &Alphas::default(), 6, false, true)
    }

    pub fn from_theme(t: &omarchy::Theme, radius: u8) -> Palette {
        let d = Palette::default_dark();
        let bg = t.color("background").unwrap_or(d.canvas);
        let fg = t.color("foreground").unwrap_or(d.ink);
        let dark = t.color("dark_background").unwrap_or(bg);
        let darker = t.color("darker_background").unwrap_or(dark);
        let accent = t.color("accent").unwrap_or(d.accent);
        let selection = t.color("selection").unwrap_or(mix(bg, fg, 0.2));
        let active = t.color("active_border_color").or_else(|| t.color("hyprland_active_border")).unwrap_or(accent);
        let a = Alphas {
            normal: t.shell_f32("controls", "normal-fill-alpha", 0.04),
            hover: t.shell_f32("controls", "hover-cursor-fill-alpha", 0.08),
            pressed: t.shell_f32("controls", "pressed-fill-alpha", 0.22),
            selected: t.shell_f32("controls", "selected-fill-alpha", 0.18),
            border: t.shell_f32("controls", "normal-border-alpha", 0.4),
            border_hover: t.shell_f32("controls", "hover-cursor-border-alpha", 0.25),
            focus: t.shell_f32("controls", "focus-fill-alpha", 0.08),
            scrim: t.shell_f32("menu", "scrim-alpha", 0.5),
            control: t.shell_color("controls", "normal-color"),
            focus_color: t.shell_color("controls", "focus-border"),
            scrim_color: t.shell_color("menu", "scrim"),
        };
        let mut p = Palette::derive(bg, dark, darker, fg, accent, selection, active, [t.color("red"), t.color("bright_red")], [t.color("yellow"), t.color("bright_yellow")], [t.color("green"), t.color("bright_green")], &a, radius, true, t.is_light());
        // the theme's hues (a theme may call any colour "blue": readable on the background, or the next one)
        let hue = |names: &[&str], fallback: Color32| pick(&names.iter().map(|n| t.color(n)).collect::<Vec<_>>(), bg, 3.0, fallback);
        p.blue = hue(&["blue", "bright_blue"], p.ink_2);
        p.cyan = hue(&["cyan", "bright_cyan"], p.ink_2);
        p.magenta = hue(&["magenta", "bright_magenta"], p.ink_2);
        p.orange = hue(&["orange", "bright_red", "red"], p.warn);
        // the surfaces Omarchy's shell draws: menus and popups, notifications, the chosen row's text
        let readable = |c: Option<Color32>, on: Color32, min: f32| c.filter(|c| contrast(*c, on) >= min);
        if let Some(c) = t.shell_color_a("popups", "background").or_else(|| t.shell_color_a("menu", "background")) {
            p.popup = c;
        }
        if let Some(c) = t.shell_color_a("popups", "border").or_else(|| t.shell_color_a("menu", "border")) {
            p.popup_border = c;
        }
        if let Some(c) = t.shell_color_a("notifications", "background") {
            p.toast = c;
        }
        if let Some(c) = t.shell_color_a("notifications", "border") {
            p.toast_border = c;
        }
        if let Some(c) = readable(t.shell_color("menu", "selected-text").or_else(|| t.shell_color("launcher", "selected-text")), p.popup, 3.0) {
            p.hilite = c;
        }
        if let Some(c) = t.shell_color_a("menu", "selected-background") {
            p.hilite_fill = c;
        }
        p.selection = alpha(selection, t.shell_f32("controls", "selection-fill-alpha", 0.85).max(0.35));
        p
    }

    #[allow(clippy::too_many_arguments)]
    fn derive(bg: Color32, dark: Color32, darker: Color32, fg: Color32, accent: Color32, selection: Color32, active: Color32, reds: [Option<Color32>; 2], yellows: [Option<Color32>; 2], greens: [Option<Color32>; 2], a: &Alphas, radius: u8, omarchy: bool, light: bool) -> Palette {
        let control = a.control.unwrap_or(fg);
        let ink_2 = mix(fg, bg, 0.22);
        // the faintest text: as far toward the background as stays readable (light themes lose contrast sooner)
        let mut t3 = 0.45;
        while t3 > 0.2 && contrast(mix(fg, bg, t3), bg) < 4.2 {
            t3 -= 0.05;
        }
        let ink_3 = mix(fg, bg, t3);
        // the brighter of a theme's two reds (greys in a monochrome theme: the label carries the meaning)
        let crit = pick(&[reds[1], reds[0]], bg, 3.0, ink_2);
        let crit_ink = pick(&[reds[1], reds[0]], bg, 4.0, fg);
        let warn = pick(&[yellows[0], yellows[1]], bg, 3.0, ink_2);
        let good = pick(&[greens[0], greens[1]], bg, 3.0, ink_2);
        let accent_ink = if contrast(accent, bg) >= 4.0 { accent } else { fg };
        let hue = |c: Color32| pick(&[Some(c)], bg, 3.0, ink_2);
        let (blue, cyan, magenta, orange) = if light { (rgb(0x2f6fb5), rgb(0x1f7f86), rgb(0x8a4fb0), rgb(0xb45a1b)) } else { (rgb(0x61afef), rgb(0x56b6c2), rgb(0xc678dd), rgb(0xe5995c)) };
        Palette {
            window: dark,
            canvas: bg,
            card: bg,
            raised: alpha(control, a.normal),
            hover: alpha(control, a.hover),
            pressed: alpha(control, a.pressed),
            selected: alpha(control, a.selected),
            well: darker,
            border: mix(bg, fg, 0.14),
            border_strong: alpha(control, a.border),
            border_hover: alpha(control, (a.border + a.border_hover).min(1.0)),
            ink: fg,
            ink_2,
            ink_3,
            accent,
            accent_ink,
            on_accent: if contrast(bg, accent) >= contrast(fg, accent) { bg } else { fg },
            accent_hover: mix(accent, fg, 0.15),
            accent_down: mix(accent, bg, 0.2),
            hilite: accent_ink,
            hilite_fill: alpha(control, a.hover),
            popup: bg,
            popup_border: active,
            toast: bg,
            toast_border: active,
            blue: hue(blue),
            cyan: hue(cyan),
            magenta: hue(magenta),
            orange: hue(orange),
            good,
            warn,
            crit,
            crit_ink,
            bezel: mix(darker, Color32::BLACK, 0.5),
            selection,
            active,
            scrim: alpha(a.scrim_color.unwrap_or(bg), a.scrim),
            focus_fill: alpha(a.focus_color.unwrap_or(control), a.focus),
            focus_border: alpha(accent_ink, 0.8),
            radius,
            omarchy,
            light,
        }
    }
}

/// The fill and border alphas of Omarchy's control chrome (shell.toml [controls], [menu])
struct Alphas {
    normal: f32,
    hover: f32,
    pressed: f32,
    selected: f32,
    border: f32,
    border_hover: f32,
    focus: f32,
    scrim: f32,
    control: Option<Color32>,
    focus_color: Option<Color32>,
    scrim_color: Option<Color32>,
}

impl Default for Alphas {
    fn default() -> Alphas {
        Alphas { normal: 0.04, hover: 0.08, pressed: 0.22, selected: 0.18, border: 0.4, border_hover: 0.25, focus: 0.08, scrim: 0.5, control: None, focus_color: None, scrim_color: None }
    }
}

static PALETTE: RwLock<Option<Palette>> = RwLock::new(None);

/// The current palette (the default until a theme is applied).
pub fn pal() -> Palette {
    (*PALETTE.read().unwrap()).unwrap_or_else(Palette::default_dark)
}

/// Hyprland's rounding: panels, cards, dialogs, buttons.
pub fn radius() -> u8 {
    pal().radius
}

/// Small elements (badges, segments, menu rows): capped at 4.
pub fn radius_sm() -> u8 {
    pal().radius.min(4)
}

/// `pal().radius` as egui's type, one corner less (the inner edge of a 1 px frame).
pub fn radius_inner() -> u8 {
    pal().radius.saturating_sub(1)
}

// ---- type scale (Omarchy's: base 12)
pub const T_CAPTION: f32 = 10.0;
pub const T_SMALL: f32 = 11.0;
pub const T_BODY: f32 = 12.0;
pub const T_LG: f32 = 13.0;
pub const T_TITLE: f32 = 14.0;
pub const T_STAT: f32 = 16.0; // the value of a stat tile, nothing else
pub const T_H1: f32 = 16.0;

// ---- spacing, control heights
pub const S1: f32 = 4.0;
pub const S2: f32 = 8.0;
pub const S3: f32 = 12.0;
pub const S4: f32 = 16.0;
pub const S5: f32 = 24.0;
pub const S6: f32 = 32.0;
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
/// The icon family: Phosphor first. Text families put it last: a Nerd Font fills the same private-use range with its
/// own glyphs, and Phosphor has (empty) glyphs for a–z, so neither may stand before the other in one list.
pub fn icons() -> FontFamily {
    FontFamily::Name("icons".into())
}
pub fn ifont(size: f32) -> FontId {
    FontId::new(size, icons())
}

// ---- text roles
pub fn h1(t: impl Into<String>) -> RichText {
    RichText::new(t).size(T_H1).family(semibold()).color(pal().ink)
}
pub fn title(t: impl Into<String>) -> RichText {
    RichText::new(t).size(T_LG).family(semibold()).color(pal().ink)
}
pub fn body(t: impl Into<String>) -> RichText {
    RichText::new(t).size(T_BODY).color(pal().ink)
}
pub fn strong(t: impl Into<String>) -> RichText {
    RichText::new(t).size(T_BODY).family(medium()).color(pal().ink)
}
pub fn sub(t: impl Into<String>) -> RichText {
    RichText::new(t).size(T_BODY).color(pal().ink_2)
}
pub fn muted(t: impl Into<String>) -> RichText {
    RichText::new(t).size(T_SMALL).color(pal().ink_3)
}
/// A quiet group label (lowercase, no tracking: the terminal's calm, not a shouting overline).
pub fn overline(t: &str) -> RichText {
    RichText::new(t.to_lowercase()).size(T_SMALL).color(pal().ink_3)
}
/// Column headings of a table.
pub fn table_head() -> FontId {
    font(T_SMALL)
}
/// The title of a modal dialog.
pub fn dialog_title(t: impl Into<String>) -> RichText {
    RichText::new(t).size(T_TITLE).family(semibold()).color(pal().ink)
}

// ---------------------------------------------------------------- applying the theme

static FONT_PATHS: Mutex<Option<(std::path::PathBuf, Option<std::path::PathBuf>)>> = Mutex::new(None);

/// What Settings > Appearance picked.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Appearance {
    /// The live Omarchy theme; without Omarchy, the desktop's light or dark preference.
    System,
    Dark,
    Light,
}

impl Appearance {
    pub const ALL: [Appearance; 3] = [Appearance::System, Appearance::Dark, Appearance::Light];
    pub fn parse(s: &str) -> Appearance {
        match s {
            "dark" => Appearance::Dark,
            "light" => Appearance::Light,
            _ => Appearance::System,
        }
    }
    pub fn key(self) -> &'static str {
        match self {
            Appearance::System => "system",
            Appearance::Dark => "dark",
            Appearance::Light => "light",
        }
    }
    pub fn label(self) -> &'static str {
        match self {
            Appearance::System => "System",
            Appearance::Dark => "Dark",
            Appearance::Light => "Light",
        }
    }
}

static APPEARANCE: Mutex<Appearance> = Mutex::new(Appearance::System);
/// The desktop preference the current palette was built from (System without Omarchy), to notice it change.
static SYS_LIGHT_USED: Mutex<Option<bool>> = Mutex::new(None);

pub fn appearance() -> Appearance {
    *APPEARANCE.lock().unwrap()
}

/// Switches the look now (Settings, and once at start from the saved choice).
pub fn set_appearance(ctx: &egui::Context, a: Appearance) {
    *APPEARANCE.lock().unwrap() = a;
    apply(ctx);
    ctx.request_repaint();
}

/// The desktop's light/dark preference: what the windowing system reports, else the freedesktop/GNOME setting the
/// watcher reads.
fn system_light(ctx: &egui::Context) -> bool {
    match ctx.system_theme() {
        Some(t) => t == egui::Theme::Light,
        None => omarchy::desktop_prefers_light(),
    }
}

/// Loads the theme (or a built-in look), sets the fonts and egui's style. At start, after every theme switch, and
/// when the appearance or the desktop preference changes.
pub fn apply(ctx: &egui::Context) {
    let theme = omarchy::load();
    let rounding = theme.as_ref().map(|_| omarchy::rounding().unwrap_or(0));
    let mut used = None;
    let mut p = match (appearance(), &theme) {
        (Appearance::System, Some(t)) => Palette::from_theme(t, rounding.unwrap_or(0)),
        (Appearance::System, None) => {
            let light = system_light(ctx);
            used = Some(light);
            if light { Palette::default_light() } else { Palette::default_dark() }
        }
        (Appearance::Dark, _) => Palette::default_dark(),
        (Appearance::Light, _) => Palette::default_light(),
    };
    *SYS_LIGHT_USED.lock().unwrap() = used;
    // Dark and Light change the colours only: on Omarchy the corners still match Hyprland's and Hyprland still owns
    // the window
    if let Some(r) = rounding {
        p.radius = r;
    }
    p.omarchy = theme.is_some();
    *PALETTE.write().unwrap() = Some(p);
    // Omarchy's apps use the system monospace font; without Omarchy the bundled Inter (fonts are reloaded only
    // when the file changed: the theme changes more often)
    let want = theme.as_ref().and_then(|_| omarchy::mono_font());
    let mut cur = FONT_PATHS.lock().unwrap();
    if *cur != want || cur.is_none() {
        set_fonts(ctx, want.as_ref());
        *cur = want;
    }
    drop(cur);
    style(ctx, &p);
}

/// Called every frame: picks up a theme change flagged by the watcher, or a desktop light/dark switch while System
/// follows it.
pub fn poll(ctx: &egui::Context) {
    let sys_changed = matches!(*SYS_LIGHT_USED.lock().unwrap(), Some(l) if l != system_light(ctx));
    if omarchy::DIRTY.swap(false, Ordering::AcqRel) || sys_changed {
        apply(ctx);
        ctx.request_repaint();
    }
}

fn set_fonts(ctx: &egui::Context, mono: Option<&(std::path::PathBuf, Option<std::path::PathBuf>)>) {
    use egui::FontData;
    let mut fonts = egui::FontDefinitions::default();
    let fd = |b: &'static [u8]| Arc::new(FontData::from_static(b));
    fonts.font_data.insert("inter".into(), fd(include_bytes!("../assets/fonts/Inter-Regular.ttf")));
    fonts.font_data.insert("inter-medium".into(), fd(include_bytes!("../assets/fonts/Inter-Medium.ttf")));
    fonts.font_data.insert("inter-semibold".into(), fd(include_bytes!("../assets/fonts/Inter-SemiBold.ttf")));
    fonts.font_data.insert("phosphor".into(), Arc::new(egui_phosphor::Variant::Regular.font_data()));
    let mut sys: Option<(String, String)> = None;
    if let Some((reg, bold)) = mono {
        if let Ok(b) = std::fs::read(reg) {
            fonts.font_data.insert("sys".into(), Arc::new(FontData::from_owned(b)));
            let bold_name = match bold.as_ref().and_then(|p| std::fs::read(p).ok()) {
                Some(b) => {
                    fonts.font_data.insert("sys-bold".into(), Arc::new(FontData::from_owned(b)));
                    "sys-bold"
                }
                None => "sys",
            };
            sys = Some(("sys".into(), bold_name.into()));
        }
    }
    let fallback = fonts.families.get(&FontFamily::Proportional).cloned().unwrap_or_default();
    let (regular, medium_f, semibold_f) = match &sys {
        Some((r, b)) => (r.clone(), r.clone(), b.clone()),
        None => ("inter".to_string(), "inter-medium".to_string(), "inter-semibold".to_string()),
    };
    // text: the system font, egui's defaults (emoji), the icon font last
    for (fam, face) in [(FontFamily::Proportional, regular.clone()), (medium(), medium_f), (semibold(), semibold_f)] {
        let mut v = vec![face];
        v.extend(fallback.iter().cloned());
        v.push("phosphor".into());
        fonts.families.insert(fam, v);
    }
    let mut m = vec![];
    if sys.is_some() {
        m.push(regular.clone());
    }
    m.extend(fonts.families.get(&FontFamily::Monospace).cloned().unwrap_or_default());
    fonts.families.insert(FontFamily::Monospace, m);
    // icons: Phosphor first, then the text font (a digit in a step marker)
    let mut i = vec!["phosphor".to_string(), regular];
    i.extend(fallback.iter().cloned());
    fonts.families.insert(icons(), i);
    ctx.set_fonts(fonts);
}

fn style(ctx: &egui::Context, p: &Palette) {
    use egui::TextStyle;
    ctx.set_theme(if p.light { egui::Theme::Light } else { egui::Theme::Dark });
    let p = *p;
    ctx.style_mut(|s| {
        s.text_styles = [
            (TextStyle::Heading, font_sb(T_H1)),
            (TextStyle::Body, font(T_BODY)),
            (TextStyle::Button, font(T_BODY)),
            (TextStyle::Small, font(T_CAPTION)),
            (TextStyle::Monospace, FontId::new(T_SMALL, FontFamily::Monospace)),
        ]
        .into();
        // no animations: panels, popups, collapsing and hover states change at once
        s.animation_time = 0.0;
        s.spacing.item_spacing = egui::vec2(S2, S2);
        s.spacing.button_padding = egui::vec2(10.0, 4.0);
        s.spacing.interact_size = egui::vec2(24.0, H_MD);
        s.spacing.combo_height = 320.0;
        s.spacing.slider_width = 160.0;
        s.spacing.menu_margin = egui::Margin::same(4);
        s.spacing.window_margin = egui::Margin::same(16);
        s.spacing.tooltip_width = 420.0;
        s.spacing.scroll = egui::style::ScrollStyle { bar_width: 6.0, floating_allocated_width: 0.0, ..egui::style::ScrollStyle::floating() };
        s.interaction.tooltip_delay = 0.35;
        let v = &mut s.visuals;
        v.panel_fill = p.canvas;
        v.window_fill = p.popup;
        v.extreme_bg_color = p.well;
        v.faint_bg_color = p.raised;
        v.code_bg_color = p.well;
        v.override_text_color = None;
        v.hyperlink_color = p.accent_ink;
        v.weak_text_color = Some(p.ink_3);
        v.selection.bg_fill = if p.selection.a() == 255 { alpha(p.selection, 0.85) } else { p.selection };
        v.selection.stroke = Stroke::new(1.0_f32, p.ink);
        v.window_corner_radius = p.radius.into();
        v.menu_corner_radius = p.radius.into();
        // popups and tooltips wear Hyprland's active border, as Omarchy's own flyouts do
        v.window_stroke = Stroke::new(1.0_f32, p.popup_border);
        v.window_shadow = egui::Shadow::NONE;
        v.popup_shadow = egui::Shadow::NONE;
        v.window_highlight_topmost = false;
        v.slider_trailing_fill = true;
        v.handle_shape = egui::style::HandleShape::Rect { aspect_ratio: 0.5 };
        v.striped = false;
        v.text_cursor.stroke = Stroke::new(1.5_f32, p.accent_ink);
        let r: egui::CornerRadius = p.radius.min(4).into();
        for w in [&mut v.widgets.noninteractive, &mut v.widgets.inactive, &mut v.widgets.hovered, &mut v.widgets.active, &mut v.widgets.open] {
            w.corner_radius = r;
            w.expansion = 0.0;
        }
        v.widgets.noninteractive.bg_fill = p.canvas;
        v.widgets.noninteractive.weak_bg_fill = p.canvas;
        v.widgets.noninteractive.bg_stroke = Stroke::new(1.0_f32, p.border);
        v.widgets.noninteractive.fg_stroke = Stroke::new(1.0_f32, p.ink_2);
        v.widgets.inactive.bg_fill = p.raised;
        v.widgets.inactive.weak_bg_fill = p.raised;
        v.widgets.inactive.bg_stroke = Stroke::new(1.0_f32, p.border_strong);
        v.widgets.inactive.fg_stroke = Stroke::new(1.0_f32, p.ink);
        v.widgets.hovered.bg_fill = p.hover;
        v.widgets.hovered.weak_bg_fill = p.hover;
        v.widgets.hovered.bg_stroke = Stroke::new(1.0_f32, alpha(p.accent_ink, 0.7));
        v.widgets.hovered.fg_stroke = Stroke::new(1.0_f32, p.ink);
        v.widgets.active.bg_fill = p.pressed;
        v.widgets.active.weak_bg_fill = p.pressed;
        v.widgets.active.bg_stroke = Stroke::new(1.0_f32, p.accent);
        v.widgets.active.fg_stroke = Stroke::new(1.0_f32, p.ink);
        v.widgets.open.bg_fill = p.selected;
        v.widgets.open.weak_bg_fill = p.selected;
        v.widgets.open.bg_stroke = Stroke::new(1.0_f32, p.border_strong);
        v.widgets.open.fg_stroke = Stroke::new(1.0_f32, p.ink);
    });
}

// ---------------------------------------------------------------- keyboard cursor over rows

/// A keyboard cursor over a page's rows (cards, list rows, form rows): j / k and the arrows move it, Enter
/// activates the row (its first button, its switch). Pages register rows in drawing order; the cursor is
/// kept by id across frames and dropped when its row is gone (another page).
pub mod nav {
    use super::*;
    use egui::Id;

    #[derive(Default)]
    struct State {
        rows: Vec<Id>,
        prev: Vec<Id>,
        cur: Option<Id>,
        activate: bool,
        moved: bool,
        /// rows a j / k step jumps (a grid's column count)
        stride: usize,
        want_search: bool,
    }

    static NAV: Mutex<Option<State>> = Mutex::new(None);
    /// a row with the cursor is being drawn and Enter was pressed: its first control takes it
    static ACTIVATE: AtomicBool = AtomicBool::new(false);

    fn with<R>(f: impl FnOnce(&mut State) -> R) -> R {
        let mut g = NAV.lock().unwrap();
        f(g.get_or_insert_with(Default::default))
    }

    /// Before the page is drawn: `dx` steps along rows, `dy` steps of a stride (lines of a grid); `activate`: Enter.
    pub fn begin_frame(dx: i32, dy: i32, activate: bool) {
        with(|s| {
            s.rows.clear();
            s.activate = activate;
            s.moved = false;
            let step = dx + dy * s.stride.max(1) as i32;
            if step != 0 && !s.prev.is_empty() {
                let n = s.prev.len() as i32;
                let i = s.cur.and_then(|c| s.prev.iter().position(|r| *r == c)).map(|i| i as i32);
                let j = match i {
                    None => {
                        if step > 0 { 0 } else { n - 1 }
                    }
                    Some(i) => (i + step).clamp(0, n - 1),
                };
                s.cur = Some(s.prev[j as usize]);
                s.moved = true;
            }
            s.stride = 1;
        });
    }

    /// After the page is drawn: keep the cursor only on a row still there.
    pub fn end_frame() {
        with(|s| {
            if s.cur.is_some_and(|c| !s.rows.contains(&c)) {
                s.cur = None;
            }
            std::mem::swap(&mut s.prev, &mut s.rows);
            s.activate = false;
        });
    }

    /// A grid: j / k move by this many rows (set while the grid is drawn).
    pub fn set_stride(n: usize) {
        with(|s| s.stride = n.max(1));
    }

    pub struct Row {
        pub current: bool,
        /// the cursor is here and Enter was pressed this frame
        pub activate: bool,
    }

    /// Registers a row; the page draws its own focus (`mark`) and acts on `activate`.
    pub fn row(id: Id) -> Row {
        with(|s| {
            s.rows.push(id);
            let current = s.cur == Some(id);
            Row { current, activate: current && s.activate }
        })
    }

    /// The cursor's look on `rect`; scrolls it into view after a move.
    pub fn mark(ui: &egui::Ui, rect: Rect, r: u8) {
        let p = pal();
        ui.painter().rect(rect, r, p.focus_fill, Stroke::new(1.0_f32, p.focus_border), egui::StrokeKind::Inside);
        if with(|s| s.moved) {
            ui.scroll_to_rect(rect.expand(S2), None);
        }
    }

    /// For a row that draws its own cursor look: only the scroll after a move.
    pub fn mark_scroll(ui: &egui::Ui, rect: Rect) {
        if with(|s| s.moved) {
            ui.scroll_to_rect(rect.expand(S2), None);
        }
    }

    /// A click puts the cursor on the row.
    pub fn select(id: Id) {
        with(|s| s.cur = Some(id));
    }

    pub fn clear() {
        with(|s| {
            s.cur = None;
            s.prev.clear();
        });
    }

    /// Around a row's controls: the first control drawn takes the activation.
    pub fn offer_activation(row: &Row) {
        ACTIVATE.store(row.activate, Ordering::Relaxed);
    }

    pub fn withdraw_activation() {
        ACTIVATE.store(false, Ordering::Relaxed);
    }

    /// A control inside the row with the cursor asks whether Enter was for it (the first one to ask gets it).
    pub fn take_activation() -> bool {
        ACTIVATE.swap(false, Ordering::Relaxed)
    }

    /// `/`: the page's search field takes the keyboard.
    pub fn want_search() {
        with(|s| s.want_search = true);
    }

    pub fn take_search() -> bool {
        with(|s| std::mem::take(&mut s.want_search))
    }
}

// ---------------------------------------------------------------- buttons

#[derive(Clone, Copy, PartialEq)]
pub enum Kind {
    /// Tinted in a state colour: Start in the theme's green, Stop and Remove in its red.
    Tinted(Color32),
    Danger,
    Primary,
    Secondary,
    Ghost,
}

/// The one button: consistent height per size, icon + label, hover/pressed/disabled/focus states. Primary is filled
/// with the theme's accent, secondary is Omarchy's control chrome (accent border on hover), tinted ones wear a state
/// colour (Start green, Stop and Remove red).
pub struct Btn {
    kind: Kind,
    icon: Option<&'static str>,
    text: String,
    h: f32,
    min_w: f32,
    /// a key hint drawn after the label ("s")
    key: &'static str,
}

impl Btn {
    fn new(kind: Kind, text: impl Into<String>) -> Btn {
        Btn { kind, icon: None, text: text.into(), h: H_MD, min_w: 0.0, key: "" }
    }
    pub fn primary(text: impl Into<String>) -> Btn {
        Btn::new(Kind::Primary, text)
    }
    pub fn secondary(text: impl Into<String>) -> Btn {
        Btn::new(Kind::Secondary, text)
    }
    /// Destructive confirm (remove, delete): the theme's red.
    pub fn danger(text: impl Into<String>) -> Btn {
        Btn::new(Kind::Danger, text)
    }
    pub fn tinted(text: impl Into<String>, col: Color32) -> Btn {
        Btn::new(Kind::Tinted(col), text)
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
    pub fn small(mut self) -> Btn {
        self.h = H_SM;
        self
    }
    pub fn min_w(mut self, w: f32) -> Btn {
        self.min_w = w;
        self
    }
    /// The key that presses it, shown after the label.
    pub fn key(mut self, k: &'static str) -> Btn {
        self.key = k;
        self
    }
}

impl egui::Widget for Btn {
    fn ui(self, ui: &mut egui::Ui) -> egui::Response {
        let pal = pal();
        let small = self.h < H_MD;
        let ts = if small { T_SMALL } else { T_BODY };
        let is = if small { 13.0 } else { 14.0 };
        let enabled = ui.is_enabled();
        let p = ui.painter().clone();
        let tg = (!self.text.is_empty()).then(|| p.layout_no_wrap(self.text.clone(), font(ts), pal.ink));
        let ig = self.icon.map(|i| p.layout_no_wrap(i.to_string(), ifont(is), pal.ink));
        let kg = (!self.key.is_empty() && tg.is_some()).then(|| p.layout_no_wrap(self.key.to_string(), font(T_CAPTION), pal.ink_3));
        let pad = if tg.is_none() { 0.0 } else if small { 8.0 } else { 10.0 };
        let gap = if tg.is_some() && ig.is_some() { 6.0 } else { 0.0 };
        let kgap = if kg.is_some() { 8.0 } else { 0.0 };
        let content = tg.as_ref().map(|g| g.size().x).unwrap_or(0.0) + ig.as_ref().map(|g| g.size().x).unwrap_or(0.0) + gap + kg.as_ref().map(|g| g.size().x + kgap).unwrap_or(0.0);
        let w = if tg.is_none() { self.h } else { (content + 2.0 * pad).max(self.min_w) };
        let (rect, mut resp) = ui.allocate_exact_size(egui::vec2(w, self.h), Sense::click());
        // Enter on the row with the keyboard cursor presses its first button
        let activated = enabled && nav::take_activation();
        if ui.is_rect_visible(rect) {
            let hov = resp.hovered() && enabled;
            let down = (resp.is_pointer_button_down_on() && enabled) || activated;
            let (bg, stroke, fg, icol) = match self.kind {
                // the theme's accent, filled
                Kind::Primary if enabled => (if down { pal.accent_down } else if hov { pal.accent_hover } else { pal.accent }, Stroke::NONE, pal.on_accent, pal.on_accent),
                Kind::Danger | Kind::Tinted(_) if enabled => {
                    let c = if let Kind::Tinted(c) = self.kind { c } else { pal.crit_ink };
                    (alpha(c, if down { 0.3 } else if hov { 0.22 } else { 0.12 }), Stroke::new(1.0_f32, alpha(c, if hov { 0.85 } else { 0.55 })), c, c)
                }
                Kind::Primary | Kind::Secondary | Kind::Danger | Kind::Tinted(_) => {
                    let bg = if !enabled { Color32::TRANSPARENT } else if down { pal.pressed } else if hov { pal.hover } else { pal.raised };
                    // hover borders take the accent: the control under the pointer says so in the theme's colour
                    let st = Stroke::new(1.0_f32, if !enabled { pal.border } else if hov { alpha(pal.accent_ink, 0.7) } else { pal.border_strong });
                    let fg = if enabled { pal.ink } else { pal.ink_3 };
                    (bg, st, fg, if enabled { pal.ink_2 } else { pal.ink_3 })
                }
                Kind::Ghost => {
                    let bg = if down { pal.pressed } else if hov { pal.hover } else { Color32::TRANSPARENT };
                    let fg = if !enabled { alpha(pal.ink_3, 0.6) } else if hov { pal.ink } else { pal.ink_2 };
                    (bg, Stroke::NONE, fg, fg)
                }
            };
            p.rect(rect, radius(), bg, stroke, egui::StrokeKind::Inside);
            if resp.has_focus() {
                p.rect_stroke(rect, radius(), Stroke::new(1.0_f32, pal.active), egui::StrokeKind::Inside);
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
                let gw = g.size().x;
                p.galley_with_override_text_color(egui::pos2(x, y), g, fg);
                x += gw + kgap;
            }
            if let Some(g) = kg {
                let y = rect.center().y - g.size().y / 2.0;
                let kc = match self.kind {
                    Kind::Primary if enabled => alpha(pal.on_accent, 0.65),
                    Kind::Danger | Kind::Tinted(_) if enabled => alpha(fg, 0.65),
                    _ if enabled => pal.ink_3,
                    _ => alpha(pal.ink_3, 0.6),
                };
                p.galley_with_override_text_color(egui::pos2(x, y), g, kc);
            }
        }
        if activated {
            resp.flags.set(egui::response::Flags::FAKE_PRIMARY_CLICKED, true);
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
    let p = pal();
    egui::Frame::new().fill(p.card).stroke(Stroke::new(1.0_f32, p.border)).corner_radius(radius()).inner_margin(S4 as i8)
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
    let p = pal();
    egui::Frame::new()
        .fill(p.card)
        .stroke(Stroke::new(1.0_f32, p.border))
        .corner_radius(radius())
        .show(ui, |ui| {
            ui.set_width(ui.available_width());
            ui.spacing_mut().item_spacing.y = 0.0;
            add(ui)
        })
        .inner
}

/// Page title row: title + optional subtitle on the left, actions on the right.
pub fn page_header(ui: &mut egui::Ui, title: &str, sub_text: &str, actions: impl FnOnce(&mut egui::Ui)) {
    // the text keeps clear of the actions (their width as last drawn): unbounded, a long subtitle ran under the
    // button at narrow widths ("Check for updates" on Versions)
    let aw_id = ui.id().with(("page-header-actions", title));
    let aw: f32 = ui.data(|d| d.get_temp(aw_id)).unwrap_or(0.0);
    ui.horizontal(|ui| {
        let tw = (ui.available_width() - aw - S4).max(160.0);
        ui.vertical(|ui| {
            ui.set_max_width(tw);
            ui.spacing_mut().item_spacing.y = 2.0;
            ui.add(egui::Label::new(h1(title)).truncate());
            if !sub_text.is_empty() {
                ui.add(egui::Label::new(sub(sub_text)).wrap());
            }
        });
        let w = ui
            .with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                actions(ui);
                ui.min_rect().width()
            })
            .inner;
        if (w - aw).abs() > 0.5 {
            ui.data_mut(|d| d.insert_temp(aw_id, w));
            ui.ctx().request_repaint();
        }
    });
    ui.add_space(S4);
}

/// Section heading inside a page with optional trailing actions.
pub fn section(ui: &mut egui::Ui, text: &str, actions: impl FnOnce(&mut egui::Ui)) {
    ui.horizontal(|ui| {
        ui.set_min_height(H_MD);
        ui.label(title(text));
        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), actions);
    });
    ui.add_space(S1);
}

/// Status: coloured dot + neutral label in a quiet box. The colour never carries meaning alone.
pub fn badge(ui: &mut egui::Ui, text: &str, col: Color32) -> egui::Response {
    let pal = pal();
    let g = ui.painter().layout_no_wrap(text.to_string(), font(T_SMALL), pal.ink_2);
    let size = egui::vec2(g.size().x + 8.0 + 6.0 + 14.0, 20.0);
    let (rect, resp) = ui.allocate_exact_size(size, Sense::hover());
    let p = ui.painter();
    let edge = if col == pal.ink_3 { pal.border } else { alpha(col, 0.5) };
    p.rect(rect, radius_sm(), if col == pal.ink_3 { pal.raised } else { alpha(col, 0.08) }, Stroke::new(1.0_f32, edge), egui::StrokeKind::Inside);
    let c = egui::pos2(rect.left() + 10.0, rect.center().y);
    dot(p, c, col);
    p.galley(egui::pos2(rect.left() + 18.0, rect.center().y - g.size().y / 2.0), g, pal.ink_2);
    resp
}

/// The status dot: filled in its colour; hollow for "off" (ink_3).
pub fn dot(p: &egui::Painter, c: egui::Pos2, col: Color32) {
    if col == pal().ink_3 {
        p.circle_stroke(c, 3.0, Stroke::new(1.0_f32, col));
    } else {
        p.circle_filled(c, 3.0, col);
    }
}

/// Bare dot + label (for dense rows).
pub fn dot_label(ui: &mut egui::Ui, text: &str, col: Color32) {
    ui.horizontal(|ui| {
        ui.spacing_mut().item_spacing.x = 6.0;
        let (r, _) = ui.allocate_exact_size(egui::vec2(8.0, 14.0), Sense::hover());
        dot(ui.painter(), r.center(), col);
        ui.label(RichText::new(text).size(T_SMALL).color(pal().ink_2));
    });
}

/// Stat tile: label, value (semibold, ink), optional note. Equal widths in a row.
pub fn stat(ui: &mut egui::Ui, w: f32, label: &str, value: &str, note: &str, fill: Color32) {
    let pal = pal();
    egui::Frame::new().fill(fill).stroke(Stroke::new(1.0_f32, pal.border)).corner_radius(radius()).inner_margin(egui::Margin::symmetric(12, 8)).show(ui, |ui| {
        ui.set_width(w - 24.0 - 2.0); // margins + the 1 px stroke on each side
        ui.vertical(|ui| {
            ui.spacing_mut().item_spacing.y = 2.0;
            ui.label(muted(label));
            ui.horizontal(|ui| {
                ui.spacing_mut().item_spacing.x = 6.0;
                ui.label(RichText::new(value).size(T_STAT).family(semibold()).color(pal.ink));
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
        ui.painter().text(r.left_center(), egui::Align2::LEFT_CENTER, label, font(T_SMALL), pal().ink_3);
        add(ui);
    });
}

pub fn kv_text(ui: &mut egui::Ui, label_w: f32, label: &str, value: impl Into<String>) {
    let v = value.into();
    kv(ui, label_w, label, |ui| {
        ui.add(egui::Label::new(RichText::new(v).size(T_SMALL).color(pal().ink)).truncate());
    });
}

/// Settings-style row: title + description on the left, control on the right, hairline below unless last. A row of
/// the keyboard cursor: Enter goes to its first control.
pub fn form_row(ui: &mut egui::Ui, label: &str, desc: &str, last: bool, control: impl FnOnce(&mut egui::Ui)) {
    let row = nav::row(ui.id().with(("form-row", label)));
    let r = egui::Frame::new().inner_margin(egui::Margin::symmetric(14, 10)).show(ui, |ui| {
        ui.set_width(ui.available_width());
        // the description wraps to what the control leaves (its width as last drawn): unbounded, a long one ran under
        // the control ("How much" on Pre-translate)
        let cw_id = ui.id().with(("form-row-control", label));
        let cw: f32 = ui.data(|d| d.get_temp(cw_id)).unwrap_or(160.0);
        ui.horizontal(|ui| {
            ui.set_min_height(H_MD);
            let tw = (ui.available_width() - cw - S4).max(140.0);
            ui.vertical(|ui| {
                ui.set_max_width(tw);
                ui.spacing_mut().item_spacing.y = 2.0;
                ui.label(strong(label));
                if !desc.is_empty() {
                    ui.add(egui::Label::new(muted(desc)).wrap());
                }
            });
            let w = ui
                .with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    nav::offer_activation(&row);
                    control(ui);
                    nav::withdraw_activation();
                    ui.min_rect().width()
                })
                .inner;
            if (w - cw).abs() > 0.5 {
                ui.data_mut(|d| d.insert_temp(cw_id, w));
                ui.ctx().request_repaint();
            }
        });
    });
    if row.current {
        nav::mark(ui, r.response.rect.shrink(1.0), radius_sm());
    }
    if !last {
        hline_inset(ui, 14.0);
    }
}

/// Empty state: icon, title, text, then whatever actions the caller adds.
pub fn empty_state(ui: &mut egui::Ui, ic: &str, title_text: &str, text: &str, actions: impl FnOnce(&mut egui::Ui)) {
    ui.vertical_centered(|ui| {
        ui.add_space(S2);
        let (r, _) = ui.allocate_exact_size(egui::vec2(40.0, 40.0), Sense::hover());
        let pal = pal();
        ui.painter().rect(r, radius(), pal.raised, Stroke::new(1.0_f32, pal.border), egui::StrokeKind::Inside);
        ui.painter().text(r.center(), egui::Align2::CENTER_CENTER, ic, ifont(20.0), pal.ink_2);
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

/// Something is happening in the background: a plain marker and a word, no spinner.
pub fn busy(ui: &mut egui::Ui, text: &str) {
    ui.horizontal(|ui| {
        ui.spacing_mut().item_spacing.x = 6.0;
        let (r, _) = ui.allocate_exact_size(egui::vec2(12.0, 14.0), Sense::hover());
        ui.painter().text(r.center(), egui::Align2::CENTER_CENTER, icon::CIRCLE_NOTCH, ifont(12.0), pal().ink_3);
        if !text.is_empty() {
            ui.label(muted(text));
        }
    });
}

/// A thin progress track. `frac`: the share done; None: a run of unknown length (the track alone).
pub fn progress(ui: &mut egui::Ui, frac: Option<f32>, col: Color32) {
    let (r, _) = ui.allocate_exact_size(egui::vec2(ui.available_width(), 4.0), Sense::hover());
    let p = ui.painter();
    p.rect_filled(r, radius_sm().min(2), pal().raised);
    p.rect_stroke(r, radius_sm().min(2), Stroke::new(1.0_f32, pal().border), egui::StrokeKind::Inside);
    if let Some(f) = frac {
        let w = (r.width() * f.clamp(0.0, 1.0)).max(if f > 0.0 { 2.0 } else { 0.0 });
        p.rect_filled(Rect::from_min_size(r.min, egui::vec2(w, r.height())), radius_sm().min(2), col);
    }
}

// ---------------------------------------------------------------- controls

/// Switch: a short track with a square knob; the selected fill when on. No animation.
pub fn toggle(ui: &mut egui::Ui, on: &mut bool) -> egui::Response {
    let size = egui::vec2(32.0, 18.0);
    let (rect, mut resp) = ui.allocate_exact_size(size, Sense::click());
    let enabled = ui.is_enabled();
    if (resp.clicked() || (enabled && nav::take_activation())) && enabled {
        *on = !*on;
        resp.mark_changed();
    }
    let pal = pal();
    let p = ui.painter();
    let fill = if !enabled { Color32::TRANSPARENT } else if *on { alpha(pal.accent, 0.3) } else if resp.hovered() { pal.hover } else { pal.raised };
    let edge = if !enabled { pal.border } else if *on { pal.accent } else if resp.hovered() { alpha(pal.accent_ink, 0.7) } else { pal.border_strong };
    p.rect(rect, radius_sm(), fill, Stroke::new(1.0_f32, edge), egui::StrokeKind::Inside);
    let kw = 12.0;
    let kx = if *on { rect.right() - 3.0 - kw } else { rect.left() + 3.0 };
    let knob = Rect::from_min_size(egui::pos2(kx, rect.top() + 3.0), egui::vec2(kw, rect.height() - 6.0));
    p.rect_filled(knob, radius_sm().min(2), if !enabled { pal.ink_3 } else if *on { pal.accent_ink } else { pal.ink_3 });
    if resp.has_focus() {
        p.rect_stroke(rect, radius_sm(), Stroke::new(1.0_f32, pal.active), egui::StrokeKind::Inside);
    }
    if enabled {
        resp.on_hover_cursor(egui::CursorIcon::PointingHand)
    } else {
        resp
    }
}

/// Segmented control; returns the clicked index. Enter on its row steps to the next segment.
pub fn segmented(ui: &mut egui::Ui, items: &[&str], sel: Option<usize>, enabled: bool) -> Option<usize> {
    let pal = pal();
    let mut out = None;
    let p = ui.painter().clone();
    let gs: Vec<_> = items.iter().map(|l| p.layout_no_wrap(l.to_string(), font(T_SMALL), pal.ink)).collect();
    let pad = 9.0;
    let w: f32 = gs.iter().map(|g| g.size().x + 2.0 * pad).sum::<f32>() + 4.0;
    let (rect, _) = ui.allocate_exact_size(egui::vec2(w, H_MD), Sense::hover());
    p.rect(rect, radius(), pal.well, Stroke::new(1.0_f32, pal.border_strong), egui::StrokeKind::Inside);
    if enabled && nav::take_activation() && !items.is_empty() {
        out = Some(sel.map(|i| (i + 1) % items.len()).unwrap_or(0));
    }
    let mut x = rect.left() + 2.0;
    for (i, g) in gs.into_iter().enumerate() {
        let iw = g.size().x + 2.0 * pad;
        let r = Rect::from_min_size(egui::pos2(x, rect.top() + 2.0), egui::vec2(iw, H_MD - 4.0));
        let resp = ui.interact(r, ui.id().with(("seg", items[i], i)), if enabled { Sense::click() } else { Sense::hover() });
        let on = sel == Some(i);
        if on {
            p.rect(r, radius_sm(), if enabled { alpha(pal.accent, 0.22) } else { pal.raised }, Stroke::new(1.0_f32, if enabled { alpha(pal.accent, 0.6) } else { pal.border }), egui::StrokeKind::Inside);
        } else if resp.hovered() && enabled {
            p.rect_filled(r, radius_sm(), pal.hover);
        }
        let col = if !enabled { pal.ink_3 } else if on { pal.hilite } else if resp.hovered() { pal.ink } else { pal.ink_2 };
        p.galley_with_override_text_color(egui::pos2(r.center().x - g.size().x / 2.0, r.center().y - g.size().y / 2.0), g, col);
        if enabled && resp.on_hover_cursor(egui::CursorIcon::PointingHand).clicked() {
            out = Some(i);
        }
        x += iw;
    }
    out
}

/// A sidebar entry: icon, label, a count or marker, and the key that opens it at the right.
pub fn nav_item(ui: &mut egui::Ui, ic: &str, label: &str, on: bool, trailing: &str, key: &str) -> bool {
    let pal = pal();
    let w = ui.available_width();
    let (rect, resp) = ui.allocate_exact_size(egui::vec2(w, 26.0), Sense::click());
    let p = ui.painter();
    if on {
        p.rect_filled(rect, radius_sm(), pal.selected);
    } else if resp.hovered() {
        p.rect_filled(rect, radius_sm(), pal.hover);
    }
    let col = if on { pal.hilite } else if resp.hovered() { pal.ink } else { pal.ink_2 };
    p.text(rect.left_center() + egui::vec2(8.0, 0.0), egui::Align2::LEFT_CENTER, ic, ifont(14.0), if on { pal.hilite } else { pal.ink_3 });
    p.text(rect.left_center() + egui::vec2(30.0, 0.0), egui::Align2::LEFT_CENTER, label, font(T_BODY), col);
    let mut right = rect.right() - 8.0;
    if !key.is_empty() {
        let g = p.layout_no_wrap(key.to_string(), font(T_CAPTION), pal.ink_3);
        right -= g.size().x;
        p.galley(egui::pos2(right, rect.center().y - g.size().y / 2.0), g, pal.ink_3);
        right -= 10.0;
    }
    if !trailing.is_empty() {
        p.text(egui::pos2(right, rect.center().y), egui::Align2::RIGHT_CENTER, trailing, font(T_SMALL), pal.ink_3);
    }
    resp.on_hover_cursor(egui::CursorIcon::PointingHand).clicked()
}

/// Fold-out section header: chevron, title, summary at the right (`tip`: more about it on hover), the key that
/// toggles it. Returns the new open state.
pub fn fold(ui: &mut egui::Ui, title_text: &str, summary: &str, tip: &str, key: &str, open: bool) -> bool {
    let pal = pal();
    let w = ui.available_width();
    let (rect, resp) = ui.allocate_exact_size(egui::vec2(w, 32.0), Sense::click());
    let p = ui.painter();
    if resp.hovered() {
        p.rect_filled(rect.shrink2(egui::vec2(0.0, 3.0)), radius_sm(), pal.hover);
    }
    let chev = if open { icon::CARET_DOWN } else { icon::CARET_RIGHT };
    p.text(rect.left_center() + egui::vec2(6.0, 0.0), egui::Align2::LEFT_CENTER, chev, ifont(11.0), pal.ink_3);
    p.text(rect.left_center() + egui::vec2(22.0, 0.0), egui::Align2::LEFT_CENTER, title_text, font_sb(T_BODY), pal.ink);
    let mut right = rect.right() - 6.0;
    if !key.is_empty() {
        let g = p.layout_no_wrap(key.to_string(), font(T_CAPTION), pal.ink_3);
        right -= g.size().x;
        p.galley(egui::pos2(right, rect.center().y - g.size().y / 2.0), g, pal.ink_3);
        right -= 10.0;
    }
    if !summary.is_empty() {
        p.text(egui::pos2(right, rect.center().y), egui::Align2::RIGHT_CENTER, summary, font(T_SMALL), pal.ink_3);
    }
    let resp = resp.on_hover_cursor(egui::CursorIcon::PointingHand);
    let resp = if tip.is_empty() { resp } else { resp.on_hover_text(tip) };
    if resp.clicked() {
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
    ui.painter().hline((r.left() + inset)..=(r.right() - inset), r.center().y, Stroke::new(1.0_f32, pal().border));
}

/// Caret for combo boxes (instead of egui's filled triangle).
pub fn caret(ui: &egui::Ui, rect: Rect, _v: &egui::style::WidgetVisuals, open: bool) {
    let ic = if open { icon::CARET_UP } else { icon::CARET_DOWN };
    ui.painter().text(rect.center(), egui::Align2::CENTER_CENTER, ic, ifont(11.0), pal().ink_3);
}

/// Single-line text, truncated with an ellipsis to `max_w`.
pub fn galley_trunc(ui: &egui::Ui, text: &str, f: FontId, col: Color32, max_w: f32) -> Arc<egui::Galley> {
    let mut job = egui::text::LayoutJob::simple_singleline(text.to_string(), f, col);
    job.wrap = egui::text::TextWrapping::truncate_at_width(max_w.max(1.0));
    ui.painter().layout_job(job)
}

/// A search field with a leading magnifier; `/` focuses it.
pub fn search(ui: &mut egui::Ui, text: &mut String, hint: &str, w: f32) -> egui::Response {
    let id = ui.id().with(("search", hint));
    let r = ui.add(egui::TextEdit::singleline(text).id(id).hint_text(RichText::new(hint).color(pal().ink_3)).desired_width(w - 34.0 - 2.0).margin(egui::Margin { left: 24, right: 8, top: 5, bottom: 5 }).vertical_align(egui::Align::Center));
    ui.painter().text(r.rect.left_center() + egui::vec2(8.0, 0.0), egui::Align2::LEFT_CENTER, icon::MAGNIFYING_GLASS, ifont(12.0), pal().ink_3);
    if nav::take_search() {
        r.request_focus();
    }
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

/// A model's name for compact places (cards, the device header): without the output mode Apple appends
/// ("Apple TV 4K (3rd generation) (at 1080p)" -> "Apple TV 4K (3rd gen)"). The full name stays in hover text.
pub fn short_model(model: &str) -> String {
    let mut s = model.to_string();
    while let Some(a) = s.find(" (at ") {
        match s[a..].find(')') {
            Some(b) => s.replace_range(a..a + b + 1, ""),
            None => break,
        }
    }
    s.replace(" generation)", " gen)")
}

/// A device named after its model ("iPhone Duo") doesn't repeat the model next to its name.
pub fn same_name(name: &str, model: &str) -> bool {
    name.trim().eq_ignore_ascii_case(model.trim()) || name.trim().eq_ignore_ascii_case(short_model(model).trim())
}

/// "iPhone 17 · iOS 27.2": the line under (or beside) a device's name.
pub fn device_line(name: &str, model: &str, version: &str) -> String {
    if same_name(name, model) {
        version.to_string()
    } else {
        format!("{} · {version}", short_model(model))
    }
}

/// Label and colour of a phone's state.
pub fn phase_look(phase: x86sim_core::instance::Phase, runtime_present: bool) -> (&'static str, Color32) {
    use x86sim_core::instance::Phase;
    let p = pal();
    match phase {
        Phase::Running => ("Running", p.good),
        Phase::Starting => ("Starting", p.warn),
        Phase::Stopping => ("Stopping", p.orange),
        Phase::Off if !runtime_present => ("Version not installed", p.magenta),
        Phase::Off => ("Off", p.ink_3),
    }
}

/// The frame of every modal dialog: flat, Hyprland's active border, no shadow.
pub fn modal_frame() -> egui::Frame {
    let p = pal();
    egui::Frame::new().fill(p.popup).stroke(Stroke::new(1.0_f32, p.popup_border)).corner_radius(radius()).inner_margin(20)
}

/// A modal with the theme's scrim behind it.
pub fn modal(id: &'static str) -> egui::Modal {
    egui::Modal::new(egui::Id::new(id)).backdrop_color(pal().scrim).frame(modal_frame())
}

/// A menu row: icon, label, optional shortcut hint on the right. Returns true when clicked.
pub fn menu_row(ui: &mut egui::Ui, ic: &str, label: &str, hint: &str, enabled: bool, danger: bool) -> egui::Response {
    let pal = pal();
    let w = ui.available_width().max(200.0);
    let (r, resp) = ui.allocate_exact_size(egui::vec2(w, 26.0), if enabled { Sense::click() } else { Sense::hover() });
    let p = ui.painter();
    let hot = enabled && resp.hovered();
    if hot {
        p.rect_filled(r, radius_sm(), pal.hilite_fill);
    }
    let col = if !enabled { pal.ink_3 } else if danger { pal.crit_ink } else if hot { pal.hilite } else { pal.ink };
    p.text(r.left_center() + egui::vec2(8.0, 0.0), egui::Align2::LEFT_CENTER, ic, ifont(13.0), if enabled && !danger { pal.ink_2 } else { col });
    p.text(r.left_center() + egui::vec2(30.0, 0.0), egui::Align2::LEFT_CENTER, label, font(T_BODY), col);
    if !hint.is_empty() {
        p.text(r.right_center() - egui::vec2(8.0, 0.0), egui::Align2::RIGHT_CENTER, hint, font(T_CAPTION), pal.ink_3);
    }
    if enabled {
        resp.on_hover_cursor(egui::CursorIcon::PointingHand)
    } else {
        resp
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compact_model_names() {
        assert_eq!(short_model("Apple TV 4K (3rd generation) (at 1080p)"), "Apple TV 4K (3rd gen)");
        assert_eq!(short_model("Apple Watch Series 11 (46mm)"), "Apple Watch Series 11 (46mm)");
        assert_eq!(short_model("iPhone 18 Pro"), "iPhone 18 Pro");
        assert_eq!(device_line("apple-tv", "Apple TV 4K (3rd generation) (at 1080p)", "tvOS 27.2"), "Apple TV 4K (3rd gen) · tvOS 27.2");
        assert_eq!(device_line("iPhone Duo", "iPhone Duo", "iOS 27.2"), "iOS 27.2");
    }

    #[test]
    fn monochrome_theme_stays_readable() {
        // Omarchy's "solitude": greys for red and green, a dark "muted"; every text role and status colour must read
        let mut t = omarchy::Theme::default();
        for (k, v) in [("background", "#101315"), ("dark_background", "#0c0e10"), ("darker_background", "#080a0b"), ("foreground", "#cacccc"), ("accent", "#798186"), ("red", "#565d60"), ("bright_red", "#de6145"), ("yellow", "#d9dbdc"), ("green", "#9fa5a9"), ("bright_green", "#343d41"), ("selection", "#343d41"), ("active_border_color", "#a8adb0")] {
            t.colors.insert(k.into(), v.into());
        }
        let p = Palette::from_theme(&t, 6);
        for c in [p.ink, p.ink_2, p.ink_3, p.accent_ink, p.crit_ink] {
            assert!(contrast(c, p.canvas) >= 4.0, "{c:?}");
        }
        for c in [p.good, p.warn, p.crit, p.blue, p.cyan, p.magenta, p.orange, p.hilite] {
            assert!(contrast(c, p.canvas) >= 3.0, "{c:?}");
        }
        assert_eq!(p.crit, rgb(0xde6145));
        assert_eq!(p.radius, 6);
        assert_eq!(Palette::default_dark().radius, 6);
    }

    #[test]
    fn built_in_looks_are_readable() {
        for (p, light) in [(Palette::default_dark(), false), (Palette::default_light(), true)] {
            assert_eq!(p.light, light);
            for c in [p.ink, p.ink_2, p.ink_3, p.accent_ink, p.crit_ink] {
                assert!(contrast(c, p.canvas) >= 4.0, "{c:?} on {:?}", p.canvas);
            }
            for c in [p.good, p.warn, p.crit, p.accent, p.blue, p.cyan, p.magenta, p.orange, p.hilite] {
                assert!(contrast(c, p.canvas) >= 3.0, "{c:?} on {:?}", p.canvas);
            }
        }
        assert_eq!(Appearance::parse("light"), Appearance::Light);
        assert_eq!(Appearance::parse(""), Appearance::System);
        assert!(Appearance::ALL.iter().all(|a| Appearance::parse(a.key()) == *a));
    }
}
