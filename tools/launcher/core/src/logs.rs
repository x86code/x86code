//! Live log tail over a phone's logs, grouped into a few sources (each line keeps the process it came from):
//! System (one log per launchd job), Translator (one log per translated process, many per boot), Boot (the boot's
//! state files), Graphics (mtlvk) and Memory (jetsam). First sight shows the last 2 KB of a file, then only what is
//! appended (a truncated file starts over). Files last written before this boot are a past session's and are skipped.
//! Lines are kept in a bounded buffer, newest last.
use std::collections::{HashMap, VecDeque};
use std::io::{Read, Seek, SeekFrom};
use std::path::PathBuf;
use std::time::{Duration, UNIX_EPOCH};

#[derive(Clone, Debug)]
pub struct Line {
    /// the source group ("System", "Translator", …)
    pub group: &'static str,
    /// the process or file the line came from
    pub source: String,
    pub text: String,
}

/// A dir of per-process logs, or one file, and the group its lines belong to.
#[derive(Clone, Debug)]
pub enum Src {
    Dir(&'static str, PathBuf),
    /// group, the tag its lines get, path
    File(&'static str, &'static str, PathBuf),
}

pub const GROUPS: [&str; 5] = ["System", "Translator", "Boot", "Graphics", "Memory"];

pub struct Tail {
    pub srcs: Vec<Src>,
    offs: HashMap<PathBuf, u64>,
    pub lines: VecDeque<Line>,
    pub cap: usize,
    pub generation: u64,
    /// unix seconds: files last modified before this are skipped (a past boot's)
    pub since: Option<f64>,
}

/// "com.apple.SpringBoard.log" -> "SpringBoard", "AegirPoster.1338.log" -> "AegirPoster", "lsim.out" -> "lsim"
fn tag(p: &std::path::Path) -> String {
    let n = p.file_name().unwrap_or_default().to_string_lossy().into_owned();
    let n = n.strip_suffix(".log").or_else(|| n.strip_suffix(".out")).or_else(|| n.strip_suffix(".txt")).unwrap_or(&n).to_string();
    let n = n.strip_prefix("com.apple.").or_else(|| n.strip_prefix("com.x86sim.")).unwrap_or(&n).to_string();
    // a trailing pid
    match n.rsplit_once('.') {
        Some((a, b)) if !a.is_empty() && b.chars().all(|c| c.is_ascii_digit()) => a.to_string(),
        _ => n,
    }
}

impl Tail {
    pub fn new(srcs: Vec<Src>) -> Tail {
        Tail { srcs, offs: HashMap::new(), lines: VecDeque::new(), cap: 6000, generation: 0, since: None }
    }

    /// Reads what is new; returns the number of lines added.
    pub fn poll(&mut self) -> usize {
        let mut paths: Vec<(&'static str, Option<&'static str>, PathBuf)> = vec![];
        for s in &self.srcs {
            match s {
                Src::File(g, t, p) => paths.push((g, Some(t), p.clone())),
                Src::Dir(g, d) => {
                    for e in std::fs::read_dir(d).into_iter().flatten().flatten() {
                        let p = e.path();
                        if p.extension().is_some_and(|x| x == "log" || x == "out" || x == "txt") {
                            paths.push((g, None, p));
                        }
                    }
                }
            }
        }
        let since = self.since.map(|s| UNIX_EPOCH + Duration::from_secs_f64((s - 5.0).max(0.0)));
        let mut added = 0;
        for (group, fixed_tag, p) in paths {
            let Ok(md) = std::fs::metadata(&p) else { continue };
            let known = self.offs.get(&p).copied();
            if known.is_none() {
                if let (Some(s), Ok(m)) = (since, md.modified()) {
                    if m < s {
                        continue; // a past boot's file (checked again next time: it may be written to)
                    }
                }
            }
            let size = md.len();
            let mut o = match known {
                None => size.saturating_sub(2048),
                Some(o) if size < o => 0,
                Some(o) => o,
            };
            if size > o {
                if let Ok(mut f) = std::fs::File::open(&p) {
                    let _ = f.seek(SeekFrom::Start(o));
                    let mut buf = vec![0u8; ((size - o) as usize).min(1 << 16)];
                    if let Ok(n) = f.read(&mut buf) {
                        buf.truncate(n);
                        // only whole lines; a partial last line is read next time
                        let end = match buf.iter().rposition(|&c| c == b'\n') {
                            Some(i) => i + 1,
                            None if n >= 1 << 16 => n, // one huge line
                            None => 0,
                        };
                        let first_sight = known.is_none() && o > 0;
                        o += end as u64;
                        let t = fixed_tag.map(String::from).unwrap_or_else(|| tag(&p));
                        let s = String::from_utf8_lossy(&buf[..end]);
                        let mut it = s.lines().peekable();
                        if first_sight {
                            it.next(); // a partial first line of the tail
                        }
                        for l in it {
                            if l.trim().is_empty() {
                                continue;
                            }
                            self.lines.push_back(Line { group, source: t.clone(), text: l.to_string() });
                            added += 1;
                        }
                    }
                }
            }
            self.offs.insert(p, o);
        }
        while self.lines.len() > self.cap {
            self.lines.pop_front();
        }
        if added > 0 {
            self.generation += 1;
        }
        added
    }

    /// Groups that have lines, in GROUPS order.
    pub fn groups(&self) -> Vec<&'static str> {
        GROUPS.iter().copied().filter(|g| self.lines.iter().any(|l| l.group == *g)).collect()
    }
}

/// "2026-11-01 07:54:40.355519 rest" -> (Some("07:54:40"), "rest"); also "[07:54:40] rest"
pub fn split_time(text: &str) -> (Option<&str>, &str) {
    let b = text.as_bytes();
    let digits = |r: std::ops::Range<usize>| b.get(r.clone()).is_some_and(|s| s.iter().all(u8::is_ascii_digit));
    if b.len() > 20 && digits(0..4) && b[4] == b'-' && digits(5..7) && b[7] == b'-' && digits(8..10) && b[10] == b' ' && digits(11..13) && b[13] == b':' {
        let end = text[11..].find(' ').map(|i| i + 11).unwrap_or(text.len());
        return (Some(&text[11..19.min(end)]), text[end..].trim_start());
    }
    (None, text)
}
