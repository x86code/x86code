//! mtlvk: the native Linux half of x86Sim's Metal stand-in for the iOS simulator.
//!
//! metalhostd (a Darling process running Apple's MTLSimImplementation over our MTLDevice classes) connects
//! here over a Unix socket and forwards Metal objects and command buffers in the VKMTL protocol
//! (host/metalhostd/vkmtl_proto.h). mtlvk executes them on Vulkan through metal2vulkan-runtime. Buffer memory is
//! shared without copying: metalhostd passes the memfd behind each MTLBuffer (Darling syscall 599) and
//! mtlvk maps it and imports the pages into Vulkan (VK_EXT_external_memory_host).
//!
//! Usage: mtlvk [socket path]      (default: var/run/mtlvk.sock, relative to the repo root)
//!        mtlvk selftest           (memfd import, clear, blits on this GPU; no Darling needed)
//!        mtlvk selftest-compute [metallib]  (stage 4: kernels of tests/metal/shaders/probe.metallib)

mod conn;
mod memstat;
mod proto;

use metal2vulkan_runtime::Device;
use std::os::unix::net::UnixListener;

pub const DEFAULT_SOCKET: &str = "var/run/mtlvk.sock";

extern "C" fn on_usr1(_: libc::c_int) {
    conn::STATS_REQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
}

/// x86Sim RAM 2: what the phone's Metal needs of the device, and no more of the driver's memory.
/// - Ray tracing withheld (VK_KHR_acceleration_structure, VK_KHR_ray_query and
///   VK_KHR_deferred_host_operations): VKMTL has no acceleration structure, and NVIDIA's driver
///   loads libnvidia-rtcore and allocates ~60 MB PSS (37 MB of it malloc) for them in vkCreateDevice
///   (src/bin/devprobe.rs: 183 -> 123 MB). MTLVK_RAYTRACING=1 keeps them.
/// - 8 VkQueues for the logical queues' round robin (METAL2VULKAN_QUEUES; the runtime takes all 16 of
///   NVIDIA's graphics family): each costs ~2.3 MB (devprobe: 16 -> 8 queues 124 -> 106 MB).
/// - The in-memory memo of translated functions and pipelines at MTLVK_MEMO_MB (default 32; the runtime's default
///   is 256 MB): it is a copy of what the on-disk shader cache holds, and live pipeline states keep their own.
fn device_options() -> metal2vulkan_runtime::DeviceOptions {
    use metal2vulkan::device::{VkExtension as E, VkFeature as F};
    if std::env::var_os("METAL2VULKAN_QUEUES").is_none() {
        std::env::set_var("METAL2VULKAN_QUEUES", "8");
    }
    let mut o = metal2vulkan_runtime::DeviceOptions::default();
    let memo_mb = std::env::var("MTLVK_MEMO_MB").ok().and_then(|v| v.parse::<u64>().ok()).filter(|v| *v > 0).unwrap_or(32);
    o.shader_cache.memory_capacity = memo_mb << 20;
    if std::env::var("MTLVK_RAYTRACING").map(|v| v != "1").unwrap_or(true) {
        o.withheld_extensions.extend([E::KhrAccelerationStructure, E::KhrRayQuery, E::KhrDeferredHostOperations]);
        o.withheld_features.extend([F::AccelerationStructure, F::RayQuery]);
    }
    o
}

