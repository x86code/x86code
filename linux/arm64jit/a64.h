// libarm64jit: runs arm64 iOS-simulator processes inside Darling.
//
// The process is an x86_64 macOS program (host/arm64host) that Darling's mldr starts instead of an arm64-only Mach-O.
// It initializes normally with Darling's libSystem, then dlopens this ELF library through Darling's elfcalls and calls
// a64_host_main(). Guest and host share one identity-mapped address space: guest pointer == host pointer.
#pragma once
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>
#include <mutex>
#include <shared_mutex>
#include <memory>
#include <atomic>
#include <optional>
#include <dynarmic/interface/A64/a64.h>
#include <dynarmic/interface/A64/config.h>
#include <dynarmic/interface/exclusive_monitor.h>

namespace a64 {
using u64 = uint64_t;
using u32 = uint32_t;

// Darwin (x86_64 Darling) functions handed over by the Mach-O host program.
struct DarwinApi {
    uint32_t version;
    void *(*dlopen)(const char *, int);
    void *(*dlsym)(void *, const char *);
    int (*dladdr)(const void *, void *);  // Dl_info*
    int *(*error)(void);                  // __error
};
extern const DarwinApi *g_darwin;
void *dsym(const char *name);
bool is_fast_fill(const void *fn);  // dsym's replacements for Darling's bzero/memset/memset_pattern (host.cpp)  // native Darwin symbol (no leading underscore), searched in the three host libraries

// Native results of a guest->native call: rax, rdx, xmm0, xmm1.
struct NRet { u64 rax, rdx, xmm0, xmm1; };
// Calls a native SysV function: ints[0..5] in registers, ints[6..15] on the stack, fps[0..7] in xmm0-7, al = 8.
extern "C" void a64_ncall(const void *fn, const u64 *ints, const u64 *fps, NRet *ret);

struct GuestThread;
using Handler = void (*)(GuestThread &, u32 index);

// One per native thread that runs guest code: its own dynarmic Jit (guest state; a Jit is single-threaded) over the
// process-wide translation cache.
struct GuestThread final : Dynarmic::A64::UserCallbacks {
    std::unique_ptr<Dynarmic::A64::Jit> jit;
    // Perf 1e: jit's register storage (Jit::GetStatePointers), refreshed whenever jit is (re)created
    Dynarmic::A64::Jit::StatePointers st{};
    u64 stack_base = 0, stack_size = 0;
    u64 tpidr = 0, tpidrro = 0;
    static constexpr int kGuestTsdSlots = 768;
    u64 *tsd = nullptr;  // the guest's TSD array (tpidrro_el0), see GuestThread()
    u64 *native_tsd = nullptr;
    // The reserved slots 1-9 (errno, MIG reply, QoS class, special reply port, semaphore cache, ...) are shared
    // state: both sides read and write them. Copied across at every guest<->native transition.
    void tsd_to_native() { if (native_tsd) memcpy(native_tsd + 1, tsd + 1, 9 * 8); }
    void tsd_from_native() { if (native_tsd) memcpy(tsd + 1, native_tsd + 1, 9 * 8); }
    bool *done = nullptr;   // the innermost call()'s completion flag; the exit stub sets it
    int depth = 0;          // nesting of call() on this thread (native -> guest -> native -> guest ...)
    u64 svc_count = 0;
    int32_t in_thunk = -1;  // thunk running on this thread (crash reports)
    std::atomic<uint32_t> sig_pending{0};  // async signals recorded by the native handler (signals.cpp)
    uint8_t sig_info[32][104];            // their Darwin siginfo
    // Darling's thread suspension (SIGRTMIN, thread_suspend / task_suspend) deferred to a safe point (signals.cpp)
    bool native = false;                  // inside a thunk handler (not in a nested call())
    int tid = 0;
    std::atomic<int> susp_pending{0}, susp_at_safe{0}, susp_parked{0};
    int susp_tries = 0;
    void *susp_timer = nullptr;
    void susp_safe_point();               // parks here if a suspension is pending

