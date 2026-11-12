//! One metalhostd connection: object table and the VKMTL request handlers.
use crate::proto::*;
use metal2vulkan::library::{FunctionConstantValue, FunctionConstantValues};
use metal2vulkan::metal::{
    BarrierScope, BlendFactor, BlendOperation, ColorWriteMask, CompareFunction, CullMode, DataType, DepthClipMode,
    DispatchType, IndexType, PixelFormat, PrimitiveTopologyClass, PrimitiveType, RenderStages, ResourceUsage,
    SamplerAddressMode, SamplerBorderColor, SamplerMinMagFilter, SamplerMipFilter, StencilOperation, TextureType,
    TextureUsage, TriangleFillMode, VertexFormat, VertexStepFunction, Winding,
};
use metal2vulkan::metal::state::{DepthStencilDescriptor, StencilDescriptor};
use metal2vulkan::pipeline::{
    ColorAttachmentDescriptor, RenderPipelineDescriptor, VertexAttributeDescriptor, VertexBufferLayoutDescriptor,
    VertexDescriptor,
};
use metal2vulkan::bind::SamplerDescriptor;
use metal2vulkan::pipeline::{ComputePipelineDescriptor, StageSource};
use metal2vulkan_runtime::{
    BlitCommandEncoder, BlitOption, Buffer, ClearColor, CommandBuffer, CommandBufferStatus, CommandQueue,
    ComputeCommandEncoder, ComputePipelineState, DepthStencilState, Device, EventRef, Function, HostMemory,
    IoSurfacePlane, Library, LoadAction, Origin, PipelineOptions, Region, RenderCommandEncoder, RenderPassDescriptor,
    RenderPipelineState, ResourceOptions, ResourceRef, SamplerState, ScissorRect, SharedEvent, Size, StoreAction,
    Texture, TextureDescriptor, Viewport,
};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::net::UnixStream;
use std::ptr::NonNull;
use std::sync::{Arc, Mutex};

type Res<T> = Result<T, String>;

fn err<E: std::fmt::Display>(what: &str) -> impl FnOnce(E) -> String + '_ {
    move |e| format!("{what}: {e}")
}

/// A MAP_SHARED mapping of a memfd from metalhostd.
struct Mapping {
    base: *mut u8,
    len: usize,
}
// SAFETY: plain shared memory; the GPU and both processes access it under Metal's rules.
unsafe impl Send for Mapping {}
unsafe impl Sync for Mapping {}
impl Drop for Mapping {
    fn drop(&mut self) {
        // SAFETY: our own mapping, unmapped once.
        unsafe { libc::munmap(self.base.cast(), self.len) };
    }
}

/// A buffer whose pages could not be imported: the runtime owns the GPU copy, and the shared mapping
/// is synchronised with it around each command buffer (copy before commit, back after completion).
#[derive(Clone)]
struct Mirror {
    buffer: Buffer,
    /// keeps `ptr..ptr + len` mapped
    _map: Arc<Mapping>,
    ptr: usize,
    len: usize,
}

impl Mirror {
    fn to_gpu(&self) {
        if let Some(c) = self.buffer.contents() {
            // SAFETY: both ranges are `len` bytes of live mappings.
            unsafe { std::ptr::copy_nonoverlapping(self.ptr as *const u8, c.as_ptr(), self.len) };
        }
    }
    fn from_gpu(&self) {
        if let Some(c) = self.buffer.contents() {
            // SAFETY: as above.
            unsafe { std::ptr::copy_nonoverlapping(c.as_ptr(), self.ptr as *mut u8, self.len) };
        }
    }
}

enum Obj {
    Buf(Buffer),
    Tex(Texture),
    Queue(CommandQueue),
    Event(SharedEvent),
    Lib(Library),
    Func(Function),
    Pso(ComputePipelineState),
    Sampler(SamplerState),
    Rps(RenderPipelineState),
    /// A render pipeline whose functions did not translate. The app gets a pipeline object anyway: draws with it are
    /// skipped. Refusing it (a nil pipeline) let the app draw with nil, and Apple's MTLSimImplementation in metalhostd
    /// aborts the whole host for that ("Attempting to draw with nil pipeline state"): every app lost its GPU connection
    /// and the screen froze (Watch's Face Gallery, the Pride Weave face's barber_vertex_shader).
    RpsFailed,
    /// The same for a compute pipeline (its dispatches are skipped): "Attempting to dispatch without pipeline set"
    /// aborted metalhostd the same way.
    PsoFailed,
    Dss(DepthStencilState),
}

/// The encoder a command buffer's commands are going into.
enum Enc {
    None,
    Blit(BlitCommandEncoder),
    Compute(ComputeCommandEncoder),
    Render(RenderCommandEncoder),
}

impl Enc {
    fn end(&mut self) -> Res<()> {
        match std::mem::replace(self, Enc::None) {
            Enc::None => Ok(()),
            Enc::Blit(b) => b.end_encoding().map_err(err("end blit")),
            Enc::Compute(c) => c.end_encoding().map_err(err("end compute")),
            Enc::Render(r) => r.end_encoding().map_err(err("end render")),
        }
    }
}

/// A VRAM render target's surface: memfd (dev, inode, offset of the plane), bytes per row, width, height, pixel format.
type VramKey = (u64, u64, u64, u64, u64, u64, u32);

pub type Sink = Arc<dyn Fn(u32, u64, Vec<u8>) + Send + Sync>;

pub struct State {
    device: Device,
    objs: HashMap<u64, Obj>,
    /// The current encoder's pipeline is an Obj::RpsFailed / PsoFailed: its draws / dispatches are skipped
    skip_draws: std::cell::Cell<bool>,
    mirrors: HashMap<u64, Mirror>,
    helper: CommandQueue,
    out: Sink,
    pub log: bool,
    /// x86Sim: library bytes (by library id) and (library id, name) by function id, kept so that a refused
    /// render pipeline can be written to var/metal/failed/ and replayed with the metal2vulkan CLI.
    lib_bytes: HashMap<u64, Vec<u8>>,
    func_src: HashMap<u64, (u64, String)>,
    /// x86Sim: VRAM render targets (default; MTLVK_VRAM_TARGETS=0 turns them off). A render-target texture over an IOSurface's host pages
    /// is drawn through a device-local texture (`proxies`: texture id -> the host texture), and the texels its
    /// command buffer wrote are copied to the host pages once, at the end of that command buffer. Drawing straight
    /// into host pages makes every blended layer cross PCIe twice (8-12 ms of GPU time for a home-screen frame).
    /// Textures over the same surface pages (`buf_keys`: buffer -> memfd dev/inode/offset) share one VRAM texture;
    /// views of a proxied texture count as it (`proxy_views`).
    vram_targets: bool,
    proxies: HashMap<u64, Texture>,
    proxy_views: HashMap<u64, u64>,
    shared_vram: HashMap<VramKey, Texture>,
    /// x86Sim RAM 2: the `shared_vram` key of each proxied texture: the VRAM texture goes with the last proxy of its
    /// surface (it was kept for good: 8 full-screen surfaces, ~100 MB of VRAM, after Settings and Maps).
    proxy_keys: HashMap<u64, VramKey>,
    buf_keys: HashMap<u64, (u64, u64, u64)>,
    written: std::cell::RefCell<std::collections::BTreeSet<u64>>,
    stats_seen: u32,
    /// x86Sim RAM 2: what each buffer/texture id is and roughly how many bytes of its own memory it holds
    /// ([`Kind`]), for the `mtlvk stats:` line.
    kinds: HashMap<u64, (Kind, u64)>,
}

/// x86Sim RAM 2: where a buffer's or texture's bytes live.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Kind {
    /// a buffer the runtime allocated (no fd): host-visible system memory
    BufOwn,
    /// a guest memfd imported without a copy (VK_EXT_external_memory_host): the guest's pages
    BufImported,
    /// a guest memfd the runtime mirrors in its own memory (import refused)
    BufMirror,
    /// a snapshot copy metalhostd syncs with BUF_WRITE/BUF_READ
    BufCopy,
    /// a texture with memory of its own, Private (VRAM)
    TexPrivate,
    /// a texture with memory of its own, host-visible
    TexShared,
    /// a texture over a buffer's bytes (an IOSurface plane): no memory of its own
    TexOverBuf,
    /// a texture view
    TexView,
    /// a VRAM proxy of an IOSurface render target
    TexProxy,
}

fn tex_bytes(d: &TextureDescriptor) -> u64 {
    let base = d.width * d.height * d.depth * d.array_length * d.sample_count * 4;
    if d.mipmap_level_count > 1 { base * 4 / 3 } else { base }
}

/// x86Sim Speed 7: SIGUSR1 bumps this; each connection prints its object counts on its next request.
pub static STATS_REQ: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);

impl State {
    fn print_stats(&self) {
        let mut n = [0usize; 10];
        let mut buf_bytes = 0u64;
        for o in self.objs.values() {
            let k = match o {
                Obj::Buf(b) => {
                    buf_bytes += b.length();
                    0
                }
                Obj::Tex(_) => 1,
                Obj::Queue(_) => 2,
                Obj::Event(_) => 3,
                Obj::Lib(_) => 4,
                Obj::Func(_) => 5,
                Obj::Pso(_) | Obj::PsoFailed => 6,
                Obj::Sampler(_) => 7,
                Obj::Rps(_) | Obj::RpsFailed => 8,
                Obj::Dss(_) => 9,
            };
            n[k] += 1;
        }
        let lib: usize = self.lib_bytes.values().map(|v| v.len()).sum();
        let mirror: usize = self.mirrors.values().map(|m| m.len).sum();
        let mut by: std::collections::BTreeMap<String, (u64, u64)> = Default::default();
        for (k, b) in self.kinds.values() {
            let e = by.entry(format!("{k:?}")).or_default();
            e.0 += 1;
            e.1 += b;
        }
        let shared_vram: u64 = self.shared_vram.values().map(|t| t.width() * t.height() * 4).sum();
        let kinds: Vec<String> = by.iter().map(|(k, (n, b))| format!("{k} {n}/{}MB", b >> 20)).collect();
        eprintln!("mtlvk stats: kinds [{}] shared_vram {} MB", kinds.join(", "), shared_vram >> 20);
        eprintln!(
            "mtlvk stats: buf {} ({} MB) tex {} queue {} event {} lib {} func {} pso {} sampler {} rps {} dss {} | lib_bytes {} ({} MB) func_src {} mirrors {} ({} MB) proxies {} shared_vram {}",
            n[0], buf_bytes >> 20, n[1], n[2], n[3], n[4], n[5], n[6], n[7], n[8], n[9], self.lib_bytes.len(), lib >> 20,
            self.func_src.len(), self.mirrors.len(), mirror >> 20, self.proxies.len(), self.shared_vram.len()
        );
    }
}

const PAGE: u64 = 4096;
static DUMPED: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
/// x86Sim: smallest render target (in pixels) drawn in VRAM (MTLVK_VRAM_MIN_PIXELS, default 1,000,000: the screen
/// and the compositor's full-size passes). Smaller surfaces stay in their host pages: iconservicesagent's icons
/// (CPU-written surfaces it later draws into) came out gray when proxied, as the proxy missed the CPU's writes.
static VRAM_MIN_PIXELS: std::sync::LazyLock<u64> = std::sync::LazyLock::new(|| {
    std::env::var("MTLVK_VRAM_MIN_PIXELS").ok().and_then(|v| v.parse().ok()).unwrap_or(1_000_000)
});

/// x86Sim: MTLVK_TIMING=1: per command buffer, the time to encode it (CB_COMMIT received -> committed), from commit
/// to the completed handler, and the GPU's own time; a summary (avg/p50/p95/max in ms) every 300 command buffers.
static TIMING: std::sync::LazyLock<bool> = std::sync::LazyLock::new(|| std::env::var_os("MTLVK_TIMING").is_some());
static TIMES: Mutex<Vec<(f64, f64, f64)>> = Mutex::new(Vec::new());
fn timing_add(enc: f64, done: f64, gpu: f64) {
    let mut t = TIMES.lock().unwrap();
    t.push((enc, done, gpu));
    if t.len() < 300 {
        return;
    }
    let col = |f: &dyn Fn(&(f64, f64, f64)) -> f64| {
        let mut v: Vec<f64> = t.iter().map(f).collect();
        v.sort_by(|a, b| a.partial_cmp(b).unwrap());
        let avg = v.iter().sum::<f64>() / v.len() as f64;
        format!("avg {:.2} p50 {:.2} p95 {:.2} max {:.2}", avg, v[v.len() / 2], v[v.len() * 95 / 100], v[v.len() - 1])
    };
    eprintln!("mtlvk timing ({} cbs, ms): encode {} | commit->done {} | gpu {}", t.len(), col(&|x| x.0), col(&|x| x.1), col(&|x| x.2));
    t.clear();
}