/// x86Sim RAM 2: every MTLVK_TRIM_EVERY seconds (default 5; 0 = never), give back what the device's spare
/// command pools and descriptor pools hold past MTLVK_TRIM_IDLE seconds unused (default 10): NVIDIA keeps a command
/// pool's 2 MB chunks of pinned system memory until the pool is reset with RELEASE_RESOURCES, so the spares held
/// the busiest moment's command buffers for good (~2 MB per spare pool).
fn start_trim(device: Device) {
    let every = std::env::var("MTLVK_TRIM_EVERY").ok().and_then(|v| v.parse::<f64>().ok()).unwrap_or(5.0);
    let idle = std::env::var("MTLVK_TRIM_IDLE").ok().and_then(|v| v.parse::<f64>().ok()).unwrap_or(10.0);
    if every <= 0.0 {
        return;
    }
    let log = std::env::var_os("MTLVK_MEMSTATS").is_some();
    let pipeline_idle = std::env::var("MTLVK_PIPELINE_IDLE").ok().and_then(|v| v.parse::<f64>().ok()).unwrap_or(300.0);
    let pipeline_idle = (pipeline_idle > 0.0).then(|| std::time::Duration::from_secs_f64(pipeline_idle));
    let file_trim_mb = std::env::var("MTLVK_FILETRIM").ok().and_then(|v| v.parse::<u64>().ok()).unwrap_or(8);
    let _ = std::thread::Builder::new().name("trim".into()).spawn(move || {
        let mut last_malloc_trim = std::time::Instant::now();
        let mut ft = memstat::FileTrim::new(file_trim_mb << 10);
        loop {
            std::thread::sleep(std::time::Duration::from_secs_f64(every));
            if file_trim_mb > 0 {
                if let Some((before, after)) = ft.tick(every) {
                    if log {
                        eprintln!("mtlvk trim: file pages {} -> {} MB", before >> 10, after >> 10);
                    }
                }
            }
            let (pools, descriptors) = device.trim_idle(std::time::Duration::from_secs_f64(idle));
            // x86Sim RAM 8: pipelines nothing used for MTLVK_PIPELINE_IDLE s (default 300; 0 = never): graphics
            // pipeline libraries no new key claimed, the VkPipelines kept for released variants and those of idle variants
            let (libraries, pipelines) = match pipeline_idle {
                Some(idle) => device.trim_idle_pipelines(idle),
                None => (0, 0),
            };
            if log && (libraries > 0 || pipelines > 0) {
                eprintln!("mtlvk trim: {libraries} pipeline libraries, {pipelines} pipelines destroyed");
            }
            let freed = pools + libraries + pipelines;
            // glibc keeps freed pages of its arenas (an app's pipelines and command logs, gone with it); give back
            // the whole free pages after a quiet trim and at least every minute.
            let malloc = (freed > 0 || descriptors > 0 || last_malloc_trim.elapsed().as_secs() >= 60) && {
                last_malloc_trim = std::time::Instant::now();
                // SAFETY: plain libc call.
                unsafe { libc::malloc_trim(0) != 0 }
            };
            if log && (freed > 0 || descriptors > 0) {
                eprintln!("mtlvk trim: {pools} command pools, {descriptors} descriptor pools released, malloc_trim {malloc}");
            }
        }
    });
}

/// Client connections being served (metalhostd's, one per phone process that renders).
static CONNS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

struct ConnGuard;
impl ConnGuard {
    fn new() -> Self {
        CONNS.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        ConnGuard
    }
}
impl Drop for ConnGuard {
    fn drop(&mut self) {
        CONNS.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
    }
}

/// Darlingservers (one per running phone) whose environment names `sock` as their phone's mtlvk.
fn phone_users(sock: &str) -> usize {
    let want = format!("X86SIM_MTLVK_SOCKET={sock}");
    let rd = |p: &std::path::Path, f: &str| std::fs::read(p.join(f)).unwrap_or_default();
    std::fs::read_dir("/proc")
        .into_iter()
        .flatten()
        .flatten()
        .filter(|e| rd(&e.path(), "comm") == b"darlingserver\n")
        .filter(|e| rd(&e.path(), "environ").split(|b| *b == 0).any(|kv| kv == want.as_bytes()))
        .count()
}

/// x86Sim RAM 5: an mtlvk lives as long as its phones. Every stop path (launcher GUI, x86sim-aot, boot-a64.sh's
/// A64_STOP_ONLY, a phone that crashed or was restarted onto another mtlvk) used to have to find and end it, and a
/// shared one whose last phone stopped through a path that did not look (or a phone that moved to a new mtlvk) stayed
/// up for good (~250-600 MB). Now mtlvk ends itself once it has had no client connection and no running phone naming
/// its socket (a darlingserver's X86SIM_MTLVK_SOCKET) for MTLVK_IDLE_EXIT seconds (default 30; 0 = never; a boot's
/// darlingserver exists ~1 s after mtlvk, and a restart's new darlingserver names the socket before its old one is
/// gone or within seconds). The socket is unlinked first, so a boot that looks for it starts a fresh mtlvk.
fn start_idle_exit(sock: String) {
    let secs = std::env::var("MTLVK_IDLE_EXIT").ok().and_then(|v| v.parse::<f64>().ok()).unwrap_or(30.0);
    if secs <= 0.0 {
        return;
    }
    let ino = |p: &str| std::fs::metadata(p).ok().map(|m| std::os::unix::fs::MetadataExt::ino(&m));
    let mine = ino(&sock);
    let _ = std::thread::Builder::new().name("idle-exit".into()).spawn(move || {
        let mut idle_since = std::time::Instant::now();
        loop {
            std::thread::sleep(std::time::Duration::from_secs(2));
            if CONNS.load(std::sync::atomic::Ordering::SeqCst) > 0 || phone_users(&sock) > 0 {
                idle_since = std::time::Instant::now();
                continue;
            }
            if idle_since.elapsed().as_secs_f64() < secs {
                continue;
            }
            // another mtlvk may have taken the path over: leave its socket alone
            if mine.is_some() && ino(&sock) == mine {
                let _ = std::fs::remove_file(&sock);
            }
            std::thread::sleep(std::time::Duration::from_millis(300));
            if CONNS.load(std::sync::atomic::Ordering::SeqCst) == 0 {
                eprintln!("mtlvk: no phone and no connection for {secs} s: exiting (MTLVK_IDLE_EXIT)");
                std::process::exit(0);
            }
        }
    });
}

