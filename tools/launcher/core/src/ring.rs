//! Reader for simfb's shared-memory frame ring (layout: cli/libexec/fbring.py). Frames are BGRA; `latest` copies the
//! newest slot and checks its seq afterwards (torn read -> None). `wait` sleeps on the header's seq word with a
//! futex (version-2 rings), so nothing runs while the screen does not change.
use memmap2::{Mmap, MmapMut};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

const HDR: usize = 4096;

pub struct Frame {
    pub w: u32,
    pub h: u32,
    pub stride: u32,
    pub seq: u64,
    pub t_ns: u64,
    pub bgra: Vec<u8>,
}

impl Frame {
    /// The frame upright as an RGB PNG. `rot`: the panel's mounting (as hid::unrotate; the viewer's convert turns it
    /// the same way): 270 = shown a quarter clockwise, 90 = counter-clockwise.
    pub fn png(&self, rot: u32) -> anyhow::Result<Vec<u8>> {
        let (w, h, s) = (self.w as usize, self.h as usize, self.stride as usize);
        let px = |x: usize, y: usize| {
            let o = y * s + x * 4;
            [self.bgra[o + 2], self.bgra[o + 1], self.bgra[o]]
        };
        let (ow, oh) = if rot % 180 == 90 { (h, w) } else { (w, h) };
        let mut rgb = Vec::with_capacity(ow * oh * 3);
        for yo in 0..oh {
            for xo in 0..ow {
                rgb.extend_from_slice(&match rot % 360 {
                    270 => px(yo, h - 1 - xo),
                    90 => px(w - 1 - yo, xo),
                    180 => px(w - 1 - xo, h - 1 - yo),
                    _ => px(xo, yo),
                });
            }
        }
        let mut out = Vec::new();
        {
            let mut e = png::Encoder::new(&mut out, ow as u32, oh as u32);
            e.set_color(png::ColorType::Rgb);
            e.set_depth(png::BitDepth::Eight);
            e.write_header()?.write_image_data(&rgb)?;
        }
        Ok(out)
    }
}

pub struct Ring {
    pub path: PathBuf,
    mm: Option<Mmap>,
    ino: Option<(u64, u64)>,
    fx: Option<MmapMut>,
}

fn u32_at(b: &[u8], o: usize) -> u32 {
    u32::from_le_bytes(b[o..o + 4].try_into().unwrap())
}
fn u64_at(b: &[u8], o: usize) -> u64 {
    u64::from_le_bytes(b[o..o + 8].try_into().unwrap())
}

impl Ring {
    pub fn new(path: &Path) -> Ring {
        Ring { path: path.to_path_buf(), mm: None, ino: None, fx: None }
    }

    fn open(&mut self) -> bool {
        use std::os::unix::fs::MetadataExt;
        let Ok(st) = std::fs::metadata(&self.path) else {
            self.mm = None;
            return false;
        };
        let key = (st.dev(), st.ino());
        if let Some(mm) = &self.mm {
            if self.ino == Some(key) && mm.len() as u64 == st.len() {
                return true;
            }
        }
        if st.len() < HDR as u64 {
            return false;
        }
        let Ok(f) = std::fs::File::open(&self.path) else { return false };
        let Ok(mm) = (unsafe { Mmap::map(&f) }) else { return false };
        self.mm = Some(mm);
        self.ino = Some(key);
        self.fx = None;
        true
    }

    pub fn seq(&mut self) -> u64 {
        if !self.open() {
            return 0;
        }
        let mm = self.mm.as_ref().unwrap();
        if &mm[..4] != b"SFBR" {
            return 0;
        }
        u64_at(mm, 32)
    }

    pub fn size(&mut self) -> Option<(u32, u32)> {
        if !self.open() {
            return None;
        }
        let mm = self.mm.as_ref().unwrap();
        (&mm[..4] == b"SFBR").then(|| (u32_at(mm, 16), u32_at(mm, 20)))
    }

    pub fn latest(&mut self) -> Option<Frame> {
        if !self.open() {
            return None;
        }
        let mm = self.mm.as_ref().unwrap();
        if &mm[..4] != b"SFBR" {
            return None;
        }
        let nslots = u32_at(mm, 8) as usize;
        let slot_bytes = u32_at(mm, 12) as usize;
        for _ in 0..4 {
            let seq = u64_at(mm, 32);
            let latest = u32_at(mm, 40) as usize;
            if seq == 0 || latest >= nslots {
                return None;
            }
            let o = 64 + 32 * latest;
            let sseq = u64_at(mm, o);
            let t_ns = u64_at(mm, o + 8);
            let (w, h, stride) = (u32_at(mm, o + 16), u32_at(mm, o + 20), u32_at(mm, o + 24));
            if sseq == 0 || (stride as usize) * (h as usize) > slot_bytes {
                continue;
            }
            let base = HDR + latest * slot_bytes;
            let end = base + stride as usize * h as usize;
            if end > mm.len() {
                return None;
            }
            let bgra = mm[base..end].to_vec();
            if u64_at(mm, o) == sseq {
                return Some(Frame { w, h, stride, seq: sseq, t_ns, bgra });
            }
        }
        None
    }