impl State {
    pub fn new(device: Device, out: Sink) -> Res<State> {
        let helper = device.new_command_queue().map_err(err("helper queue"))?;
        let vram_targets = std::env::var("MTLVK_VRAM_TARGETS").map(|v| v != "0").unwrap_or(true);
        if vram_targets {
            eprintln!("mtlvk: render targets over IOSurfaces are drawn in VRAM (MTLVK_VRAM_TARGETS)");
        }
        Ok(State { device, objs: HashMap::new(), skip_draws: std::cell::Cell::new(false), mirrors: HashMap::new(), helper, out, log: std::env::var_os("MTLVK_LOG").is_some(), lib_bytes: HashMap::new(), func_src: HashMap::new(),
            vram_targets, proxies: HashMap::new(), proxy_views: HashMap::new(), shared_vram: HashMap::new(), proxy_keys: HashMap::new(), buf_keys: HashMap::new(),
            written: Default::default(), stats_seen: 0, kinds: HashMap::new() })
    }

    /// x86Sim: note that a command writes texture `id` (a proxied one is copied back at the end of the command
    /// buffer).
    fn mark(&self, id: u64) {
        let id = *self.proxy_views.get(&id).unwrap_or(&id);
        if self.proxies.contains_key(&id) {
            self.written.borrow_mut().insert(id);
        }
    }

    fn buf(&self, id: u64) -> Res<&Buffer> {
        match self.objs.get(&id) {
            Some(Obj::Buf(b)) => Ok(b),
            _ => Err(format!("no buffer {id:#x}")),
        }
    }
    fn tex(&self, id: u64) -> Res<&Texture> {
        match self.objs.get(&id) {
            Some(Obj::Tex(t)) => Ok(t),
            _ => Err(format!("no texture {id:#x}")),
        }
    }
    fn lib(&self, id: u64) -> Res<&Library> {
        match self.objs.get(&id) {
            Some(Obj::Lib(l)) => Ok(l),
            _ => Err(format!("no library {id:#x}")),
        }
    }
    fn func(&self, id: u64) -> Res<&Function> {
        match self.objs.get(&id) {
            Some(Obj::Func(f)) => Ok(f),
            _ => Err(format!("no function {id:#x}")),
        }
    }
    fn pso(&self, id: u64) -> Res<&ComputePipelineState> {
        match self.objs.get(&id) {
            Some(Obj::Pso(p)) => Ok(p),
            _ => Err(format!("no compute pipeline state {id:#x}")),
        }
    }
    fn sampler(&self, id: u64) -> Res<&SamplerState> {
        match self.objs.get(&id) {
            Some(Obj::Sampler(p)) => Ok(p),
            _ => Err(format!("no sampler {id:#x}")),
        }
    }
    fn rps(&self, id: u64) -> Res<&RenderPipelineState> {
        match self.objs.get(&id) {
            Some(Obj::Rps(p)) => Ok(p),
            _ => Err(format!("no render pipeline state {id:#x}")),
        }
    }
    fn dss(&self, id: u64) -> Res<&DepthStencilState> {
        match self.objs.get(&id) {
            Some(Obj::Dss(p)) => Ok(p),
            _ => Err(format!("no depth-stencil state {id:#x}")),
        }
    }
    fn event(&self, id: u64) -> Res<&SharedEvent> {
        match self.objs.get(&id) {
            Some(Obj::Event(e)) => Ok(e),
            _ => Err(format!("no event {id:#x}")),
        }
    }

    /// Handles one request. Returns the reply payload for requests that have one. `fd` (the SCM_RIGHTS fd that
    /// came with the message) is closed when the request is done with it.
    pub fn handle(&mut self, op: u32, p: &[u8], fd: Option<OwnedFd>) -> Option<Vec<u8>> {
        let stats_req = STATS_REQ.load(std::sync::atomic::Ordering::Relaxed);
        if stats_req != self.stats_seen {
            self.stats_seen = stats_req;
            self.print_stats();
        }
        let mut r = Rd::new(p);
        let mut w = Wr::default();
        match op {
            HELLO => {
                let props = self.device.properties();
                let name = format!("{} (Vulkan, x86Sim)", self.device.name());
                w.u64(self.device.registry_id())
                    .u64(4 << 30)
                    .u64(props.max_buffer_length)
                    .u32(props.has_unified_memory as u32)
                    .u32(name.len() as u32)
                    .bytes(name.as_bytes());
                Some(w.0)
            }
            BUF_NEW => {
                let (id, length, options, off, has_fd, shared) = (r.u64(), r.u64(), r.u64(), r.u64(), r.u32(), r.u32());
                let (status, copied) = match self.buf_new(id, length, options, off, if has_fd != 0 { fd } else { None }, shared != 0) {
                    Ok(c) => (0, c as u32),
                    Err(e) => {
                        eprintln!("mtlvk: BUF_NEW {id:#x} len {length}: {e}");
                        (-1, 0)
                    }
                };
                let gpu = self.buf(id).map(|b| b.gpu_address().0).unwrap_or(0);
                w.i32(status).u32(copied).u64(gpu);
                Some(w.0)
            }
            OBJ_DEL => {
                let id = r.u64();
                self.objs.remove(&id);
                self.mirrors.remove(&id);
                self.proxies.remove(&id);
                self.proxy_views.remove(&id);
                self.buf_keys.remove(&id);
                // x86Sim Speed 7: these were never dropped (a released library kept its bytes for good)
                self.lib_bytes.remove(&id);
                self.func_src.remove(&id);
                self.kinds.remove(&id);
                if let Some(k) = self.proxy_keys.remove(&id) {
                    if !self.proxy_keys.values().any(|o| *o == k) {
                        self.shared_vram.remove(&k);
                    }
                }
                None
            }
            TEX_NEW => {
                let id = r.u64();
                let (status, size) = match self.tex_new(id, &mut r) {
                    Ok(s) => (0, s),
                    Err(e) => {
                        eprintln!("mtlvk: TEX_NEW {id:#x}: {e}");
                        (-1, 0)
                    }
                };
                w.i32(status).u32(0).u64(size);
                Some(w.0)
            }
            TEX_REPLACE => {
                if let Err(e) = self.tex_replace(&mut r) {
                    eprintln!("mtlvk: TEX_REPLACE: {e}");
                }
                None
            }
            TEX_GETBYTES => {
                match self.tex_getbytes(&mut r) {
                    Ok(data) => {
                        w.i32(0).u32(0).u64(data.len() as u64).bytes(&data);
                    }
                    Err(e) => {
                        eprintln!("mtlvk: TEX_GETBYTES: {e}");
                        w.i32(-1).u32(0).u64(0);
                    }
                }
                Some(w.0)
            }
            QUEUE_NEW => {
                let id = r.u64();
                match self.device.new_command_queue() {
                    Ok(q) => {
                        self.objs.insert(id, Obj::Queue(q));
                    }
                    Err(e) => eprintln!("mtlvk: QUEUE_NEW: {e}"),
                }
                None
            }
            CB_COMMIT => {
                let (queue, cb) = (r.u64(), r.u64());
                if let Err(e) = self.cb_commit(queue, cb, &mut r) {
                    eprintln!("mtlvk: command buffer {cb:#x}: {e}");
                    let mut ev = Wr::default();
                    ev.u64(cb).u32(5).u32(1).f64(0.0).f64(0.0);
                    (self.out)(EV_CB_DONE, 0, ev.0);
                }
                None
            }
            EVENT_NEW => {
                let id = r.u64();
                match self.device.new_shared_event() {
                    Ok(e) => {
                        self.objs.insert(id, Obj::Event(e));
                    }
                    Err(e) => eprintln!("mtlvk: EVENT_NEW: {e}"),
                }
                None
            }
            EVENT_SET => {
                let (id, v) = (r.u64(), r.u64());
                match self.event(id) {
                    Ok(e) => e.set_signaled_value(v),
                    Err(e) => eprintln!("mtlvk: EVENT_SET: {e}"),
                }
                None
            }
            EVENT_GET => {
                let id = r.u64();
                w.u64(self.event(id).map(|e| e.signaled_value()).unwrap_or(0));
                Some(w.0)
            }
            BUF_WRITE => {
                let (id, off, len) = (r.u64(), r.u64(), r.u64());
                let data = r.rest();
                if let Ok(b) = self.buf(id) {
                    if let (Some(c), true) = (b.contents(), off < b.length()) {
                        let n = (len as usize).min(data.len()).min((b.length() - off) as usize);
                        // SAFETY: n bytes inside the buffer's contents.
                        unsafe { std::ptr::copy_nonoverlapping(data.as_ptr(), c.as_ptr().add(off as usize), n) };
                    }
                }
                None
            }
            BUF_READ => {
                let (id, off, len) = (r.u64(), r.u64(), r.u64());
                match self.buf(id).ok().and_then(|b| b.contents().map(|c| (c, b.length()))) {
                    Some((c, blen)) if off.checked_add(len).is_some_and(|end| end <= blen) => {
                        w.i32(0).u32(0);
                        // SAFETY: inside the buffer.
                        w.bytes(unsafe { std::slice::from_raw_parts(c.as_ptr().add(off as usize), len as usize) });
                    }
                    _ => {
                        w.i32(-1).u32(0);
                    }
                }
                Some(w.0)
            }
            SYNC => Some(Vec::new()),
            LIB_NEW => {
                let (id, len) = (r.u64(), r.u64());
                let data = r.bytes(len as usize);
                match self.device.new_library_with_data(data) {
                    Ok(l) => {
                        let names = l.function_names();
                        w.i32(0).u32(names.len() as u32);
                        for n in &names {
                            let ty = l.new_function_with_name(n).ok().and_then(|f| f.function_type().ok()).map(|t| t.as_raw()).unwrap_or(0);
                            w.u32(ty).text(n);
                        }
                        if self.log {
                            eprintln!("mtlvk: library {id:#x}: {len} bytes, functions {names:?}");
                        }
                        self.objs.insert(id, Obj::Lib(l));
                        self.lib_bytes.insert(id, data.to_vec());
                    }
                    Err(e) => {
                        eprintln!("mtlvk: LIB_NEW {id:#x} ({len} bytes): {e}");
                        w.i32(-1).u32(0).text(&e.to_string());
                    }
                }
                Some(w.0)
            }
            FUNC_NEW => {
                let id = r.u64();
                match self.func_new(id, &mut r) {
                    Ok(ty) => {
                        w.i32(0).u32(ty);
                    }
                    Err(e) => {
                        eprintln!("mtlvk: FUNC_NEW {id:#x}: {e}");
                        w.i32(-1).u32(0).text(&e);
                    }
                }
                Some(w.0)
            }
            CPS_NEW => {
                let (id, f, max_total, multiple) = (r.u64(), r.u64(), r.u32(), r.u32());
                match self.cps_new(id, f, max_total, multiple != 0) {
                    Ok((tew, max, stat)) => {
                        w.i32(0).u32(tew).u32(max).u32(stat);
                    }
                    Err(e) => {
                        eprintln!("mtlvk: CPS_NEW {id:#x}: {e} (its dispatches are skipped)");
                        self.objs.insert(id, Obj::PsoFailed);
                        let max = if max_total == 0 { 1024 } else { max_total.min(1024) };
                        w.i32(0).u32(32).u32(max).u32(0);
                    }
                }
                Some(w.0)
            }
            SAMPLER_NEW => {
                let id = r.u64();
                match self.sampler_new(id, &mut r) {
                    Ok(rid) => {
                        w.i32(0).u32(0).u64(rid);
                    }
                    Err(e) => {
                        eprintln!("mtlvk: SAMPLER_NEW {id:#x}: {e}");
                        w.i32(-1).u32(0).u64(0);
                    }
                }
                Some(w.0)
            }
            RPS_NEW => {
                let id = r.u64();
                match self.rps_new(id, &mut r) {
                    Ok(()) => {
                        w.i32(0).u32(0);
                    }
                    Err(e) => {
                        eprintln!("mtlvk: RPS_NEW {id:#x}: {e} (its draws are skipped)");
                        self.objs.insert(id, Obj::RpsFailed);
                        w.i32(0).u32(0);
                    }
                }
                Some(w.0)
            }
            DSS_NEW => {
                let id = r.u64();
                match self.dss_new(id, &mut r) {
                    Ok(()) => {
                        w.i32(0).u32(0);
                    }
                    Err(e) => {
                        eprintln!("mtlvk: DSS_NEW {id:#x}: {e}");
                        w.i32(-1).u32(0);
                    }
                }
                Some(w.0)
            }
            TEX_NEW_BUF => {
                let (id, buf) = (r.u64(), r.u64());
                let (status, size) = match self.tex_new_buf(id, buf, &mut r) {
                    Ok(s) => (0, s),
                    Err(e) => {
                        eprintln!("mtlvk: TEX_NEW_BUF {id:#x}: {e}");
                        (-1, 0)
                    }
                };
                w.i32(status).u32(0).u64(size);
                Some(w.0)
            }
            TEX_VIEW => {
                let (id, parent) = (r.u64(), r.u64());
                let status = match self.tex_view(id, parent, &mut r) {
                    Ok(()) => 0,
                    Err(e) => {
                        eprintln!("mtlvk: TEX_VIEW {id:#x} of {parent:#x}: {e}");
                        -1
                    }
                };
                w.i32(status).u32(0).u64(0);
                Some(w.0)
            }
            _ => {
                eprintln!("mtlvk: unknown op {op}");
                None
            }
        }
    }

