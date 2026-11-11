//! Cache keys. Mirrors linux/arm64jit/jitcache.cpp: the image is `<cache uuid>-<build>.aot` with
//! build = CODEGEN_VERSION | code-shaping flags << 16 | FNV-1a(placement.txt) << 32. A chunk's key covers only what its
//! translated code depends on: the library's identity (UUID or size+mtime), its load address, CODEGEN_VERSION and the
//! flags. libarm64jit's build-id is not part of either: a translator rebuild that leaves codegen alone keeps
//! everything.
use std::path::{Path, PathBuf};

/// Fallback only: kCodegenVersion when neither the installed libarm64jit.so nor jitcache.cpp can be read. Everything
/// asks `codegen()`, which reads the value from the translator itself, so a launcher built against an older value can't
/// disagree with the builder (it once showed 0x16 parts as stale while the builder and the image were 0x17).
pub const CODEGEN_VERSION: u64 = 0x1d;
/// inline objc (bit 17) and the Apple timebase (bit 18), the defaults; fuse_svc (bit 16) and the strict exclusive
/// monitor (bit 19) and the inline memory address check (bit 20, X86SIM_A64_MEMCHECK=1) are off.
pub const FLAGS: u64 = 0x6 << 16;
/// FLAGS plus the code-shaping flags set in the environment (inherited by the builder): X86SIM_A64_MEMCHECK=1 (bit
/// 20) builds and names an image with the inline memory address check, for A/B against the default.
pub fn flags() -> u64 {
    let memcheck = std::env::var("X86SIM_A64_MEMCHECK").map(|v| v.trim() == "1").unwrap_or(false);
    FLAGS | (memcheck as u64) << 20
}

/// The installed translator (what boots and what the builder runs).
pub fn translator() -> PathBuf {
    crate::aot::repo_root().join("darling-prefix/libexec/darling/usr/libexec/darling/libarm64jit.so")
}

/// Where the codegen version came from, for status lines.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
pub enum CodegenSource {
    /// read from the installed libarm64jit.so (its g_build's initial value)
    Translator,
    /// kCodegenVersion in linux/arm64jit/jitcache.cpp (no readable translator)
    Source,
    /// compiled into this program
    Builtin,
}

/// kCodegenVersion of the installed translator. Read from libarm64jit.so's `g_build` (initialised to
/// kCodegenVersion in .data); re-read when the file changes. Falls back to jitcache.cpp, then the compiled value.
pub fn codegen() -> u64 {
    codegen_info().0
}

pub fn codegen_info() -> (u64, CodegenSource) {
    use std::os::unix::fs::MetadataExt;
    /// the translator file's (size, mtime, inode) and what was read from it
    type Cached = ((u64, i64, u64), u64, CodegenSource);
    static CACHE: std::sync::Mutex<Option<Cached>> = std::sync::Mutex::new(None);
    let so = translator();
    let stamp = std::fs::metadata(&so).map(|m| (m.size(), m.mtime(), m.ino())).unwrap_or_default();
    let mut c = CACHE.lock().unwrap_or_else(|e| e.into_inner());
    if let Some((s, v, src)) = *c {
        if s == stamp {
            return (v, src);
        }
    }
    let (v, src) = match elf_codegen(&so) {
        Some(v) => (v, CodegenSource::Translator),
        None => match source_codegen() {
            Some(v) => (v, CodegenSource::Source),
            None => (CODEGEN_VERSION, CodegenSource::Builtin),
        },
    };
    *c = Some((stamp, v, src));
    (v, src)
}

fn source_codegen() -> Option<u64> {
    let s = std::fs::read_to_string(crate::aot::repo_root().join("linux/arm64jit/jitcache.cpp")).ok()?;
    let l = s.lines().find(|l| l.trim_start().starts_with("constexpr u64 kCodegenVersion"))?;
    let v = l.split('=').nth(1)?.split(';').next()?.trim().trim_end_matches("ull").trim_end_matches("ULL");
    u64::from_str_radix(v.trim_start_matches("0x"), 16).ok().map(|v| v & 0xffff)
}