    GuestThread();
    void reset_after_unwind();  // after a longjmp out of call() (pthread_exit)
    void run_guest_tsd_destructors();  // at thread exit (jit.cpp)
    Dynarmic::A64::UserConfig cfg;
    ~GuestThread() override;
    static GuestThread &self();
    static GuestThread *current();  // null if this thread has none  // the calling native thread's GuestThread (created on first use)

    // Runs guest code at pc with integer args x0..x7 and fp args d0..d7 until it returns to the exit stub.
    // Nested calls (from a native callee of guest code) save and restore the full guest state.
    NRet call(u64 pc, const u64 *ints, int nints, const u64 *fps = nullptr, int nfps = 0);
    u64 call(u64 pc, std::initializer_list<u64> args) { std::vector<u64> v(args); return call(pc, v.data(), (int)v.size()).rax; }

    // Perf 1e: direct reads/writes of the Jit's state (same semantics as GetRegister & co: index 31 is SP)
    u64 x(int i) { return i == 31 ? *st.sp : st.reg[i]; }
    void set_x(int i, u64 v) { if (i == 31) *st.sp = v; else st.reg[i] = v; }
    u64 d(int i) { return st.vec[2 * i]; }
    void set_d(int i, u64 bits) { st.vec[2 * i] = bits; st.vec[2 * i + 1] = 0; }
    u64 sp() { return *st.sp; }
    u64 stack_slot(int i) { return *(u64 *)(sp() + 8 * i); }