    /// Returns whether the buffer is a copy (metalhostd must BUF_WRITE/BUF_READ it).
    fn buf_new(&mut self, id: u64, length: u64, options: u64, off: u64, fd: Option<OwnedFd>, shared: bool) -> Res<bool> {
        // storage mode bits (4..8) cleared: Shared. Pages from metalhostd are host memory whatever the
        // app asked for (Private buffers too, for now).
        let shared_opts = ResourceOptions::from_raw(options & !0xf0).map_err(err("options"))?;
        let Some(fd) = fd else {
            let b = self.device.new_buffer(length.max(1), shared_opts).map_err(err("new_buffer"))?;
            self.objs.insert(id, Obj::Buf(b));
            self.kinds.insert(id, (Kind::BufOwn, length));
            return Ok(false);
        };
        if self.vram_targets {
            // SAFETY: fstat of the fd we were given.
            let mut st: libc::stat = unsafe { std::mem::zeroed() };
            if unsafe { libc::fstat(fd.as_raw_fd(), &mut st) } == 0 {
                self.buf_keys.insert(id, (st.st_dev as u64, st.st_ino as u64, off));
            }
        }
        let map_off = off & !(PAGE - 1);
        let delta = off - map_off;
        let map_len = ((delta + length.max(1) + PAGE - 1) & !(PAGE - 1)) as usize;
        // SAFETY: mapping a memfd we were given.
        let base = unsafe { libc::mmap(std::ptr::null_mut(), map_len, libc::PROT_READ | libc::PROT_WRITE, libc::MAP_SHARED, fd.as_raw_fd(), map_off as libc::off_t) };
        drop(fd);
        if base == libc::MAP_FAILED {
            return Err(format!("mmap {map_len} at {map_off}: {}", std::io::Error::last_os_error()));
        }
        let map = Arc::new(Mapping { base: base.cast(), len: map_len });
        // SAFETY: inside the mapping.
        let ptr = unsafe { map.base.add(delta as usize) };
        if shared {
            let keep = map.clone();
            // SAFETY: the pages stay mapped (and writable) until the deallocator drops `keep`.
            let r = unsafe {
                self.device.new_buffer_with_bytes_no_copy(
                    HostMemory::new(NonNull::new(ptr).unwrap()),
                    length.max(1),
                    shared_opts,
                    Some(Box::new(move |_, _| drop(keep))),
                )
            };
            match r {
                Ok(b) => {
                    if self.log {
                        eprintln!("mtlvk: buffer {id:#x}: {length} bytes imported without a copy");
                    }
                    self.objs.insert(id, Obj::Buf(b));
                    self.kinds.insert(id, (Kind::BufImported, length));
                    return Ok(false);
                }
                Err(e) => eprintln!("mtlvk: buffer {id:#x}: import refused ({e}); mirroring it"),
            }
        }
        let b = self.device.new_buffer(length.max(1), shared_opts).map_err(err("new_buffer"))?;
        let m = Mirror { buffer: b.clone(), _map: map, ptr: ptr as usize, len: length as usize };
        m.to_gpu();
        self.objs.insert(id, Obj::Buf(b));
        self.kinds.insert(id, (if shared { Kind::BufMirror } else { Kind::BufCopy }, length));
        if shared {
            self.mirrors.insert(id, m);
            Ok(false)
        } else {
            // a snapshot: metalhostd's pages are not these; it copies with BUF_WRITE/BUF_READ
            Ok(true)
        }
    }

    /// A function of a library, specialized with the constant values that come with it.
    fn func_new(&mut self, id: u64, r: &mut Rd) -> Res<u32> {
        let lib = r.u64();
        let (name_len, nconst) = (r.u32(), r.u32());
        let name = String::from_utf8_lossy(r.bytes(name_len as usize)).into_owned();
        let mut consts = FunctionConstantValues::defaults();
        for _ in 0..nconst {
            let (index, ty, size, nl) = (r.u32(), r.u32(), r.u32(), r.u32());
            let cname = String::from_utf8_lossy(r.bytes(nl as usize)).into_owned();
            let bytes = r.bytes(size as usize).to_vec();
            let v = FunctionConstantValue::new(DataType::try_from(ty).map_err(err("constant type"))?, bytes);
            consts = if index == u32::MAX { consts.with_name(cname, v) } else { consts.with_index(index, v) };
        }
        if r.short {
            return Err("truncated FUNC_NEW".into());
        }
        let l = self.lib(lib)?;
        let f = if nconst == 0 {
            l.new_function_with_name(&name)
        } else {
            l.new_function_with_name_constant_values(&name, &consts)
        }
        .map_err(err("new_function"))?;
        let ty = f.function_type().map(|t| t.as_raw()).unwrap_or(0);
        if self.log {
            eprintln!("mtlvk: function {id:#x}: {name} type {ty} ({nconst} constants)");
        }
        self.objs.insert(id, Obj::Func(f));
        self.func_src.insert(id, (lib, name));
        Ok(ty)
    }

    fn cps_new(&mut self, id: u64, f: u64, max_total: u32, multiple: bool) -> Res<(u32, u32, u32)> {
        let f = self.func(f)?;
        let mut desc = ComputePipelineDescriptor::new(StageSource::Function(f.function_descriptor()));
        desc.max_total_threads_per_threadgroup = if max_total == 0 { None } else { Some(max_total) };
        desc.threadgroup_size_is_multiple_of_execution_width = multiple;
        let t0 = std::time::Instant::now();
        let p = self.device.new_compute_pipeline_state(&desc, &PipelineOptions::default()).map_err(err("new_compute_pipeline_state"))?;
        let r = (p.thread_execution_width(), p.max_total_threads_per_threadgroup(), p.static_threadgroup_memory_length());
        if self.log {
            eprintln!("mtlvk: compute pipeline {id:#x}: width {} max {} static tg {} ({:.1} ms)", r.0, r.1, r.2, t0.elapsed().as_secs_f64() * 1e3);
        }
        self.objs.insert(id, Obj::Pso(p));
        Ok(r)
    }

    fn sampler_new(&mut self, id: u64, r: &mut Rd) -> Res<u64> {
        let mut d = SamplerDescriptor::new();
        d.min_filter = SamplerMinMagFilter::try_from(r.u32()).map_err(err("min filter"))?;
        d.mag_filter = SamplerMinMagFilter::try_from(r.u32()).map_err(err("mag filter"))?;
        d.mip_filter = SamplerMipFilter::try_from(r.u32()).map_err(err("mip filter"))?;
        d.s_address_mode = SamplerAddressMode::try_from(r.u32()).map_err(err("s address"))?;
        d.t_address_mode = SamplerAddressMode::try_from(r.u32()).map_err(err("t address"))?;
        d.r_address_mode = SamplerAddressMode::try_from(r.u32()).map_err(err("r address"))?;
        d.border_color = SamplerBorderColor::try_from(r.u32()).map_err(err("border colour"))?;
        d.normalized_coordinates = r.u32() != 0;
        d.lod_min_clamp = r.f32();
        d.lod_max_clamp = r.f32();
        d.lod_average = r.u32() != 0;
        d.max_anisotropy = r.u32().max(1);
        d.compare_function = CompareFunction::try_from(r.u32()).map_err(err("compare function"))?;
        let s = self.device.new_sampler_state(&d).map_err(err("new_sampler_state"))?;
        let rid = s.gpu_resource_id().0;
        self.objs.insert(id, Obj::Sampler(s));
        Ok(rid)
    }

    fn tex_new(&mut self, id: u64, r: &mut Rd) -> Res<u64> {
        let desc = Self::texdesc(r)?;
        let t = self.device.new_texture(&desc).map_err(err("new_texture"))?;
        if self.log {
            eprintln!("mtlvk: texture {id:#x}: {:?} {}x{}x{} mips {} usage {:?} sample count {}", desc.pixel_format, desc.width,
                desc.height, desc.depth, desc.mipmap_level_count, desc.usage, desc.sample_count);
        }
        let k = if desc.resource_options.raw() & 0xf0 == 0x20 { Kind::TexPrivate } else { Kind::TexShared };
        self.kinds.insert(id, (k, tex_bytes(&desc)));
        self.objs.insert(id, Obj::Tex(t));
        Ok(0)
    }

    /// A texture over a buffer's bytes: an IOSurface plane (the surface's memfd pages, imported as the buffer) or
    /// `newTextureWithDescriptor:offset:bytesPerRow:`.
    fn tex_new_buf(&mut self, id: u64, buf: u64, r: &mut Rd) -> Res<u64> {
        let desc = Self::texdesc(r)?;
        let (offset, bpr, iosurface, planar) = (r.u64(), r.u64(), r.u32(), r.u32());
        let b = self.buf(buf)?.clone();
        let t = if iosurface != 0 {
            let plane = IoSurfacePlane::new(offset, bpr, planar != 0);
            b.new_texture_with_iosurface_plane(&desc, plane).map_err(err("new_texture_with_iosurface_plane"))?
        } else {
            b.new_texture(&desc, offset, bpr).map_err(err("buffer new_texture"))?
        };
        if self.log {
            eprintln!("mtlvk: texture {id:#x} over buffer {buf:#x} (+{offset}, row {bpr}{}): {:?} {}x{} usage {:?}",
                if iosurface != 0 { ", IOSurface" } else { "" }, desc.pixel_format, desc.width, desc.height, desc.usage);
        }
        if self.vram_targets && iosurface != 0 && planar == 0 && desc.usage.contains(TextureUsage::RENDER_TARGET)
            && desc.texture_type == TextureType::Type2D && desc.mipmap_level_count == 1 && desc.sample_count == 1
            && desc.array_length == 1 && desc.width * desc.height >= *VRAM_MIN_PIXELS
        {
            let key = self.buf_keys.get(&buf).map(|k| (k.0, k.1, k.2 + offset, bpr, desc.width, desc.height, desc.pixel_format.as_raw() as u32));
            let vram = match key.and_then(|k| self.shared_vram.get(&k).cloned()) {
                Some(v) => Ok(v),
                None => {
                    let mut d2 = desc.clone();
                    d2.resource_options = ResourceOptions::from_raw(0x20).map_err(err("options"))?;   // Private
                    match self.device.new_texture(&d2) {
                        Ok(v) => {
                            let (w, h) = (desc.width, desc.height);
                            let r = self.helper_blit(|e| e.copy_from_texture_to_texture(&t, 0, 0, Origin::new(0, 0, 0), Size::new(w, h, 1), &v, 0, 0, Origin::new(0, 0, 0)));
                            r.map(|_| v)
                        }
                        Err(e) => Err(format!("{e}")),
                    }
                }
            };
            match vram {
                Ok(v) => {
                    if let Some(k) = key {
                        self.shared_vram.insert(k, v.clone());
                        self.proxy_keys.insert(id, k);
                    }
                    if self.log {
                        eprintln!("mtlvk: texture {id:#x}: drawn in VRAM, copied to the surface after each command buffer");
                    }
                    self.proxies.insert(id, t);
                    self.objs.insert(id, Obj::Tex(v));
                    self.kinds.insert(id, (Kind::TexProxy, 0));
                    return Ok(0);
                }
                Err(e) => eprintln!("mtlvk: texture {id:#x}: no VRAM proxy ({e}); drawing into the surface"),
            }
        }
        self.objs.insert(id, Obj::Tex(t));
        self.kinds.insert(id, (Kind::TexOverBuf, 0));
        Ok(0)
    }

    /// x86Sim: newTextureViewWithPixelFormat:[textureType:levels:slices:[swizzle:]]
    fn tex_view(&mut self, id: u64, parent: u64, r: &mut Rd) -> Res<()> {
        let (pf, ttype) = (r.u32(), r.u32());
        let (l0, ln, s0, sn) = (r.u64(), r.u64(), r.u64(), r.u64());
        let (has_swizzle, sw) = (r.u32(), r.u32());
        let t = match self.objs.get(&parent) {
            Some(Obj::Tex(t)) => t.clone(),
            _ => return Err(format!("no texture {parent:#x}")),
        };
        let root = *self.proxy_views.get(&parent).unwrap_or(&parent);
        if self.proxies.contains_key(&root) {
            self.proxy_views.insert(id, root);
        }
        let pf = PixelFormat::try_from(pf).map_err(err("pixel format"))?;
        let tt = TextureType::try_from(ttype).map_err(err("texture type"))?;
        let v = if has_swizzle != 0 {
            let c = |b: u32| metal2vulkan::metal::TextureSwizzle::try_from((sw >> b) & 0xff).map_err(err("swizzle"));
            let swz = metal2vulkan::metal::TextureSwizzleChannels::new(c(0)?, c(8)?, c(16)?, c(24)?);
            t.new_texture_view_with_swizzle(pf, tt, l0..l0 + ln, s0..s0 + sn, swz).map_err(err("new_texture_view_with_swizzle"))?
        } else {
            t.new_texture_view_with_levels_slices(pf, tt, l0..l0 + ln, s0..s0 + sn).map_err(err("new_texture_view_with_levels_slices"))?
        };
        if self.log {
            eprintln!("mtlvk: texture view {id:#x} of {parent:#x}: {pf:?} {tt:?} levels {l0}+{ln} slices {s0}+{sn}");
        }
        self.objs.insert(id, Obj::Tex(v));
        self.kinds.insert(id, (Kind::TexView, 0));
        Ok(())
    }