/// g_build's initial value in an ELF64 libarm64jit.so (symbol a64::(anonymous)::g_build in .symtab)
fn elf_codegen(path: &Path) -> Option<u64> {
    let f = std::fs::File::open(path).ok()?;
    let b = unsafe { memmap2::Mmap::map(&f).ok()? };
    if b.len() < 64 || &b[..4] != b"\x7fELF" || b[4] != 2 || b[5] != 1 {
        return None;
    }
    let u16_at = |o: usize| -> Option<u64> { Some(u16::from_le_bytes(b.get(o..o + 2)?.try_into().ok()?) as u64) };
    let u32_at = |o: usize| -> Option<u64> { Some(u32::from_le_bytes(b.get(o..o + 4)?.try_into().ok()?) as u64) };
    let u64_at = |o: usize| -> Option<u64> { Some(u64::from_le_bytes(b.get(o..o + 8)?.try_into().ok()?)) };
    let (shoff, shentsize, shnum) = (u64_at(0x28)? as usize, u16_at(0x3a)? as usize, u16_at(0x3c)? as usize);
    // (type, addr, offset, size, link, entsize)
    let sh = |i: usize| -> Option<(u64, u64, u64, u64, u64, u64)> {
        let o = shoff + i * shentsize;
        Some((u32_at(o + 4)?, u64_at(o + 0x10)?, u64_at(o + 0x18)?, u64_at(o + 0x20)?, u32_at(o + 0x28)?, u64_at(o + 0x38)?))
    };
    for i in 0..shnum {
        let (ty, _, off, size, link, ent) = sh(i)?;
        if ty != 2 || ent < 24 {
            continue; // SHT_SYMTAB
        }
        let (_, _, stroff, strsize, _, _) = sh(link as usize)?;
        let strtab = b.get(stroff as usize..(stroff + strsize) as usize)?;
        for k in 0..(size / ent) as usize {
            let o = off as usize + k * ent as usize;
            let name_off = u32_at(o)? as usize;
            let name = strtab.get(name_off..)?.split(|&c| c == 0).next()?;
            if name != b"_ZN3a6412_GLOBAL__N_17g_buildE" {
                continue;
            }
            let (shndx, value) = (u16_at(o + 6)? as usize, u64_at(o + 8)?);
            let (sty, saddr, soff, _, _, _) = sh(shndx)?;
            if sty == 8 {
                return None; // .bss: no initial value
            }
            return u64_at((soff + value - saddr) as usize).map(|v| v & 0xffff);
        }
    }
    None
}

pub struct Fnv64(u64);
impl Fnv64 {
    pub fn new() -> Self {
        Fnv64(0xcbf2_9ce4_8422_2325)
    }
    pub fn bytes(&mut self, b: &[u8]) {
        for &c in b {
            self.0 = (self.0 ^ c as u64).wrapping_mul(0x100_0000_01b3);
        }
    }
    pub fn str(&mut self, s: &str) {
        self.bytes(s.as_bytes());
        self.bytes(&[0]);
    }
    pub fn u64(&mut self, v: u64) {
        self.bytes(&v.to_le_bytes());
    }
    pub fn finish(&self) -> u64 {
        self.0
    }
}

impl Default for Fnv64 {
    fn default() -> Self {
        Self::new()
    }
}

/// libarm64jit's placement_load hash: FNV-1a (32-bit) over every byte of placement.txt; 0 without a usable table.
pub fn placement_hash(path: &Path) -> u32 {
    let Ok(b) = std::fs::read(path) else { return 0 };
    if crate::discover::read_placement(path).is_empty() {
        return 0;
    }
    let mut h: u32 = 2_166_136_261;
    for &c in &b {
        h = (h ^ c as u32).wrapping_mul(16_777_619);
    }
    h
}

pub fn build_id(placement: &Path) -> u64 {
    codegen() | flags() | (placement_hash(placement) as u64) << 32
}

pub fn image_name(cache_uuid: &str, build: u64) -> String {
    format!("{cache_uuid}-{build:016x}.aot")
}

pub fn chunk_key(name: &str, ident: &str, addr: u64) -> String {
    let mut h = Fnv64::new();
    h.str(name);
    h.str(ident);
    h.u64(addr);
    h.u64(codegen());
    h.u64(flags());
    format!("{:016x}", h.finish())
}

pub fn name_id(name: &str) -> String {
    let mut h = Fnv64::new();
    h.str(name);
    let base = name.rsplit('/').next().unwrap_or(name);
    let clean: String = base.chars().map(|c| if c.is_ascii_alphanumeric() || c == '.' || c == '-' { c } else { '_' }).take(40).collect();
    format!("{clean}.{:08x}", h.finish() as u32)
}
