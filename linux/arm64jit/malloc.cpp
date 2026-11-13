// libarm64jit: native malloc for guest processes.
//
// Every exported function of the cache's libsystem_malloc is overwritten with "svc #i; ret" when ___libkernel_init
// runs (libSystem's initializer calls it before __malloc_init, so the guest's xzone malloc never allocates anything).
// The handlers call the native guest heap (gheap.cpp: below 64 GB, which Darling's own malloc is not). Zones: the guest sees guest-side malloc_zone_t structs whose
// function pointers are svc stubs too; all of them are backed by the native default zone (zone separation is not
// kept, malloc_destroy_zone leaks). Zones the guest builds itself and registers are called through their own guest
// function pointers. Introspection enumerates nothing.
#include "a64.h"
#include "macho.h"
#include <algorithm>
#ifndef LC_FUNCTION_STARTS
#define LC_FUNCTION_STARTS 0x26
#endif
#include <cstring>
#include <cstdio>
#include <map>
#include <mutex>
#include <set>
#include <sys/mman.h>

namespace a64 {

namespace {

struct Fn {
    void *(*malloc)(size_t);
    void *(*calloc)(size_t, size_t);
    void *(*realloc)(void *, size_t);
    void (*free)(void *);
    size_t (*size)(const void *);
    size_t (*good_size)(size_t);
} n;

std::vector<std::string> g_names;
std::vector<u64> g_addrs;
std::map<std::string, u64> g_exp;  // name -> guest address
u64 g_text_lo, g_text_hi;          // libsystem_malloc's __TEXT
bool is_text(u64 a) { return a >= g_text_lo && a < g_text_hi; }

constexpr int kZoneWords = 25;
struct GuestZone { u64 w[kZoneWords]; };
std::mutex g_mu;
std::set<u64> g_our_zones;  // guest addresses of our zone structs
GuestZone *g_default;
u64 g_introspect;
u64 *g_zone_array;          // guest malloc_zones array (ours)
u32 g_nzones = 0;

u64 stub_for(const char *name, Handler h) { return stub_code(add_thunk(name, h)); }

bool ours(u64 z) {
    if (z == (u64)g_default || !z) return true;
    std::lock_guard l(g_mu);
    return g_our_zones.count(z) != 0;
}
u64 zone_fn(u64 z, int word) { return ((u64 *)z)[word]; }

void *aligned(size_t align, size_t size) { return gh_memalign(align, size); }
void nfree(void *p) { gh_free(p); }

// ---- plain API ----
// Perf 16: the guest-code fast paths find this thread's gheap cache through TSD slot kHeapTsdSlot, set here (the first
// call on a thread is always native)
static bool g_fast_malloc;
static inline void arm_fast(GuestThread &t) { if (g_fast_malloc && !t.tsd[kHeapTsdSlot]) t.tsd[kHeapTsdSlot] = (u64)gheap_thread_cache(); }
void h_malloc(GuestThread &t, u32) { arm_fast(t); t.set_x(0, (u64)n.malloc(t.x(0))); }
void h_calloc(GuestThread &t, u32) { arm_fast(t); t.set_x(0, (u64)n.calloc(t.x(0), t.x(1))); }
void h_realloc(GuestThread &t, u32) { t.set_x(0, (u64)n.realloc((void *)t.x(0), t.x(1))); }
void h_reallocf(GuestThread &t, u32) {
    void *p = n.realloc((void *)t.x(0), t.x(1));
    if (!p && t.x(1)) nfree((void *)t.x(0));
    t.set_x(0, (u64)p);
}
void h_reallocarray(GuestThread &t, u32) {
    size_t s;
    if (__builtin_mul_overflow(t.x(1), t.x(2), &s)) { *g_darwin->error() = 12; t.set_x(0, 0); return; }
    t.set_x(0, (u64)n.realloc((void *)t.x(0), s));
}
void h_reallocarrayf(GuestThread &t, u32) {
    size_t s;
    if (__builtin_mul_overflow(t.x(1), t.x(2), &s)) { nfree((void *)t.x(0)); *g_darwin->error() = 12; t.set_x(0, 0); return; }
    void *p = n.realloc((void *)t.x(0), s);
    if (!p && s) nfree((void *)t.x(0));
    t.set_x(0, (u64)p);
}
void h_free(GuestThread &t, u32) { arm_fast(t); nfree((void *)t.x(0)); }
void h_valloc(GuestThread &t, u32) { t.set_x(0, (u64)aligned(16384, t.x(0))); }
void h_aligned_alloc(GuestThread &t, u32) { t.set_x(0, (u64)aligned(t.x(0), t.x(1))); }
void h_posix_memalign(GuestThread &t, u32) {  // (void **, align, size)
    size_t a = t.x(1);
    if (a < 8 || (a & (a - 1))) { t.set_x(0, 22); return; }
    void *p = aligned(a, t.x(2));
    if (!p) { t.set_x(0, 12); return; }
    *(void **)t.x(0) = p;
    t.set_x(0, 0);
}
void h_size(GuestThread &t, u32) { arm_fast(t); t.set_x(0, n.size((void *)t.x(0))); }
void h_good_size(GuestThread &t, u32) { arm_fast(t); t.set_x(0, n.good_size(t.x(0))); }
void h_claimed(GuestThread &t, u32) { t.set_x(0, n.size((void *)t.x(0)) != 0); }

// ---- zone API: (zone, ...) ----
// Word indices in malloc_zone_t.
enum { Z_SIZE = 2, Z_MALLOC, Z_CALLOC, Z_VALLOC, Z_FREE, Z_REALLOC, Z_DESTROY, Z_NAME, Z_BATCH_MALLOC, Z_BATCH_FREE,
       Z_INTROSPECT, Z_VERSION, Z_MEMALIGN, Z_FREE_DEF, Z_PRESSURE, Z_CLAIMED, Z_TRY_FREE_DEFAULT, Z_MALLOC_OPT,
       Z_TYPE_MALLOC, Z_TYPE_CALLOC, Z_TYPE_REALLOC, Z_TYPE_MEMALIGN, Z_TYPE_MALLOC_OPT };

// A guest zone not made by us: forward to its own function pointer.
#define FOREIGN(word, ...) \
    if (!ours(t.x(0))) { t.set_x(0, t.call(zone_fn(t.x(0), word), {__VA_ARGS__})); return; }
void hz_malloc(GuestThread &t, u32) { arm_fast(t); FOREIGN(Z_MALLOC, t.x(0), t.x(1)); t.set_x(0, (u64)n.malloc(t.x(1))); }
void hz_calloc(GuestThread &t, u32) { arm_fast(t); FOREIGN(Z_CALLOC, t.x(0), t.x(1), t.x(2)); t.set_x(0, (u64)n.calloc(t.x(1), t.x(2))); }
void hz_valloc(GuestThread &t, u32) { FOREIGN(Z_VALLOC, t.x(0), t.x(1)); t.set_x(0, (u64)aligned(16384, t.x(1))); }
void hz_realloc(GuestThread &t, u32) { FOREIGN(Z_REALLOC, t.x(0), t.x(1), t.x(2)); t.set_x(0, (u64)n.realloc((void *)t.x(1), t.x(2))); }
void hz_free(GuestThread &t, u32) { arm_fast(t); FOREIGN(Z_FREE, t.x(0), t.x(1)); nfree((void *)t.x(1)); }
void hz_size(GuestThread &t, u32) { FOREIGN(Z_SIZE, t.x(0), t.x(1)); t.set_x(0, n.size((void *)t.x(1))); }
void hz_memalign(GuestThread &t, u32) { FOREIGN(Z_MEMALIGN, t.x(0), t.x(1), t.x(2)); t.set_x(0, (u64)aligned(t.x(1), t.x(2))); }
void hz_free_def(GuestThread &t, u32) { nfree((void *)t.x(1)); }
void hz_claimed(GuestThread &t, u32) { t.set_x(0, n.size((void *)t.x(1)) != 0); }
void hz_zero(GuestThread &t, u32) { t.set_x(0, 0); }
// malloc_with_options(zone, align, size, options): MALLOC_NP_OPTION_CLEAR = 1
void hz_malloc_opt(GuestThread &t, u32) {
    void *p = aligned(t.x(1), t.x(2));
    if (p && (t.x(3) & 1)) memset(p, 0, t.x(2));
    t.set_x(0, (u64)p);
}
// type variants: (zone, size, type) / (zone, count, size, type) / (zone, ptr, size, type) / (zone, align, size, type)
void hz_type_malloc(GuestThread &t, u32 i) { hz_malloc(t, i); }
void hz_type_calloc(GuestThread &t, u32 i) { hz_calloc(t, i); }
void hz_type_realloc(GuestThread &t, u32 i) { hz_realloc(t, i); }
void hz_type_memalign(GuestThread &t, u32 i) { hz_memalign(t, i); }
// malloc_type_zone_malloc_with_options(zone, align, size, type, options)
void hz_type_malloc_opt(GuestThread &t, u32) {
    void *p = aligned(t.x(1), t.x(2));
    if (p && (t.x(4) & 1)) memset(p, 0, t.x(2));
    t.set_x(0, (u64)p);
}
// batch_malloc(zone, size, void **results, unsigned num) -> unsigned
void hz_batch_malloc(GuestThread &t, u32) {
    u32 k = 0, num = (u32)t.x(3);
    void **res = (void **)t.x(2);
    for (; k < num; k++) if (!(res[k] = n.malloc(t.x(1)))) break;
    t.set_x(0, k);
}
void hz_batch_free(GuestThread &t, u32) {  // (zone, void **, unsigned)
    void **p = (void **)t.x(1);
    for (u32 k = 0; k < (u32)t.x(2); k++) nfree(p[k]);
}
void hz_destroy(GuestThread &, u32) {}

GuestZone *make_zone(const char *name) {
    static const struct { int word; Handler h; } fns[] = {
        {Z_SIZE, hz_size}, {Z_MALLOC, hz_malloc}, {Z_CALLOC, hz_calloc}, {Z_VALLOC, hz_valloc}, {Z_FREE, hz_free},
        {Z_REALLOC, hz_realloc}, {Z_DESTROY, hz_destroy}, {Z_BATCH_MALLOC, hz_batch_malloc}, {Z_BATCH_FREE, hz_batch_free},
        {Z_MEMALIGN, hz_memalign}, {Z_FREE_DEF, hz_free_def}, {Z_PRESSURE, hz_zero}, {Z_CLAIMED, hz_claimed},
        {Z_TRY_FREE_DEFAULT, hz_free_def}, {Z_MALLOC_OPT, hz_malloc_opt}, {Z_TYPE_MALLOC, hz_type_malloc},
        {Z_TYPE_CALLOC, hz_type_calloc}, {Z_TYPE_REALLOC, hz_type_realloc}, {Z_TYPE_MEMALIGN, hz_type_memalign},
        {Z_TYPE_MALLOC_OPT, hz_type_malloc_opt},
    };
    static u64 stubs[kZoneWords];
    static std::once_flag once;
    std::call_once(once, [] {
        for (auto &f : fns) stubs[f.word] = stub_for("zone fn", f.h);
        // introspection: every entry returns 0 (enumerator: KERN_SUCCESS without recording anything)
        u64 *intro = (u64 *)n.calloc(32, 8);
        u64 z = stub_for("zone introspect", hz_zero);
        for (int k = 0; k < 32; k++) intro[k] = z;
        g_introspect = (u64)intro;
    });
    auto *gz = (GuestZone *)n.calloc(1, sizeof(GuestZone));
    for (int k = 0; k < kZoneWords; k++) gz->w[k] = stubs[k];
    gz->w[0] = gz->w[1] = 0;
    gz->w[Z_NAME] = (u64)strdup(name ? name : "");
    gz->w[Z_INTROSPECT] = g_introspect;
    gz->w[Z_VERSION] = 16;
    { std::lock_guard l(g_mu); g_our_zones.insert((u64)gz); }
    return gz;
}

void register_zone(u64 z) {
    std::lock_guard l(g_mu);
    if (g_nzones < 63) g_zone_array[g_nzones++] = z;
    if (u64 a = g_exp["_malloc_num_zones"]) *(u32 *)a = g_nzones;
}

void h_default_zone(GuestThread &t, u32) { arm_fast(t); t.set_x(0, (u64)g_default); }
void h_create_zone(GuestThread &t, u32) {  // (start_size, flags)
    GuestZone *z = make_zone("");
    register_zone((u64)z);
    t.set_x(0, (u64)z);
}
void h_zone_register(GuestThread &t, u32) { if (!ours(t.x(0))) register_zone(t.x(0)); }
void h_set_zone_name(GuestThread &t, u32) {
    if (ours(t.x(0)) && t.x(0)) ((u64 *)t.x(0))[Z_NAME] = (u64)strdup((const char *)t.x(1));
}
void h_get_zone_name(GuestThread &t, u32) { t.set_x(0, t.x(0) ? ((u64 *)t.x(0))[Z_NAME] : 0); }
void h_zone_from_ptr(GuestThread &t, u32) { t.set_x(0, n.size((void *)t.x(0)) ? (u64)g_default : 0); }
// malloc_get_all_zones(task, reader, vm_address_t **addresses, unsigned *count)
void h_get_all_zones(GuestThread &t, u32) {
    if (t.x(2)) *(u64 **)t.x(2) = g_zone_array;
    if (t.x(3)) *(u32 *)t.x(3) = g_nzones;
    t.set_x(0, 0);
}
// malloc_zone_statistics(zone, malloc_statistics_t *{blocks_in_use, size_in_use, max_size_in_use, size_allocated})
void h_zone_statistics(GuestThread &t, u32) { if (t.x(1)) memset((void *)t.x(1), 0, 4 + 3 * 8); }
void h_mstats(GuestThread &t, u32) { if (t.x(8)) memset((void *)t.x(8), 0, 5 * 8); }  // struct mstats: returned via x8
void h_zone_check(GuestThread &t, u32) { t.set_x(0, 1); }
void h_malloc_init(GuestThread &t, u32) { t.set_x(0, 0); }
// x86Sim (2026-11-13): libSystem's fork() calls these around the syscall: the heap's locks (and malloc.cpp's zone
// lock) are held across it, then released in parent and child (gheap.cpp gheap_fork_lock). They were no-ops.
// The translation lock first (a translating thread finishes), then the heap's.
// X86SIM_A64_MALLOC_FORK=0: no-ops as before (bisecting).
const bool g_fork_hooks = [] { const char *e = getenv("X86SIM_A64_MALLOC_FORK"); return !(e && *e == '0'); }();
void h_fork_prepare(GuestThread &, u32) { if (g_fork_hooks) { jit_fork_lock(); g_mu.lock(); gheap_fork_lock(); } }
void h_fork_parent(GuestThread &, u32) { if (g_fork_hooks) { gheap_fork_unlock(); g_mu.unlock(); jit_fork_unlock(); } }
void h_fork_child(GuestThread &, u32) { if (g_fork_hooks) { gheap_fork_unlock(); g_mu.unlock(); jit_fork_unlock(); } }
void h_unknown(GuestThread &t, u32 i) {
    static std::mutex mu; static std::set<u32> seen;
    { std::lock_guard l(mu); if (seen.insert(i).second) logf("native malloc: %s not implemented (returns 0)", g_thunks[i].name.c_str()); }
    t.set_x(0, 0);
}
// malloc_type_*: the type id is dropped.
void ht_malloc(GuestThread &t, u32 i) { h_malloc(t, i); }
void ht_calloc(GuestThread &t, u32 i) { h_calloc(t, i); }
void ht_realloc(GuestThread &t, u32 i) { h_realloc(t, i); }
void ht_valloc(GuestThread &t, u32 i) { h_valloc(t, i); }
void ht_aligned_alloc(GuestThread &t, u32 i) { h_aligned_alloc(t, i); }
void ht_posix_memalign(GuestThread &t, u32 i) { h_posix_memalign(t, i); }
void ht_zone_free(GuestThread &t, u32 i) { hz_free(t, i); }
void ht_zone_valloc(GuestThread &t, u32 i) { hz_valloc(t, i); }
// malloc_zone_malloc_with_options_np(zone, align, size, options)
void hz_malloc_opt_np(GuestThread &t, u32 i) { hz_malloc_opt(t, i); }

const std::map<std::string, Handler> &handlers() {
    static const std::map<std::string, Handler> m = {
        {"_malloc", h_malloc}, {"_calloc", h_calloc}, {"_realloc", h_realloc}, {"_reallocf", h_reallocf},
        {"_reallocarray$DARWIN_EXTSN", h_reallocarray}, {"_reallocarrayf$DARWIN_EXTSN", h_reallocarrayf},
        {"_free", h_free}, {"_vfree", h_free}, {"_valloc", h_valloc}, {"_aligned_alloc", h_aligned_alloc},
        {"_posix_memalign", h_posix_memalign}, {"_malloc_size", h_size}, {"_malloc_good_size", h_good_size},
        {"_malloc_claimed_address", h_claimed},
        {"_malloc_type_malloc", ht_malloc}, {"_malloc_type_calloc", ht_calloc}, {"_malloc_type_free", h_free},
        {"_malloc_type_realloc", ht_realloc}, {"_malloc_type_valloc", ht_valloc},
        {"_malloc_type_aligned_alloc", ht_aligned_alloc}, {"_malloc_type_posix_memalign", ht_posix_memalign},
        {"_malloc_type_zone_malloc", hz_type_malloc}, {"_malloc_type_zone_calloc", hz_type_calloc},
        {"_malloc_type_zone_free", ht_zone_free}, {"_malloc_type_zone_realloc", hz_type_realloc},
        {"_malloc_type_zone_valloc", ht_zone_valloc}, {"_malloc_type_zone_memalign", hz_type_memalign},
        {"_malloc_type_zone_malloc_with_options", hz_type_malloc_opt},
        {"_malloc_type_zone_malloc_with_options_internal", hz_type_malloc_opt},
        {"_malloc_zone_malloc_with_options", hz_malloc_opt_np}, {"_malloc_zone_malloc_with_options_np", hz_malloc_opt_np},
        {"_malloc_zone_malloc", hz_malloc}, {"_malloc_zone_calloc", hz_calloc}, {"_malloc_zone_valloc", hz_valloc},
        {"_malloc_zone_realloc", hz_realloc}, {"_malloc_zone_free", hz_free}, {"_malloc_zone_memalign", hz_memalign},
        {"_malloc_zone_claimed_address", hz_claimed}, {"_malloc_zone_batch_malloc", hz_batch_malloc},
        {"_malloc_zone_batch_free", hz_batch_free}, {"_malloc_zone_pressure_relief", hz_zero},
        {"_malloc_zone_from_ptr", h_zone_from_ptr}, {"_malloc_default_zone", h_default_zone},
        {"_malloc_default_purgeable_zone", h_default_zone}, {"_malloc_create_zone", h_create_zone},
        {"_malloc_create_legacy_default_zone", h_create_zone}, {"_malloc_zone_register", h_zone_register},
        {"_malloc_zone_unregister", h_noop}, {"_malloc_destroy_zone", h_noop}, {"_malloc_set_zone_name", h_set_zone_name},
        {"_malloc_get_zone_name", h_get_zone_name}, {"_malloc_get_all_zones", h_get_all_zones},
        {"_malloc_zone_statistics", h_zone_statistics}, {"_mstats", h_mstats}, {"_malloc_zone_check", h_zone_check},
        {"___malloc_init", h_malloc_init}, {"___malloc_late_init", h_noop}, {"__malloc_fork_prepare", h_fork_prepare},
        {"__malloc_fork_parent", h_fork_parent}, {"__malloc_fork_child", h_fork_child}, {"_malloc_make_purgeable", h_noop},
        {"_malloc_make_nonpurgeable", h_zero}, {"_malloc_engaged_nano", h_zero},
        {"_malloc_engaged_secure_allocator", h_zero}, {"_malloc_memory_event_handler", h_noop},
        {"_malloc_enter_process_memory_limit_warn_mode", h_noop}, {"_malloc_zone_print", h_noop},
        {"_malloc_zone_print_ptr_info", h_noop}, {"_malloc_zone_log", h_noop}, {"_malloc_error", h_noop},
        {"_malloc_printf", h_noop}, {"_malloc_get_thread_options", h_zero}, {"_malloc_set_thread_options", h_noop},
        {"_malloc_sanitizer_is_enabled", h_zero}, {"_malloc_sanitizer_get_functions", h_zero},
        {"_malloc_sanitizer_set_functions", h_noop}, {"_malloc_register_stack_logger", h_noop},
        {"_turn_on_stack_logging", h_zero}, {"_turn_off_stack_logging", h_noop}, {"_set_malloc_singlethreaded", h_noop},
        {"_malloc_singlethreaded", h_zero}, {"_malloc_debug", h_noop}, {"_malloc_zero_on_free_disable", h_noop},
        {"_malloc_get_wrapped_zone", h_zero}, {"_mag_set_thread_index", h_noop}, {"_malloc_jumpstart", h_zero},
        {"_malloc_freezedry", h_zero},
    };
    return m;
}

}  // namespace

static bool g_native_malloc = false;

void native_malloc_prepare(const std::string &cache) {
    const char *e = getenv("X86SIM_A64_GUEST_MALLOC");  // =1: keep the guest's own xzone malloc
    if (e && *e == '1') return;
    g_names = cache_exports(cache, "/usr/lib/system/libsystem_malloc.dylib", &g_addrs, &g_text_lo, &g_text_hi);
    for (size_t k = 0; k < g_names.size(); k++) if (g_addrs[k] != ~0ull) g_exp[g_names[k]] = g_addrs[k];
    auto *dfree = (void (*)(void *))dsym("free");
    auto *dsize = (size_t (*)(const void *))dsym("malloc_size");
    if (!dfree || !dsize) die("native malloc: Darling's free/malloc_size not found");
    gheap_set_native(dfree, dsize);
    n.malloc = gh_malloc; n.calloc = gh_calloc; n.realloc = gh_realloc; n.free = gh_free;
    n.size = gh_size; n.good_size = gh_good_size;
    g_native_malloc = true;
}

void native_malloc_install() {
    if (!g_native_malloc) return;
    static bool done;
    if (done) return;
    done = true;
    g_zone_array = (u64 *)n.calloc(64, 8);
    g_default = make_zone("DefaultMallocZone");
    register_zone((u64)g_default);
    gheap_set_default_zone((u64)g_default);
    if (u64 a = g_exp["_malloc_zones"]) *(u64 **)a = g_zone_array;
    // The cache's text is mapped read+exec from the file (private): make each page writable while patching.
    int patched = 0, unknown = 0;
    std::map<u64, std::string> text;  // address -> export
    std::map<u64, Handler> targets;    // internal tail-call targets patched
    for (auto &[name, addr] : g_exp)
        if (is_text(addr)) text[addr] = name;
        else if (handlers().count(name)) logf("native malloc: %s is not in __TEXT", name.c_str());
    // Perf 16: malloc/calloc/free (and their malloc_type_ forms) get a guest-code fast path instead of the 2-word stub
    // where the function has room for it (up to its next function start, LC_FUNCTION_STARTS); its `svc #0` slow path
    // becomes this export's thunk. X86SIM_A64_GUEST_MALLOC=0: stubs only (code-shaping: the AOT image holds the patched
    // code, so the builder must use the same setting; debug only).
    static const uint32_t kFastMalloc[] = {0xd53bd069u, 0xf94bfd29u, 0xb4000269u, 0xf140201fu, 0x54000228u, 0x91003c0au,
        0xd344fd4au, 0xf940f12bu, 0x386a696au, 0x8b0a0d2du, 0xf94001acu, 0xb400014cu, 0xf940018eu, 0xf90001aeu, 0x9105012fu,
        0xb86a79f0u, 0x51000610u, 0xb82a79f0u, 0xa9007d9fu, 0xaa0c03e0u, 0xd65f03c0u, 0xd4000001u, 0xd65f03c0u};
    static const uint32_t kFastCalloc[] = {0xd53bd069u, 0xf94bfd29u, 0xb40002c9u, 0x9bc17c08u, 0xb5000288u, 0x9b017c08u,
        0xf140211fu, 0x54000228u, 0x91003d0au, 0xd344fd4au, 0xf940f12bu, 0x386a696au, 0x8b0a0d2du, 0xf94001acu, 0xb400014cu,
        0xf940018eu, 0xf90001aeu, 0x9105012fu, 0xb86a79f0u, 0x51000610u, 0xb82a79f0u, 0xa9007d9fu, 0xaa0c03e0u, 0xd65f03c0u,
        0xd4000001u, 0xd65f03c0u};
    static const uint32_t kFastFree[] = {0xb4000540u, 0xd53bd069u, 0xf94bfd29u, 0xb4000509u, 0xd2c0006au, 0xeb0a000bu,
        0x540004a3u, 0xd354fd6bu, 0xd2998010u, 0xeb10017fu, 0x54000422u, 0xf940f52cu, 0x386b698du, 0x340003cdu, 0x510005adu,
        0xd289ec6fu, 0xf2a14f6fu, 0xf2d1c3afu, 0xf2ebe58fu, 0xf940040eu, 0xeb0f01dfu, 0x540002c0u, 0xf940fd30u, 0xb86d7a10u,
        0x91050131u, 0xb86d7a28u, 0x6b10011fu, 0x54000202u, 0xf940f930u, 0xb86d7a10u, 0x7104021fu, 0x54000188u, 0xaa0003eeu,
        0xa8817ddfu, 0x71004210u, 0x54ffffc1u, 0xf900040fu, 0xf86d792eu, 0xf900000eu, 0xf82d7920u, 0x11000508u, 0xb82d7a28u,
        0xd65f03c0u, 0xd4000001u, 0xd65f03c0u};
    // Perf 17: the zone API for the default zone, malloc_default_zone and malloc_good_size (tests/arm64/guestmalloc)
    static const uint32_t kFastDefaultZone[] = {0xd53bd069u, 0xf94bfd29u, 0xb4000089u, 0xf941012au, 0xf9400140u, 0xd65f03c0u, 0xd4000001u, 0xd65f03c0u};
    static const uint32_t kFastGoodSize[] = {0xd53bd069u, 0xf94bfd29u, 0xb4000149u, 0xf140201fu, 0x54000108u, 0x91003c0au, 0xd344fd4au, 0xf940f12bu, 0x386a696au, 0xf940f92bu, 0xb86a7960u, 0xd65f03c0u, 0xd4000001u, 0xd65f03c0u};
    static const uint32_t kFastZoneMalloc[] = {0xd53bd069u, 0xf94bfd29u, 0xb4000389u, 0xf941012au, 0xf940014au, 0xeb0a001fu, 0x540000c0u, 0xb40002e0u, 0xf9400c0bu, 0xf9400d4au, 0xeb0a017fu, 0x54000261u, 0xf140203fu, 0x54000228u, 0x91003c2au, 0xd344fd4au, 0xf940f12bu, 0x386a696au, 0x8b0a0d2du, 0xf94001acu, 0xb400014cu, 0xf940018eu, 0xf90001aeu, 0x9105012fu, 0xb86a79f0u, 0x51000610u, 0xb82a79f0u, 0xa9007d9fu, 0xaa0c03e0u, 0xd65f03c0u, 0xd4000001u, 0xd65f03c0u
};
    static const uint32_t kFastZoneCalloc[] = {0xd53bd069u, 0xf94bfd29u, 0xb40003e9u, 0xf941012au, 0xf940014au, 0xeb0a001fu, 0x540000c0u, 0xb4000340u, 0xf9400c0bu, 0xf9400d4au, 0xeb0a017fu, 0x540002c1u, 0x9bc27c28u, 0xb5000288u, 0x9b027c28u, 0xf140211fu, 0x54000228u, 0x91003d0au, 0xd344fd4au, 0xf940f12bu, 0x386a696au, 0x8b0a0d2du, 0xf94001acu, 0xb400014cu, 0xf940018eu, 0xf90001aeu, 0x9105012fu, 0xb86a79f0u, 0x51000610u, 0xb82a79f0u, 0xa9007d9fu, 0xaa0c03e0u, 0xd65f03c0u, 0xd4000001u, 0xd65f03c0u
};
    static const uint32_t kFastMallocSize[] = {0xd53bd069u, 0xf94bfd29u, 0xb40001e9u, 0xd2c0006au, 0xeb0a000bu, 0x54000183u, 0xd354fd6bu, 0xd2998010u, 0xeb10017fu, 0x54000102u, 0xf940f52cu, 0x386b698du, 0x340000adu, 0x510005adu, 0xf940f930u, 0xb86d7a00u, 0xd65f03c0u, 0xd4000001u, 0xd65f03c0u
};  // Perf 22
    static const uint32_t kFastZoneFree[] = {0xd53bd069u, 0xf94bfd29u, 0xb4000649u, 0xf941012au, 0xf940014au, 0xeb0a001fu, 0x540000c0u, 0xb40005a0u, 0xf9400c0bu, 0xf9400d4au, 0xeb0a017fu, 0x54000521u, 0xb40004e1u, 0xd2c0006au, 0xeb0a002bu, 0x540004a3u, 0xd354fd6bu, 0xd2998010u, 0xeb10017fu, 0x54000422u, 0xf940f52cu, 0x386b698du, 0x340003cdu, 0x510005adu, 0xd289ec6fu, 0xf2a14f6fu, 0xf2d1c3afu, 0xf2ebe58fu, 0xf940042eu, 0xeb0f01dfu, 0x540002c0u, 0xf940fd30u, 0xb86d7a10u, 0x91050131u, 0xb86d7a28u, 0x6b10011fu, 0x54000202u, 0xf940f930u, 0xb86d7a10u, 0x7104021fu, 0x54000188u, 0xaa0103eeu, 0xa8817ddfu, 0x71004210u, 0x54ffffc1u, 0xf900042fu, 0xf86d792eu, 0xf900002eu, 0xf82d7921u, 0x11000508u, 0xb82d7a28u, 0xd65f03c0u, 0xd4000001u, 0xd65f03c0u
};
    g_fast_malloc = gheap_zeroes() && n.malloc == gh_malloc && !(getenv("X86SIM_A64_GUEST_MALLOC") && atoi(getenv("X86SIM_A64_GUEST_MALLOC")) == 0);
    std::vector<u64> starts;  // libsystem_malloc's function starts (LC_FUNCTION_STARTS of the image in the cache)
    if (g_fast_malloc) {
        const auto *mh = (const mach_header_64 *)g_text_lo;
        const uint8_t *lc = (const uint8_t *)(mh + 1);
        u64 le = 0, text_vm = g_text_lo; uint32_t fs_off = 0, fs_size = 0;
        for (uint32_t k = 0; k < mh->ncmds; k++, lc += ((const load_command *)lc)->cmdsize) {
            auto *sg = (const segment_command_64 *)lc;
            if (sg->cmd == LC_SEGMENT_64 && !strcmp(sg->segname, "__LINKEDIT")) le = sg->vmaddr - sg->fileoff;
            if (sg->cmd == LC_FUNCTION_STARTS) { fs_off = ((const linkedit_data_command *)lc)->dataoff; fs_size = ((const linkedit_data_command *)lc)->datasize; }
        }
        const uint8_t *p = (const uint8_t *)(le + fs_off), *e = p + fs_size;
        u64 a = text_vm;
        while (le && fs_size && p < e) {
            u64 v = 0; int sh = 0;
            while (p < e) { uint8_t b = *p++; v |= (u64)(b & 0x7f) << sh; sh += 7; if (!(b & 0x80)) break; }
            if (!v) break;
            a += v; starts.push_back(a);
        }
        if (starts.empty()) g_fast_malloc = false;
    }
    // A fast path longer than its function (free's tail-call target has 84 bytes, malloc/calloc 20-24) goes into dead
    // space: libsystem_malloc's internal functions that are neither an export nor the tail-call target of one (every
    // way into this image is patched, so their code never runs). The function itself gets `b` to it. Taken in address
    // order, so every process (and the AOT builder) writes the same code to the same places.
    std::vector<std::pair<u64, u64>> pool;  // [start, end) of dead functions
    if (g_fast_malloc) {
        std::set<u64> live;
        for (auto &[addr, name] : text) {
            live.insert(addr);
            uint32_t ins = *(uint32_t *)addr;
            if ((ins & 0xFC000000u) == 0x14000000u) live.insert(addr + (u64)((int64_t)((int32_t)(ins << 6) >> 6) * 4));
        }
        for (size_t k = 0; k + 1 < starts.size(); k++)
            if (!live.count(starts[k]) && starts[k + 1] - starts[k] >= 64) pool.push_back({starts[k], starts[k + 1]});
    }
    size_t pool_i = 0;
    auto pool_take = [&](size_t bytes) -> u64 {
        for (; pool_i < pool.size(); pool_i++)
            if (pool[pool_i].second - pool[pool_i].first >= bytes) {
                const u64 a = pool[pool_i].first;
                pool[pool_i].first = (a + bytes + 15) & ~15ull;
                return a;
            }
        return 0;
    };
    int fast = 0;
    auto patch = [&](u64 addr, const std::string &name, Handler h) {
        const uint32_t *fc = nullptr; size_t fn = 0;
        if (g_fast_malloc) {
            if (h == h_malloc || h == ht_malloc) { fc = kFastMalloc; fn = sizeof kFastMalloc / 4; }
            else if (h == h_calloc || h == ht_calloc) { fc = kFastCalloc; fn = sizeof kFastCalloc / 4; }
            else if (h == h_free) { fc = kFastFree; fn = sizeof kFastFree / 4; }
            else if (h == hz_free) { fc = kFastZoneFree; fn = sizeof kFastZoneFree / 4; }
            else if (h == hz_malloc || h == hz_type_malloc) { fc = kFastZoneMalloc; fn = sizeof kFastZoneMalloc / 4; }
            else if (h == hz_calloc || h == hz_type_calloc) { fc = kFastZoneCalloc; fn = sizeof kFastZoneCalloc / 4; }
            else if (h == h_default_zone) { fc = kFastDefaultZone; fn = sizeof kFastDefaultZone / 4; }
            else if (h == h_good_size) { fc = kFastGoodSize; fn = sizeof kFastGoodSize / 4; }
            else if (h == h_size) { fc = kFastMallocSize; fn = sizeof kFastMallocSize / 4; }
            if (fc && std::find(starts.begin(), starts.end(), addr) == starts.end()) fc = nullptr;
        }
        u64 at = addr;  // where the fast path goes
        if (fc) {
            auto nx = std::upper_bound(starts.begin(), starts.end(), addr);
            if (nx == starts.end() || *nx - addr < fn * 4) {
                at = pool_take(fn * 4);
                if (!at || (int64_t)(at - addr) >= (128 << 20) || (int64_t)(addr - at) > (128 << 20)) { at = addr; fc = nullptr; }
            }
        }
        if (fc && at != addr) {  // the fast path in dead space, a branch to it here
            u64 page = at & ~0xfffull, len = ((at + fn * 4 + 0xfff) & ~0xfffull) - page;
            std::lock_guard g(g_text_patch_mu);
            if (mprotect((void *)page, len, PROT_READ | PROT_WRITE | PROT_EXEC)) die("native malloc: mprotect %#lx", (unsigned long)page);
            const u32 idx = add_thunk(name, h);
            for (size_t k = 0; k < fn; k++) ((uint32_t *)at)[k] = fc[k] == 0xd4000001u ? 0xd4000001u | idx << 5 : fc[k];
            mprotect((void *)page, len, PROT_READ | PROT_EXEC);
            u64 page2 = addr & ~0xfffull, len2 = ((addr + 4 + 0xfff) & ~0xfffull) - page2;
            if (mprotect((void *)page2, len2, PROT_READ | PROT_WRITE | PROT_EXEC)) die("native malloc: mprotect %#lx", (unsigned long)page2);
            *(uint32_t *)addr = 0x14000000u | (uint32_t)(((int64_t)(at - addr) >> 2) & 0x3ffffff);  // b at
            mprotect((void *)page2, len2, PROT_READ | PROT_EXEC);
            fast++;
            patched++;
            return;
        }
        const size_t bytes = fc ? fn * 4 : 8;
        u64 page = addr & ~0xfffull, len = ((addr + bytes + 0xfff) & ~0xfffull) - page;
        std::lock_guard g(g_text_patch_mu);
        if (mprotect((void *)page, len, PROT_READ | PROT_WRITE | PROT_EXEC)) die("native malloc: mprotect %#lx", (unsigned long)page);
        const u32 idx = add_thunk(name, h);
        if (fc) {
            for (size_t k = 0; k < fn; k++) ((uint32_t *)addr)[k] = fc[k] == 0xd4000001u ? 0xd4000001u | idx << 5 : fc[k];
            fast++;
        } else {
            emit_stub((uint32_t *)addr, idx);
        }
        mprotect((void *)page, len, PROT_READ | PROT_EXEC);
        patched++;
    };
    for (auto it = text.begin(); it != text.end(); ++it) {
        auto [addr, name] = *it;
        auto h = handlers().find(name);
        Handler fn = h == handlers().end() ? h_unknown : h->second;
        if (h == handlers().end()) unknown++;
        // A function whose first instruction is "b target" is a tail call and may be only 4 bytes long (vfree, free,
        // realloc, malloc_type_free, ...): an 8-byte stub would overwrite the next function. Exported targets are
        // patched anyway; an internal target gets this export's handler.
        uint32_t ins = *(uint32_t *)addr;
        if (ins == 0xD65F03C0u) continue;  // "ret": nothing to replace
        if ((ins & 0xFC000000u) != 0x14000000u) { patch(addr, name, fn); continue; }
        u64 target = addr + (u64)((int64_t)((int32_t)(ins << 6) >> 6) * 4);
        if (text.count(target)) continue;
        if (auto t = targets.find(target); t != targets.end()) {
            if (t->second != fn) logf("native malloc: %s and another export tail-call %#lx with different handlers", name.c_str(), (unsigned long)target);
            continue;
        }
        targets[target] = fn;
        patch(target, name + " (target)", fn);
    }
    if (getenv("X86SIM_A64_STATS")) logf("native malloc: %d libsystem_malloc exports patched (%d without a handler, %d with a guest fast path)", patched, unknown, fast);
}

}  // namespace a64