    // Top-byte-ignore: Darwin arm64 code dereferences pointers with tag bits in the top byte (Swift's _StringObject
    // discriminator). Fastmem sends addresses above 47 bits to these slow-path callbacks, which drop the top byte.
    static constexpr u64 kTbi = 0x00ffffffffffffffull;
    template <typename T> static T rd(u64 a) { T v; __builtin_memcpy(&v, (void *)(a & kTbi), sizeof v); return v; }
    template <typename T> static void wr(u64 a, T v) { __builtin_memcpy((void *)(a & kTbi), &v, sizeof v); }
    std::optional<uint32_t> MemoryReadCode(u64 a) override { return rd<uint32_t>(a); }
    uint8_t MemoryRead8(u64 a) override { return rd<uint8_t>(a); }
    uint16_t MemoryRead16(u64 a) override { return rd<uint16_t>(a); }
    uint32_t MemoryRead32(u64 a) override { return rd<uint32_t>(a); }
    u64 MemoryRead64(u64 a) override { return rd<u64>(a); }
    Dynarmic::A64::Vector MemoryRead128(u64 a) override { return rd<Dynarmic::A64::Vector>(a); }
    void MemoryWrite8(u64 a, uint8_t v) override { wr(a, v); }
    void MemoryWrite16(u64 a, uint16_t v) override { wr(a, v); }
    void MemoryWrite32(u64 a, uint32_t v) override { wr(a, v); }
    void MemoryWrite64(u64 a, u64 v) override { wr(a, v); }
    void MemoryWrite128(u64 a, Dynarmic::A64::Vector v) override { wr(a, v); }
    bool MemoryWriteExclusive8(u64 a, uint8_t v, uint8_t e) override { return __atomic_compare_exchange_n((uint8_t *)(a & kTbi), &e, v, false, 5, 5); }
    bool MemoryWriteExclusive16(u64 a, uint16_t v, uint16_t e) override { return __atomic_compare_exchange_n((uint16_t *)(a & kTbi), &e, v, false, 5, 5); }
    bool MemoryWriteExclusive32(u64 a, uint32_t v, uint32_t e) override { return __atomic_compare_exchange_n((uint32_t *)(a & kTbi), &e, v, false, 5, 5); }
    bool MemoryWriteExclusive64(u64 a, u64 v, u64 e) override { return __atomic_compare_exchange_n((u64 *)(a & kTbi), &e, v, false, 5, 5); }
    bool MemoryWriteExclusive128(u64 a, Dynarmic::A64::Vector v, Dynarmic::A64::Vector e) override;
    void InterpreterFallback(u64 pc, size_t n) override;
    void CallSVC(uint32_t swi) override;
    void ExceptionRaised(u64 pc, Dynarmic::A64::Exception e) override;
    void InstructionCacheOperationRaised(Dynarmic::A64::InstructionCacheOperation op, u64 value) override;
    void AddTicks(u64) override {}
    u64 GetTicksRemaining() override { return ~0ull; }
    u64 GetCNTPCT() override;
};

// ---- the svc boundary -------------------------------------------------------------------------------------------
// Guest code reaches native code through 8-byte stubs "svc #i; ret". Thunk i has a handler and a native target.
struct Thunk {
    std::string name;
    Handler fn;
    const void *native = nullptr;  // target of the generic handlers
    int nfixed = 0;                // variadic: number of fixed arguments
};
extern std::vector<Thunk> g_thunks;
constexpr u32 kExitSvc = 0xffff;
// "svc #0xfffe": a Linux syscall for our own arm64 shims (host/simfb's futex wake): x8 = x86_64 syscall number,
// x0-x5 arguments, result (or -errno) in x0. The runtime's code never uses svc immediates this high.
constexpr u32 kLinuxSvc = 0xfffe;
// "svc #0xfffd": Swift conformance scan step (swiftconf.cpp), substituted by MemoryReadCode, never in memory.
constexpr u32 kSwiftConfSvc = 0xfffd;
// "svc #0xfff9": Speed 29 verify mode of the conformance filter (X86SIM_A64_SWIFT_CONF_VERIFY), at the match sites.
constexpr u32 kSwiftConfVerifySvc = 0xfff9;
// Speed 30 debug (X86SIM_A64_AGDL=1, iOS 27.2 24B8117 only): AttributeGraph deadline probes, jit.cpp
constexpr u32 kAgDlSetSvc = 0xfff1, kAgDlPassedSvc = 0xfff2, kAgDlCancelSvc = 0xfff3;
// Speed 31 debug (X86SIM_A64_AGOUT=<attribute id hex>, 27.2 24B8117): AGGraphSetOutputValue / AGGraphGetOutputValue probes
constexpr u32 kAgOutSetSvc = 0xfff4, kAgOutGetSvc = 0xfff5;
// Speed 35 debug (X86SIM_A64_AGCHK=1): AG::Graph::UpdateStack::update's post-rule flags load (27.2 0x1c950c134)
constexpr u32 kAgChkSvc = 0xffd0;
// Platforms 1 debug: X86SIM_A64_BLWATCH sites (jit.cpp), substituted by MemoryReadCode
constexpr u32 kBlWatchSvc = 0xffcf;
void agout_dump(u32 attr);
// "svc #0xfffc": Swift type-by-name conformance walk step (swiftscan.cpp), substituted by MemoryReadCode.
constexpr u32 kSwiftTypeSvc = 0xfffc;
// "svc #0xfffb" / "#0xfffa": dyld_sim's loaded-loader scans (dyldsim.cpp), substituted by MemoryReadCode.
constexpr u32 kDyldScanSvcA = 0xfffb, kDyldScanSvcB = 0xfffa;
std::optional<u32> dyld_scan_read_code(u64 a);
// "svc #0xfff0": Speed 31, entry of libate's at_encoder_decompress_texels (astc.cpp), substituted by MemoryReadCode.
constexpr u32 kAstcSvc = 0xfff0;
// "svc #0xffef" / "#0xffee": Speed 32, entries of libcompression's compression_decode_buffer / lzfse_decode_buffer
// (lzfse.cpp), substituted by MemoryReadCode.
constexpr u32 kLzfseSvcA = 0xffef, kLzfseSvcB = 0xffee;
// "svc #0xffed".."#0xffea": compression_stream_init / _reinit / _process / _destroy (lzfse.cpp)
constexpr u32 kLzfseSvcInit = 0xffed, kLzfseSvcReinit = 0xffec, kLzfseSvcProc = 0xffeb, kLzfseSvcDestroy = 0xffea;
void lzfse_prepare(const std::string &cache_path);
std::optional<u32> lzfse_read_code(u64 a);
void astc_prepare(const std::string &cache_path);
std::optional<u32> astc_read_code(u64 a);
extern u64 g_exit_stub;  // "svc #0xffff": LR of every native->guest call

u32 add_thunk(const std::string &name, Handler fn, const void *native = nullptr, int nfixed = 0);
u64 stub_code(u32 index);              // guest address of thunk i's "svc #i; ret" in the shared stub page
void emit_stub(uint32_t *at, u32 index);  // writes "svc #index; ret" at a guest address
void boundary_init();
void dyld_sim_patches(u64 slide);
struct GuestThread;
void dyld_scan_step(GuestThread &t, bool loop_b);
void astc_step(GuestThread &t);
void lzfse_step(GuestThread &t, bool lzfse_entry);
void lzfse_stream_step(GuestThread &t, u32 swi);
std::optional<u32> swiftconf_read_code(u64 a);  // swiftconf.cpp: svc substituted at the Swift conformance step
void swiftconf_step(GuestThread &t);
void swiftconf_verify(GuestThread &t);
std::optional<u32> swifttype_read_code(u64 a);  // swiftscan.cpp: svc at the type-by-name conformance walk
void swifttype_step(GuestThread &t);
const std::string &scratch_dir();  // jitcache.cpp: $X86SIM_SCRATCH, else <real user home>/scratch/x86sim
const std::string &jitcache_cache_file();  // jitcache.cpp: the main dyld cache file
u32 swift_text_word(u64 a);  // swiftscan.cpp: a code word of the cache, read from its file
u64 swift_text_find(const u32 *words, const u32 *mask, size_t n);  // swiftscan.cpp: code pattern in libswiftCore
struct GuestThread;
void svc_bench(GuestThread &t);  // X86SIM_A64_SVCBENCH=n / X86SIM_A64_GUESTLIB_TEST=1 (guestlibc.cpp)
bool is_guest_libc_export(const std::string &n);
size_t emit_guest_libc(const std::string &n, uint32_t *o, u32 slow);  // dyldsim.cpp: native shortcuts in dyld_sim (after mapping, before it runs)
uint32_t thunk_count();                // acquire-load of published thunk count (see add_thunk)

// Generic handlers: integer/pointer/fp arguments straight through (x0-x7 -> rdi..r9 + stack, d0-d7 -> xmm0-7).
bool memcheck();            // X86SIM_A64_MEMCHECK=1: inline address check per guest access (RAM 3; jit.cpp)
bool strict_monitor();      // X86SIM_A64_STRICT_MONITOR=1: dynarmic's global exclusive monitor (handlers.cpp)
bool timebase_apple();       // X86SIM_A64_TIMEBASE=apple: guest mach time at 24 MHz (handlers.cpp)
void tb_convert_qos_changes(void *list, int n);  // kevent_qos_s timer changes: guest ticks -> ns (handlers.cpp)
u64 tb_ns_to_ticks(u64 ns);
void gsample_start(GuestThread *t);
void gsample_forget(GuestThread *t);  // X86SIM_A64_GSAMPLE (jit.cpp)
void h_generic(GuestThread &t, u32 i);
void h_generic_bool(GuestThread &t, u32 i);  // bool result: zero-extend al
void h_variadic(GuestThread &t, u32 i);      // fixed args in registers, the rest from guest stack slots
void h_noop(GuestThread &t, u32 i);           // leaves every register as it is (___chkstk_darwin)
void h_zero(GuestThread &t, u32 i);           // returns 0 (__libkernel_init and friends: native side is initialized)
void h_missing(GuestThread &t, u32 i);        // not provided by Darling: logs once, returns -1/ENOSYS

// Native -> guest: a native function pointer that runs guest function pc on the calling thread's Jit.
const void *guest_callable(u64 pc);
u64 guest_of_callable(const void *native);  // inverse (0 if not a trampoline)
extern "C" void a64_tramp_entry();           // callconv.S

// Special handlers for libsystem functions (handlers.cpp). Returns null if the export needs no special handling.
void h_sigaction(GuestThread &t, u32 i);  // signals.cpp
void h_platform_sigaction(GuestThread &t, u32 i);
void deliver_signals(GuestThread &t);
void susp_thread_init(GuestThread &t);  // signals.cpp: suspension wrapper, timer, port registry
void susp_thread_fini(GuestThread &t);
void h_thread_get_state(GuestThread &t, u32 i);
void h_thread_set_state(GuestThread &t, u32 i);
void h_thread_get_register_pointer_values(GuestThread &t, u32 i);
Handler special_handler(const std::string &name, int *nfixed, const char **native_name);
bool special_needs_native(const std::string &name);
bool is_guest_code_export(const std::string &name);  // setjmp family: emitted as arm64 code in the stub dylib
size_t emit_guest_code(const std::string &name, uint32_t *out, u32 slow_thunk);  // arm64 code for those, returns instruction count

// ---- stub dylibs ------------------------------------------------------------------------------------------------
// path: a real copy of the file as Darling sees it (/Volumes/SystemRoot<jitcache dir>/stubs/<name>),
// the answer to F_GETPATH on fd; empty if it could not be written
// Perf 8: fixed addresses of the libsystem stub dylibs (host.cpp stub_fixed_address): the top 1 MB of the cache window
// (cli/libexec/arm64/mkplacement.py places files below it), so their blocks are in the image and the cache's import
// stubs link to them there. Their code is the same in every process (stub_code_hash checks it, jitcache.cpp).
constexpr u64 kStubBase = 0x2FFF00000ull, kStubSlot = 0x40000ull;
u64 stub_code_hash();
u64 stub_fixed_address(const char *install);  // 0: anywhere (X86SIM_A64_STUB_FIXED=0)
void *gheap_thread_cache();  // Perf 16: this thread's gheap Cache (guest-code malloc fast paths)
bool gheap_zeroes();
void gheap_set_default_zone(u64 z);
constexpr int kHeapTsdSlot = 767;  // guest TSD slot holding gheap_thread_cache() (set by the native malloc handlers)
struct StubLib { std::string install_name; int fd = -1; size_t size = 0; std::string path; };
// Builds the arm64 stub dylib for one host library (exports from the cache placeholder's export trie).
StubLib build_stub_dylib(const std::string &install_name, const std::vector<std::string> &exports);
// addrs (optional): each export's unslid address (the cache is mapped at its fixed address), ~0 for re-exports.
std::vector<std::string> cache_exports(const std::string &cache_path, const std::string &image, std::vector<u64> *addrs = nullptr,
                                       u64 *text_lo = nullptr, u64 *text_hi = nullptr);
// Native malloc (malloc.cpp): replaces libsystem_malloc's exports in the mapped cache with thunks to Darling's malloc.
void native_malloc_prepare(const std::string &cache_path);  // before dyld_sim maps the cache: reads the exports
void native_malloc_install();
// Native / inline objc_msgSend (objc.cpp).
void native_objc_prepare(const std::string &cache_path);
void native_objc_install();
void objc_cache_gc_guard(GuestThread &t);
void sim_service_patches(GuestThread &t);
extern std::atomic<bool> g_stub_guard_armed;
void jitcache_save_on_exit();
// RAM 6: held shared by every guest call that can make memory writable or map over it (mprotect, vm_protect, mmap,
// vm_map, vm_remap, vm_allocate); exclusive while the file trim drops clean pages of the dyld cache's writable-max
// (read-only now) mappings, so no write can land between its pagemap check and the MADV_DONTNEED.
extern std::shared_mutex g_cache_prot_mu;
extern std::mutex g_text_patch_mu;  // RAM 4: held while libarm64jit patches guest __TEXT (host.cpp file trim)
extern thread_local bool g_non_darling_thread;  // logf: stderr only (plain std::thread, e.g. the cache saver)
// Speed 6: state that translated code addresses, at a fixed address (jit.cpp; shared AOT image).
struct FixedData {
    alignas(64) unsigned char callbacks[256];  // the shared code's UserCallbacks object
    alignas(64) u64 objc_hits = 0, objc_misses = 0;
};
FixedData &fixed_data();
void native_objc_configure_jit(Dynarmic::A64::UserConfig &c);  // wire inline_* into a new Jit's config
void native_objc_stats();  // hits/misses into the process log
// Persistent JIT cache (dyld shared-cache translations). Keyed by cache UUID + build id.
void jitcache_prepare(const std::string &cache_path, const std::string &exe);  // read UUID; call before first Jit
// Speed 14: fixed placement of non-cache Mach-Os (dylibs, bundles, app executables) in the free top of the cache
// window, from <jitcache dir>/placement.txt, so their translations can be persisted by address like the cache's.
struct Placement { u64 addr, slot, fsize, mtime; std::string key; };
const Placement *placement_find(const char *path);  // entry whose key ends `path` (nullptr: none)
bool placement_claim(const Placement *p, int fd);   // file matches (size, mtime) and the slot is unused here
void jitcache_set_shared(const std::shared_ptr<Dynarmic::A64::Jit::SharedCode> &sp);
void jitcache_try_load(Dynarmic::A64::Jit::SharedCode &shared);
u64 jitcache_image_code_bytes();  // Speed 18: code size of the image this process will load (0: none)
void jitcache_try_save(Dynarmic::A64::Jit::SharedCode &shared, const std::string &to = "");
void jitcache_aot_build(GuestThread &t);  // X86SIM_A64_AOT_BUILD=1: union of training .bins -> .aot
void jitcache_save_if_shared();  // no-op when SHARED=0 or no live shared code
u64 reserve_aligned(u64 size, u64 mask);  // guest-VM range [12 GB, 63 GB), PROT_NONE
// gheap.cpp
void gheap_set_native(void (*nfree)(void *), size_t (*nsize)(const void *));
void *gh_malloc(size_t); void *gh_calloc(size_t, size_t); void *gh_realloc(void *, size_t); void gh_free(void *);
void *gh_memalign(size_t align, size_t size); size_t gh_size(const void *); size_t gh_good_size(size_t);                               // from ___libkernel_init: patches the mapped cache text
void ax_euid_prepare(const std::string &cache);  // handlers.cpp: libAccessibility's text range for h_geteuid
int stub_fd_for_path(const char *path);  // open() redirect: a dup of the stub dylib's fd, or -1
const char *stub_path_for_fd(int fd);    // F_GETPATH for a stub dylib open on fd (its real copy), or nullptr

void set_guest_key_destructor(u64 key, u64 guest_dtor);  // pthread keys (handlers.cpp, jit.cpp)

// misc
void guest_backtrace(GuestThread &t);
void register_stub_symbols(const std::string &file, std::vector<std::pair<u64, std::string>> fn);  // stub dylib exports
std::string where(u64 guest_addr);  // file+offset (non-cache) or "cache"  // frame-pointer chain to the log (jit.cpp)
[[noreturn]] void die(const char *fmt, ...);
void logf(const char *fmt, ...);
extern bool g_trace;
std::string guest_format(const char *fmt, const u64 *slot);  // printf with Apple arm64 vararg slots

}  // namespace a64