    fn texdesc(r: &mut Rd) -> Res<TextureDescriptor> {
        let (ttype, pf) = (r.u32(), r.u32());
        let (w, h, d) = (r.u64(), r.u64(), r.u64());
        let (mips, samples) = (r.u32(), r.u32());
        let array = r.u64();
        let mut options = r.u64();
        let usage = r.u64();
        let _swizzle = r.u32();
        let _allow_opt = r.u32();
        if (options >> 4) & 0xf == 3 {
            // memoryless: no tile memory here
            options = (options & !0xf0) | 0x20;
        }
        let pf = PixelFormat::try_from(pf).map_err(err("pixel format"))?;
        let mut desc = TextureDescriptor::texture_2d(pf, w.max(1), h.max(1), false);
        desc.texture_type = TextureType::try_from(ttype).map_err(err("texture type"))?;
        desc.depth = d.max(1);
        desc.mipmap_level_count = (mips as u64).max(1);
        desc.sample_count = (samples as u64).max(1);
        desc.array_length = array.max(1);
        desc.usage = TextureUsage::try_from(usage as u32).map_err(err("usage"))?;
        desc.resource_options = ResourceOptions::from_raw(options).map_err(err("options"))?;
        Ok(desc)
    }

    /// x86Sim: write a refused pipeline's libraries and descriptor to var/metal/failed/<id>-*.
    fn dump_failed(&self, id: u64, funcs: &[(&str, u64)], text: &str) {
        let dir = std::env::var("MTLVK_FAILED_DIR").unwrap_or_else(|_| "var/metal/failed".into());
        let _ = std::fs::create_dir_all(&dir);
        let mut t = String::from(text);
        for (stage, f) in funcs {
            if let Some((lib, name)) = self.func_src.get(f) {
                if let Some(b) = self.lib_bytes.get(lib) {
                    let _ = std::fs::write(format!("{dir}/{id:x}-{stage}.metallib"), b);
                }
                t += &format!("{stage}: {name}\n");
            }
        }
        let _ = std::fs::write(format!("{dir}/{id:x}.txt"), t);
    }

    fn rps_new(&mut self, id: u64, r: &mut Rd) -> Res<()> {
        let (vf, ff) = (r.u64(), r.u64());
        let mut desc = RenderPipelineDescriptor::new(StageSource::Function(self.func(vf)?.function_descriptor()));
        if ff != 0 {
            desc.fragment = Some(StageSource::Function(self.func(ff)?.function_descriptor()));
        }
        let mut formats = Vec::new();
        for i in 0..8 {
            let v: Vec<u32> = (0..10).map(|_| r.u32()).collect();
            if v[0] == 0 {
                continue;
            }
            let pf = PixelFormat::try_from(v[0]).map_err(err("color format"))?;
            let mut a = ColorAttachmentDescriptor::new(pf);
            a.blending_enabled = v[1] != 0;
            a.source_rgb_blend_factor = BlendFactor::try_from(v[2]).map_err(err("blend factor"))?;
            a.destination_rgb_blend_factor = BlendFactor::try_from(v[3]).map_err(err("blend factor"))?;
            a.rgb_blend_operation = BlendOperation::try_from(v[4]).map_err(err("blend op"))?;
            a.source_alpha_blend_factor = BlendFactor::try_from(v[5]).map_err(err("blend factor"))?;
            a.destination_alpha_blend_factor = BlendFactor::try_from(v[6]).map_err(err("blend factor"))?;
            a.alpha_blend_operation = BlendOperation::try_from(v[7]).map_err(err("blend op"))?;
            a.write_mask = ColorWriteMask::try_from(v[8]).map_err(err("write mask"))?;
            formats.push(format!("{i}:{pf:?}{}", if a.blending_enabled { "+blend" } else { "" }));
            desc.color_attachments[i] = Some(a);
        }
        let (df, sf, samples, a2c, a2o, raster) = (r.u32(), r.u32(), r.u32(), r.u32(), r.u32(), r.u32());
        let (topo, has_vd, nl, na) = (r.u32(), r.u32(), r.u32(), r.u32());
        if df != 0 {
            desc.depth_format = Some(PixelFormat::try_from(df).map_err(err("depth format"))?);
        }
        if sf != 0 {
            desc.stencil_format = Some(PixelFormat::try_from(sf).map_err(err("stencil format"))?);
        }
        desc.raster_sample_count = samples.max(1);
        desc.alpha_to_coverage = a2c != 0;
        desc.alpha_to_one = a2o != 0;
        desc.rasterization_enabled = raster != 0;
        desc.input_primitive_topology = PrimitiveTopologyClass::try_from(topo).map_err(err("topology"))?;
        if has_vd != 0 {
            let mut vd = VertexDescriptor::new();
            for _ in 0..nl {
                let (index, stride, step, rate) = (r.u32(), r.u32(), r.u32(), r.u32());
                let mut l = VertexBufferLayoutDescriptor::new(Some(stride));
                l.step_function = VertexStepFunction::try_from(step).map_err(err("step function"))?;
                l.step_rate = rate;
                vd.layouts.insert(index, l);
            }
            for _ in 0..na {
                let (index, format, offset, bi) = (r.u32(), r.u32(), r.u32(), r.u32());
                let f = VertexFormat::try_from(format).map_err(err("vertex format"))?;
                vd.attributes.insert(index, VertexAttributeDescriptor::new(f, offset, bi));
            }
            desc.vertex_descriptor = Some(vd);
        }
        if r.short {
            return Err("truncated RPS_NEW".into());
        }
        let t0 = std::time::Instant::now();
        let p = match self.device.new_render_pipeline_state(&desc, &PipelineOptions::default()) {
            Ok(p) => p,
            Err(e) => {
                self.dump_failed(id, &[("vert", vf), ("frag", ff)], &format!("{e}\ncolors [{}] depth {df} stencil {sf} samples {samples}\n", formats.join(" ")));
                return Err(format!("new_render_pipeline_state: {e}"));
            }
        };
        if self.log {
            eprintln!("mtlvk: render pipeline {id:#x}: colors [{}] depth {df} stencil {sf} samples {samples} ({:.1} ms)",
                formats.join(" "), t0.elapsed().as_secs_f64() * 1e3);
        }
        self.objs.insert(id, Obj::Rps(p));
        Ok(())
    }

    fn dss_new(&mut self, id: u64, r: &mut Rd) -> Res<()> {
        let mut d = DepthStencilDescriptor::default();
        d.depth_compare_function = CompareFunction::try_from(r.u32()).map_err(err("depth compare"))?;
        d.depth_write_enabled = r.u32() != 0;
        let face = |r: &mut Rd| -> Res<StencilDescriptor> {
            let v: Vec<u32> = (0..8).map(|_| r.u32()).collect();
            let mut s = StencilDescriptor::default();
            if v[0] != 0 {
                s.stencil_compare_function = CompareFunction::try_from(v[1]).map_err(err("stencil compare"))?;
                s.stencil_failure_operation = StencilOperation::try_from(v[2]).map_err(err("stencil op"))?;
                s.depth_failure_operation = StencilOperation::try_from(v[3]).map_err(err("stencil op"))?;
                s.depth_stencil_pass_operation = StencilOperation::try_from(v[4]).map_err(err("stencil op"))?;
                s.read_mask = v[5];
                s.write_mask = v[6];
            }
            Ok(s)
        };
        d.front_face_stencil = face(r)?;
        d.back_face_stencil = face(r)?;
        let s = self.device.new_depth_stencil_state(&d).map_err(err("new_depth_stencil_state"))?;
        self.objs.insert(id, Obj::Dss(s));
        Ok(())
    }

    fn region(r: &mut Rd) -> Region {
        let (x, y, z, w, h, d) = (r.u64(), r.u64(), r.u64(), r.u64(), r.u64(), r.u64());
        Region::new_3d(x, y, z, w, h, d)
    }

    /// Runs one blit on the helper queue and waits (CPU-side texture access to non-shared storage).
    fn helper_blit(&self, f: impl FnOnce(&mut BlitCommandEncoder) -> Result<(), metal2vulkan_runtime::Error>) -> Res<()> {
        let cb = self.helper.command_buffer().map_err(err("command buffer"))?;
        let mut enc = cb.blit_command_encoder().map_err(err("blit encoder"))?;
        f(&mut enc).map_err(err("blit"))?;
        enc.end_encoding().map_err(err("end encoding"))?;
        cb.commit().map_err(err("commit"))?;
        cb.wait_until_completed().map_err(err("wait"))?;
        Ok(())
    }

    fn tex_replace(&mut self, r: &mut Rd) -> Res<()> {
        let id = r.u64();
        let region = Self::region(r);
        let (level, slice) = (r.u32() as u64, r.u32() as u64);
        let (bpr, bpi, len) = (r.u64(), r.u64(), r.u64());
        let data = r.bytes(len as usize);
        self.mark(id);
        let t = self.tex(id)?.clone();
        // x86Sim: diagnostics, MTLVK_DUMP_REPLACE=<dir> saves every replaceRegion's bytes
        if let Some(dir) = std::env::var_os("MTLVK_DUMP_REPLACE") {
            let n = format!("{}/{id:x}-f{}-{}x{}-bpr{bpr}-l{level}.raw", dir.to_string_lossy(), t.pixel_format().as_raw(),
                region.size.width, region.size.height);
            let _ = std::fs::write(n, data);
        }
        match t.replace_region(region, level, slice, data, bpr, bpi) {
            Ok(()) => Ok(()),
            Err(e) => {
                if self.log {
                    eprintln!("mtlvk: replace_region direct: {e}; staging");
                }
                let staging = self.device.new_buffer_with_bytes(data, ResourceOptions::shared()).map_err(err("staging"))?;
                let bpi = if bpi == 0 { bpr * region.size.height } else { bpi };
                self.helper_blit(|enc| {
                    enc.copy_from_buffer_to_texture(&staging, 0, bpr, bpi, region.size, &t, slice, level, region.origin, BlitOption::None)
                })
            }
        }
    }

    fn tex_getbytes(&mut self, r: &mut Rd) -> Res<Vec<u8>> {
        let id = r.u64();
        let region = Self::region(r);
        let (level, slice) = (r.u32() as u64, r.u32() as u64);
        let (bpr, bpi, len) = (r.u64(), r.u64(), r.u64());
        let t = self.tex(id)?.clone();
        let mut out = vec![0u8; len as usize];
        match t.get_bytes(&mut out, bpr, bpi, region, level, slice) {
            Ok(()) => Ok(out),
            Err(e) => {
                if self.log {
                    eprintln!("mtlvk: get_bytes direct: {e}; staging");
                }
                let bpi = if bpi == 0 { bpr * region.size.height } else { bpi };
                let staging = self.device.new_buffer(len.max(1), ResourceOptions::shared()).map_err(err("staging"))?;
                self.helper_blit(|enc| {
                    enc.copy_from_texture_to_buffer(&t, slice, level, region.origin, region.size, &staging, 0, bpr, bpi, BlitOption::None)
                })?;
                let c = staging.contents().ok_or("staging has no contents")?;
                // SAFETY: len bytes of the staging buffer.
                out.copy_from_slice(unsafe { std::slice::from_raw_parts(c.as_ptr(), len as usize) });
                Ok(out)
            }
        }
    }

