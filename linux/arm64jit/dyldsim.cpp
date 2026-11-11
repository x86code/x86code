// Speed 6: native shortcuts inside dyld_sim (iOS 27.x), applied after dyld_sim is mapped, before it runs.
//
// JustInTimeLoader::matchesPath(state, path) is how dyld finds an already-loaded image for dlopen and friends: for
// each of the ~900 loaded images it compares the path, then (dylibs) the install name. To get the install name it
// builds a full mach_o::Image (Loader::image -> Image::makeFromDyldMapped, which walks every segment and the
// linkedit) and calls Header::installName (another load-command walk through blocks). Under the JIT that was ~54% of
// SpringBoard's dyld_sim prepare (~19 s). The two calls are replaced by one call to a short arm64 routine that reads
// LC_ID_DYLIB from the loader's mach header; the rest of matchesPath (strlen/memcmp, PseudoDylib) is Apple's code.
// X86SIM_A64_DYLD_NATIVE=0 leaves dyld_sim alone.
#include "a64.h"
#include "macho.h"
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <optional>
#include <unordered_map>

namespace a64 {

// Header::installName() for a JustInTimeLoader, in arm64, placed in the zero padding at the end of dyld_sim's __TEXT
// (after __unwind_info). x19 = JustInTimeLoader*, [x19+0x20] = its mach header. Returns x0 = the LC_ID_DYLIB name (or
// ""), x1 = its length; clobbers x2-x7. Guest code rather than an svc: it is called ~14M times in SpringBoard's
// prepare, and an svc leaves the JIT's run loop each time (5 s of the 6 s left).
static const uint32_t kInstallName[] = {
    0xf9401262u,  // ldr  x2, [x19, #0x20]
    0xb9401043u,  // ldr  w3, [x2, #0x10]       ncmds
    0x91008044u,  // add  x4, x2, #0x20         first load command
    0x34000123u,  // cbz  w3, none
    0xb9400085u,  // loop: ldr w5, [x4]         cmd
    0x710034bfu,  // cmp  w5, #0xd              LC_ID_DYLIB
    0x54000120u,  // b.eq found
    0xb9400486u,  // ldr  w6, [x4, #4]          cmdsize
    0x34000086u,  // cbz  w6, none
    0x8b060084u,  // add  x4, x4, x6
    0x71000463u,  // subs w3, w3, #1
    0x54ffff21u,  // b.ne loop
    0x10000160u,  // none: adr x0, empty
    0xd2800001u,  // mov  x1, #0
    0xd65f03c0u,  // ret
    0xb9400886u,  // found: ldr w6, [x4, #8]    name offset
    0x8b060080u,  // add  x0, x4, x6
    0xaa0003e1u,  // mov  x1, x0
    0x38401427u,  // strlen: ldrb w7, [x1], #1
    0x35ffffe7u,  // cbnz w7, strlen
    0xcb000021u,  // sub  x1, x1, x0
    0xd1000421u,  // sub  x1, x1, #1
    0xd65f03c0u,  // ret
    0x00000000u,  // empty: ""
};
// JustInTimeLoader::matchesPath+0x44: 0x1f2f4 in 27.0/27.1, 0x1f378 in 27.2 (Speed 24: found by its code, so any
// 27.x build gets it: "bl Loader::image" (same distance in every build so far); "add x0, sp, #8"; "bl installName")
constexpr u64 kSearchLo = 0x1000, kSearchHi = 0x40000;
constexpr u64 kTextPad = 0x5b000;          // __unwind_info ends at 0x5914c, __TEXT at 0x5c000

// Speed 28: the loaded-image scans themselves. JustInTimeLoader::loadDependents (one per dependent path) and
// Loader::getLoader (one per path variant) walk the whole loaded-loader vector calling Loader::matchesPath on each:
// ~900 loaders per lookup, O(images^2) per process. With the Speed 6 install-name routine it was still ~45% of
// Preferences' running guest samples in its first 10 s (~1.2 s of dyld_sim prepare; every process pays it). The loop
// head ("ldr w8, [vector, #gen]") is read by the JIT as "svc #kDyldScanSvcA/B" (MemoryReadCode, like swiftconf; guest
// memory is not written). The handler runs the same walk natively: the same order, the same matchesPath for a
// JustInTimeLoader (path strcmp; dylibs: LC_ID_DYLIB name, as the Speed 6 routine). A loader with a PseudoDylib, one
// that is not a JustInTimeLoader, or an invalidated vector resumes the guest's own instructions for that iteration.
// X86SIM_A64_DYLD_SCAN=0 turns it off (the image keeps the old blocks of the loops until dyld_sim's chunk is rebuilt).
namespace {
// loop A (loadDependents block): head .. "b head"; loop B (getLoader block): head .. "b.ne head; b done"
constexpr uint32_t kLoopA[] = {0xb9404328u, 0x6b1b011fu, 0x54000141u, 0xf8408757u, 0xf9401e61u, 0xaa1703e0u, 0xaa1503e2u,
                               0u, 0x35000320u, 0xf100239cu, 0x54000300u, 0x17fffff5u};
constexpr uint32_t kLoopB[] = {0xb9402348u, 0x6b1c011fu, 0x540002e1u, 0xf9400377u, 0xf9401e81u, 0xaa1703e0u, 0xaa1303e2u,
                               0u, 0x340001a0u};
u64 g_loop_a = 0, g_loop_b = 0;
constexpr uint32_t kJitLoaderMagic = 0x6c347964u;  // 'l4yd'

u64 find_loop(u64 slide, const uint32_t *w, size_t n) {
    for (u64 a = kSearchLo; a + 4 * n < kSearchHi; a += 4) {
        const auto *q = (const uint32_t *)(slide + a);
        size_t i = 0;
        for (; i < n; i++)
            if (w[i] ? q[i] != w[i] : (q[i] >> 26) != 0x25) break;
        if (i == n) return slide + a;
    }
    return 0;
}

const char *install_name(u64 mh, size_t &len) {
    const uint32_t ncmds = *(const uint32_t *)(mh + 0x10);
    u64 lc = mh + 0x20;
    for (uint32_t i = 0; i < ncmds; i++) {
        const uint32_t cmd = *(const uint32_t *)lc, size = *(const uint32_t *)(lc + 4);
        if (cmd == 0xd) {
            const char *n = (const char *)(lc + *(const uint32_t *)(lc + 8));
            len = strlen(n);
            return n;
        }
        if (!size) break;
        lc += size;
    }
    len = 0;
    return "";
}

// Perf 3: a loader's path and install name (its LC_ID_DYLIB) as length + hash, computed once per loader: the scan
// compared every loader's full path with strcmp (simulator paths share a ~150-byte prefix) and walked a dylib's load
// commands for its install name, per loader, per lookup (~1300 loaders, thousands of lookups per process). The hashes
// only skip loaders that cannot match; a candidate is still compared in full, so the answer is the same. An entry is
// recomputed when the address holds a different loader (its mach header or flags word differ: reuse after dlclose).
u64 str_hash(const char *s, size_t n) {
    u64 h = 0xcbf29ce484222325ull;
    for (size_t i = 0; i < n; i++) h = (h ^ (uint8_t)s[i]) * 0x100000001b3ull;
    return h;
}
struct LdInfo {
    u64 mh, f, path_hash, in_hash;
    const char *in;
    uint32_t path_len, in_len;
};
std::mutex g_ld_mu;  // held for a whole dyld_scan_step
std::unordered_map<u64, LdInfo> g_ld;
const bool g_ld_cache = !(getenv("X86SIM_A64_DYLD_SCAN_CACHE") && atoi(getenv("X86SIM_A64_DYLD_SCAN_CACHE")) == 0);
const LdInfo &ld_info(u64 ld, u64 f) {
    const u64 mh = *(const u64 *)(ld + 0x20);
    LdInfo &e = g_ld[ld];
    if (e.mh != mh || e.f != f || !e.path_len) {
        const char *p = (const char *)(ld + (f & 0xffff));
        const size_t pl = strlen(p);
        e = LdInfo{mh, f, str_hash(p, pl), 0, "", (uint32_t)pl, 0};
        if (f & (1u << 20)) {
            size_t n;
            e.in = install_name(mh, n);
            e.in_len = (uint32_t)n;
            e.in_hash = str_hash(e.in, n);
        }
    }
    return e;
}

// 1 match, 0 no match, -1 the guest must do this one. ph: str_hash(path, plen)
int matches(u64 ld, const char *path, size_t plen, u64 ph) {
    if (*(const uint32_t *)ld != kJitLoaderMagic) return -1;
    const u64 f = *(const u64 *)(ld + 0x28);
    if (g_ld_cache) {
        const LdInfo &e = ld_info(ld, f);
        if (e.path_len == plen && e.path_hash == ph && !memcmp(path, (const char *)(ld + (f & 0xffff)), plen)) return 1;
        if ((f & (1u << 20)) && e.in_len == plen && e.in_hash == ph && !memcmp(e.in, path, plen)) return 1;
        return *(const u64 *)(ld + 0x68) ? -1 : 0;
    }
    if (!strcmp(path, (const char *)(ld + (f & 0xffff)))) return 1;
    if (f & (1u << 20)) {
        size_t n;
        const char *in = install_name(*(const u64 *)(ld + 0x20), n);
        if (n == plen && !memcmp(in, path, n)) return 1;
    }
    return *(const u64 *)(ld + 0x68) ? -1 : 0;
}
}  // namespace

std::optional<uint32_t> dyld_scan_read_code(u64 a) {
    if (a == g_loop_a && a) return 0xd4000001u | (kDyldScanSvcA << 5);
    if (a == g_loop_b && a) return 0xd4000001u | (kDyldScanSvcB << 5);
    return std::nullopt;
}

// loop A: x25 state (vector at +0x28, generation +0x40), x26 cursor, w27 generation, x28 bytes left, x21 path,
// x19 block (state at +0x38). found -> head+0x84 (cbnz x23 ...), end -> head+0x88, invalidated -> head+0x30.
// loop B: x26 vector (generation +0x20), x27 cursor, w28 generation, x22 bytes left, x19 path, x20 block.
// found -> head+0x24, end -> head+0x6c, invalidated -> head+0x64; the guest's iteration starts at head+0xc.
void dyld_scan_step(GuestThread &t, bool b) {
    const u64 head = b ? g_loop_b : g_loop_a;
    const u64 vec = t.x(b ? 26 : 25);
    const uint32_t gen = (uint32_t)t.x(b ? 28 : 27);
    const char *path = (const char *)t.x(b ? 19 : 21);
    const u64 state = *(const u64 *)(t.x(b ? 20 : 19) + 0x38);
    const size_t plen = strlen(path);
    const u64 ph = g_ld_cache ? str_hash(path, plen) : 0;
    const int rc = b ? 27 : 26, rn = b ? 22 : 28;
    u64 cur = t.x(rc), left = t.x(rn);
    std::lock_guard<std::mutex> lk(g_ld_mu);
    for (;;) {
        if (*(const uint32_t *)(vec + (b ? 0x20 : 0x40)) != gen) {
            t.set_x(rc, cur), t.set_x(rn, left);
            t.jit->SetPC(head + (b ? 0x64 : 0x30));
            return;
        }
        const u64 ld = *(const u64 *)cur;
        const int m = matches(ld, path, plen, ph);
        if (m < 0) {
            t.set_x(rc, cur), t.set_x(rn, left);
            t.jit->SetPC(head + 0xc);
            return;
        }
        t.set_x(23, ld);
        if (m) {
            t.set_x(0, 1), t.set_x(1, state), t.set_x(2, (u64)path);
            if (!b) cur += 8;  // "ldr x23, [x26], #8" advanced before the call
            t.set_x(rc, cur), t.set_x(rn, left);
            t.jit->SetPC(head + (b ? 0x24 : 0x84));
            return;
        }
        cur += 8;
        left -= 8;
        if (!left) {
            t.set_x(0, 0), t.set_x(1, state), t.set_x(2, (u64)path);
            t.set_x(rc, cur), t.set_x(rn, 0);
            t.jit->SetPC(head + (b ? 0x6c : 0x88));
            return;
        }
    }
}

// Perf 1: dyld4::APIs::dyld_shared_cache_some_image_overridden() returns RuntimeState's overridden-cached-dylib count
// != 0 (JustInTimeLoader::make counts every image loaded from outside the cache at a path the cache has). Our
// libsystem_kernel/platform/pthread stub dylibs (stubdylib.cpp: the native host libraries) are three such images by
// design, so it was always true, and libswiftCore then registers every shared-cache image's conformance section
// (addImageProtocolConformanceBlockCallbackUnsafe) instead of using the cache's precomputed conformance tables:
// swift_conformsToProtocol misses walked 612 cache sections (~346K records) on top of the dyld lookups, ~6M native
// round trips in a cold Settings launch. The stubs carry no Swift conformances and no ObjC classes, so the cache's
// Swift and ObjC tables stay exact for them; every other on-disk copy of a cached image is hidden from dyld_sim
// (host.cpp dyld_hides), so these stubs are the only overrides left. Its "ldr w19, [x0, #0x418]" (the count) reads
// "mov w19, #0". X86SIM_A64_DYLD_OVERRIDES=1 keeps dyld's answer.
// Applied by the AOT builder too (jitcache.cpp), so the image's dyld_sim chunk is translated from the same words.
constexpr uint32_t kOverriddenCount[] = {0xb9441813u /* ldr w19, [x0, #0x418] */, 0xf9400408u /* ldr x8, [x0, #8] */};

static void patch_overridden(u64 slide) {
    if (const char *e = getenv("X86SIM_A64_DYLD_OVERRIDES"); e && atoi(e) == 1) return;
    for (u64 a = kSearchLo; a + 8 < kSearchHi; a += 4) {
        auto *q = (uint32_t *)(slide + a);
        if (q[0] == kOverriddenCount[0] && q[1] == kOverriddenCount[1]) {
            q[0] = 0x52800013u;  // mov w19, #0
            return;
        }
    }
    logf("dyld_sim some_image_overridden: count load not found; not patched");
}

void dyld_sim_patches(u64 slide) {
    if (const char *e = getenv("X86SIM_A64_DYLD_SCAN"); !e || atoi(e) != 0) {
        g_loop_a = find_loop(slide, kLoopA, sizeof kLoopA / 4);
        g_loop_b = find_loop(slide, kLoopB, sizeof kLoopB / 4);
        if (!g_loop_a || !g_loop_b) logf("dyld_sim loader scan: loops not found (%#llx %#llx)", (unsigned long long)g_loop_a, (unsigned long long)g_loop_b);
    }
    patch_overridden(slide);
    if (const char *e = getenv("X86SIM_A64_DYLD_NATIVE"); e && atoi(e) == 0) return;
    // bl Loader::image; add x0, sp, #8; bl Header::installName  ->  bl kInstallName; nop; nop
    uint32_t *p = nullptr;
    // Platforms 1: the bl's distance differs between runtimes (0x9400107a in iOS 27.2, 0x94001077 in tvOS 27.2), so
    // the call is found by the instructions around it: "add x8, sp, #8; mov x0, x19; mov x1, x21" before it
    for (u64 a = kSearchLo + 12; a < kSearchHi && !p; a += 4) {
        auto *q = (uint32_t *)(slide + a);
        if ((q[0] >> 26) == 0x25 && q[1] == 0x910023e0u && (q[2] >> 26) == 0x25 && q[-3] == 0x910023e8u && q[-2] == 0xaa1303e0u
            && q[-1] == 0xaa1503e1u)
            p = q;
    }
    auto *pad = (uint32_t *)(slide + kTextPad);
    if (!p) {
        logf("dyld_sim matchesPath: call not found; not patched");
        return;
    }
    u64 call = (u64)p - slide;
    bool zero = true;
    for (size_t i = 0; i < sizeof kInstallName / 4; i++) zero &= pad[i] == 0;
    if (!zero) {
        logf("dyld_sim matchesPath: __TEXT padding in use; not patched");
        return;
    }
    memcpy(pad, kInstallName, sizeof kInstallName);
    p[0] = 0x94000000u | (uint32_t)(((kTextPad - call) >> 2) & 0x3ffffff);  // bl
    p[1] = 0xd503201fu;  // nop
    p[2] = 0xd503201fu;  // nop
}

}  // namespace a64
