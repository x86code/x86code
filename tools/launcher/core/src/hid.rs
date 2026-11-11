//! Input to a phone: host/simhid's socket (<device>/data/simhid.sock), one text command per line (touch, touch2,
//! key, button, crown, usage, hinge). Edge touches are marked as Apple's Simulator does (simview.py's rule: within 4% of the width of an
//! edge; top and bottom win in the corners), so the home indicator and Control/Notification Center work.
use std::io::Write;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::Duration;

pub struct Hid {
    path: PathBuf,
    sock: Option<UnixStream>,
    /// Models 2: touches go to another display: (SFB display id, its native rotation); x, y given upright
    pub display: Option<(u32, u32)>,
}

/// Upright normalized (x, y) on a panel mounted at `rot` degrees -> the panel's framebuffer coordinates
/// (270: the framebuffer is shown turned a quarter clockwise, so its x runs down the picture and y right to left)
pub fn unrotate(x: f32, y: f32, rot: u32) -> (f32, f32) {
    match rot % 360 {
        270 => (y, 1.0 - x),
        90 => (1.0 - y, x),
        180 => (1.0 - x, 1.0 - y),
        _ => (x, y),
    }
}

fn unrotate_edge(e: &str, rot: u32) -> &str {
    const E: [&str; 4] = ["top", "right", "bottom", "left"];
    let Some(i) = E.iter().position(|n| *n == e) else { return e };
    // 270: upright top = panel left, upright right = panel top (the inverse of unrotate)
    E[(i + (rot % 360 / 90) as usize) % 4]
}

impl Hid {
    pub fn new(path: &Path) -> Hid {
        Hid { path: path.to_path_buf(), sock: None, display: None }
    }

    pub fn send(&mut self, line: &str) {
        static DEBUG: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
        if *DEBUG.get_or_init(|| std::env::var_os("X86SIM_HID_DEBUG").is_some()) {
            eprintln!("hid {}: {line}", self.path.display());
        }
        for _ in 0..2 {
            if self.sock.is_none() {
                // a device path too long for sun_path is a symlink to a short socket (host/simhid listen_thread)
                let path = std::fs::canonicalize(&self.path).unwrap_or_else(|_| self.path.clone());
                match UnixStream::connect(&path) {
                    Ok(mut s) => {
                        let _ = s.set_write_timeout(Some(Duration::from_millis(500)));
                        // a human types with pauses: keep simhid's on-demand keyboard attached for 5 min after this
                        // client's last key (default 30 s, then the next key pays a re-attach + 1.5 s settle).
                        // X86SIM_VIEWER_KB_IDLE_S overrides; older simhids log it as an unknown command.
                        let idle = std::env::var("X86SIM_VIEWER_KB_IDLE_S").ok().and_then(|v| v.parse::<i64>().ok()).unwrap_or(300);
                        let _ = s.write_all(format!("kbidle {idle}\n").as_bytes());
                        self.sock = Some(s);
                    }
                    Err(_) => return,
                }
            }
            if self.sock.as_mut().unwrap().write_all(format!("{line}\n").as_bytes()).is_ok() {
                return;
            }
            self.sock = None;
        }
    }

    /// x, y normalized 0..1; screen (w, h) in device pixels for the edge rule
    pub fn touch(&mut self, phase: &str, x: f32, y: f32, edge: Option<&str>) {
        let (x, y) = (x.clamp(0.0, 1.0), y.clamp(0.0, 1.0));
        let (pre, (x, y), edge) = match self.display {
            Some((id, rot)) => (format!("@{id} "), unrotate(x, y, rot), edge.map(|e| unrotate_edge(e, rot))),
            None => (String::new(), (x, y), edge),
        };
        match edge {
            Some(e) => self.send(&format!("{pre}touch {phase} {x:.5} {y:.5} {e}")),
            None => self.send(&format!("{pre}touch {phase} {x:.5} {y:.5}")),
        }
    }

    pub fn touch2(&mut self, phase: &str, x1: f32, y1: f32, x2: f32, y2: f32) {
        let c = |v: f32| v.clamp(0.0, 1.0);
        let (pre, (x1, y1), (x2, y2)) = match self.display {
            Some((id, rot)) => (format!("@{id} "), unrotate(c(x1), c(y1), rot), unrotate(c(x2), c(y2), rot)),
            None => (String::new(), (c(x1), c(y1)), (c(x2), c(y2))),
        };
        self.send(&format!("{pre}touch2 {phase} {x1:.5} {y1:.5} {x2:.5} {y2:.5}"));
    }

