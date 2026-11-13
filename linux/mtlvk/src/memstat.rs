//! x86Sim RAM 2: where mtlvk's memory goes. `MTLVK_MEMSTATS=<seconds>` prints, every that many seconds, one
//! `mtlvk mem:` line: this process's PSS by mapping kind (from /proc/self/smaps), glibc malloc's own figures
//! (mallinfo2) and the GPU's memory heaps as VK_EXT_memory_budget reports them (this process's usage per heap). It
//! also asks every connection for its object counts (`mtlvk stats:`, the SIGUSR1 line) on its next request.
//!
//! Mapping kinds (MB of PSS):
//!   nvctl-small  /dev/nvidiactl mappings under 4 MB: the driver's own system-memory chunks (command buffer memory,
//!                descriptor/pipeline state, its internal pools)
//!   nvctl-big    /dev/nvidiactl mappings of 4 MB or more: host-visible VkDeviceMemory blocks (system memory)
//!   nvidia0      /dev/nvidia0 mappings (BAR / device-local mapped memory)
//!   arenas       anonymous 64 MB-aligned regions: glibc's per-thread malloc arenas
//!   anon         other anonymous memory (big mallocs over the mmap threshold, the driver's own anonymous maps)
//!   heap         the brk heap (main arena)
//!   memfd        memfd mappings (guest buffers and IOSurfaces imported or mirrored)
//!   lib          file mappings (the binary, NVIDIA's libraries)
use std::collections::BTreeMap;

pub fn smaps_summary() -> String {
    let Ok(s) = std::fs::read_to_string("/proc/self/smaps") else { return String::new() };
    let mut cat: BTreeMap<&'static str, u64> = BTreeMap::new();
    let mut cur: &'static str = "other";
    for l in s.lines() {
        let first = l.split_whitespace().next().unwrap_or("");
        if first.contains('-') && !first.ends_with(':') {
            let mut it = l.split_whitespace();
            let range = it.next().unwrap_or("");
            let _perm = it.next();
            let _off = it.next();
            let _dev = it.next();
            let _ino = it.next();
            let name: String = it.collect::<Vec<_>>().join(" ");
            let (a, b) = range.split_once('-').unwrap_or(("0", "0"));
            let (a, b) = (u64::from_str_radix(a, 16).unwrap_or(0), u64::from_str_radix(b, 16).unwrap_or(0));
            let len = b - a;
            cur = if name.starts_with("/dev/nvidiactl") {
                if len >= 4 << 20 { "nvctl-big" } else { "nvctl-small" }
            } else if name.starts_with("/dev/nvidia") {
                "nvidia0"
            } else if name == "[heap]" {
                "heap"
            } else if name.starts_with("/memfd:") {
                "memfd"
            } else if name.is_empty() {
                if a & ((64 << 20) - 1) == 0 && len <= 64 << 20 && len >= 60 << 20 { "arenas" } else { "anon" }
            } else if name.starts_with('/') {
                "lib"
            } else {
                "other"
            };
        } else if let Some(v) = l.strip_prefix("Pss:") {
            *cat.entry(cur).or_default() += v.trim().trim_end_matches(" kB").trim().parse::<u64>().unwrap_or(0);
        }
    }
    let total: u64 = cat.values().sum();
    let mut out = format!("pss {} MB:", total >> 10);
    for (k, v) in &cat {
        out += &format!(" {k} {}", v >> 10);
    }
    out
}

pub fn malloc_summary() -> String {
    // SAFETY: plain libc query.
    let m = unsafe { libc::mallinfo2() };
    format!("malloc: arena {} MB mmap {} MB in use {} MB free {} MB", m.arena >> 20, m.hblkhd >> 20, m.uordblks >> 20, m.fordblks >> 20)
}