    fn cb_commit(&mut self, queue: u64, id: u64, r: &mut Rd) -> Res<()> {
        let q = match self.objs.get(&queue) {
            Some(Obj::Queue(q)) => q.clone(),
            _ => return Err(format!("no queue {queue:#x}")),
        };
        let t_recv = std::time::Instant::now();
        let count = r.u32();
        r.u32();
        let cb: CommandBuffer = q.command_buffer().map_err(err("command buffer"))?;
        let mut enc = Enc::None;
        // x86Sim: diagnostics, MTLVK_DUMP_PASSES=<dir>: every render pass's colour attachments are copied out
        // after the pass (in this command buffer) and written to <dir> when it completes (MTLVK_DUMP_MAX command
        // buffers with render passes, default 60)
        let dump_dir = std::env::var("MTLVK_DUMP_PASSES").ok();
        let mut dump_targets: Vec<(Texture, u64)> = Vec::new();
        let mut dumps: Vec<(String, Buffer)> = Vec::new();
        let mut npass = 0u32;
        for _ in 0..count {
            let (kind, size) = (r.u32(), r.u32());
            let body = r.bytes(size as usize);
            if r.short {
                return Err("truncated command".into());
            }
            let mut c = Rd::new(body);
            if self.log {
                eprintln!("mtlvk: cb {id:#x}: command {kind} ({size} bytes)");
            }
            match kind {
                C_COPY_BB | C_COPY_BT | C_COPY_TB | C_COPY_TT | C_FILL | C_MIPMAPS => {
                    if !matches!(enc, Enc::Blit(_)) {
                        enc.end()?;
                        enc = Enc::Blit(cb.blit_command_encoder().map_err(err("blit encoder"))?);
                    }
                    let Enc::Blit(enc) = &mut enc else { unreachable!() };
                    self.blit_command(enc, kind, &mut c)?;
                }
                C_CS_BEGIN => {
                    enc.end()?;
                    let dt = DispatchType::try_from(c.u32()).map_err(err("dispatch type"))?;
                    self.skip_draws.set(false);
                    enc = Enc::Compute(cb.compute_command_encoder_with_dispatch_type(dt).map_err(err("compute encoder"))?);
                }
                C_CS_END => {
                    enc.end()?;
                    // x86Sim: MTLVK_DUMP_PASSES also dumps the textures a compute encoder bound (every level)
                    if dump_dir.is_some() && !dump_targets.is_empty() && DUMPED.load(std::sync::atomic::Ordering::Relaxed) < 400 {
                        let ts: Vec<Texture> = dump_targets.drain(..).map(|(t, _)| t).collect();
                        for t in ts {
                            for l in 0..t.mipmap_level_count() {
                                dump_targets.push((t.clone(), l));
                            }
                        }
                        self.dump_now(&cb, &mut dump_targets, &mut dumps, dump_dir.as_deref().unwrap(), id, npass, "cs")?;
                        npass += 1;
                    }
                    dump_targets.clear();
                }
                C_CS_PIPELINE..=C_CS_USE | C_CS_BUFFER_OFFSET | C_CS_DISPATCH_INDIRECT => {
                    if dump_dir.is_some() {
                        self.dump_compute_command(id, kind, body, &mut dump_targets);
                    }
                    let Enc::Compute(ce) = &mut enc else {
                        return Err(format!("compute command {kind} outside a compute encoder"));
                    };
                    self.compute_command(ce, kind, &mut c).map_err(|e| format!("compute command {kind}: {e}"))?;
                }
                C_RENDER_PASS => {
                    enc.end()?;
                    let pass = self.pass(&mut c)?;
                    if dump_dir.is_some() {
                        dump_targets = pass.color_attachments.iter().filter_map(|a| match &a.resolve_texture {
                            Some(r) => Some((r.clone(), a.resolve_level)),
                            None => a.texture.clone().map(|t| (t, a.level)),
                        }).collect();
                    }
                    self.skip_draws.set(false);
                    enc = Enc::Render(cb.render_command_encoder(&pass).map_err(err("render encoder"))?);
                }
                C_RE_END => {
                    enc.end()?;
                    if let Some(dir) = &dump_dir {
                        let n = DUMPED.load(std::sync::atomic::Ordering::Relaxed);
                        let max: u32 = std::env::var("MTLVK_DUMP_MAX").ok().and_then(|v| v.parse().ok()).unwrap_or(60);
                        if n < max && !dump_targets.is_empty() {
                            self.dump_now(&cb, &mut dump_targets, &mut dumps, dir, id, npass, "p")?;
                        }
                        npass += 1;
                    }
                }
                C_RE_PIPELINE..=C_RE_USE | C_RE_DRAW_INDIRECT | C_RE_DRAW_INDEXED_INDIRECT | C_RE_VIEWPORTS | C_RE_SCISSORS => {
                    let Enc::Render(re) = &mut enc else {
                        return Err(format!("render command {kind} outside a render encoder"));
                    };
                    self.render_command(re, kind, &mut c).map_err(|e| format!("render command {kind}: {e}"))?;
                }
                C_SIGNAL | C_WAIT => {
                    enc.end()?;
                    let (e, v) = (c.u64(), c.u64());
                    let ev = self.event(e)?;
                    if kind == C_SIGNAL {
                        cb.encode_signal_event(EventRef::Shared(ev), v).map_err(err("signal"))?;
                    } else {
                        cb.encode_wait_for_event(EventRef::Shared(ev), v).map_err(err("wait"))?;
                    }
                }
                k => return Err(format!("unknown command {k}")),
            }
        }
        enc.end()?;
        let written: Vec<u64> = std::mem::take(&mut *self.written.borrow_mut()).into_iter().collect();
        if !written.is_empty() {
            let mut be = cb.blit_command_encoder().map_err(err("blit encoder"))?;
            for id in written {
                if let (Some(host), Ok(v)) = (self.proxies.get(&id), self.tex(id)) {
                    let (w, h) = (v.width(), v.height());
                    be.copy_from_texture_to_texture(v, 0, 0, Origin::new(0, 0, 0), Size::new(w, h, 1), host, 0, 0, Origin::new(0, 0, 0))
                        .map_err(err("copy back"))?;
                }
            }
            be.end_encoding().map_err(err("end blit"))?;
        }
        let mirrors: Vec<Mirror> = self.mirrors.values().cloned().collect();
        for m in &mirrors {
            m.to_gpu();
        }
        if !dumps.is_empty() {
            DUMPED.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        }
        let out = self.out.clone();
        let t_commit = std::sync::Arc::new(std::sync::OnceLock::<std::time::Instant>::new());
        let t_commit2 = t_commit.clone();
        cb.add_completed_handler(Box::new(move |cb: &CommandBuffer| {
            if *TIMING {
                let now = std::time::Instant::now();
                let tc = *t_commit2.get().unwrap_or(&now);
                let gpu = (cb.gpu_end_time().unwrap_or(0.0) - cb.gpu_start_time().unwrap_or(0.0)) * 1000.0;
                timing_add((tc - t_recv).as_secs_f64() * 1000.0, (now - tc).as_secs_f64() * 1000.0, gpu);
            }
            for (name, b) in &dumps {
                if let Some(c) = b.contents() {
                    // SAFETY: the buffer's own length.
                    let _ = std::fs::write(name, unsafe { std::slice::from_raw_parts(c.as_ptr(), b.length() as usize) });
                }
            }
            for m in &mirrors {
                m.from_gpu();
            }
            let ok = matches!(cb.status(), CommandBufferStatus::Completed);
            let mut w = Wr::default();
            w.u64(id)
                .u32(if ok { 4 } else { 5 })
                .u32(if ok { 0 } else { 1 })
                .f64(cb.gpu_start_time().unwrap_or(0.0))
                .f64(cb.gpu_end_time().unwrap_or(0.0));
            out(EV_CB_DONE, 0, w.0);
        }))
        .map_err(err("completed handler"))?;
        let _ = t_commit.set(std::time::Instant::now());
        cb.commit().map_err(err("commit"))?;
        Ok(())
    }

    /// x86Sim: MTLVK_DUMP_PASSES: log a compute command's buffer bindings, bytes and dispatches, and collect its
    /// textures for the dump at C_CS_END.
    fn dump_compute_command(&self, id: u64, kind: u32, body: &[u8], dump_targets: &mut Vec<(Texture, u64)>) {
        let mut c = Rd::new(body);
        match kind {
            C_CS_DISPATCH => {
                let (k, _) = (c.u32(), c.u32());
                let g = [c.u64(), c.u64(), c.u64(), c.u64(), c.u64(), c.u64()];
                eprintln!("mtlvk: cb {id:#x} dispatch kind {k} {g:?}");
            }
            C_CS_BUFFER | C_CS_BUFFER_OFFSET => {
                let b = if kind == C_CS_BUFFER { c.u64() } else { 0 };
                let (off, index) = (c.u64(), c.u32());
                let mut head = String::new();
                if let Ok(buf) = self.buf(b) {
                    if let (Some(p), true) = (buf.contents(), off < buf.length()) {
                        let n = (buf.length() - off).min(64) as usize;
                        // SAFETY: within the buffer.
                        let bytes = unsafe { std::slice::from_raw_parts(p.as_ptr().add(off as usize), n) };
                        let words: Vec<u32> = bytes.chunks_exact(4).map(|w| u32::from_le_bytes(w.try_into().unwrap())).collect();
                        head = format!("len {} {words:?}", buf.length());
                    }
                }
                eprintln!("mtlvk: cb {id:#x} compute buffer [{index}] {b:#x} +{off} {head}");
            }
            C_CS_BYTES => {
                let (index, len) = (c.u32(), c.u32());
                let words: Vec<u32> = c.bytes(len as usize).chunks(4).map(|w| {
                    let mut a = [0u8; 4];
                    a[..w.len()].copy_from_slice(w);
                    u32::from_le_bytes(a)
                }).collect();
                eprintln!("mtlvk: cb {id:#x} compute bytes [{index}]: {words:?}");
            }
            C_CS_TEXTURE => {
                if let Ok(t) = self.tex(c.u64()) {
                    dump_targets.push((t.clone(), 0));
                }
            }
            _ => {}
        }
    }

    /// x86Sim: MTLVK_DUMP_PASSES: copy `targets` (texture, level) into new buffers at this point of `cb`.
    #[allow(clippy::too_many_arguments)]
    fn dump_now(&self, cb: &CommandBuffer, targets: &mut Vec<(Texture, u64)>, dumps: &mut Vec<(String, Buffer)>, dir: &str, id: u64, npass: u32, tag: &str) -> Res<()> {
        let n = DUMPED.load(std::sync::atomic::Ordering::Relaxed);
        let mut be = cb.blit_command_encoder().map_err(err("blit encoder"))?;
        for (i, (t, level)) in targets.drain(..).enumerate() {
            let bpp = match t.pixel_format().as_raw() { 10 | 13 => 1, 30 | 25 => 2, 65 | 70 | 71 | 80 | 81 | 90 | 92 | 93 | 94 | 53 | 54 | 55 => 4, 105 | 115 => 8, 125 => 16, _ => 0 };
            if bpp == 0 || t.sample_count() > 1 { continue; }
            let (w, h) = ((t.width() >> level).max(1), (t.height() >> level).max(1));
            let bpr = (w * bpp).div_ceil(256) * 256;
            let st = self.device.new_buffer(bpr * h, ResourceOptions::shared()).map_err(err("dump buffer"))?;
            if let Err(e) = be.copy_from_texture_to_buffer(&t, 0, level, Origin::new(0, 0, 0), Size::new(w, h, 1), &st, 0, bpr, bpr * h, BlitOption::None) {
                eprintln!("mtlvk: dump copy f{} {w}x{h} level {level}: {e}", t.pixel_format().as_raw());
                continue;
            }
            dumps.push((format!("{dir}/cb{n:04}-{id:x}-{tag}{npass:02}-a{i}-l{level}-f{}-{w}x{h}-r{bpr}.raw", t.pixel_format().as_raw()), st));
        }
        be.end_encoding().map_err(err("end blit"))?;
        Ok(())
    }

    fn blit_command(&self, enc: &mut BlitCommandEncoder, kind: u32, c: &mut Rd) -> Res<()> {
        match kind {
            C_COPY_BB => {
                let (s, so, d, dof, n) = (c.u64(), c.u64(), c.u64(), c.u64(), c.u64());
                enc.copy_from_buffer_to_buffer(self.buf(s)?, so, self.buf(d)?, dof, n).map_err(err("copy buffer"))?;
            }
            C_COPY_BT => {
                let (s, so, bpr, bpi) = (c.u64(), c.u64(), c.u64(), c.u64());
                let size = Size::new(c.u64(), c.u64(), c.u64());
                let d = c.u64();
                let (slice, level) = (c.u32() as u64, c.u32() as u64);
                let origin = Origin::new(c.u64(), c.u64(), c.u64());
                self.mark(d);
                enc.copy_from_buffer_to_texture(self.buf(s)?, so, bpr, bpi, size, self.tex(d)?, slice, level, origin, BlitOption::None)
                    .map_err(err("copy buffer to texture"))?;
            }
            C_COPY_TB => {
                let s = c.u64();
                let (slice, level) = (c.u32() as u64, c.u32() as u64);
                let origin = Origin::new(c.u64(), c.u64(), c.u64());
                let size = Size::new(c.u64(), c.u64(), c.u64());
                let (d, dof, bpr, bpi) = (c.u64(), c.u64(), c.u64(), c.u64());
                enc.copy_from_texture_to_buffer(self.tex(s)?, slice, level, origin, size, self.buf(d)?, dof, bpr, bpi, BlitOption::None)
                    .map_err(err("copy texture to buffer"))?;
            }
            C_COPY_TT => {
                let s = c.u64();
                let (ss, sl) = (c.u32() as u64, c.u32() as u64);
                let so = Origin::new(c.u64(), c.u64(), c.u64());
                let size = Size::new(c.u64(), c.u64(), c.u64());
                let d = c.u64();
                let (ds, dl) = (c.u32() as u64, c.u32() as u64);
                let dor = Origin::new(c.u64(), c.u64(), c.u64());
                self.mark(d);
                enc.copy_from_texture_to_texture(self.tex(s)?, ss, sl, so, size, self.tex(d)?, ds, dl, dor).map_err(err("copy texture"))?;
            }
            C_FILL => {
                let (b, start, len, v) = (c.u64(), c.u64(), c.u64(), c.u32());
                enc.fill_buffer(self.buf(b)?, start..start + len, v as u8).map_err(err("fill"))?;
            }
            _ => {
                let t = c.u64();
                enc.generate_mipmaps(self.tex(t)?).map_err(err("mipmaps"))?;
            }
        }
        Ok(())
    }

