//! The live Omarchy theme: colours from `~/.local/state/omarchy/current/theme/colors.toml`, the control language
//! (fill and border alphas) from `shell.toml` next to it, the window rounding from Hyprland and the system monospace
//! font from fontconfig. A watcher thread polls the theme's generation file once a second and flags a reload; the
//! window applies it on its next frame, so a theme switch repaints live. Nothing here writes to Omarchy's files.
//! `X86SIM_OMARCHY_THEME_DIR` points the loader at another theme directory (tests: a copy you can edit).
use eframe::egui::Color32;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, SystemTime};

/// Set by the watcher when the theme changed on disk; the window takes it and reloads.
pub static DIRTY: AtomicBool = AtomicBool::new(false);

/// The desktop's colour-scheme preference (freedesktop portal / GNOME `color-scheme`), refreshed by the watcher; used
/// when the windowing system doesn't report one and there is no Omarchy theme.
static PREFERS_LIGHT: AtomicBool = AtomicBool::new(false);

pub fn desktop_prefers_light() -> bool {
    PREFERS_LIGHT.load(Ordering::Relaxed)
}

/// `gsettings get org.gnome.desktop.interface color-scheme`: 'prefer-light' (or 'default' with a light GTK theme
/// name) means light. GNOME, Omarchy and most GTK desktops keep it; anything else counts as dark.
fn read_prefers_light() -> bool {
    let get = |key: &str| {
        std::process::Command::new("gsettings")
            .args(["get", "org.gnome.desktop.interface", key])
            .stderr(std::process::Stdio::null())
            .output()
            .ok()
            .filter(|o| o.status.success())
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().trim_matches('\'').to_lowercase())
    };
    match get("color-scheme").as_deref() {
        Some("prefer-light") => true,
        Some("prefer-dark") => false,
        _ => get("gtk-theme").is_some_and(|t| !t.is_empty() && !t.contains("dark")),
    }
}

/// `colors.toml` as read: every key, plus what `shell.toml` says about controls.
#[derive(Clone, Debug, Default)]
pub struct Theme {
    pub colors: HashMap<String, String>,
    /// `[section] key` -> value (strings without quotes, numbers as written)
    pub shell: HashMap<String, String>,
}

impl Theme {
    pub fn color(&self, key: &str) -> Option<Color32> {
        self.colors.get(key).and_then(|v| parse_color(v))
    }
    pub fn shell_f32(&self, section: &str, key: &str, default: f32) -> f32 {
        self.shell.get(&format!("{section}.{key}")).and_then(|v| v.parse().ok()).unwrap_or(default)
    }
    pub fn shell_color(&self, section: &str, key: &str) -> Option<Color32> {
        self.shell.get(&format!("{section}.{key}")).and_then(|v| parse_color(v))
    }
    pub fn is_light(&self) -> bool {
        self.colors.get("mode").is_some_and(|m| m == "light")
    }
}

/// The theme directory: the override, else Omarchy's current theme.
pub fn theme_dir() -> PathBuf {
    if let Some(d) = std::env::var_os("X86SIM_OMARCHY_THEME_DIR") {
        return PathBuf::from(d);
    }
    state_dir().join("theme")
}

/// `~/.local/state/omarchy/current`: `theme/`, `theme.name`, `theme.generation` (rewritten by every theme switch)
fn state_dir() -> PathBuf {
    let base = std::env::var_os("XDG_STATE_HOME").map(PathBuf::from).unwrap_or_else(|| home().join(".local/state"));
    base.join("omarchy/current")
}

fn home() -> PathBuf {
    std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default()
}

pub fn load() -> Option<Theme> {
    let dir = theme_dir();
    let colors = std::fs::read_to_string(dir.join("colors.toml")).ok()?;
    let shell = std::fs::read_to_string(dir.join("shell.toml")).unwrap_or_default();
    Some(Theme { colors: parse_toml(&colors).into_iter().map(|(k, v)| (k.rsplit('.').next().unwrap_or(&k).to_string(), v)).collect(), shell: parse_toml(&shell) })
}

/// A flat TOML reader for Omarchy's generated files: `[section]` headers and `key = value` lines (strings, numbers,
/// booleans); comments and anything else are skipped. Keys come back as `section.key` (or `key` at the top).
fn parse_toml(s: &str) -> HashMap<String, String> {
    let mut out = HashMap::new();
    let mut section = String::new();
    for line in s.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if let Some(h) = line.strip_prefix('[').and_then(|l| l.strip_suffix(']')) {
            section = h.trim().to_string();
            continue;
        }
        let Some((k, v)) = line.split_once('=') else { continue };
        let k = k.trim();
        let v = v.trim();
        // a quoted string (a comment may follow it), else a bare value up to any comment
        let v = if let Some(rest) = v.strip_prefix('"') {
            rest.split('"').next().unwrap_or("").to_string()
        } else {
            v.split('#').next().unwrap_or("").trim().to_string()
        };
        let key = if section.is_empty() { k.to_string() } else { format!("{section}.{k}") };
        out.insert(key, v);
    }
    out
}

