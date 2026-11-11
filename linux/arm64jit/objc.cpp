// libarm64jit: objc_msgSend fast paths.
//
// Two modes (in preference order):
//   1. Inline x86 probe in dynarmic (default): when a block at _objc_msgSend is translated,
//      EmitInlineObjCMsgSend emits the cache lookup in x86 and FastDispatches to the IMP.
//      No CallSVC, no HostCall spill. X86SIM_A64_INLINE_OBJC=0 disables.
//   2. Legacy svc stub (X86SIM_A64_NATIVE_OBJC=1): patch entry to svc; host C++ probe;
//      SetPC(IMP). Kept for comparison; slower than guest A64 (~1.8×) because of the boundary.
//
// Layout verified against iOS 27.0 sim cache (dyld_sim_shared_cache_arm64):
//   isa mask 0x7ffffffffffff8; cache at class+0x10; HIGH_16_BIG_ADDRS (mask<<48 | buckets);
//   bucket = {imp^class, sel}; scan decrements; no SEL_HASH_SHIFT_XOR on this build.
#include "a64.h"
#include <atomic>
#include <cstdlib>
#include <cstring>
#include <sys/mman.h>

namespace a64 {

namespace {

constexpr u64 kIsaMask = 0x7ffffffffffff8ull;
constexpr u64 kBucketsMask = 0xffffffffffffull;
constexpr u64 kCacheOffset = 0x10;  // offsetof(objc_class, cache)
constexpr u64 kDefaultMsgSend = 0x1c0093800ull;
constexpr u64 kDefaultUncached = 0x1c0093ae0ull;
constexpr u64 kTaggedGetClass = 0x1c0093870ull;  // past b.eq nil inside NilOrTagged

u64 g_msgsend = kDefaultMsgSend;
u64 g_uncached = kDefaultUncached;
u64 g_tagged = kTaggedGetClass;
bool g_inline = false;
bool g_svc_native = false;

std::atomic<u64> g_hits{0}, g_misses{0}, g_nils{0}, g_taggeds{0};
// Plain u64 for lock-inc from emitted x86 (inline path).

static bool is_tagged(u64 obj) {
    return (int64_t)obj < 0;
}

static u64 cache_lookup(u64 cls, u64 sel) {
    u64 mask_and_buckets = GuestThread::rd<u64>(cls + kCacheOffset);
    u64 buckets = mask_and_buckets & kBucketsMask;
    u32 mask = (u32)(mask_and_buckets >> 48);
    if (!buckets) return 0;

    u32 idx = (u32)sel & mask;
    u64 cur = buckets + ((u64)idx << 4);
    u64 first = cur;

    for (;;) {
        u64 stored_imp = GuestThread::rd<u64>(cur);
        u64 bsel = GuestThread::rd<u64>(cur + 8);
        cur -= 16;
        if (bsel == sel) return stored_imp ^ cls;
        if (bsel == 0) return 0;
        if (cur >= buckets) continue;
        break;
    }
    cur = buckets + ((u64)mask << 4);
    for (;;) {
        u64 stored_imp = GuestThread::rd<u64>(cur);
        u64 bsel = GuestThread::rd<u64>(cur + 8);
        cur -= 16;
        if (bsel == sel) return stored_imp ^ cls;
        if (bsel == 0) return 0;
        if (cur > first) continue;
        return 0;
    }
}

void h_objc_msgSend(GuestThread &t, u32) {
    u64 obj = t.x(0);
    u64 sel = t.x(1);

    if (obj == 0) {
        g_nils.fetch_add(1, std::memory_order_relaxed);
        t.set_x(0, 0);
        t.set_x(1, 0);
        t.set_d(0, 0);
        t.set_d(1, 0);
        t.set_d(2, 0);
        t.set_d(3, 0);
        return;
    }

    if (is_tagged(obj)) {
        g_taggeds.fetch_add(1, std::memory_order_relaxed);
        t.jit->SetPC(g_tagged);
        return;
    }

    u64 raw_isa = GuestThread::rd<u64>(obj);
    u64 cls = raw_isa & kIsaMask;
    u64 imp = cache_lookup(cls, sel);
    if (imp) {
        g_hits.fetch_add(1, std::memory_order_relaxed);
        t.jit->SetPC(imp);
        return;
    }

    g_misses.fetch_add(1, std::memory_order_relaxed);
    t.set_x(15, cls);
    t.set_x(16, cls);
    t.jit->SetPC(g_uncached);
}

}  // namespace

static u64 g_bks_text;  // BackBoardServices' __TEXT in this runtime's cache (sim_service_patches)
static u64 g_objc_text_lo, g_objc_text_hi;  // libobjc's __TEXT (objc_cache_gc_guard)

void native_objc_prepare(const std::string &cache_path) {
    u64 bks_hi = 0;
    cache_exports(cache_path, "/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", nullptr,
                  &g_bks_text, &bks_hi);
    cache_exports(cache_path, "/usr/lib/libobjc.A.dylib", nullptr, &g_objc_text_lo, &g_objc_text_hi);
    // X86SIM_A64_GUEST_OBJC=1: leave guest A64 msgSend alone (baseline).
    const char *guest = getenv("X86SIM_A64_GUEST_OBJC");
    if (guest && *guest == '1') return;

    u64 text_lo = 0, text_hi = 0;
    std::vector<u64> addrs;
    auto names = cache_exports(cache_path, "/usr/lib/objc/libobjcMsgSend.dylib", &addrs, &text_lo, &text_hi);
    // Platforms 1: __objc_msgSend_uncached is not exported (27.x), so it was always the iOS 27 constant: on tvOS
    // (_objc_msgSend at 0x18009b800) every cache miss jumped into FindMyCrypto and libSystem's initializer crashed.
    // It is _objc_msgSend's own cache-miss target (the "b" at +0x68: +0x2e0), the same code on iOS, tvOS and watchOS.
    g_uncached = 0;
    for (size_t i = 0; i < names.size(); i++) {
        if (addrs[i] == ~0ull) continue;
        if (names[i] == "_objc_msgSend") g_msgsend = addrs[i];
        else if (names[i] == "__objc_msgSend_uncached") g_uncached = addrs[i];
    }
    if (!g_uncached && g_msgsend) g_uncached = g_msgsend + (kDefaultUncached - kDefaultMsgSend);
    if (!g_msgsend || !g_uncached) {
        logf("native objc: msgSend exports missing (msgsend %#lx uncached %#lx)",
             (unsigned long)g_msgsend, (unsigned long)g_uncached);
        return;
    }
    g_tagged = g_msgsend + (kTaggedGetClass - kDefaultMsgSend);

    // Default: inline x86 probe. Opt out with INLINE_OBJC=0; legacy svc with NATIVE_OBJC=1.
    const char *inline_env = getenv("X86SIM_A64_INLINE_OBJC");
    const char *native_env = getenv("X86SIM_A64_NATIVE_OBJC");
    if (native_env && *native_env == '1') {
        g_svc_native = true;
        g_inline = false;
    } else if (!inline_env || *inline_env != '0') {
        g_inline = true;
        g_svc_native = false;
    }
}

void native_objc_install() {
    if (g_svc_native) {
        static bool done;
        if (done) return;
        done = true;
        u64 addr = g_msgsend;
        u64 page = addr & ~0xfffull;
        u64 len = ((addr + 8 + 0xfff) & ~0xfffull) - page;
        std::lock_guard g(g_text_patch_mu);
        if (mprotect((void *)page, len, PROT_READ | PROT_WRITE | PROT_EXEC)) {
            logf("native objc: mprotect %#lx failed", (unsigned long)page);
            g_svc_native = false;
            return;
        }
        emit_stub((uint32_t *)addr, add_thunk("_objc_msgSend", h_objc_msgSend));
        mprotect((void *)page, len, PROT_READ | PROT_EXEC);
        if (getenv("X86SIM_A64_STATS"))
            logf("native objc: patched _objc_msgSend at %#lx (svc path; uncached %#lx)",
                 (unsigned long)addr, (unsigned long)g_uncached);
        return;
    }
    // Inline path: addresses are wired into each Jit's UserConfig in GuestThread().
    if (g_inline && getenv("X86SIM_A64_STATS"))
        logf("native objc: inline x86 probe at %#lx (uncached %#lx tagged %#lx)",
             (unsigned long)g_msgsend, (unsigned long)g_uncached, (unsigned long)g_tagged);
}

// Speed 5: libobjc frees a class's old method-cache buckets (cache_t::collectNolock) only when
// _collecting_in_critical() finds no thread whose PC is inside objc_msgSend / cache_getImp
// (objc_restartableRanges + thread_get_state). Under the JIT the probe runs as x86: the inline msgSend
// probe and translated blocks have no guest PC inside those ranges, so the check always passed and buckets
// were freed while another thread was still scanning them: SpringBoard SIGSEGVs in lookUpImpOrForward /
// _collecting_in_critical on garbage caches (count=1867017839, 1634885989), the "libobjc lookup crash" of
// Speed 4. Make _collecting_in_critical return true: old buckets are never freed (they stay on objc's
// garbage list; a bounded leak, at most the caches' cumulative growth). X86SIM_A64_OBJC_CACHE_GC=1 restores
// Apple's behaviour.
// Replace a shared-cache function's entry with `mov x0/w0, #ret; ret` when its first instruction matches (the
// cache text is a private mapping), and drop any translation of it (persistent cache / AOT image included).
static bool patch_return(GuestThread &t, u64 addr, uint32_t expect, uint32_t mov_ret, const char *what) {
    auto *p = (uint32_t *)addr;
    if (p[0] != expect) {
        logf("patch %s: prologue mismatch at %#lx (%#x); not patched", what, (unsigned long)addr, p[0]);
        return false;
    }
    u64 page = addr & ~0xfffull, len = ((addr + 8 + 0xfff) & ~0xfffull) - page;
    std::unique_lock g(g_text_patch_mu);
    if (mprotect((void *)page, len, PROT_READ | PROT_WRITE | PROT_EXEC)) {
        logf("patch %s: mprotect %#lx failed", what, (unsigned long)page);
        return false;
    }
    p[0] = mov_ret;
    p[1] = 0xd65f03c0u;  // ret
    mprotect((void *)page, len, PROT_READ | PROT_EXEC);
    g.unlock();
    t.jit->InvalidateCacheRange(addr, 8);
    if (getenv("X86SIM_A64_STATS")) logf("patch %s at %#lx", what, (unsigned long)addr);
    return true;
}

constexpr u64 kCollectingInCritical = 0x1c005ae50ull;  // __ZL23_collecting_in_criticalv, iOS 27.0 24A434 and 27.2
// Platforms 1: found by its first six instructions in libobjc's text (sub sp, sp, #368; stp x28, x27 / x22, x21 /
// x20, x19 / x29, x30; add x29, sp, #352): one function in iOS 27.2, tvOS 27.2 (0x180062e48) and watchOS 27.2
// (0x18006ee50). The 27.0 constant alone missed tvOS, where the cache flush then spun in thread_get_state with the
// runtime lock held: migrationpluginwrapper deadlocked, datamigrator killed it every 30 s and backboardd waited on the
// data migration for good (no home screen).
static u64 find_collecting_in_critical() {
    static const uint32_t sig[] = {0xd105c3ffu, 0xa9136ffcu, 0xa91457f6u, 0xa9154ff4u, 0xa9167bfdu, 0x910583fdu};
    u64 hit = 0;
    int n = 0;
    if (g_objc_text_lo && g_objc_text_hi > g_objc_text_lo)
        for (u64 a = g_objc_text_lo; a + sizeof sig <= g_objc_text_hi; a += 4)
            if (!memcmp((const void *)a, sig, sizeof sig)) { hit = a; n++; }
    return n == 1 ? hit : kCollectingInCritical;
}
void objc_cache_gc_guard(GuestThread &t) {
    if (const char *e = getenv("X86SIM_A64_OBJC_CACHE_GC"); e && atoi(e) == 1) return;
    // sub sp, sp, #368 -> mov w0, #1
    patch_return(t, find_collecting_in_critical(), 0xd105c3ffu, 0x52800020u, "objc _collecting_in_critical -> true");
}

// Speed 5: the simulator backboardd has no UI sensor server. BKHIDUISensorCoordinator is compiled out of the sim
// build (only the ivar's type name is left), yet backboardd's Info.plist still declares BKHIDUISensorService in the
// BKSHIDServices domain. BoardServices therefore drops it at its "automatic bootstrap deadline" (a dispatch_async to
// backboardd's main queue, queued when BSServiceManager is created: "no listener at automatic bootstrap deadline")
// and invalidates every client connection ("... because there is no listener"). SpringBoard's
// -[_BKSHIDUISensorOverseer _connectionLock_connectToRemoteServiceIfNeeded] (objc_direct, so not swizzlable)
// activates a fresh connection and aborts (brk, "we must have a remote target") if -remoteTarget is already nil. On
// a Mac the invalidation arrives after -remoteTarget returned (the same backboardd lines appear there and
// SpringBoard carries on with a dead connection, "backboardd must be exiting"). Under a cold JIT SpringBoard's
// activate -> remoteTarget window is long enough for backboardd's reply to win, so cold boots restarted
// SpringBoard 2-6 times. There is no server to reach in the simulator, so the overseer gets no remote target (what
// it ends up with on a Mac too); mode pushes and queries go to nil. X86SIM_A64_UISENSOR=1 leaves it alone.
// Speed 24: as an offset into BackBoardServices' __TEXT (0x1c8e3e22c in 27.0, 0x1c8dec22c in 27.2, 0x1c8f2622c in
// 27.1: the same code, the image moved); patch_return checks the prologue.
constexpr u64 kUISensorConnect = 0xb22c;  // -[_BKSHIDUISensorOverseer _connectionLock_connectToRemoteServiceIfNeeded]
void sim_service_patches(GuestThread &t) {
    if (const char *e = getenv("X86SIM_A64_UISENSOR"); e && atoi(e) == 1) return;
    if (!g_bks_text) {
        logf("patch BKS UI sensor connect: BackBoardServices not in the cache; not patched");
        return;
    }
    // sub sp, sp, #0xb0 -> mov x0, #0
    patch_return(t, g_bks_text + kUISensorConnect, 0xd102c3ffu, 0xd2800000u, "BKS UI sensor connect -> nil");
}

void native_objc_configure_jit(Dynarmic::A64::UserConfig &c) {
    if (!g_inline) return;
    c.inline_objc_msgsend = g_msgsend;
    c.inline_objc_uncached = g_uncached;
    c.inline_objc_tagged = g_tagged;
    // Perf 1f: the hit/miss counters were a `lock incq` on one shared word in every objc_msgSend, all threads (~3% of
    // a cold Settings launch on the instruction after it), for a debug line (native_objc_stats, X86SIM_A64_STATS).
    // X86SIM_A64_OBJC_COUNT=1 emits them again; the image is built without them, so only code translated live counts.
    if (getenv("X86SIM_A64_OBJC_COUNT") && atoi(getenv("X86SIM_A64_OBJC_COUNT")) == 1) {
        c.inline_objc_hit_counter = &fixed_data().objc_hits;
        c.inline_objc_miss_counter = &fixed_data().objc_misses;
    }
}

void native_objc_stats() {
    if (g_svc_native) {
        logf("native objc (svc): hits %llu misses %llu nils %llu tagged %llu",
             (unsigned long long)g_hits.load(), (unsigned long long)g_misses.load(),
             (unsigned long long)g_nils.load(), (unsigned long long)g_taggeds.load());
    } else if (g_inline) {
        logf("native objc (inline): hits %llu misses %llu msgsend %#lx",
             (unsigned long long)fixed_data().objc_hits, (unsigned long long)fixed_data().objc_misses,
             (unsigned long)g_msgsend);
    }
}

}  // namespace a64