    fn compute_command(&self, enc: &mut ComputeCommandEncoder, kind: u32, c: &mut Rd) -> Res<()> {
        let e = |e: metal2vulkan_runtime::Error| e.to_string();
        match kind {
            C_CS_PIPELINE => {
                let id = c.u64();
                let failed = matches!(self.objs.get(&id), Some(Obj::PsoFailed));
                self.skip_draws.set(failed);
                if !failed {
                    enc.set_compute_pipeline_state(self.pso(id)?).map_err(e)?;
                }
            }
            C_CS_BUFFER => {
                let (b, off, index) = (c.u64(), c.u64(), c.u32());
                let b = if b == 0 { None } else { Some(self.buf(b)?) };
                enc.set_buffer(b, off, index).map_err(e)?;
            }
            C_CS_BUFFER_OFFSET => {
                let (off, index) = (c.u64(), c.u32());
                enc.set_buffer_offset(off, index).map_err(e)?;
            }
            C_CS_BYTES => {
                let (index, len) = (c.u32(), c.u32());
                enc.set_bytes(c.bytes(len as usize), index).map_err(e)?;
            }
            C_CS_TEXTURE => {
                let (t, index) = (c.u64(), c.u32());
                self.mark(t);
                let t = if t == 0 { None } else { Some(self.tex(t)?) };
                enc.set_texture(t, index).map_err(e)?;
            }
            C_CS_SAMPLER => {
                let (s, index, has_lod, lmin, lmax) = (c.u64(), c.u32(), c.u32(), c.f32(), c.f32());
                let s = if s == 0 { None } else { Some(self.sampler(s)?) };
                if has_lod != 0 {
                    enc.set_sampler_state_with_lod_clamps(s, lmin, lmax, index).map_err(e)?;
                } else {
                    enc.set_sampler_state(s, index).map_err(e)?;
                }
            }
            C_CS_TGMEM => {
                let (len, index) = (c.u32(), c.u32());
                enc.set_threadgroup_memory_length(len, index).map_err(e)?;
            }
            C_CS_DISPATCH => {
                let (k, _) = (c.u32(), c.u32());
                let grid = Size::new(c.u64(), c.u64(), c.u64());
                let group = Size::new(c.u64(), c.u64(), c.u64());
                if self.skip_draws.get() {
                } else if k == 0 {
                    enc.dispatch_threads(grid, group).map_err(e)?;
                } else {
                    enc.dispatch_threadgroups(grid, group).map_err(e)?;
                }
            }
            C_CS_DISPATCH_INDIRECT => {
                let (ib, off) = (c.u64(), c.u64());
                let group = Size::new(c.u64(), c.u64(), c.u64());
                if !self.skip_draws.get() {
                    enc.dispatch_threadgroups_indirect(self.buf(ib)?, off, group).map_err(e)?;
                }
            }
            C_CS_BARRIER => {
                let scope = BarrierScope::try_from(c.u64() as u32).map_err(err("barrier scope"))?;
                enc.memory_barrier_with_scope(scope);
            }
            C_CS_USE => {
                let (res, usage, is_tex) = (c.u64(), c.u32(), c.u32());
                let usage = ResourceUsage::try_from(usage).map_err(err("usage"))?;
                let r = if is_tex != 0 { ResourceRef::Texture(self.tex(res)?) } else { ResourceRef::Buffer(self.buf(res)?) };
                enc.use_resource(r, usage).map_err(e)?;
            }
            _ => return Err(format!("unknown compute command {kind}")),
        }
        Ok(())
    }

    fn render_command(&self, enc: &mut RenderCommandEncoder, kind: u32, c: &mut Rd) -> Res<()> {
        let e = |e: metal2vulkan_runtime::Error| e.to_string();
        match kind {
            C_RE_PIPELINE => {
                let id = c.u64();
                let failed = matches!(self.objs.get(&id), Some(Obj::RpsFailed));
                self.skip_draws.set(failed);
                if !failed {
                    enc.set_render_pipeline_state(self.rps(id)?).map_err(e)?;
                }
            }
            C_RE_BUFFER => {
                let (b, off, stage, index) = (c.u64(), c.u64(), c.u32(), c.u32());
                let b = if b == 0 { None } else { Some(self.buf(b)?) };
                if stage == 0 { enc.set_vertex_buffer(b, off, index) } else { enc.set_fragment_buffer(b, off, index) }.map_err(e)?;
            }
            C_RE_BUFFER_OFFSET => {
                let (off, stage, index) = (c.u64(), c.u32(), c.u32());
                if stage == 0 { enc.set_vertex_buffer_offset(off, index) } else { enc.set_fragment_buffer_offset(off, index) }.map_err(e)?;
            }
            C_RE_BYTES => {
                let (stage, index, len, _) = (c.u32(), c.u32(), c.u32(), c.u32());
                let bytes = c.bytes(len as usize);
                if stage == 0 { enc.set_vertex_bytes(bytes, index) } else { enc.set_fragment_bytes(bytes, index) }.map_err(e)?;
            }
            C_RE_TEXTURE => {
                let (t, stage, index) = (c.u64(), c.u32(), c.u32());
                let t = if t == 0 { None } else { Some(self.tex(t)?) };
                if stage == 0 { enc.set_vertex_texture(t, index) } else { enc.set_fragment_texture(t, index) }.map_err(e)?;
            }
            C_RE_SAMPLER => {
                let (s, stage, index, has_lod, lmin, lmax) = (c.u64(), c.u32(), c.u32(), c.u32(), c.f32(), c.f32());
                let s = if s == 0 { None } else { Some(self.sampler(s)?) };
                if has_lod != 0 {
                    let (mn, mx) = ([lmin], [lmax]);
                    let clamps = Some((&mn[..], &mx[..]));
                    if stage == 0 { enc.set_vertex_sampler_states(&[s], clamps, index) } else { enc.set_fragment_sampler_states(&[s], clamps, index) }
                        .map_err(e)?;
                } else if stage == 0 {
                    enc.set_vertex_sampler_state(s, index).map_err(e)?;
                } else {
                    enc.set_fragment_sampler_state(s, index).map_err(e)?;
                }
            }
            C_RE_VIEWPORT => {
                let v = Viewport::new(c.f64(), c.f64(), c.f64(), c.f64(), c.f64(), c.f64());
                enc.set_viewport(v).map_err(e)?;
            }
            C_RE_SCISSOR => {
                let s = ScissorRect::new(c.u64(), c.u64(), c.u64(), c.u64());
                enc.set_scissor_rect(s).map_err(e)?;
            }
            C_RE_VIEWPORTS => {
                let n = c.u32() as usize;
                c.u32();
                let vs: Vec<Viewport> = (0..n.min(16)).map(|_| Viewport::new(c.f64(), c.f64(), c.f64(), c.f64(), c.f64(), c.f64())).collect();
                enc.set_viewports(&vs).map_err(e)?;
            }
            C_RE_SCISSORS => {
                let n = c.u32() as usize;
                c.u32();
                let rs: Vec<ScissorRect> = (0..n.min(16)).map(|_| ScissorRect::new(c.u64(), c.u64(), c.u64(), c.u64())).collect();
                enc.set_scissor_rects(&rs).map_err(e)?;
            }
            C_RE_CULL => enc.set_cull_mode(CullMode::try_from(c.u32()).map_err(err("cull mode"))?),
            C_RE_WINDING => enc.set_front_facing_winding(Winding::try_from(c.u32()).map_err(err("winding"))?),
            C_RE_FILL => enc.set_triangle_fill_mode(TriangleFillMode::try_from(c.u32()).map_err(err("fill mode"))?).map_err(e)?,
            C_RE_DEPTH_CLIP => enc.set_depth_clip_mode(DepthClipMode::try_from(c.u32()).map_err(err("clip mode"))?).map_err(e)?,
            C_RE_DEPTH_BIAS => {
                let (b, s, cl) = (c.f32(), c.f32(), c.f32());
                enc.set_depth_bias(b, s, cl).map_err(e)?;
            }
            C_RE_STENCIL_REF => {
                let (f, b) = (c.u32(), c.u32());
                enc.set_stencil_reference_values(f, b);
            }
            C_RE_BLEND_COLOR => {
                let (r, g, b, a) = (c.f32(), c.f32(), c.f32(), c.f32());
                enc.set_blend_color(r, g, b, a);
            }
            C_RE_DSS => {
                let id = c.u64();
                let s = if id == 0 { None } else { Some(self.dss(id)?) };
                enc.set_depth_stencil_state(s).map_err(e)?;
            }
            C_RE_DRAW => {
                let (p, start, count, inst, base) = (c.u32(), c.u32(), c.u32(), c.u32(), c.u32());
                let p = PrimitiveType::try_from(p).map_err(err("primitive"))?;
                if !self.skip_draws.get() {
                    enc.draw_primitives(p, start, count, inst, base).map_err(e)?;
                }
            }
            C_RE_DRAW_INDEXED => {
                let (p, count, it, inst) = (c.u32(), c.u32(), c.u32(), c.u32());
                let (ib, off, base_vertex, base_inst) = (c.u64(), c.u64(), c.i32(), c.u32());
                let p = PrimitiveType::try_from(p).map_err(err("primitive"))?;
                let it = IndexType::try_from(it).map_err(err("index type"))?;
                if !self.skip_draws.get() {
                    enc.draw_indexed_primitives(p, count, it, self.buf(ib)?, off, inst, base_vertex, base_inst).map_err(e)?;
                }
            }
            C_RE_DRAW_INDIRECT => {
                let (p, _pad, ib, off) = (c.u32(), c.u32(), c.u64(), c.u64());
                let p = PrimitiveType::try_from(p).map_err(err("primitive"))?;
                if !self.skip_draws.get() {
                    enc.draw_primitives_indirect(p, self.buf(ib)?, off).map_err(e)?;
                }
            }
            C_RE_DRAW_INDEXED_INDIRECT => {
                let (p, it, xb, xoff, ib, off) = (c.u32(), c.u32(), c.u64(), c.u64(), c.u64(), c.u64());
                let p = PrimitiveType::try_from(p).map_err(err("primitive"))?;
                let it = IndexType::try_from(it).map_err(err("index type"))?;
                if !self.skip_draws.get() {
                    enc.draw_indexed_primitives_indirect(p, it, self.buf(xb)?, xoff, self.buf(ib)?, off).map_err(e)?;
                }
            }
            C_RE_USE => {
                let (res, usage, is_tex) = (c.u64(), c.u32(), c.u32());
                let usage = ResourceUsage::try_from(usage).map_err(err("usage"))?;
                let r = if is_tex != 0 { ResourceRef::Texture(self.tex(res)?) } else { ResourceRef::Buffer(self.buf(res)?) };
                enc.use_resource(r, usage, RenderStages::VERTEX | RenderStages::FRAGMENT).map_err(e)?;
            }
            _ => return Err(format!("unknown render command {kind}")),
        }
        Ok(())
    }