/// VK_EXT_memory_budget: this process's usage and the budget of each memory heap (MB), with the heap's kind.
pub fn budget_summary(device: &metal2vulkan_runtime::Device) -> String {
    use ash::vk;
    // SAFETY: read-only instance query on the device's own physical device.
    unsafe {
        let h = device.raw();
        let exts = h.instance.enumerate_device_extension_properties(h.physical_device).unwrap_or_default();
        let has = exts.iter().any(|e| e.extension_name_as_c_str().map(|n| n == c"VK_EXT_memory_budget").unwrap_or(false));
        if !has {
            return "budget: no VK_EXT_memory_budget".into();
        }
        let mut b = vk::PhysicalDeviceMemoryBudgetPropertiesEXT::default();
        let mut p = vk::PhysicalDeviceMemoryProperties2::default().push_next(&mut b);
        h.instance.get_physical_device_memory_properties2(h.physical_device, &mut p);
        let mp = p.memory_properties;
        let mut out = String::from("budget (usage/budget MB):");
        for i in 0..mp.memory_heap_count as usize {
            let dl = mp.memory_heaps[i].flags.contains(vk::MemoryHeapFlags::DEVICE_LOCAL);
            out += &format!(" heap{i}{} {}/{}", if dl { "(vram)" } else { "(sys)" }, b.heap_usage[i] >> 20, b.heap_budget[i] >> 20);
        }
        out
    }
}

/// Starts the MTLVK_MEMSTATS thread.
pub fn start(device: metal2vulkan_runtime::Device) {
    let Some(secs) = std::env::var("MTLVK_MEMSTATS").ok().and_then(|v| v.parse::<f64>().ok()).filter(|s| *s > 0.0) else { return };
    let _ = std::thread::Builder::new().name("memstats".into()).spawn(move || loop {
        let t = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
        let (pools, primaries, secondaries, descriptors) = device.spare_counts();
        eprintln!(
            "mtlvk mem: t {t} | {} | {} | {} | spares: command pools {pools} (primaries {primaries} secondaries {secondaries}) descriptor pools {descriptors} | {}",
            smaps_summary(),
            malloc_summary(),
            budget_summary(&device),
            device.pipeline_census()
        );
        crate::conn::STATS_REQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        prof_dump_on_request();
        std::thread::sleep(std::time::Duration::from_secs_f64(secs));
    });
}

/// x86Sim RAM 10: with jemalloc preloaded with prof:true, a heap profile now (jemalloc's `prof.dump`) when the file
/// MTLVK_PROF_TRIGGER names exists (removed); checked at each memstats line.
fn prof_dump_on_request() {
    let Some(trigger) = std::env::var_os("MTLVK_PROF_TRIGGER") else { return };
    if std::fs::remove_file(&trigger).is_err() {
        return;
    }
    type Mallctl = unsafe extern "C" fn(*const libc::c_char, *mut libc::c_void, *mut usize, *mut libc::c_void, usize) -> libc::c_int;
    // SAFETY: looking up and calling jemalloc's mallctl with its documented arguments for "prof.dump".
    unsafe {
        let f = libc::dlsym(libc::RTLD_DEFAULT, c"mallctl".as_ptr());
        if f.is_null() {
            eprintln!("mtlvk: MTLVK_PROF_TRIGGER: no mallctl (jemalloc not preloaded)");
            return;
        }
        let f: Mallctl = std::mem::transmute(f);
        let r = f(c"prof.dump".as_ptr(), std::ptr::null_mut(), std::ptr::null_mut(), std::ptr::null_mut(), 0);
        eprintln!("mtlvk: prof.dump {r}");
    }
}