    /// Blocks until seq differs from `seq`, the ring is recreated, or `timeout` passes.
    pub fn wait(&mut self, seq: u64, timeout: Duration) -> u64 {
        let end = Instant::now() + timeout;
        loop {
            let cur = self.seq();
            if cur != seq || self.mm.is_none() {
                return cur;
            }
            let left = end.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return cur;
            }
            let v2 = self.mm.as_ref().map(|m| u32_at(m, 4) >= 2).unwrap_or(false);
            if !v2 || !self.futex_wait(cur, left.min(Duration::from_secs(1))) {
                std::thread::sleep(left.min(Duration::from_millis(4)));
            }
        }
    }

    fn futex_wait(&mut self, seq: u64, d: Duration) -> bool {
        if self.fx.is_none() {
            let Ok(f) = std::fs::OpenOptions::new().read(true).write(true).open(&self.path) else { return false };
            let Ok(m) = (unsafe { memmap2::MmapOptions::new().len(HDR).map_mut(&f) }) else { return false };
            self.fx = Some(m);
        }
        let fx = self.fx.as_mut().unwrap();
        let addr = unsafe { fx.as_mut_ptr().add(32) } as *mut u32;
        let ts = libc::timespec { tv_sec: d.as_secs() as libc::time_t, tv_nsec: d.subsec_nanos() as libc::c_long };
        unsafe {
            libc::syscall(libc::SYS_futex, addr, 0 as libc::c_int /* FUTEX_WAIT */, (seq & 0xffff_ffff) as u32, &ts as *const libc::timespec, std::ptr::null::<u32>(), 0u32);
        }
        true
    }

    /// framecheck.py's home test on the newest frame published after `after_unix_s`: not the boot logo (~98% dark)
    /// and either colourful wallpaper (mean saturation > 25) or enough bright pixels (icons/dock, > 5%).
    /// `tvos`: the tvOS home is a dim, grey shelf (almost no saturation or bright pixels), told from the black boot
    /// screen with its white logo by its share of dark pixels alone.
    pub fn home_frame(&mut self, after_unix_s: f64, tvos: bool) -> bool {
        let Some(f) = self.latest() else { return false };
        if (f.t_ns as f64) / 1e9 < after_unix_s {
            return false;
        }
        let (gw, gh) = (118usize, 256usize);
        let (mut dark, mut bright, mut sat_sum, mut n) = (0usize, 0usize, 0f64, 0usize);
        for gy in 0..gh {
            let y = gy * f.h as usize / gh;
            for gx in 0..gw {
                let x = gx * f.w as usize / gw;
                let o = y * f.stride as usize + x * 4;
                let (b, g, r) = (f.bgra[o] as f64, f.bgra[o + 1] as f64, f.bgra[o + 2] as f64);
                let luma = 0.299 * r + 0.587 * g + 0.114 * b;
                if luma < 30.0 {
                    dark += 1;
                }
                if luma > 200.0 {
                    bright += 1;
                }
                let mx = r.max(g).max(b);
                let mn = r.min(g).min(b);
                sat_sum += if mx > 0.0 { (mx - mn) / mx * 255.0 } else { 0.0 };
                n += 1;
            }
        }
        let n = n.max(1) as f64;
        let dark_f = dark as f64 / n;
        if tvos {
            return dark_f < 0.9;
        }
        dark_f < 0.98 && (sat_sum / n > 25.0 || bright as f64 / n > 0.05)
    }
}

#[cfg(test)]
mod tests {
    use super::Frame;

    fn decode(png: &[u8]) -> (u32, u32, Vec<u8>) {
        let mut r = png::Decoder::new(std::io::Cursor::new(png)).read_info().unwrap();
        let mut buf = vec![0; r.output_buffer_size().unwrap()];
        let info = r.next_frame(&mut buf).unwrap();
        (info.width, info.height, buf[..info.buffer_size()].to_vec())
    }

    #[test]
    fn png_upright_and_rotated() {
        // 2x1 BGRA, stride 12 (padding): left pixel red, right pixel blue
        let f = Frame { w: 2, h: 1, stride: 12, seq: 1, t_ns: 0, bgra: vec![0, 0, 255, 255, 255, 0, 0, 255, 9, 9, 9, 9] };
        assert_eq!(decode(&f.png(0).unwrap()), (2, 1, vec![255, 0, 0, 0, 0, 255]));
        // 270 (the viewer's convert): framebuffer x runs down the picture
        assert_eq!(decode(&f.png(270).unwrap()), (1, 2, vec![255, 0, 0, 0, 0, 255]));
        assert_eq!(decode(&f.png(90).unwrap()), (1, 2, vec![0, 0, 255, 255, 0, 0]));
        assert_eq!(decode(&f.png(180).unwrap()), (2, 1, vec![0, 0, 255, 255, 0, 0]));
    }
}