    fn pass(&self, c: &mut Rd) -> Res<RenderPassDescriptor> {
        let mut pass = RenderPassDescriptor::new();
        let mut resolves: Vec<(Option<Texture>, u64, u64)> = Vec::new();
        let mut att = |c: &mut Rd| -> Res<(Option<Texture>, u64, u64, u64, u64, u64, [f64; 4])> {
            let t = c.u64();
            let (level, slice, plane, load, store, _pad) = (c.u32(), c.u32(), c.u32(), c.u32(), c.u32(), c.u32());
            let clear = [c.f64(), c.f64(), c.f64(), c.f64()];
            let (rt, rl, rs) = (c.u64(), c.u32(), c.u32());
            self.mark(t);
            self.mark(rt);
            let tex = if t == 0 { None } else { Some(self.tex(t)?.clone()) };
            resolves.push((if rt == 0 { None } else { Some(self.tex(rt)?.clone()) }, rl as u64, rs as u64));
            Ok((tex, level as u64, slice as u64, plane as u64, load as u64, store as u64, clear))
        };
        let mut colors = Vec::new();
        for _ in 0..MAX_COLOR {
            colors.push(att(c)?);
        }
        let depth = att(c)?;
        let stencil = att(c)?;
        for (i, (tex, level, slice, plane, load, store, clear)) in colors.into_iter().enumerate() {
            if tex.is_none() || i >= pass.color_attachments.len() {
                continue;
            }
            let a = &mut pass.color_attachments[i];
            a.texture = tex;
            a.level = level;
            a.slice = slice;
            a.depth_plane = plane;
            a.load_action = LoadAction::from_raw(load).map_err(err("load action"))?;
            a.store_action = StoreAction::from_raw(store).map_err(err("store action"))?;
            a.clear_color = ClearColor::new(clear[0], clear[1], clear[2], clear[3]);
            (a.resolve_texture, a.resolve_level, a.resolve_slice) = resolves[i].clone();
        }
        let (tex, level, slice, plane, load, store, clear) = depth;
        if tex.is_some() {
            let a = &mut pass.depth_attachment;
            a.texture = tex;
            a.level = level;
            a.slice = slice;
            a.depth_plane = plane;
            a.load_action = LoadAction::from_raw(load).map_err(err("load action"))?;
            a.store_action = StoreAction::from_raw(store).map_err(err("store action"))?;
            a.clear_depth = clear[0];
            (a.resolve_texture, a.resolve_level, a.resolve_slice) = resolves[MAX_COLOR].clone();
        }
        let (tex, level, slice, plane, load, store, clear) = stencil;
        if tex.is_some() {
            let a = &mut pass.stencil_attachment;
            a.texture = tex;
            a.level = level;
            a.slice = slice;
            a.depth_plane = plane;
            a.load_action = LoadAction::from_raw(load).map_err(err("load action"))?;
            a.store_action = StoreAction::from_raw(store).map_err(err("store action"))?;
            a.clear_stencil = clear[1] as u32;
            (a.resolve_texture, a.resolve_level, a.resolve_slice) = resolves[MAX_COLOR + 1].clone();
        }
        let (w, h, layers, samples) = (c.u64(), c.u64(), c.u64(), c.u64());
        pass.render_target_width = w;
        pass.render_target_height = h;
        pass.render_target_array_length = layers;
        pass.default_raster_sample_count = samples;
        Ok(pass)
    }
}

/// Reads one message header, picking up SCM_RIGHTS fds that came with it.
fn recv_header(fd: RawFd) -> std::io::Result<([u8; 16], Option<RawFd>)> {
    let mut hdr = [0u8; 16];
    let mut got = 0usize;
    let mut passed = None;
    while got < 16 {
        let mut iov = libc::iovec { iov_base: hdr[got..].as_mut_ptr().cast(), iov_len: 16 - got };
        let mut cbuf = [0u64; 8];
        // SAFETY: zeroed msghdr filled with valid buffers.
        let mut msg: libc::msghdr = unsafe { std::mem::zeroed() };
        msg.msg_iov = &mut iov;
        msg.msg_iovlen = 1;
        msg.msg_control = cbuf.as_mut_ptr().cast();
        msg.msg_controllen = std::mem::size_of_val(&cbuf);
        // SAFETY: as above.
        let n = unsafe { libc::recvmsg(fd, &mut msg, libc::MSG_CMSG_CLOEXEC) };
        if n < 0 {
            let e = std::io::Error::last_os_error();
            if e.kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            return Err(e);
        }
        if n == 0 {
            return Err(std::io::ErrorKind::UnexpectedEof.into());
        }
        // SAFETY: walking the control messages recvmsg wrote.
        unsafe {
            let mut cm = libc::CMSG_FIRSTHDR(&msg);
            while !cm.is_null() {
                if (*cm).cmsg_level == libc::SOL_SOCKET && (*cm).cmsg_type == libc::SCM_RIGHTS {
                    let fds = ((*cm).cmsg_len as usize - libc::CMSG_LEN(0) as usize) / 4;
                    let data = libc::CMSG_DATA(cm) as *const RawFd;
                    for i in 0..fds {
                        let f = *data.add(i);
                        if passed.is_none() {
                            passed = Some(f);
                        } else {
                            libc::close(f);
                        }
                    }
                }
                cm = libc::CMSG_NXTHDR(&msg, cm);
            }
        }
        got += n as usize;
    }
    Ok((hdr, passed))
}

pub fn serve(n: usize, device: Device, stream: UnixStream) {
    let writer = Arc::new(Mutex::new(stream.try_clone().expect("clone stream")));
    let out: Sink = Arc::new(move |op, seq, payload: Vec<u8>| {
        let mut m = Vec::with_capacity(16 + payload.len());
        m.extend_from_slice(&op.to_le_bytes());
        m.extend_from_slice(&(payload.len() as u32).to_le_bytes());
        m.extend_from_slice(&seq.to_le_bytes());
        m.extend_from_slice(&payload);
        let _ = writer.lock().unwrap().write_all(&m);
    });
    let mut state = match State::new(device, out.clone()) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("mtlvk: conn{n}: {e}");
            return;
        }
    };
    let fd = stream.as_raw_fd();
    let mut reader = &stream;
    eprintln!("mtlvk: conn{n}: connected");
    loop {
        let (hdr, passed) = match recv_header(fd) {
            Ok(h) => h,
            Err(e) => {
                eprintln!("mtlvk: conn{n}: closed ({e})");
                return;
            }
        };
        let op = u32::from_le_bytes(hdr[0..4].try_into().unwrap());
        let size = u32::from_le_bytes(hdr[4..8].try_into().unwrap()) as usize;
        let seq = u64::from_le_bytes(hdr[8..16].try_into().unwrap());
        let mut payload = vec![0u8; size];
        if reader.read_exact(&mut payload).is_err() {
            eprintln!("mtlvk: conn{n}: truncated message");
            return;
        }
        if state.log {
            eprintln!("mtlvk: conn{n}: op {op} size {size} seq {seq}{}", if passed.is_some() { " +fd" } else { "" });
        }
        // SAFETY: recvmsg gave us this fd; nothing else owns it.
        let reply = state.handle(op, &payload, passed.map(|f| unsafe { OwnedFd::from_raw_fd(f) }));
        if let Some(reply) = reply {
            if seq != 0 {
                out(op | REPLY, seq, reply);
            }
        }
    }
}

/// Exercises the handlers on this GPU the way metalhostd drives them, with a memfd as the app's memory.
pub fn selftest(device: &Device) -> Res<()> {
    let (tx, rx) = std::sync::mpsc::channel::<(u32, Vec<u8>)>();
    let tx = Mutex::new(tx);
    let mut s = State::new(device.clone(), Arc::new(move |op, _, p| {
        let _ = tx.lock().unwrap().send((op, p));
    }))?;
    s.log = true;
    let h = s.handle(HELLO, &[], None).unwrap();
    let mut r = Rd::new(&h);
    let (reg, _, _, _, nl) = (r.u64(), r.u64(), r.u64(), r.u32(), r.u32());
    println!("hello: registryID {reg:#x} name {}", String::from_utf8_lossy(r.bytes(nl as usize)));

    // the app's buffer: a memfd mapped here (as metalhostd maps it), handed over by fd
    const LEN: usize = 64 * 64 * 4;
    // SAFETY: plain syscalls.
    let memfd = unsafe { libc::memfd_create(c"selftest".as_ptr(), 0) };
    unsafe { libc::ftruncate(memfd, (2 * LEN) as i64) };
    let app = unsafe { libc::mmap(std::ptr::null_mut(), 2 * LEN, libc::PROT_READ | libc::PROT_WRITE, libc::MAP_SHARED, memfd, 0) } as *mut u8;
    let app = unsafe { std::slice::from_raw_parts_mut(app, 2 * LEN) };
    for (i, b) in app[..LEN].iter_mut().enumerate() {
        *b = (i % 251) as u8;
    }
    let mut w = Wr::default();
    w.u64(1).u64((2 * LEN) as u64).u64(0).u64(0).u32(1).u32(1);
    let rep = s.handle(BUF_NEW, &w.0, Some(unsafe { OwnedFd::from_raw_fd(libc::dup(memfd)) })).unwrap();
    let mut r = Rd::new(&rep);
    let (st, copied) = (r.u32() as i32, r.u32());
    println!("buffer: status {st} copied {copied} mirrored {}", s.mirrors.contains_key(&1));
    if st != 0 {
        return Err("BUF_NEW failed".into());
    }
    // texture 64x64 RGBA8, private, render target
    let mut w = Wr::default();
    w.u64(2).u32(2).u32(70).u64(64).u64(64).u64(1).u32(1).u32(1).u64(1).u64(0x20).u64(0x4 | 0x1).u32(0x03020100).u32(1);
    let rep = s.handle(TEX_NEW, &w.0, None).unwrap();
    if rep[0] != 0 {
        return Err("TEX_NEW failed".into());
    }
    let mut w = Wr::default();
    w.u64(3);
    s.handle(QUEUE_NEW, &w.0, None);
    let mut w = Wr::default();
    w.u64(4).u32(1).u32(0);
    s.handle(EVENT_NEW, &w.0, None);

    // cb: clear texture to (0.25, 0.5, 0.75, 1), copy it into the second half of the buffer, copy the first
    // half's first 16 bytes over its last 16 bytes, signal event 4 = 7
    let mut pass = Wr::default();
    for i in 0..MAX_COLOR {
        pass.u64(if i == 0 { 2 } else { 0 }).u32(0).u32(0).u32(0).u32(2).u32(1).u32(0);
        pass.f64(0.25).f64(0.5).f64(0.75).f64(1.0).u64(0).u32(0).u32(0);
    }
    for _ in 0..2 {
        pass.u64(0).u32(0).u32(0).u32(0).u32(0).u32(0).u32(0).f64(0.0).f64(0.0).f64(0.0).f64(0.0).u64(0).u32(0).u32(0);
    }
    pass.u64(64).u64(64).u64(0).u64(1);
    let mut cmds = Wr::default();
    cmds.u32(C_RENDER_PASS).u32(pass.0.len() as u32).bytes(&pass.0);
    let mut tb = Wr::default();
    tb.u64(2).u32(0).u32(0).u64(0).u64(0).u64(0).u64(64).u64(64).u64(1).u64(1).u64(LEN as u64).u64(256).u64(LEN as u64).u64(0);
    cmds.u32(C_COPY_TB).u32(tb.0.len() as u32).bytes(&tb.0);
    let mut bb = Wr::default();
    bb.u64(1).u64(0).u64(1).u64((LEN - 16) as u64).u64(16);
    cmds.u32(C_COPY_BB).u32(bb.0.len() as u32).bytes(&bb.0);
    let mut sg = Wr::default();
    sg.u64(4).u64(7);
    cmds.u32(C_SIGNAL).u32(sg.0.len() as u32).bytes(&sg.0);
    let mut w = Wr::default();
    w.u64(3).u64(10).u32(4).u32(0).bytes(&cmds.0);
    s.handle(CB_COMMIT, &w.0, None);
    let (op, p) = rx.recv_timeout(std::time::Duration::from_secs(10)).map_err(err("completion"))?;
    let mut r = Rd::new(&p);
    let (cb, status, error) = (r.u64(), r.u32(), r.u32());
    println!("completion: op {op} cb {cb} status {status} error {error}");
    if status != 4 {
        return Err("command buffer failed".into());
    }
    let px = &app[LEN..LEN + 4];
    println!("cleared texel via memfd: {px:?}");
    // the device rounds the clear colour its own way (metal2vulkan-degrade-device-color-conversion): +-1 per channel
    if px.iter().zip([64u8, 128, 191, 255]).any(|(&g, w)| g.abs_diff(w) > 1) {
        return Err(format!("texel {px:?}"));
    }
    if app[LEN - 16..LEN] != app[0..16] {
        return Err("buffer copy not visible".into());
    }
    let mut w = Wr::default();
    w.u64(4);
    let v = u64::from_le_bytes(s.handle(EVENT_GET, &w.0, None).unwrap()[..8].try_into().unwrap());
    println!("event value: {v}");
    if v != 7 {
        return Err("event".into());
    }
    // replaceRegion / getBytes round trip on the private texture
    let src: Vec<u8> = (0..16 * 4).map(|i| i as u8).collect();
    let mut w = Wr::default();
    w.u64(2).u64(8).u64(8).u64(0).u64(4).u64(4).u64(1).u32(0).u32(0).u64(16).u64(64).u64(64).bytes(&src);
    s.handle(TEX_REPLACE, &w.0, None);
    let mut w = Wr::default();
    w.u64(2).u64(8).u64(8).u64(0).u64(4).u64(4).u64(1).u32(0).u32(0).u64(16).u64(64).u64(64);
    let rep = s.handle(TEX_GETBYTES, &w.0, None).unwrap();
    if rep[16..] != src[..] {
        return Err(format!("getBytes {:?}", &rep[16..32]));
    }
    println!("replaceRegion/getBytes round trip ok");

    // x86Sim Speed 1c: IOSurface row pitch must survive VRAM copy-back.
    // Arm64 home is 1206 wide: tight rows are 4824 bytes, IOSurface/ring stride is 4864 (64-byte
    // aligned). A write that uses width*4 into that buffer shows as thin diagonal lines when the
    // ring is read with the real stride (pad/4 = 10 px of shift per row). The x86 device is 1179
    // wide (4716 tight vs 4736 aligned): same class of bug, smaller pad. This probe uses the arm64
    // sizes and checks every row's content and that the 40-byte pad is untouched.
    {
        const W: u64 = 1206;
        const H: u64 = 900; // >= VRAM_MIN_PIXELS (1e6) so the VRAM proxy path runs
        const BPR: u64 = 4864; // align64(1206*4)
        const TIGHT: u64 = W * 4;
        const PAD: u64 = BPR - TIGHT; // 40
        assert_eq!(PAD, 40);
        let bytes = (BPR * H) as usize;
        let memfd = unsafe { libc::memfd_create(c"stride".as_ptr(), 0) };
        unsafe { libc::ftruncate(memfd, bytes as i64) };
        let base = unsafe {
            libc::mmap(
                std::ptr::null_mut(),
                bytes,
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_SHARED,
                memfd,
                0,
            )
        } as *mut u8;
        let surf = unsafe { std::slice::from_raw_parts_mut(base, bytes) };
        surf.fill(0xCD);
        let mut w = Wr::default();
        w.u64(0x101).u64(bytes as u64).u64(0).u64(0).u32(1).u32(1);
        let rep = s.handle(BUF_NEW, &w.0, Some(unsafe { OwnedFd::from_raw_fd(libc::dup(memfd)) })).unwrap();
        if Rd::new(&rep).u32() != 0 {
            return Err("stride BUF_NEW failed".into());
        }
        // TEX_NEW_BUF: id, buffer, texdesc, offset, bytesPerRow, iosurface=1, planar=0
        // BGRA8Unorm=80, Type2D=2, Shared=0, usage RenderTarget|ShaderRead = 0x4|0x1
        let mut w = Wr::default();
        w.u64(0x102)
            .u64(0x101)
            .u32(2)
            .u32(80)
            .u64(W)
            .u64(H)
            .u64(1)
            .u32(1)
            .u32(1)
            .u64(1)
            .u64(0)
            .u64(0x4 | 0x1)
            .u32(0x03020100)
            .u32(1)
            .u64(0)
            .u64(BPR)
            .u32(1)
            .u32(0);
        let rep = s.handle(TEX_NEW_BUF, &w.0, None).unwrap();
        if rep[0] != 0 {
            return Err(format!("stride TEX_NEW_BUF failed: {:?}", &rep[..4.min(rep.len())]));
        }
        if !s.proxies.contains_key(&0x102) {
            return Err("stride: expected VRAM proxy for 1206x900 IOSurface render target".into());
        }
        let mut w = Wr::default();
        w.u64(0x103);
        s.handle(QUEUE_NEW, &w.0, None);
        // Clear the (proxied) texture to opaque red in BGRA = (0, 0, 255, 255)
        let mut pass = Wr::default();
        for i in 0..MAX_COLOR {
            pass.u64(if i == 0 { 0x102 } else { 0 })
                .u32(0)
                .u32(0)
                .u32(0)
                .u32(2)
                .u32(1)
                .u32(0);
            pass.f64(1.0).f64(0.0).f64(0.0).f64(1.0).u64(0).u32(0).u32(0);
        }
        for _ in 0..2 {
            pass.u64(0)
                .u32(0)
                .u32(0)
                .u32(0)
                .u32(0)
                .u32(0)
                .u32(0)
                .f64(0.0)
                .f64(0.0)
                .f64(0.0)
                .f64(0.0)
                .u64(0)
                .u32(0)
                .u32(0);
        }
        pass.u64(W).u64(H).u64(0).u64(1);
        let mut cmds = Wr::default();
        cmds.u32(C_RENDER_PASS).u32(pass.0.len() as u32).bytes(&pass.0);
        let mut w = Wr::default();
        w.u64(0x103).u64(0x11).u32(1).u32(0).bytes(&cmds.0);
        s.handle(CB_COMMIT, &w.0, None);
        let (op, p) = rx.recv_timeout(std::time::Duration::from_secs(30)).map_err(err("stride completion"))?;
        let mut r = Rd::new(&p);
        let (cb, status, error) = (r.u64(), r.u32(), r.u32());
        println!("stride completion: op {op} cb {cb} status {status} error {error}");
        if status != 4 {
            return Err("stride command buffer failed".into());
        }
        let mut bad_px = 0u64;
        let mut bad_pad = 0u64;
        for y in 0..H {
            let row = (y * BPR) as usize;
            for x in 0..W {
                let o = row + (x * 4) as usize;
                let px = [surf[o], surf[o + 1], surf[o + 2], surf[o + 3]];
                // BGRA clear red; allow +-1 on the converted channel
                if px[0] > 1 || px[1] > 1 || px[2] < 254 || px[3] < 254 {
                    bad_px += 1;
                    if bad_px <= 3 {
                        println!("stride bad texel ({x},{y}) BGRA={px:?}");
                    }
                }
            }
            for p in 0..PAD {
                if surf[row + TIGHT as usize + p as usize] != 0xCD {
                    bad_pad += 1;
                }
            }
        }
        println!(
            "stride 1206x{H} bpr {BPR}: {bad_px} wrong texels, {bad_pad} pad bytes overwritten (want 0, 0)"
        );
        if bad_px != 0 || bad_pad != 0 {
            return Err(format!(
                "stride mismatch: {bad_px} wrong texels, {bad_pad} pad bytes clobbered (tight write into padded IOSurface)"
            ));
        }
        unsafe {
            libc::munmap(base.cast(), bytes);
            libc::close(memfd);
        }
        println!("IOSurface VRAM copy-back stride 1206/4864 ok");
    }
    Ok(())
}