/// x86Sim RAM 8: glibc malloc for a long-lived process whose driver compiles. NVIDIA's compiler takes large
/// short-lived blocks on the threads that make pipelines, beside the pipelines' small long-lived objects; glibc
/// raises its mmap threshold to each large block freed (up to 32 MB), so later ones came from the arenas and left
/// them holed around the long-lived objects (after a gate run: 110 MB free in the arenas, malloc_trim returning
/// little). A fixed threshold (MTLVK_MMAP_THRESHOLD KiB, default 256; 0 = glibc's dynamic one) keeps large blocks
/// in their own mappings, returned at free; MTLVK_ARENA_MAX (default 4; 0 = glibc's 8 per core) bounds the arenas
/// the many short-lived threads (one per off-class compile, the pool's) spread over.
fn tune_malloc() {
    let env = |k: &str, d: i32| std::env::var(k).ok().and_then(|v| v.parse::<i32>().ok()).unwrap_or(d);
    let threshold = env("MTLVK_MMAP_THRESHOLD", 256);
    let arenas = env("MTLVK_ARENA_MAX", 4);
    // SAFETY: plain libc calls, before any other thread starts.
    unsafe {
        if threshold > 0 {
            libc::mallopt(libc::M_MMAP_THRESHOLD, threshold << 10);
        }
        if arenas > 0 {
            libc::mallopt(libc::M_ARENA_MAX, arenas);
        }
    }
}

fn main() {
    tune_malloc();
    // x86Sim Speed 7: SIGUSR1 -> per-connection object counts on stderr (next request)
    // SAFETY: the handler only bumps an atomic.
    unsafe { libc::signal(libc::SIGUSR1, on_usr1 as extern "C" fn(libc::c_int) as libc::sighandler_t) };
    let arg = std::env::args().nth(1);
    // x86Sim RAM 2: the device as the phone needs it (see device_options).
    let device = match Device::system_default_with(&device_options()) {
        Ok(d) => d,
        Err(e) => {
            eprintln!("mtlvk: no Vulkan device: {e}");
            std::process::exit(1);
        }
    };
    eprintln!("mtlvk: device {} (registryID {:#x})", device.name(), device.registry_id());
    if arg.as_deref() == Some("selftest-compute") {
        let path = std::env::args().nth(2).unwrap_or_else(|| "tests/metal/shaders/probe.metallib".into());
        let data = std::fs::read(&path).unwrap_or_else(|e| {
            eprintln!("mtlvk: {path}: {e}");
            std::process::exit(1);
        });
        std::process::exit(match conn::selftest_compute(&device, &data) {
            Ok(()) => {
                println!("mtlvk selftest-compute: PASS");
                0
            }
            Err(e) => {
                println!("mtlvk selftest-compute: FAIL: {e}");
                1
            }
        });
    }
    if arg.as_deref() == Some("selftest") {
        std::process::exit(match conn::selftest(&device) {
            Ok(()) => {
                println!("mtlvk selftest: PASS");
                0
            }
            Err(e) => {
                println!("mtlvk selftest: FAIL: {e}");
                1
            }
        });
    }
    memstat::start(device.clone());
    start_trim(device.clone());
    let path = arg.unwrap_or_else(|| DEFAULT_SOCKET.to_string());
    let _ = std::fs::remove_file(&path);
    if let Some(dir) = std::path::Path::new(&path).parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let listener = UnixListener::bind(&path).unwrap_or_else(|e| {
        eprintln!("mtlvk: bind {path}: {e}");
        std::process::exit(1);
    });
    eprintln!("mtlvk: listening on {path}");
    start_idle_exit(path.clone());
    for (n, stream) in listener.incoming().enumerate() {
        match stream {
            Ok(s) => {
                let device = device.clone();
                // counted until the thread ends, a panic included (the guard drops on unwind or if spawn fails)
                let guard = ConnGuard::new();
                std::thread::Builder::new()
                    .name(format!("conn{n}"))
                    .spawn(move || {
                        let _g = guard;
                        conn::serve(n, device, s)
                    })
                    .ok();
            }
            Err(e) => eprintln!("mtlvk: accept: {e}"),
        }
    }
}