/// x86Sim RAM 14: clean file pages of read-only private mappings (NVIDIA's shader compiler libnvidia-gpucomp ~45 MB,
/// glvkspirv, rtcore, glcore, mtlvk's own text, the other ICDs the loader opened) stay mapped after the burst that
/// touched them, and how much a boot touched varied with what it compiled (fresh home 230-300 MB PSS). After a quiet
/// trim tick (under 3% CPU) with the file RSS grown >= MTLVK_FILETRIM MB (default 8: the ~2 MB an idle frame
/// path maps again each tick stays) since the last trim, their page-table entries are dropped
/// (MADV_DONTNEED: the pages stay in the page cache, a later touch maps them again without I/O). Only mappings with
/// no anonymous (written, copy-on-write) page: relocated RELRO / data pages are never touched. MTLVK_FILETRIM=0 off.
/// A busy tick counts as quiet too once the file RSS has held within 1 MB for STEADY_TICKS ticks (30 s at the default
/// 5 s): visionOS's compositor keeps mtlvk at ~9% CPU rendering every frame, so the CPU test alone never let it trim
/// (NVIDIA's compiler stayed at ~34 MB, mapped once at the boot's pipeline compiles); a steady render loop maps no new
/// file pages, and after a trim it maps its frame path's few MB again.
pub struct FileTrim {
    last_cpu: u64,
    base_kb: u64,
    grow_kb: u64,
    last_kb: u64,
    steady: u32,
}
const STEADY_TICKS: u32 = 6;
fn cpu_ticks() -> u64 {
    let s = std::fs::read_to_string("/proc/self/stat").unwrap_or_default();
    let rest = s.rsplit_once(')').map(|(_, r)| r).unwrap_or("");
    let f: Vec<&str> = rest.split_whitespace().collect();
    // fields after ")": state is index 0, utime 11, stime 12
    f.get(11).and_then(|v| v.parse::<u64>().ok()).unwrap_or(0) + f.get(12).and_then(|v| v.parse::<u64>().ok()).unwrap_or(0)
}
fn rss_file_kb() -> u64 {
    std::fs::read_to_string("/proc/self/status")
        .unwrap_or_default()
        .lines()
        .find_map(|l| l.strip_prefix("RssFile:"))
        .and_then(|v| v.trim().trim_end_matches("kB").trim().parse().ok())
        .unwrap_or(0)
}
impl FileTrim {
    pub fn new(grow_kb: u64) -> Self {
        FileTrim { last_cpu: cpu_ticks(), base_kb: 0, grow_kb, last_kb: 0, steady: 0 }
    }
    /// Returns (RssFile before, after) in KiB when it trimmed.
    pub fn tick(&mut self, secs: f64) -> Option<(u64, u64)> {
        let cpu = cpu_ticks();
        // SAFETY: plain libc call.
        let hz = unsafe { libc::sysconf(libc::_SC_CLK_TCK) }.max(1) as f64;
        let busy = (cpu.saturating_sub(self.last_cpu)) as f64 / hz / secs;
        self.last_cpu = cpu;
        let now = rss_file_kb();
        self.steady = if now.abs_diff(self.last_kb) < 1024 { self.steady + 1 } else { 0 };
        self.last_kb = now;
        if (busy >= 0.03 && self.steady < STEADY_TICKS) || now < self.base_kb + self.grow_kb {
            self.base_kb = self.base_kb.min(now);
            return None;
        }
        trim_file_pages();
        let after = rss_file_kb();
        self.base_kb = after;
        self.last_kb = after;
        self.steady = 0;
        Some((now, after))
    }
}
fn trim_file_pages() {
    let Ok(s) = std::fs::read_to_string("/proc/self/smaps") else { return };
    let mut cur: Option<(usize, usize)> = None;
    let mut rss = 0u64;
    let flush = |cur: Option<(usize, usize)>, rss: u64, anon_zero: bool| {
        if let (Some((a, b)), true, true) = (cur, rss > 0, anon_zero) {
            // SAFETY: a read-only private file mapping with no anonymous page: dropping its PTEs only unmaps
            // page-cache pages, which the next access maps again unchanged.
            unsafe { libc::madvise(a as *mut libc::c_void, b - a, libc::MADV_DONTNEED) };
        }
    };
    for l in s.lines() {
        let mut it = l.split_whitespace();
        let first = it.next().unwrap_or("");
        if let Some((a, b)) = first.split_once('-').filter(|(a, _)| a.chars().all(|c| c.is_ascii_hexdigit())) {
            let perms = it.next().unwrap_or("");
            let path = it.nth(3).unwrap_or("");
            let ok = perms.len() == 4
                && !perms.contains('w')
                && perms.ends_with('p')
                && path.starts_with('/')
                && !path.starts_with("/dev/")
                && !path.starts_with("/memfd:")
                && !l.ends_with("(deleted)");
            cur = match (ok, usize::from_str_radix(a, 16), usize::from_str_radix(b, 16)) {
                (true, Ok(a), Ok(b)) => Some((a, b)),
                _ => None,
            };
            rss = 0;
        } else if let Some(v) = l.strip_prefix("Rss:") {
            rss = v.trim().trim_end_matches("kB").trim().parse().unwrap_or(0);
        } else if let Some(v) = l.strip_prefix("Anonymous:") {
            let anon: u64 = v.trim().trim_end_matches("kB").trim().parse().unwrap_or(1);
            flush(cur.take(), rss, anon == 0);
        }
    }
}