    /// Models 2: the hinge of a two-screen phone, degrees (0 folded .. 180 flat), moved over `ms`
    pub fn hinge(&mut self, deg: f64, ms: u32) {
        self.send(&format!("hinge {deg:.1} {ms}"));
    }

    /// Platforms 1: turns an Apple Watch's Digital Crown by `delta` (positive: towards the bottom), host/simhid "crown"
    pub fn crown(&mut self, delta: f32) {
        self.send(&format!("crown {delta:.2} y"));
    }

    pub fn key(&mut self, down: bool, usage: u32) {
        self.send(&format!("key {} {usage}", if down { "down" } else { "up" }));
    }

    /// Platforms 1: any page / usage on the buttons service (host/simhid "usage"), for buttons simhid has no name for
    pub fn usage(&mut self, page: u32, usage: u32, down: bool) {
        self.send(&format!("usage {page:#x} {usage:#x} {}", if down { "down" } else { "up" }));
    }

    pub fn button(&mut self, name: &str, down: bool) {
        self.send(&format!("button {name} {}", if down { "down" } else { "up" }));
    }

    pub fn press(&mut self, name: &str) {
        self.button(name, true);
        std::thread::sleep(Duration::from_millis(80));
        self.button(name, false);
    }

    /// Holds a button for `ms` without blocking the caller: its own connection on a thread (the side button held
    /// 2.5 s is Siri, as tests/arm64/gate/gate.sh presses it).
    pub fn hold(&self, name: &str, ms: u64) {
        let (path, name) = (self.path.clone(), name.to_string());
        std::thread::spawn(move || {
            let mut h = Hid::new(&path);
            h.button(&name, true);
            std::thread::sleep(Duration::from_millis(ms));
            h.button(&name, false);
        });
    }
}

/// The edge a touch at normalized (x, y) begins on, for a screen of w x h device pixels.
pub fn edge_at(x: f32, y: f32, w: u32, h: u32) -> Option<&'static str> {
    let mx = 0.04;
    let my = 0.04 * w as f32 / h.max(1) as f32;
    if y >= 1.0 - my {
        Some("bottom")
    } else if y <= my {
        Some("top")
    } else if x <= mx {
        Some("left")
    } else if x >= 1.0 - mx {
        Some("right")
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn inner_screen_touch_mapping() {
        // iPhone Duo inner screen (nativeRotation 270): Settings drawn upright at (0.803, 0.291) was tapped with
        // "@3 touch ... 0.291 0.197" on the framebuffer (Models 2)
        let (x, y) = unrotate(0.803, 0.291, 270);
        assert!((x - 0.291).abs() < 1e-6 && (y - 0.197).abs() < 1e-3);
        assert_eq!(unrotate(0.3, 0.4, 0), (0.3, 0.4));
        // upright top / right / bottom / left of a 270 panel = its left / top / right / bottom
        assert_eq!(unrotate_edge("top", 270), "left");
        assert_eq!(unrotate_edge("right", 270), "top");
        assert_eq!(unrotate_edge("bottom", 270), "right");
        assert_eq!(unrotate_edge("left", 270), "bottom");
        assert_eq!(unrotate_edge("bottom", 0), "bottom");
    }

    #[test]
    fn long_socket_path_is_followed() {
        // simhid links a device path too long for sun_path to a short socket: connect through the link
        use std::io::BufRead;
        let t = std::env::temp_dir().join(format!("x86sim-hid-{}", std::process::id()));
        let dir = t.join("d".repeat(60)).join("e".repeat(60)).join("data");
        std::fs::create_dir_all(&dir).unwrap();
        let short = t.join("s.sock");
        let link = dir.join("simhid.sock");
        assert!(link.as_os_str().len() > 108);
        let l = std::os::unix::net::UnixListener::bind(&short).unwrap();
        std::os::unix::fs::symlink(&short, &link).unwrap();
        Hid::new(&link).send("touch down 0.5 0.5");
        let (c, _) = l.accept().unwrap();
        let lines: Vec<String> = std::io::BufReader::new(c).lines().take(2).map(|l| l.unwrap()).collect();
        assert!(lines[0].starts_with("kbidle "));
        assert_eq!(lines[1], "touch down 0.5 0.5");
        std::fs::remove_dir_all(&t).unwrap();
    }
}