/// Stage 4 on this GPU through the handlers: library, functions (with constants), pipelines, compute
/// dispatches over memfd-imported buffers, setBytes, threadgroup memory, a buffer of GPU addresses.
pub fn selftest_compute(device: &Device, metallib: &[u8]) -> Res<()> {
    let (tx, rx) = std::sync::mpsc::channel::<(u32, Vec<u8>)>();
    let tx = Mutex::new(tx);
    let mut s = State::new(device.clone(), Arc::new(move |op, _, p| {
        let _ = tx.lock().unwrap().send((op, p));
    }))?;
    s.log = true;
    let mut w = Wr::default();
    w.u64(100).u64(metallib.len() as u64).bytes(metallib);
    let rep = s.handle(LIB_NEW, &w.0, None).unwrap();
    if rep[0..4] != [0, 0, 0, 0] {
        return Err("LIB_NEW failed".into());
    }
    let func = |s: &mut State, id: u64, name: &str, consts: &[(u32, u32, Vec<u8>)]| -> Res<()> {
        let mut w = Wr::default();
        w.u64(id).u64(100).u32(name.len() as u32).u32(consts.len() as u32).bytes(name.as_bytes());
        for (i, t, b) in consts {
            w.u32(*i).u32(*t).u32(b.len() as u32).u32(0).bytes(b);
        }
        let rep = s.handle(FUNC_NEW, &w.0, None).unwrap();
        if rep[0..4] != [0, 0, 0, 0] {
            return Err(format!("FUNC_NEW {name}"));
        }
        let mut w = Wr::default();
        w.u64(id + 1).u64(id).u32(0).u32(0);
        let rep = s.handle(CPS_NEW, &w.0, None).unwrap();
        let mut r = Rd::new(&rep);
        let (st, tew, max) = (r.u32(), r.u32(), r.u32());
        println!("pipeline {name}: status {st} threadExecutionWidth {tew} maxTotalThreadsPerThreadgroup {max}");
        if st != 0 { Err(format!("CPS_NEW {name}")) } else { Ok(()) }
    };
    func(&mut s, 200, "vadd", &[])?;
    // MTLDataTypeFloat = 3, Bool = 53, Int = 29
    func(&mut s, 210, "fconst", &[(0, 3, 2.5f32.to_le_bytes().to_vec()), (1, 53, vec![1]), (2, 29, 3i32.to_le_bytes().to_vec())])?;
    func(&mut s, 220, "reduce_sum", &[])?;
    func(&mut s, 230, "via_ptr", &[])?;

    const N: usize = 1024;
    let mk = |s: &mut State, id: u64, init: &dyn Fn(usize) -> f32| -> Res<&'static mut [f32]> {
        // SAFETY: plain syscalls; the mapping is leaked for the test.
        let fd = unsafe { libc::memfd_create(c"selftest".as_ptr(), 0) };
        unsafe { libc::ftruncate(fd, (N * 4) as i64) };
        let p = unsafe { libc::mmap(std::ptr::null_mut(), N * 4, libc::PROT_READ | libc::PROT_WRITE, libc::MAP_SHARED, fd, 0) } as *mut f32;
        let v = unsafe { std::slice::from_raw_parts_mut(p, N) };
        for (i, x) in v.iter_mut().enumerate() {
            *x = init(i);
        }
        let mut w = Wr::default();
        w.u64(id).u64((N * 4) as u64).u64(0).u64(0).u32(1).u32(1);
        let rep = s.handle(BUF_NEW, &w.0, Some(unsafe { OwnedFd::from_raw_fd(fd) })).unwrap();
        if rep[0..4] != [0, 0, 0, 0] {
            return Err("BUF_NEW".into());
        }
        Ok(v)
    };
    let a = mk(&mut s, 301, &|i| i as f32)?;
    let b = mk(&mut s, 302, &|i| 2.0 * i as f32)?;
    let c = mk(&mut s, 303, &|_| -1.0)?;
    let d = mk(&mut s, 304, &|_| -1.0)?;
    let e = mk(&mut s, 306, &|_| -1.0)?;
    let gpu_of = |s: &State, id: u64| s.buf(id).unwrap().gpu_address().0;
    let mut w = Wr::default();
    w.u64(400);
    s.handle(QUEUE_NEW, &w.0, None);

    let mut cmds = Wr::default();
    let mut n = 0u32;
    let mut cmd = |k: u32, body: &Wr| {
        cmds.u32(k).u32(body.0.len() as u32).bytes(&body.0);
        n += 1;
    };
    let mut x = Wr::default();
    x.u32(0).u32(0);
    cmd(C_CS_BEGIN, &x);
    let mut x = Wr::default();
    x.u64(201);
    cmd(C_CS_PIPELINE, &x);
    for (i, id) in [301u64, 302, 303].iter().enumerate() {
        let mut x = Wr::default();
        x.u64(*id).u64(0).u32(i as u32).u32(0);
        cmd(C_CS_BUFFER, &x);
    }
    let mut x = Wr::default();
    x.u32(0).u32(0).u64(N as u64).u64(1).u64(1).u64(64).u64(1).u64(1);
    cmd(C_CS_DISPATCH, &x);
    // fconst: d = -(a * 2.5 + 3)
    let mut x = Wr::default();
    x.u64(211);
    cmd(C_CS_PIPELINE, &x);
    let mut x = Wr::default();
    x.u64(301).u64(0).u32(0).u32(0);
    cmd(C_CS_BUFFER, &x);
    let mut x = Wr::default();
    x.u64(304).u64(0).u32(1).u32(0);
    cmd(C_CS_BUFFER, &x);
    let mut x = Wr::default();
    x.u32(0).u32(0).u64(N as u64).u64(1).u64(1).u64(64).u64(1).u64(1);
    cmd(C_CS_DISPATCH, &x);
    // via_ptr through setBytes: {src = gpu(a), dst = gpu(e), count}
    let mut x = Wr::default();
    x.u64(231);
    cmd(C_CS_PIPELINE, &x);
    let mut ptrs = Wr::default();
    ptrs.u64(gpu_of(&s, 301)).u64(gpu_of(&s, 306)).u32(N as u32).u32(0);
    let mut x = Wr::default();
    x.u32(0).u32(ptrs.0.len() as u32).bytes(&ptrs.0);
    cmd(C_CS_BYTES, &x);
    for (id, usage) in [(301u64, 1u32), (306, 2)] {
        let mut x = Wr::default();
        x.u64(id).u32(usage).u32(0);
        cmd(C_CS_USE, &x);
    }
    let mut x = Wr::default();
    x.u32(0).u32(0).u64(N as u64).u64(1).u64(1).u64(64).u64(1).u64(1);
    cmd(C_CS_DISPATCH, &x);
    cmd(C_CS_END, &Wr::default());
    let mut w = Wr::default();
    w.u64(400).u64(500).u32(n).u32(0).bytes(&cmds.0);
    s.handle(CB_COMMIT, &w.0, None);
    let (_, p) = rx.recv_timeout(std::time::Duration::from_secs(20)).map_err(err("completion"))?;
    let mut r = Rd::new(&p);
    let (_, status) = (r.u64(), r.u32());
    if status != 4 {
        return Err(format!("compute command buffer status {status}"));
    }
    let bad_add = (0..N).filter(|&i| c[i] != a[i] + b[i]).count();
    let bad_fc = (0..N).filter(|&i| d[i] != -(a[i] * 2.5 + 3.0)).count();
    let bad_ptr = (0..N).filter(|&i| e[i] != a[i] * 2.0 + 1.0).count();
    println!("vadd: {bad_add} wrong; fconst: {bad_fc} wrong (d[1] = {}); via_ptr: {bad_ptr} wrong (e[1] = {})", d[1], e[1]);
    if bad_add + bad_fc + bad_ptr != 0 {
        return Err("compute results".into());
    }
    Ok(())
}