/// "#rrggbb", "#rrggbbaa", "rgb(rrggbb)", "rgba(rrggbbaa)"; a gradient ("rgba(..) rgba(..)") gives its first stop.
pub fn parse_color(v: &str) -> Option<Color32> {
    let v = v.trim();
    let hex = if let Some(h) = v.strip_prefix('#') {
        h.split_whitespace().next()?
    } else if let Some(r) = v.strip_prefix("rgba(").or_else(|| v.strip_prefix("rgb(")) {
        r.split(')').next()?.trim()
    } else {
        return None;
    };
    let n = u32::from_str_radix(hex, 16).ok()?;
    match hex.len() {
        6 => Some(Color32::from_rgb((n >> 16) as u8, (n >> 8) as u8, n as u8)),
        8 => Some(Color32::from_rgba_unmultiplied((n >> 24) as u8, (n >> 16) as u8, (n >> 8) as u8, n as u8)),
        _ => None,
    }
}

/// Hyprland's window rounding (`decoration:rounding`); None when hyprctl isn't there.
pub fn rounding() -> Option<u8> {
    let out = std::process::Command::new("hyprctl").args(["getoption", "decoration:rounding", "-j"]).output().ok()?;
    if !out.status.success() {
        return None;
    }
    let s = String::from_utf8_lossy(&out.stdout);
    let i = s.find("\"int\"")?;
    let rest = &s[i + 5..];
    let digits: String = rest.chars().skip_while(|c| !c.is_ascii_digit()).take_while(|c| c.is_ascii_digit()).collect();
    digits.parse::<u32>().ok().map(|n| n.min(32) as u8)
}

/// The system monospace font's files (regular, bold), as fontconfig resolves "monospace" (what omarchy-font-current
/// reports). None when fontconfig isn't there or resolves to nothing usable.
pub fn mono_font() -> Option<(PathBuf, Option<PathBuf>)> {
    let family = fc(&["monospace", "-f", "%{family}"])?;
    let family = family.split(',').next()?.trim().to_string();
    if family.is_empty() {
        return None;
    }
    let regular = PathBuf::from(fc(&[&family, "-f", "%{file}"])?);
    if !regular.is_file() {
        return None;
    }
    let bold = fc(&[&format!("{family}:bold"), "-f", "%{file}"]).map(PathBuf::from).filter(|p| p.is_file() && p != &regular);
    Some((regular, bold))
}

fn fc(args: &[&str]) -> Option<String> {
    let out = std::process::Command::new("fc-match").args(args).output().ok()?;
    if !out.status.success() {
        return None;
    }
    let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
    (!s.is_empty()).then_some(s)
}

fn mtime(p: &Path) -> Option<SystemTime> {
    std::fs::metadata(p).ok().and_then(|m| m.modified().ok())
}

/// What a theme or font switch touches: the generation and name files beside the theme, the two files read from it,
/// and fontconfig's user configuration (omarchy-font-set).
fn signature() -> Vec<Option<SystemTime>> {
    let dir = theme_dir();
    let parent = dir.parent().map(Path::to_path_buf).unwrap_or_default();
    let fontconf = std::env::var_os("XDG_CONFIG_HOME").map(PathBuf::from).unwrap_or_else(|| home().join(".config")).join("fontconfig/fonts.conf");
    vec![mtime(&parent.join("theme.generation")), mtime(&parent.join("theme.name")), mtime(&dir.join("colors.toml")), mtime(&dir.join("shell.toml")), mtime(&fontconf), std::fs::read_link(&dir).ok().map(|_| SystemTime::UNIX_EPOCH), std::fs::canonicalize(&dir).ok().and_then(|p| mtime(&p))]
}

/// Polls the theme once a second; on a change flags DIRTY and asks for a repaint. A theme switch replaces the files
/// (and the directory's symlink), so the mtimes are enough and no inotify watch has to be re-armed.
pub fn watch(ctx: eframe::egui::Context) {
    std::thread::Builder::new()
        .name("omarchy-theme".into())
        .spawn(move || {
            let mut last = signature();
            PREFERS_LIGHT.store(read_prefers_light(), Ordering::Relaxed);
            let mut tick = 0u32;
            loop {
                std::thread::sleep(Duration::from_secs(1));
                // the desktop preference: a process per read, so every 3 s, and only without an Omarchy theme
                tick += 1;
                if tick % 3 == 0 && !theme_dir().join("colors.toml").exists() {
                    let l = read_prefers_light();
                    if PREFERS_LIGHT.swap(l, Ordering::Relaxed) != l {
                        DIRTY.store(true, Ordering::Release);
                        ctx.request_repaint();
                    }
                }
                let now = signature();
                if now != last {
                    // the switch writes several files in a row: let it finish
                    std::thread::sleep(Duration::from_millis(150));
                    last = signature();
                    DIRTY.store(true, Ordering::Release);
                    ctx.request_repaint();
                }
            }
        })
        .expect("theme watcher");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn toml_and_colours() {
        let t = parse_toml("mode = \"dark\"\n# c\naccent = \"#798186\" # trailing\n[controls]\nnormal-fill-alpha   = 0.04\n");
        assert_eq!(t["mode"], "dark");
        assert_eq!(t["accent"], "#798186");
        assert_eq!(t["controls.normal-fill-alpha"], "0.04");
        assert_eq!(parse_color("#798186"), Some(Color32::from_rgb(0x79, 0x81, 0x86)));
        assert_eq!(parse_color("rgba(798186ee) rgba(caccccee)"), Some(Color32::from_rgba_unmultiplied(0x79, 0x81, 0x86, 0xee)));
        assert_eq!(parse_color("rgb(1e1e1e)"), Some(Color32::from_rgb(0x1e, 0x1e, 0x1e)));
        assert_eq!(parse_color("hyprland.active-border"), None);
    }
}
