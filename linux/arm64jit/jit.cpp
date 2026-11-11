// libarm64jit: guest threads. Each native thread that runs guest code gets its own dynarmic Jit (guest registers) and an 8 MB guest stack; the translated code is shared by all threads of the process (shared_code below).
// Native code may call back into guest code on the same thread (qsort comparators, pthread_once, TSD destructors...):
// call() then runs a nested Jit::Run (re-entrant in our dynarmic fork) on a stack frame 128 bytes below the guest's
// current SP and restores the full guest state afterwards.
#include <dlfcn.h>
#include <new>
#include <sys/personality.h>
#include "a64.h"
#include <atomic>
#include <algorithm>
#include <mutex>
#include <unordered_map>
#include <map>
#include <thread>
#include <vector>
#include <cstring>
#include <csignal>
#include <pthread.h>
#include <sys/uio.h>
#include <malloc.h>
#include <sched.h>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <sys/prctl.h>
#include <asm/prctl.h>
#include <sys/syscall.h>
#include <unistd.h>

namespace a64 {
extern bool g_step;

static Dynarmic::ExclusiveMonitor *monitor() {
    static auto *m = new Dynarmic::ExclusiveMonitor(64);
    return m;
}
static std::atomic<size_t> g_next_cpu{0};
static std::atomic<int> g_live_threads{0};  // GuestThreads alive (profiling)
// Perf 1: initial-exec (GuestThread::self() runs on every native call; 8 bytes of glibc's static TLS surplus)
static thread_local GuestThread *t_self __attribute__((tls_model("initial-exec")));
static thread_local struct Owner { GuestThread *t = nullptr; ~Owner() { delete t; } } t_owner;

// Darling's threads end without running the ELF's thread_local destructors: a native (Darling) TSD key with a
// destructor frees the thread's GuestThread (Jit, code cache, guest stack) when the thread exits. Before this every
// exited workqueue thread leaked ~20 MB.
// Guest pthread key destructors (guest function addresses; 0 = none), see h_key_create.
static std::atomic<u64> g_key_dtor[GuestThread::kGuestTsdSlots];
void set_guest_key_destructor(u64 key, u64 guest_dtor) {
    if (key < GuestThread::kGuestTsdSlots) g_key_dtor[key].store(guest_dtor);
}
// As libpthread's _pthread_tsd_cleanup: up to PTHREAD_DESTRUCTOR_ITERATIONS (4) passes over the keys, each value
// cleared before its destructor runs (a destructor may set values again). Slots 0-9 are the reserved shared ones.
void GuestThread::run_guest_tsd_destructors() {
    for (int pass = 0; pass < 4; pass++) {
        bool any = false;
        for (int k = 10; k < kGuestTsdSlots; k++) {
            const u64 v = tsd[k], d = g_key_dtor[k].load(std::memory_order_relaxed);
            if (!v || !d) continue;
            tsd[k] = 0;
            any = true;
            call(d, {v});
        }
        if (!any) break;
    }
}

static void destroy_guest_thread(void *p) {
    auto *t = (GuestThread *)p;
    if (t->depth == 0 && t_self == t) {
        t->run_guest_tsd_destructors();
        t_self = nullptr; t_owner.t = nullptr; delete t;
    }
}
// X86SIM_A64_GSAMPLE=<exe name> (debug): a host thread samples the process's main guest thread (from dyld_sim start) every 5 ms (last
// block PC, LR and 6 frame-pointer frames, read with process_vm_readv) and logs the 15 most frequent stacks every 10 s.
// For "busy but nothing visible" loops that perf cannot attribute (JIT frames have no host unwind info).
// X86SIM_A64_GSAMPLE_ALL=1: every guest thread of the process is sampled, and only samples running guest code (not
// in a thunk) count: the busy worker thread instead of an idle main thread. =2: blocked threads too (lock holders).
static std::mutex g_gs_mu;
static std::vector<GuestThread *> g_gs_threads;
static int g_gs_all;  // 1: threads in guest code; 2: every thread (also blocked in a thunk: lock holders)
// Speed 33: sampled execution counts for AOT training (X86SIM_A64_COUNT=1). A host thread looks at every guest thread
// of the process every 4 ms; one running guest code (not in a native thunk) adds a hit to its current block PC. The
// totals go to <key>.<exe>.cnt next to the jitcache .bin every 20 s ("A64CNT1\0", u64 n, n x {u64 pc, u32 hits,
// u32 0}; merged with what the file held when this process started). tools/launcher's hot set weighs blocks by these
// hits (hot::load), so the image keeps the truly hot code first and hot_split_pct can separate hot from cold.
static bool cnt_on() {
    static const bool on = [] { const char *e = getenv("X86SIM_A64_COUNT"); return e && atoi(e) == 1; }();
    return on;
}
std::string jitcache_path();
static void count_start() {
    if (!cnt_on()) return;
    static std::once_flag once;
    std::call_once(once, [] {
        sigset_t all, old;
        sigfillset(&all);
        pthread_sigmask(SIG_SETMASK, &all, &old);
        std::thread([] {
            g_non_darling_thread = true;
            std::unordered_map<u64, u32> mine, base;
            std::string path;
            bool loaded = false, dirty = false;
            u64 ticks = 0;
            for (;;) {
                usleep(4000);
                {
                    std::lock_guard l(g_gs_mu);
                    for (GuestThread *c : g_gs_threads)
                        if (c->jit && c->in_thunk < 0) { const u64 pc = c->jit->GetPC(); if (pc) { mine[pc]++; dirty = true; } }
                }
                if (++ticks % 5000 || !dirty) continue;
                if (path.empty()) {
                    const std::string b = jitcache_path();
                    if (b.size() < 5) continue;
                    path = b.substr(0, b.size() - 4) + ".cnt";
                }
                if (!loaded) {
                    loaded = true;
                    if (FILE *f = fopen(path.c_str(), "rb")) {
                        char h[16]; u64 n = 0;
                        if (fread(h, 1, 16, f) == 16 && !memcmp(h, "A64CNT1", 8) && (memcpy(&n, h + 8, 8), n < (1u << 26)))
                            for (u64 i = 0; i < n; i++) { u64 e[2]; if (fread(e, 1, 16, f) != 16) break; base[e[0]] += (u32)e[1]; }
                        fclose(f);
                    }
                }
                dirty = false;
                std::unordered_map<u64, u32> all = base;
                for (auto &[pc, h] : mine) all[pc] += h;
                const std::string tmp = path + ".tmp." + std::to_string(getpid());
                FILE *f = fopen(tmp.c_str(), "wb");
                if (!f) continue;
                char h[16]{}; memcpy(h, "A64CNT1", 8); const u64 n = all.size(); memcpy(h + 8, &n, 8);
                fwrite(h, 1, 16, f);
                for (auto &[pc, k] : all) { u64 e[2]{pc, k}; fwrite(e, 1, 16, f); }
                if (fclose(f) != 0 || rename(tmp.c_str(), path.c_str()) != 0) unlink(tmp.c_str());
            }
        }).detach();
        pthread_sigmask(SIG_SETMASK, &old, nullptr);
    });
}
static void gsample_register(GuestThread *t) {
    if (!g_gs_all && !cnt_on()) return;
    std::lock_guard l(g_gs_mu); g_gs_threads.push_back(t);
}
void gsample_forget(GuestThread *t) {
    if (!g_gs_all && !cnt_on()) return;
    std::lock_guard l(g_gs_mu);
    g_gs_threads.erase(std::remove(g_gs_threads.begin(), g_gs_threads.end(), t), g_gs_threads.end());
}
void gsample_start(GuestThread *t) {
    if (cnt_on()) { gsample_register(t); count_start(); }
    const char *want = getenv("X86SIM_A64_GSAMPLE"), *exe = getenv("X86SIM_A64_EXE");
    if (!want || !exe) return;
    const char *b = strrchr(exe, '/');
    if (strcmp(want, b ? b + 1 : exe) != 0) return;
    sigset_t all, old;
    sigfillset(&all);
    pthread_sigmask(SIG_SETMASK, &all, &old);
    g_gs_all = getenv("X86SIM_A64_GSAMPLE_ALL") ? atoi(getenv("X86SIM_A64_GSAMPLE_ALL")) : 0;
    if (g_gs_all && !cnt_on()) gsample_register(t);
    std::thread([t]() mutable {
        g_non_darling_thread = true;
        auto rd = [](u64 a) -> u64 {
            u64 v = 0;
            struct iovec lo{&v, 8}, re{reinterpret_cast<void *>(a), 8};
            return syscall(SYS_process_vm_readv, getpid(), &lo, 1, &re, 1, 0) == 8 ? v : 0;
        };
        std::map<std::vector<u64>, u32> counts;
        std::map<u64, u32> incl;
        u32 n = 0;
        const u32 period = getenv("X86SIM_A64_GSAMPLE_PERIOD") ? atoi(getenv("X86SIM_A64_GSAMPLE_PERIOD")) : 2000;
        const char *sk = getenv("X86SIM_A64_GSAMPLE_SKIP");  // a PC to leave out (the run loop's mach_msg wait)
        const bool skip_stubs = sk && !strcmp(sk, "stubs");  // Speed 33: every thread parked in the stub area
        const u64 skip = sk && !skip_stubs ? strtoull(sk, nullptr, 16) : 0;
        const bool trace = getenv("X86SIM_A64_GSAMPLE_TRACE") != nullptr;
        const int depth = getenv("X86SIM_A64_GSAMPLE_DEPTH") ? atoi(getenv("X86SIM_A64_GSAMPLE_DEPTH")) : 6;
        // logf skips the per-process log on this (non-Darling) thread: X86SIM_A64_GSAMPLE_OUT=<Linux path> writes
        // <path>.<pid> with glibc instead (a job's stderr is often gone)
        FILE *out = nullptr;
        if (const char *o = getenv("X86SIM_A64_GSAMPLE_OUT"))
            out = fopen((std::string(o) + "." + std::to_string(getpid())).c_str(), "a");
        timespec ts0; clock_gettime(CLOCK_MONOTONIC, &ts0);
        auto emit = [out, ts0](const char *line) {
            if (!out) { logf("%s", line); return; }
            timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
            fprintf(out, "%.2f %s\n", (ts.tv_sec - ts0.tv_sec) + (ts.tv_nsec - ts0.tv_nsec) / 1e9, line);
            fflush(out);
        };
        for (;;) {
            usleep(5000);
            std::unique_lock<std::mutex> lk(g_gs_mu, std::defer_lock);
            if (g_gs_all) {  // one sample: a thread in guest code, round robin from a random start
                lk.lock();
                GuestThread *pick = nullptr;
                const size_t m = g_gs_threads.size();
                for (size_t k = 0, r = m ? (size_t)random() % m : 0; k < m && !pick; k++) {
                    GuestThread *c = g_gs_threads[(r + k) % m];
                    // Speed 33: X86SIM_A64_GSAMPLE_SKIP also passes over a thread parked at that guest PC
                    if (c->jit && (c->in_thunk < 0 || g_gs_all == 2) && !(skip && c->jit->GetPC() == skip) &&
                        !(skip_stubs && c->jit->GetPC() >= 0x7f0000000000ull)) pick = c;
                }
                if (!pick) continue;
                t = pick;
            }
            if (!t->jit) continue;
            // a native call in progress is recorded as its thunk index (high marker) in front of the guest pc
            const int32_t th = t->in_thunk;
            std::vector<u64> st{th >= 0 ? 0xF000000000000000ull | (u32)th : 0, t->jit->GetPC(), t->x(30)};
            if (skip && st[0] == skip) continue;
            u64 fp = t->x(29);
            for (int k = 0; k < depth && fp > 0x10000 && !(fp & 7); k++) {
                st.push_back(rd(fp + 8));
                const u64 next = rd(fp);
                if (next <= fp) break;
                fp = next;
            }
            if (trace) {  // X86SIM_A64_GSAMPLE_TRACE=1: every sample with its CLOCK_REALTIME ns (lines up with simhid/ring)
                timespec tr; clock_gettime(CLOCK_REALTIME, &tr);
                char line[1024];
                int o = snprintf(line, sizeof line, "T %llu", (unsigned long long)tr.tv_sec * 1000000000ull + tr.tv_nsec);
                for (u64 a : st) {
                    // Speed 22: the thunk's number, not g_thunks[i].name: thunks are still added while this thread reads
                    // (vector reallocation: the sampler SIGSEGV'd SpringBoard). Names: the thunk table in the log.
                    if (a >> 60 == 0xF) o += snprintf(line + o, sizeof line - o > 0 ? sizeof line - o : 0, " [#%u]", (unsigned)(a & 0xffffffff));
                    else o += snprintf(line + o, sizeof line - o > 0 ? sizeof line - o : 0, " %#lx", (unsigned long)a);
                    if (o >= (int)sizeof line) break;
                }
                if (out) { fputs(line, out); fputc('\n', out); if (n % 200 == 0) fflush(out); }  // Speed 33: survives a kill
            }
            counts[st]++;
            for (size_t i = 0; i < st.size(); i++)
                if (std::find(st.begin(), st.begin() + i, st[i]) == st.begin() + i) incl[st[i]]++;
            if (++n % period) continue;
            std::vector<std::pair<u32, const std::vector<u64> *>> top;
            for (auto &[k, v] : counts) top.push_back({v, &k});
            std::sort(top.begin(), top.end(), [](auto &a, auto &b) { return a.first > b.first; });
            { char l[64]; snprintf(l, sizeof l, "gsample: %u samples", n); emit(l); }
            for (size_t i = 0; i < top.size() && i < 15; i++) {
                char line[1024];
                int o = snprintf(line, sizeof line, "gsample %4u:", top[i].first);
                for (u64 a : *top[i].second) {
                    if (a >> 60 == 0xF) o += snprintf(line + o, sizeof line - o > 0 ? sizeof line - o : 0, " [%s]", g_thunks[a & 0xffffffff].name.c_str());
                    else if (a) o += snprintf(line + o, sizeof line - o > 0 ? sizeof line - o : 0, " %#lx", (unsigned long)a);
                }
                emit(line);
            }
            counts.clear();
            // inclusive: every frame address with the samples it appears in (attribute to images offline)
            std::vector<std::pair<u32, u64>> inc;
            for (auto &[a, v] : incl) inc.push_back({v, a});
            std::sort(inc.rbegin(), inc.rend());
            for (size_t i = 0; i < inc.size() && i < 80; i++) {
                char l[64]; snprintf(l, sizeof l, "gsample incl %u %#lx", inc[i].first, (unsigned long)inc[i].second); emit(l);
            }
            incl.clear();
        }
    }).detach();
    pthread_sigmask(SIG_SETMASK, &old, nullptr);
}

// Input 3 (debug): X86SIM_A64_GBT=1: every guest thread of the process is registered, and a host thread dumps all of
// them on request: when <scratch>/gbt/req is newer than the last dump (tools/debug/gbt.sh touches it) or when gdb calls
// a64_gbt_dump(). Per thread: Linux tid, the thunk it is in (host call in progress: its native wait), the kernel's
// wchan and /proc syscall line, guest pc/lr/sp/fp, x0-x7, the mach message header at x0 for mach_msg thunks, and the
// guest frame-pointer chain (40 frames). Output: <scratch>/gbt/<exe>.<pid>.txt (appended), addresses raw plus where()
// for non-cache ones; tools/debug/gbt.sh symbolizes cache addresses with dscsym.py. Off: no registry, no thread.
// read once at load (after the a64-penv constructor, priority 101): a plain load in CallSVC
static const bool g_gbt_on = [] { const char *e = getenv("X86SIM_A64_GBT"); return e && atoi(e) == 1; }();
static bool gbt_on() { return g_gbt_on; }
struct GbtEnt { GuestThread *t; int tid; std::string proc; };  // proc: /proc/<pid>/task/<tid> as /proc sees it
static std::mutex g_gbt_mu;
static std::vector<GbtEnt> g_gbt_threads;
static void gbt_start();
static void gbt_register(GuestThread *t) {
    if (!gbt_on()) return;
    // Darling's container has its own pid namespace but sees the host's /proc: the thread's own entry, by readlink
    char ts[128] = "";
    const ssize_t n = readlink("/proc/thread-self", ts, sizeof ts - 1);
    ts[n > 0 ? n : 0] = 0;
    { std::lock_guard l(g_gbt_mu); g_gbt_threads.push_back({t, (int)syscall(SYS_gettid), n > 0 ? std::string("/proc/") + ts : ""}); }
    gbt_start();
}
static void gbt_forget(GuestThread *t) {
    if (!gbt_on()) return;
    std::lock_guard l(g_gbt_mu);
    g_gbt_threads.erase(std::remove_if(g_gbt_threads.begin(), g_gbt_threads.end(), [t](const GbtEnt &e) { return e.t == t; }), g_gbt_threads.end());
}
// guest memory that may be unmapped: pread of /proc/self/mem (process_vm_readv with the namespace pid failed here)
static bool gbt_rd(u64 a, void *buf, size_t n) {
    static int fd = open("/proc/self/mem", O_RDONLY | O_CLOEXEC);
    return fd >= 0 && pread(fd, buf, n, (off_t)(a & GuestThread::kTbi)) == (ssize_t)n;
}
static std::string gbt_procline(const std::string &proc, const char *what) {
    std::string r;
    if (proc.empty()) return r;
    if (FILE *f = fopen((proc + "/" + what).c_str(), "r")) { char b[256]; if (fgets(b, sizeof b, f)) r = b; fclose(f); }
    while (!r.empty() && (r.back() == '\n' || r.back() == ' ')) r.pop_back();
    return r;
}
static std::string gbt_dir() { return scratch_dir() + "/gbt"; }
extern "C" __attribute__((visibility("default"), used)) int a64_gbt_dump() {
    const char *exe = getenv("X86SIM_A64_EXE");
    const char *b = exe ? strrchr(exe, '/') : nullptr;
    b = b ? b + 1 : exe ? exe : "?";
    mkdir(gbt_dir().c_str(), 0755);
    const std::string fn = gbt_dir() + "/" + b + "." + std::to_string(getpid()) + ".txt";
    FILE *o = fopen(fn.c_str(), "a");
    if (!o) return -1;
    timespec ts; clock_gettime(CLOCK_REALTIME, &ts);
    std::lock_guard l(g_gbt_mu);
    fprintf(o, "=== gbt %s pid %d time %ld.%03ld threads %zu\n", b, (int)getpid(), (long)ts.tv_sec, ts.tv_nsec / 1000000, g_gbt_threads.size());
    const u32 nth = thunk_count();
    for (const GbtEnt &e : g_gbt_threads) {
        GuestThread *t = e.t;
        if (!t->jit) { fprintf(o, "--- tid %d: no jit\n", e.tid); continue; }
        const int32_t th = t->in_thunk;
        const char *thn = th >= 0 && (u32)th < nth ? g_thunks[th].name.c_str() : "";
        // depth 0: not inside a guest call at all (an idle workqueue thread parked in Darling); the registers are stale
        fprintf(o, "--- tid %d (%s) depth %d %s%s | wchan %s | syscall %s\n", e.tid, e.proc.c_str() + (e.proc.empty() ? 0 : 6), t->depth,
                t->depth == 0 ? "idle (no guest call)" : th >= 0 ? "in thunk " : "running guest", t->depth && th >= 0 ? thn : "",
                gbt_procline(e.proc, "wchan").c_str(), gbt_procline(e.proc, "syscall").c_str());
        if (t->depth == 0) continue;
        const u64 pc = t->jit->GetPC(), lr = t->x(30), sp = t->sp(), fp = t->x(29);
        // tsd[3]: the thread's Mach port name (an os_unfair_lock's owner field), tsd[0]: its pthread_t
        fprintf(o, "  pc %#lx lr %#lx sp %#lx fp %#lx port %#lx pthread %#lx\n  x0-7", (unsigned long)pc, (unsigned long)lr, (unsigned long)sp,
                (unsigned long)fp, t->tsd ? (unsigned long)t->tsd[3] : 0ul, t->tsd ? (unsigned long)t->tsd[0] : 0ul);
        for (int i = 0; i < 8; i++) fprintf(o, " %#lx", (unsigned long)t->x(i));
        fputc('\n', o);
        if (th >= 0 && strstr(thn, "mach_msg")) {
            u32 h[6];  // bits, size, remote, local, voucher, id
            if (gbt_rd(t->x(0), h, sizeof h))
                fprintf(o, "  msg bits %#x size %u remote %#x local %#x voucher %#x id %u (%#x)\n", h[0], h[1], h[2], h[3], h[4], h[5], h[5]);
        }
        auto fr = [&](int k, u64 a) {
            std::string w = a >= 0x1c0000000ull && a < 0x300000000ull ? "" : where(a);
            fprintf(o, "  #%-2d %#lx %s\n", k, (unsigned long)a, w.c_str());
        };
        fr(-1, pc); fr(0, lr);
        u64 f = fp;
        for (int k = 1; k < 40 && f > 0x10000 && !(f & 7); k++) {
            u64 two[2];
            if (!gbt_rd(f, two, sizeof two)) break;
            fr(k, two[1] & 0x0000ffffffffffffull);
            if (two[0] <= f) break;
            f = two[0];
        }
    }
    fclose(o);
    return 0;
}
// The process's Mach port space, written by the next guest thread to make a native call after a dump request (the
// dumper thread is not a Darling thread and cannot make Mach calls): every name with its type and, for receive rights,
// the queued message count, queue limit, send rights, send-once rights and port set. A message that stays queued on
// a port while the process waits is a lost wakeup.
static std::atomic<int> g_gbt_ports_req{0};
static void gbt_ports_dump() {
    using kr_t = int;
    static auto *task_self = (unsigned *)dsym("mach_task_self_");
    static auto *names = (kr_t (*)(unsigned, unsigned **, unsigned *, unsigned **, unsigned *))dsym("mach_port_names");
    static auto *attrs = (kr_t (*)(unsigned, unsigned, int, int *, unsigned *))dsym("mach_port_get_attributes");
    static auto *vmdealloc = (kr_t (*)(unsigned, uint64_t, uint64_t))dsym("vm_deallocate");
    if (!task_self || !names || !attrs) return;
    const char *exe = getenv("X86SIM_A64_EXE");
    const char *b = exe ? strrchr(exe, '/') : nullptr;
    b = b ? b + 1 : exe ? exe : "?";
    FILE *o = fopen((gbt_dir() + "/" + b + "." + std::to_string(getpid()) + ".ports.txt").c_str(), "a");
    if (!o) return;
    unsigned *nm = nullptr, *ty = nullptr, nn = 0, nt = 0;
    timespec ts; clock_gettime(CLOCK_REALTIME, &ts);
    const kr_t kr = names(*task_self, &nm, &nn, &ty, &nt);
    fprintf(o, "=== ports %s pid %d time %ld.%03ld kr %d names %u\n", b, (int)getpid(), (long)ts.tv_sec, ts.tv_nsec / 1000000, kr, nn);
    unsigned dead = 0;
    for (unsigned k = 0; kr == 0 && k < nn; k++) {
        const unsigned t = ty[k];
        if (t & 0x100000) { dead++; continue; }  // MACH_PORT_TYPE_DEAD_NAME: counted
        if (!(t & 0x20000)) continue;            // MACH_PORT_TYPE_RECEIVE only
        int st[10] = {}; unsigned cnt = 10;      // mach_port_status_t (MACH_PORT_RECEIVE_STATUS = 2)
        attrs(*task_self, nm[k], 2, st, &cnt);
        // pset, seqno, mscount, qlimit, msgcount, sorights, srights, pdrequest, nsrequest, flags
        fprintf(o, "%#x type %#x pset %#x qlimit %d msgs %d sorights %d srights %d flags %#x%s\n", nm[k], t, st[0], st[3], st[4],
                st[5], st[6] ? 1 : 0, st[9], st[4] ? "  <== queued" : "");
    }
    fprintf(o, "dead names %u\n", dead);
    // port sets and their members: a receive right in a set a thread waits on, with a message queued, while that
    // thread stays asleep, is a lost port-set wakeup
    static auto *setstat = (kr_t (*)(unsigned, unsigned, unsigned **, unsigned *))dsym("mach_port_get_set_status");
    for (unsigned k = 0; setstat && kr == 0 && k < nn; k++) {
        if (!(ty[k] & 0x80000)) continue;  // MACH_PORT_TYPE_PORT_SET
        unsigned *mem = nullptr, nmem = 0;
        if (setstat(*task_self, nm[k], &mem, &nmem) != 0) { fprintf(o, "set %#x: status failed\n", nm[k]); continue; }
        fprintf(o, "set %#x: %u members:", nm[k], nmem);
        for (unsigned j = 0; j < nmem; j++) {
            int st[10] = {}; unsigned cnt = 10;
            attrs(*task_self, mem[j], 2, st, &cnt);
            fprintf(o, " %#x%s", mem[j], st[4] ? "(queued)" : "");
        }
        fprintf(o, "\n");
        if (vmdealloc && mem) vmdealloc(*task_self, (uint64_t)mem, nmem * 4ull);
    }
    fclose(o);
    if (vmdealloc && nm) { vmdealloc(*task_self, (uint64_t)nm, nn * 4ull); vmdealloc(*task_self, (uint64_t)ty, nt * 4ull); }
}
static void gbt_svc_hook() {
    if (g_gbt_ports_req.load(std::memory_order_relaxed) && g_gbt_ports_req.exchange(0)) gbt_ports_dump();
}
static void gbt_start() {
    static std::once_flag once;
    std::call_once(once, [] {
        sigset_t all, old;
        sigfillset(&all);
        pthread_sigmask(SIG_SETMASK, &all, &old);
        std::thread([] {
            g_non_darling_thread = true;
            const std::string req = gbt_dir() + "/req";
            struct stat st;
            timespec last{};
            if (stat(req.c_str(), &st) == 0) last = st.st_mtim;  // only requests made after the start
            for (;;) {
                sleep(1);
                if (stat(req.c_str(), &st) != 0) continue;
                if (st.st_mtim.tv_sec == last.tv_sec && st.st_mtim.tv_nsec == last.tv_nsec) continue;
                last = st.st_mtim;
                a64_gbt_dump();
                g_gbt_ports_req = 1;
            }
        }).detach();
        pthread_sigmask(SIG_SETMASK, &old, nullptr);
    });
}

GuestThread &GuestThread::self() {
    if (!t_self) {
        t_owner.t = new GuestThread(); t_self = t_owner.t;
        gsample_register(t_self);
        gbt_register(t_self);
        static unsigned long key = [] {
            unsigned long k = 0;
            auto *create = (int (*)(unsigned long *, void (*)(void *)))dsym("pthread_key_create");
            if (create) create(&k, destroy_guest_thread);
            return k;
        }();
        static auto *setspec = (int (*)(unsigned long, const void *))dsym("pthread_setspecific");
        if (key && setspec) setspec(key, t_self);
    }
    return *t_self;
}

GuestThread *GuestThread::current() { return t_self; }

// Stage 3: one translation cache per process, shared by every guest thread (dynarmic's shared_translations: the
// code reads tpidr/tpidrro and the exclusive-monitor slot from the running thread's JitState). The code calls these
// process-wide callbacks, which forward to the calling thread's GuestThread. X86SIM_A64_SHARED=0: one cache per
// thread (stage 2). Shared code is never freed while the process runs (threads blocked in native calls return
// into it), so the cache is a large reservation: only the code actually emitted is resident.
namespace {
// Speed 9: libswift_Concurrency's dispatch executor (the swift_task_enqueueGlobalWithDeadline path) converts a
// deadline from ns to mach ticks with Apple silicon's timebase inlined (ns * 3 / 125). Our guest timebase is 1/1 (mach
// time counts ns, like Darling's), so every Swift sleep (Task.sleep, Clock.sleep, ...) fired at once: Settings'
// search-field task spun its main thread (~10k wakeups/s, ~90% of a core while idle) and its placeholder crossfade
// never settled. The two words that pick the conversion branch read as "mov x21, x8; b <join>" (deadline unchanged).
// Only when the original words are there (iOS 27.0 24A434 cache); guest memory is not written (MemoryReadCode, like
// swiftconf), so the AOT builder sees the same code. X86SIM_A64_SWIFT_TIMEBASE=0 turns it off (rebuild the image).
constexpr u64 kSwiftDeadlineConv = 0x1c156d4ac;
std::optional<uint32_t> swift_timebase_read_code(u64 a) {
    if (a != kSwiftDeadlineConv && a != kSwiftDeadlineConv + 4) return std::nullopt;
    static const bool ok = [] {
        const char *e = getenv("X86SIM_A64_SWIFT_TIMEBASE");
        if (e && atoi(e) == 0) return false;
        if (timebase_apple()) return false;  // the guest's timebase is 125/3: the inlined conversion is right
        // cmp x8, x9 ; b.lo (x*3 first) ; ... and the join branch both conversions take (b -> 0x1c156d3bc)
        const bool match = GuestThread::rd<uint32_t>(kSwiftDeadlineConv) == 0xeb09011fu &&
                           GuestThread::rd<uint32_t>(kSwiftDeadlineConv + 4) == 0x54000663u &&
                           GuestThread::rd<uint32_t>(0x1c156d4d8) == 0x17ffffb9u;
        if (!match) logf("swift timebase: libswift_Concurrency deadline conversion not found; Task.sleep stays early");
        return match;
    }();
    if (!ok) return std::nullopt;
    return a == kSwiftDeadlineConv ? 0xaa0803f5u /* mov x21, x8 */ : 0x17ffffc3u /* b 0x1c156d3bc */;
}

// Speed 30 debug: X86SIM_A64_AGDL=1 (27.2 24B8117 cache addresses; needs X86SIM_A64_LIVE_ONLY=1 for the process,
// the image holds these blocks translated): AG::Graph::Context::set_deadline(ctx, deadline) logs the deadline relative
// to now; passed_deadline_slow's "passed" exit logs the overshoot. The replaced words are emulated in the handler.
constexpr u64 kAgSetDeadline = 0x1c95106b4, kAgPassed = 0x1c95111f4, kAgPassed2 = 0x1c9511208;
constexpr u64 kAgCancel = 0x1c950c654, kAgCancelApi = 0x1c952c850;  // UpdateStack::cancel, AGGraphCancelUpdate
std::optional<uint32_t> agdl_read_code(u64 a) {
    if (a == kAgCancel || a == kAgCancelApi) {
        static const bool on = getenv("X86SIM_A64_AGDL") && GuestThread::rd<uint32_t>(kAgCancel) == 0xa9bf7bfdu &&
                               GuestThread::rd<uint32_t>(kAgCancelApi) == 0xa9bf7bfdu;
        if (!on) return std::nullopt;
        return 0xD4000001u | (kAgDlCancelSvc << 5);
    }
    if (a == kAgPassed2) {
        static const bool on = getenv("X86SIM_A64_AGDL") && GuestThread::rd<uint32_t>(kAgPassed2) == 0x52800020u;
        if (!on) return std::nullopt;
        return 0xD4000001u | (kAgDlPassedSvc << 5);
    }
    if (a != kAgSetDeadline && a != kAgPassed) return std::nullopt;
    static const bool on = getenv("X86SIM_A64_AGDL") && GuestThread::rd<uint32_t>(kAgSetDeadline) == 0xf9401c08u &&
                           GuestThread::rd<uint32_t>(kAgPassed) == 0x52800020u;
    if (!on) return std::nullopt;
    return 0xD4000001u | ((a == kAgSetDeadline ? kAgDlSetSvc : kAgDlPassedSvc) << 5);
}

// Speed 31 debug: X86SIM_A64_AGOUT=<attribute id, hex> (27.2 24B8117 addresses; with X86SIM_A64_LIVE_ONLY for the
// process): AGGraphSetOutputValue / AGGraphGetOutputValue log when AttributeGraph's current attribute (top frame of
// the thread's UpdateStack: pthread key at 0x22e74c980, frames as in the Speed 30 abort dump) is that attribute
// (0 = every call, first 2000). The replaced first instructions are emulated in the handlers.
constexpr u64 kAgSetOut = 0x1c952c490, kAgGetOut = 0x1c952c91c, kAgKeyVar = 0x22e74c980;
constexpr u64 kAgOutRing = 1 << 16;
struct AgOutEv { u64 frame = 0, value = 0, type = 0, lr = 0; u32 tid = 0; bool set = false, ret = false; uint8_t result = 0; u32 f0 = 0, f1 = 0, v0 = 0, f1a = 0, v0a = 0; u64 val = 0; };
AgOutEv g_agout_ring[kAgOutRing];
std::atomic<u64> g_agout_n{0};
constexpr u64 kAgTableVar = 0x22e74c908;
struct AgOutRet { u64 lr; u32 attr; u32 before[8]; u64 ring; };
thread_local std::vector<AgOutRet> t_agout_ret;
void agout_node(u32 attr, u32 *w) {
    const u64 base = GuestThread::rd<u64>(kAgTableVar);
    for (int i = 0; i < 8; i++) w[i] = base ? GuestThread::rd<u32>(base + attr + 4 * i) : 0;
}
void agout_ret_h(GuestThread &t, u32) {
    if (t_agout_ret.empty()) die("agout: return thunk without a pending set");
    AgOutRet r = t_agout_ret.back();
    t_agout_ret.pop_back();
    u32 w[8];
    agout_node(r.attr, w);
    const u64 base = GuestThread::rd<u64>(kAgTableVar);
    u64 val[2] = {};
    if (base && w[2]) { val[0] = GuestThread::rd<u64>(base + w[2]); val[1] = GuestThread::rd<u64>(base + w[2] + 8); }
    if (r.ring != ~0ull) {  // the abort dump shows it (ring mode: the failing attribute is not known in advance)
        AgOutEv &e = g_agout_ring[r.ring & (kAgOutRing - 1)];
        e.ret = true; e.result = (uint8_t)t.x(0); e.f0 = r.before[0]; e.f1 = r.before[1]; e.v0 = r.before[2]; e.f1a = w[1]; e.v0a = w[2]; e.val = val[0];
    }
    static const u64 want = strtoull(getenv("X86SIM_A64_AGOUT"), nullptr, 16);
    if (want > 1) logf("agout: set returned %lu for attr %#x: node before %08x %08x %08x %08x %08x %08x, after %08x %08x %08x %08x %08x %08x"
         " (flags word +4: %#x -> %#x, value offset +8: %#x -> %#x), value %016lx %016lx, table %#lx",
         (unsigned long)(t.x(0) & 0xff), r.attr, r.before[0], r.before[1], r.before[2], r.before[3], r.before[4], r.before[5],
         w[0], w[1], w[2], w[3], w[4], w[5], r.before[1], w[1], r.before[2], w[2], (unsigned long)val[0], (unsigned long)val[1],
         (unsigned long)base);
    t.set_x(30, r.lr);  // the thunk's "ret" goes back to the caller
}
void agout_arm_return(GuestThread &t, u32 attr, u64 ring) {
    static const u32 thunk = add_thunk("x86sim_agout_ret", agout_ret_h);
    AgOutRet r{t.x(30), attr, {}, ring};
    agout_node(attr, r.before);
    t_agout_ret.push_back(r);
    t.set_x(30, stub_code(thunk));
}
std::optional<uint32_t> agout_read_code(u64 a) {
    if (a != kAgSetOut && a != kAgGetOut) return std::nullopt;
    static const bool on = getenv("X86SIM_A64_AGOUT") && GuestThread::rd<uint32_t>(kAgSetOut) == 0xd10203ffu &&
                           GuestThread::rd<uint32_t>(kAgGetOut) == 0xa9be4ff4u;
    if (!on) return std::nullopt;
    return 0xD4000001u | ((a == kAgSetOut ? kAgOutSetSvc : kAgOutGetSvc) << 5);
}

// Speed 35 debug: X86SIM_A64_AGCHK=1 (27.2 24B8117; with X86SIM_A64_LIVE_ONLY for the process). After the rule runs,
// AG::Graph::UpdateStack::update reloads the node's flags through x28 (= [table base 0x22e74c908] + attribute id,
// computed before the rule; 0x1c950bf90) and aborts "failed to set an initial value" when bit 4 is clear and the value
// type is not empty (0x1c950c138 -> 0x1c950c4b8 -> 0x1c950c628). The SVC replaces that load (ldr w8, [x28, #4]) and
// logs when the cached pointer no longer equals the current base + id, or bit 4 is clear, with both views' flags.
constexpr u64 kAgChkPc = 0x1c950c134;
std::optional<uint32_t> agchk_read_code(u64 a) {
    if (a != kAgChkPc) return std::nullopt;
    static const bool on = getenv("X86SIM_A64_AGCHK") && atoi(getenv("X86SIM_A64_AGCHK")) == 1 && GuestThread::rd<uint32_t>(kAgChkPc) == 0xb9400788u;
    if (!on) return std::nullopt;
    return 0xD4000001u | (kAgChkSvc << 5);
}

// Platforms 1 debug: X86SIM_A64_BLWATCH=<addr>[,<addr>...] (guest addresses of "bl" / "b" instructions, hex): each is read
// by the JIT as "svc #kBlWatchSvc"; the handler logs the call (target, x0-x2, lr) and makes it. "+<hex>": an offset
// from the main executable's load address. Translations with the
// substitution are not meant to be kept: run with X86SIM_A64_JITCACHE=0 X86SIM_A64_AOT=0 (and X86SIM_A64_NOASLR=1 for
// a non-cache image's unslid addresses).
static const std::vector<u64> &blwatch_sites() {
    static const std::vector<u64> v = [] {
        std::vector<u64> r;
        // "+<offset>": from the main executable's load address (its first mapping in /proc/self/maps)
        u64 exe_base = 0;
        if (const char *exe = getenv("X86SIM_A64_EXE")) {
            const char *bn = strrchr(exe, '/');
            bn = bn ? bn + 1 : exe;
            if (FILE *f = fopen("/proc/self/maps", "r")) {
                char line[1024];
                while (!exe_base && fgets(line, sizeof line, f)) {
                    char *nl = strchr(line, '\n');
                    if (nl) *nl = 0;
                    const char *sl = strrchr(line, '/');
                    if (sl && !strcmp(sl + 1, bn)) exe_base = strtoull(line, nullptr, 16);
                }
                fclose(f);
            }
        }
        if (const char *e = getenv("X86SIM_A64_BLWATCH"))
            for (const char *q = e; *q;) {
                const bool rel = *q == '+';
                if (rel) q++;
                char *end; u64 a = strtoull(q, &end, 16);
                if (end == q) break;
                r.push_back(rel ? exe_base + a : a);
                q = *end == ',' ? end + 1 : end;
            }
        if (!r.empty()) logf("blwatch: %zu sites (main executable at %#lx)", r.size(), (unsigned long)exe_base);
        return r;
    }();
    return v;
}
std::optional<uint32_t> blwatch_read_code(u64 a) {
    for (u64 w : blwatch_sites())
        if (w == a) return 0xD4000001u | (kBlWatchSvc << 5);
    return std::nullopt;
}

struct Forward final : Dynarmic::A64::UserCallbacks {
    static GuestThread &T() { return *t_self; }
    std::optional<uint32_t> MemoryReadCode(u64 a) override {
        if (auto w = swiftconf_read_code(a)) return w;
        if (auto w = dyld_scan_read_code(a)) return w;
        if (auto w = swifttype_read_code(a)) return w;
        if (auto w = swift_timebase_read_code(a)) return w;
        if (auto w = agdl_read_code(a)) return w;
        if (auto w = astc_read_code(a)) return w;
        if (auto w = lzfse_read_code(a)) return w;
        if (auto w = agout_read_code(a)) return w;
        if (auto w = agchk_read_code(a)) return w;
        if (__builtin_expect(!blwatch_sites().empty(), 0))
            if (auto w = blwatch_read_code(a)) return w;
        return GuestThread::rd<uint32_t>(a);
    }
    uint8_t MemoryRead8(u64 a) override { return GuestThread::rd<uint8_t>(a); }
    uint16_t MemoryRead16(u64 a) override { return GuestThread::rd<uint16_t>(a); }
    uint32_t MemoryRead32(u64 a) override { return GuestThread::rd<uint32_t>(a); }
    u64 MemoryRead64(u64 a) override { return GuestThread::rd<u64>(a); }
    // Speed 17: an import stub's GOT slot, for the guarded direct link (A64StubLinkPass). Only slots and targets in
    // the persisted window (shared cache + placed images: fixed per cache key), read without faulting. Unbound
    // slots (chained-fixup encodings in the AOT builder's unbound placed images) fall outside the window.
    std::optional<u64> MemoryReadConstant64(u64 a) override {
        constexpr u64 lo = 0x1c0000000ull, hi = 0x300000000ull;  // RAM 13: kCacheHi
        if (a < lo || a + 8 > hi || (a & 7)) return std::nullopt;
        u64 v = 0;
        iovec l{&v, 8}, r{(void *)a, 8};
        if (process_vm_readv(getpid(), &l, 1, &r, 1, 0) != 8) return std::nullopt;
        if (v < lo || v >= hi) return std::nullopt;
        return v;
    }
    Dynarmic::A64::Vector MemoryRead128(u64 a) override { return GuestThread::rd<Dynarmic::A64::Vector>(a); }
    void MemoryWrite8(u64 a, uint8_t v) override { GuestThread::wr(a, v); }
    void MemoryWrite16(u64 a, uint16_t v) override { GuestThread::wr(a, v); }
    void MemoryWrite32(u64 a, uint32_t v) override { GuestThread::wr(a, v); }
    void MemoryWrite64(u64 a, u64 v) override { GuestThread::wr(a, v); }
    void MemoryWrite128(u64 a, Dynarmic::A64::Vector v) override { GuestThread::wr(a, v); }
    bool MemoryWriteExclusive8(u64 a, uint8_t v, uint8_t e) override { return T().MemoryWriteExclusive8(a, v, e); }
    bool MemoryWriteExclusive16(u64 a, uint16_t v, uint16_t e) override { return T().MemoryWriteExclusive16(a, v, e); }
    bool MemoryWriteExclusive32(u64 a, uint32_t v, uint32_t e) override { return T().MemoryWriteExclusive32(a, v, e); }
    bool MemoryWriteExclusive64(u64 a, u64 v, u64 e) override { return T().MemoryWriteExclusive64(a, v, e); }
    bool MemoryWriteExclusive128(u64 a, Dynarmic::A64::Vector v, Dynarmic::A64::Vector e) override { return T().MemoryWriteExclusive128(a, v, e); }
    void InterpreterFallback(u64 pc, size_t n) override { T().InterpreterFallback(pc, n); }
    void CallSVC(uint32_t swi) override { T().CallSVC(swi); }
    void ExceptionRaised(u64 pc, Dynarmic::A64::Exception e) override { T().ExceptionRaised(pc, e); }
    void InstructionCacheOperationRaised(Dynarmic::A64::InstructionCacheOperation op, u64 value) override {
        T().InstructionCacheOperationRaised(op, value);
    }
    void AddTicks(u64) override {}
    u64 GetTicksRemaining() override { return ~0ull; }
    u64 GetCNTPCT() override { return T().GetCNTPCT(); }
};
}

static bool shared_translations() {
    static const bool on = !(getenv("X86SIM_A64_SHARED") && atoi(getenv("X86SIM_A64_SHARED")) == 0);
    return on;
}

// Speed 6 (shared AOT image): translated code embeds the code cache address, the FastDispatch table (mapped after the
// code cache), the callbacks object and the inline objc counters. All of them sit at fixed addresses so the relocated
// image is byte-identical in every process: the code cache at kNoAslrCodeBase when ASLR is off (launchd_sim's
// children; the library's own address still differs by executable), else 1 GB below this library (rel32 reach to it
// < 2 GB), and the rest in a fixed data page 2 MB below the code cache.
constexpr u64 kNoAslrCodeBase = 0x7fffa0000000ull;
// Speed 18: the shared code cache holds the AOT image plus room for this process's own translations. Default 768 MB;
// with a larger image, image + 384 MB. RAM 13: up to 2000 MB (was 1344: rel32 reach of libarm64jit and glibc for the
// prelude's near host calls). Every host call now goes through a stub page 4 MB below the cache (host_call_stubs), so
// the cache needs reach only to that page and FixedData. X86SIM_A64_CODECACHE_MB overrides.
constexpr u64 kMaxCodeCacheMb = 2000;
static u64 code_cache_mb() {
    static const u64 mb = []() -> u64 {
        if (const char *e = getenv("X86SIM_A64_CODECACHE_MB")) { const int v = atoi(e); if (v >= 64) return std::min<u64>(v, kMaxCodeCacheMb); }
        const u64 img = jitcache_image_code_bytes() >> 20;
        return std::clamp<u64>(img + 384, 768, kMaxCodeCacheMb);
    }();
    return mb;
}
static u64 code_cache_base() {
    static const u64 base = []() -> u64 {
        // the cache ends where the 768 MB one always ended (kNoAslrCodeBase + 768 MB) and grows downwards
        if (personality(0xffffffff) & ADDR_NO_RANDOMIZE) return kNoAslrCodeBase + (768ull << 20) - (code_cache_mb() << 20);
        Dl_info di{};
        // below libarm64jit, as close as fits (builders use slabs of up to kMaxCodeCacheMb)
        return dladdr((void *)&code_cache_base, &di) && di.dli_fbase
                   ? ((u64)di.dli_fbase - std::max<u64>(1ull << 30, (code_cache_mb() << 20) + (64ull << 20))) & ~0xfffffull : 0;
    }();
    return base;
}
FixedData &fixed_data() {
    static FixedData *fd = [] {
        void *p = MAP_FAILED;
        if (const u64 b = code_cache_base())
            p = mmap((void *)(b - 0x200000), sizeof(FixedData), PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0);
        if (p == MAP_FAILED) p = mmap(nullptr, sizeof(FixedData), PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        return new (p) FixedData();
    }();
    return *fd;
}

// RAM 13: host-call stubs (16 bytes each, 64K of them) at a fixed address 4 MB below the code cache, filled as the
// emitter needs them (the prelude first, in the same order in every process, so the prelude bytes stay shareable).
static void host_call_stubs() {
    constexpr size_t kBytes = 1u << 20;
    const u64 b = code_cache_base();
    if (!b || (getenv("X86SIM_A64_HOSTSTUBS") && atoi(getenv("X86SIM_A64_HOSTSTUBS")) == 0)) return;
    void *p = mmap((void *)(b - 0x400000), kBytes, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0);
    if (p == MAP_FAILED) { logf("hoststubs: %#llx taken", (unsigned long long)(b - 0x400000)); return; }
    prctl(0x53564d41 /* PR_SET_VMA */, 0 /* ANON_NAME */, (unsigned long)p, kBytes, (unsigned long)"a64:hoststubs");
    Dynarmic::A64::Jit::SetHostCallStubs(p, kBytes);
}

static Dynarmic::A64::Jit::SharedCode *g_shared_code;  // for memlog from host threads (never freed)
static std::shared_ptr<Dynarmic::A64::Jit::SharedCode> shared_code(const Dynarmic::A64::UserConfig &thread_cfg) {
    static std::shared_ptr<Dynarmic::A64::Jit::SharedCode> code = [&] {
        static_assert(sizeof(Forward) <= sizeof(FixedData::callbacks));
        Dynarmic::A64::UserConfig c = thread_cfg;
        c.callbacks = new (fixed_data().callbacks) Forward;
        c.shared_translations = true;
        c.tpidr_el0 = nullptr; c.tpidrro_el0 = nullptr;
        // Shared BlockLinking uses atomic 8-byte patch heads (see EmitSharedPatchSite). Required for
        // boot-to-home: with linking off, SpringBoard livelocks in the dispatcher (billions of
        // lookups, idle black). X86SIM_A64_LINK=0 disables linking for experiments.
        // Fastmem fault "recompile" Invalidates/Unpatches from the SIGSEGV handler — even with
        // shared_mutex held that still patches live code; redirect the fault via FakeCall only
        // (recompile_on_*_failure = false). FastDispatch stays (16-byte atomic data). RSB: see below.
        if (getenv("X86SIM_A64_LINK") && atoi(getenv("X86SIM_A64_LINK")) == 0) {
            c.optimizations &= ~Dynarmic::OptimizationFlag::BlockLinking;
        }
        // Speed 25: a pop checks the shared invalidate generation (A64JitState::rsb_gen): after another thread's
        // Invalidate/ClearCache this thread's entries are dropped and the return goes through FastDispatch. On by default
        // (X86SIM_A64_RSB=0: off, experiments only; code-shaping: PushRSB and the pop terminal are in the image).
        if (getenv("X86SIM_A64_RSB") && atoi(getenv("X86SIM_A64_RSB")) == 0) {
            c.optimizations &= ~Dynarmic::OptimizationFlag::ReturnStackBuffer;
        }
        // Speed 29 (experiments): X86SIM_A64_OPT_KEEP=<hex mask> keeps only these Dynarmic::OptimizationFlag bits (with
        // X86SIM_A64_LIVE_ONLY for the process: image code was translated with the defaults).
        if (const char *e = getenv("X86SIM_A64_OPT_KEEP"))
            c.optimizations = Dynarmic::OptimizationFlag((u32)c.optimizations & (u32)strtoul(e, nullptr, 16));
        // X86SIM_A64_SAFE=1: also drop FastDispatch (narrows shared races further for experiments).
        if (getenv("X86SIM_A64_SAFE") && atoi(getenv("X86SIM_A64_SAFE")) == 1) {
            c.optimizations &= ~Dynarmic::OptimizationFlag::FastDispatch;
            c.optimizations &= ~Dynarmic::OptimizationFlag::ReturnStackBuffer;
        }
        // X86SIM_A64_FASTDISPATCH=0: drop FastDispatch only (keep other SAFE-independent opts).
        if (getenv("X86SIM_A64_FASTDISPATCH") && atoi(getenv("X86SIM_A64_FASTDISPATCH")) == 0) {
            c.optimizations &= ~Dynarmic::OptimizationFlag::FastDispatch;
        }
        // Speed 20: LDXR/STXR without the process-wide monitor: STXR is a lock cmpxchg against the value its LDXR
        // read, with a reservation private to the thread (QEMU user-mode semantics; only ABA differs from real LL/SC).
        // The global monitor took a spinlock and scanned all 64 slots on every STXR: objc retain/release were ~1/3 of
        // SpringBoard's CPU on a tap. X86SIM_A64_STRICT_MONITOR=1 restores it (a code-shaping flag: key bit 19).
        if (!strict_monitor()) {
            c.unsafe_optimizations = true;
            c.optimizations |= Dynarmic::OptimizationFlag::Unsafe_IgnoreGlobalMonitor;
        }
        c.recompile_on_fastmem_failure = false;
        c.recompile_on_exclusive_fastmem_failure = false;
        // Per process (reserved; only emitted pages are resident). Stage 2's per-thread 8 MB is too small here.
        // Speed 8: 384 MB (was 256): the AOT image with MTLCompilerService and iconservicesagent holds ~230 MB of
        // code, and SpringBoard's own new code no longer fit ("shared code cache full").
        // Speed 12: 768 MB. The image trained on SpringBoard after home, Settings sub-pages, the keyboard and the stock
        // apps holds ~380 MB of code and filled 384 MB (SpringBoard aborted in a loop).
        c.code_cache_size = (size_t)code_cache_mb() << 20;
        if (const u64 b = code_cache_base()) Dynarmic::A64::Jit::SetCodeCacheAddress(b);
        host_call_stubs();
        auto sc = Dynarmic::A64::Jit::MakeSharedCode(c);
        jitcache_set_shared(sc);
        g_shared_code = sc.get();
        jitcache_try_load(*sc);
        return sc;
    }();
    return code;
}

bool memcheck() {
    static const bool v = getenv("X86SIM_A64_MEMCHECK") && atoi(getenv("X86SIM_A64_MEMCHECK")) == 1;
    return v;
}

static std::unique_ptr<Dynarmic::A64::Jit> make_jit(const Dynarmic::A64::UserConfig &cfg) {
    if (shared_translations()) return std::make_unique<Dynarmic::A64::Jit>(cfg, shared_code(cfg));
    return std::make_unique<Dynarmic::A64::Jit>(cfg);
}

GuestThread::GuestThread() {
    // The guest has its own TSD (tpidrro_el0): slots 0-9 (pthread_self, errno, mach thread self, ...) are copied from
    // Darling's native TSD (the gs base on x86_64); keys 10+ are the guest's alone. Sharing the native array let
    // Darling's own libobjc/libdispatch destructors free guest values at thread exit (SIGABRT in every daemon).
    // Guest key destructors run at thread exit (run_guest_tsd_destructors).
    unsigned long gs = 0;
    syscall(SYS_arch_prctl, ARCH_GET_GS, &gs);
    tsd = (u64 *)calloc(kGuestTsdSlots, 8);
    native_tsd = (u64 *)gs;
    if (gs) memcpy(tsd, (void *)gs, 10 * 8);
    {  // Perf 22: guest TSD slot 766 = 1 on the main thread, 2 elsewhere (pthread_main_np's guest code; 0: ask natively)
        static auto *main_np = (void *(*)())dsym("pthread_main_thread_np");
        if (gs && main_np) tsd[766] = tsd[0] == (u64)main_np() ? 1 : 2;
    }
    tpidrro = (u64)tsd;
    Dynarmic::A64::UserConfig &c = cfg;
    c.callbacks = this;
    c.processor_id = g_next_cpu++ % 64;
    c.global_monitor = monitor();
    c.fastmem_pointer = 0;               // identity mapping: guest address == host address
    c.fastmem_address_space_bits = 47;   // x86-64 user space
    c.silently_mirror_fastmem = false;
    c.fastmem_exclusive_access = true;
    // RAM 3: no inline address check: an address above 47 bits (a top-byte tag) is non-canonical and faults into the
    // fastmem handler, which calls the callback (drops the tag). X86SIM_A64_MEMCHECK=1: the old mov/shr 47/jnz +
    // stub per access (code-shaping: key bit 20).
    c.fastmem_unchecked = !memcheck();
    c.enable_cycle_counting = false;
    c.wall_clock_cntpct = true;
    c.cntfrq_el0 = timebase_apple() ? 24000000 : 1000000000;  // ns like Darling's mach time (1/1), or 24 MHz (125/3)
    c.tpidr_el0 = &tpidr;
    c.tpidrro_el0 = &tpidrro;
    // Hybrid svc;ret (frontend): a thunk block ends in FastDispatchHint instead of PopRSBHint. With RSB off
    // (shared translations) PopRSBHint is ReturnFromRunCode, so every libsystem call left Run(). Opt-in for now.
    c.fuse_svc_ret = getenv("X86SIM_A64_FUSE_SVC") && atoi(getenv("X86SIM_A64_FUSE_SVC")) == 1;
    // Speed 17: guarded direct links for import stubs (X86SIM_A64_STUBLINK=0: off)
    c.link_import_stubs = !(getenv("X86SIM_A64_STUBLINK") && atoi(getenv("X86SIM_A64_STUBLINK")) == 0);
    // Perf 9: forward block links skip the halt check (X86SIM_A64_HALT_ALL=1: every link checks; code-shaping, debug only)
    c.halt_check_all_links = getenv("X86SIM_A64_HALT_ALL") && atoi(getenv("X86SIM_A64_HALT_ALL")) == 1;
    // Perf 14: guest registers kept in r12/r13/r14/rbp across blocks (X86SIM_A64_PIN="32,0,8": NZCV, x0, x8; up to 4;
    // "-1": none; code-shaping, so the image builder must use the same)
    {
        const char *pin = getenv("X86SIM_A64_PIN");
        if (!pin) pin = "32,0,8";  // NZCV (32), then the most loaded/stored guest registers in a cold Settings launch
        int i = 0;
        for (const char *q = pin; *q && i < 4;) {
            c.pinned_regs[i++] = (int8_t)atoi(q);
            while (*q && *q != ',') q++;
            if (*q == ',') q++;
        }
    }
    // Perf 8: the stub dylibs' svc thunk blocks are persisted (same code in every process: stub_code_hash)
    if (stub_fixed_address("/usr/lib/system/libsystem_kernel.dylib")) {
        c.persist_svc_lo = kStubBase;
        c.persist_svc_hi = kStubBase + 3 * kStubSlot;
    }
    native_objc_configure_jit(c);
    // Per-thread caches (X86SIM_A64_SHARED=0): a full cache is cleared, which also drops its block metadata (in
    // glibc malloc, ~3x the code). 16 MB bounds a thread at ~60 MB.
    c.code_cache_size = (getenv("X86SIM_A64_CODECACHE_MB") ? atoi(getenv("X86SIM_A64_CODECACHE_MB")) : 16) << 20;
    static const bool rss_debug = getenv("X86SIM_A64_RSS") != nullptr;
    auto rss = [] { long v = 0; if (FILE *f = fopen("/proc/self/statm", "r")) { long a, b, c2; if (fscanf(f, "%ld %ld %ld", &a, &b, &c2) == 3) v = (b - c2) * 4; fclose(f); } return v; };
    long before = rss_debug ? rss() : 0;
    jit = make_jit(c);
    st = jit->GetStatePointers();
    if (rss_debug) { struct mallinfo2 mi = mallinfo2(); logf("new Jit: anon RSS +%ld kB; glibc mmapped %zu MB in %zu blocks, arena %zu MB", rss() - before, mi.hblkhd >> 20, mi.hblks, mi.arena >> 20); }
    g_live_threads++;
    stack_size = 8u << 20;
    stack_base = (u64)mmap(nullptr, stack_size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    if (stack_base == (u64)MAP_FAILED) die("cannot allocate a guest stack");
    susp_thread_init(*this);
}
// After a longjmp out of call() (pthread_exit) the Jit still counts as executing: its state is abandoned (leaked,
// destroying it could assert) and the thread gets a fresh one for whatever guest code still runs on it (TSD
// destructors at thread exit).
void GuestThread::reset_after_unwind() {
    depth = 0; done = nullptr; in_thunk = -1; native = false;
    (void)jit.release();
    jit = make_jit(cfg);
    st = jit->GetStatePointers();
}
GuestThread::~GuestThread() { gbt_forget(this); susp_thread_fini(*this); gsample_forget(this); g_live_threads--; munmap((void *)stack_base, stack_size); free(tsd); }

NRet GuestThread::call(u64 pc, const u64 *ints, int nints, const u64 *fps, int nfps) {
    struct Saved {
        std::array<u64, 31> r; u64 sp, pc; std::array<Dynarmic::A64::Vector, 32> v; u32 pstate, fpcr, fpsr;
    } saved;
    const bool nested = depth > 0;
    if (nested) {
        saved.r = jit->GetRegisters(); saved.sp = jit->GetSP(); saved.pc = jit->GetPC(); saved.v = jit->GetVectors();
        saved.pstate = jit->GetPstate(); saved.fpcr = jit->GetFpcr(); saved.fpsr = jit->GetFpsr();
    }
    for (int i = 0; i < nints && i < 8; i++) jit->SetRegister(i, ints[i]);
    for (int i = 0; i < nfps; i++) jit->SetVector(i, {fps[i], 0});
    jit->SetRegister(30, g_exit_stub);
    jit->SetSP(nested ? ((saved.sp - 128) & ~15ull) : ((stack_base + stack_size - 64) & ~15ull));
    for (int i = 8; i < nints; i++) wr<u64>(jit->GetSP() + 8 * (i - 8), ints[i]);  // 9th+ arguments: stack slots
    jit->SetPC(pc);
    bool finished = false;
    bool *outer_done = done;
    done = &finished;
    depth++;
    const bool outer_native = native;
    native = false;
    // X86SIM_A64_EXEC_LOCK=1: one process-wide mutex around every Run (bisect: cache/linking race vs
    // per-thread state leak). Shared-mode only; huge slowdown, for experiments.
    static std::mutex *exec_lock = []() -> std::mutex * {
        if (!(getenv("X86SIM_A64_EXEC_LOCK") && atoi(getenv("X86SIM_A64_EXEC_LOCK")) == 1)) return nullptr;
        return new std::mutex;
    }();
    if (g_step && depth == 1) while (!finished) jit->Step();
    else while (!finished) {
        if (exec_lock) {
            std::lock_guard<std::mutex> g(*exec_lock);
            jit->Run();
        } else {
            jit->Run();
        }
        if (sig_pending.load(std::memory_order_relaxed)) deliver_signals(*this);
        susp_safe_point();
    }
    native = outer_native;
    depth--;
    done = outer_done;
    NRet r{jit->GetRegister(0), jit->GetRegister(1), jit->GetVector(0)[0], jit->GetVector(1)[0]};
    if (nested) {
        jit->SetRegisters(saved.r); jit->SetSP(saved.sp); jit->SetPC(saved.pc); jit->SetVectors(saved.v);
        jit->SetPstate(saved.pstate); jit->SetFpcr(saved.fpcr); jit->SetFpsr(saved.fpsr);
    }
    return r;
}

bool GuestThread::MemoryWriteExclusive128(u64 a, Dynarmic::A64::Vector v, Dynarmic::A64::Vector e) {
    unsigned __int128 ev = ((unsigned __int128)e[1] << 64) | e[0], nv = ((unsigned __int128)v[1] << 64) | v[0];
    return __atomic_compare_exchange_n((unsigned __int128 *)(a & kTbi), &ev, nv, false, 5, 5);
}

bool g_count_thunks = getenv("X86SIM_A64_STATS") != nullptr;
u64 g_thunk_counts[0x10000];

// X86SIM_A64_PROFILE=1: every 10 s a line in the process log: wall and process CPU time since start, time spent
// translating (shared cache), blocks, guest instructions and x86 bytes emitted, dispatcher lookups, live threads.
static const bool g_profile = getenv("X86SIM_A64_PROFILE") != nullptr;
static void profile_tick() {
    static const u64 start = [] { timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (u64)t.tv_sec * 1000000000ull + t.tv_nsec; }();
    static std::atomic<u64> last{0};
    timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    const u64 now = (u64)t.tv_sec * 1000000000ull + t.tv_nsec;
    u64 prev = last.load();
    if (now - prev < 10000000000ull || !last.compare_exchange_strong(prev, now)) return;
    timespec c; clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &c);
    Dynarmic::A64::Jit::SharedStats st{};
    if (shared_translations()) st = Dynarmic::A64::Jit::GetSharedStats(*shared_code(GuestThread::self().cfg));
    logf("profile: wall %.1fs cpu %.1fs translate %.1fs blocks %llu insns %llu code %.1f MB lookups %llu threads %d"
         " | getblock %llu thunk %llu l0 %llu probe %llu lf %llu",
         (now - start) / 1e9, c.tv_sec + c.tv_nsec / 1e9, st.translate_ns / 1e9, (unsigned long long)st.blocks,
         (unsigned long long)st.guest_instructions, st.code_bytes / 1048576.0, (unsigned long long)st.lookups, g_live_threads.load(),
         (unsigned long long)st.getblock, (unsigned long long)st.thunk, (unsigned long long)st.l0_hits,
         (unsigned long long)st.probe_hits, (unsigned long long)st.lf_hits);
    std::string top;
    for (const auto &[n, pc] : Dynarmic::A64::Jit::TopThunkTargets(12)) {
        char b[48];
        snprintf(b, sizeof b, " %#llx:%llu", (unsigned long long)pc, (unsigned long long)n);
        top += b;
    }
    if (!top.empty()) logf("profile: dispatcher lookups by pc:%s", top.c_str());
    top.clear();
    for (const auto &[n, ra] : Dynarmic::A64::Jit::TopThunkTargets(8, true)) {
        char b[48];
        snprintf(b, sizeof b, " %#llx:%llu", (unsigned long long)ra, (unsigned long long)n);
        top += b;
    }
    if (!top.empty()) logf("profile: dispatcher lookups by emitted call site:%s", top.c_str());
}

// RAM 4 (host.cpp file trim): fn(arg) under the shared emitter lock; false when there is no shared cache (yet).
bool with_shared_code_lock(void (*fn)(void *), void *arg) {
    if (!shared_translations() || !g_shared_code) return false;
    Dynarmic::A64::Jit::WithSharedLock(*g_shared_code, fn, arg);
    return true;
}

// Called from host.cpp memlog_once / SIGUSR1. Safe when this tid has no GuestThread.
void memlog_shared_stats() {
    if (!shared_translations()) return;
    if (!GuestThread::current()) {  // RAM 3: a host thread (SIGUSR1 lands on one mostly): the maps line only
        if (!g_shared_code) return;
        auto st = Dynarmic::A64::Jit::GetSharedStats(*g_shared_code);
        logf("memlog: shared blocks %llu insns %llu code %.1f MB translate %.1fs lookups %llu threads %d",
             (unsigned long long)st.blocks, (unsigned long long)st.guest_instructions, st.code_bytes / 1048576.0,
             st.translate_ns / 1e9, (unsigned long long)st.lookups, g_live_threads.load());
        logf("memlog: maps (MB) %s", Dynarmic::A64::Jit::GetMemoryReport(*g_shared_code).c_str());
        return;
    }
    auto st = Dynarmic::A64::Jit::GetSharedStats(*shared_code(GuestThread::self().cfg));
    logf("memlog: shared blocks %llu insns %llu code %.1f MB translate %.1fs lookups %llu threads %d",
         (unsigned long long)st.blocks, (unsigned long long)st.guest_instructions,
         st.code_bytes / 1048576.0, st.translate_ns / 1e9,
         (unsigned long long)st.lookups, g_live_threads.load());
    logf("memlog: maps (MB) %s", Dynarmic::A64::Jit::GetMemoryReport(*shared_code(GuestThread::self().cfg)).c_str());
    native_objc_stats();
    jitcache_save_if_shared();
}

void GuestThread::CallSVC(uint32_t swi) {
    const u64 pc0 = *st.pc;  // svc+4 (Perf 1e: direct)
    // Perf 17: every special svc is >= kMaxThunks (0xff00); a thunk call skips their ~15 compares
    if (__builtin_expect(swi < 0xff00u, 1)) goto thunk_call;
    if (swi == kExitSvc) { *done = true; jit->HaltExecution(); return; }
    if (swi == kSwiftConfSvc) { swiftconf_step(*this); return; }
    if (swi == kSwiftConfVerifySvc) { swiftconf_verify(*this); return; }
    if (swi == kDyldScanSvcA || swi == kDyldScanSvcB) { dyld_scan_step(*this, swi == kDyldScanSvcB); return; }
    if (swi == kSwiftTypeSvc) { swifttype_step(*this); return; }
    if (swi == kAstcSvc) { astc_step(*this); return; }
    if (swi == kLzfseSvcA || swi == kLzfseSvcB) { lzfse_step(*this, swi == kLzfseSvcB); return; }
    if (swi >= kLzfseSvcDestroy && swi <= kLzfseSvcInit) { lzfse_stream_step(*this, swi); return; }
    if (swi == kBlWatchSvc) {  // X86SIM_A64_BLWATCH: the original b / bl at svc's address, logged and made
        const u64 site = pc0 - 4;
        const u32 insn = rd<u32>(site);
        const bool link = (insn & 0xfc000000u) == 0x94000000u, br = (insn & 0xfc000000u) == 0x14000000u;
        if (!link && !br) die("blwatch: %#lx is not a b/bl (%08x)", (unsigned long)site, insn);
        int64_t off = (int64_t)(insn & 0x3ffffff) << 38 >> 36;
        const u64 target = site + off;
        logf("blwatch %#lx %s %#lx x0 %#lx x1 %#lx x2 %#lx lr %#lx tid %ld", (unsigned long)site, link ? "bl" : "b",
             (unsigned long)target, (unsigned long)x(0), (unsigned long)x(1), (unsigned long)x(2), (unsigned long)x(30),
             (long)syscall(SYS_gettid));
        if (link) set_x(30, site + 4);
        jit->SetPC(target);
        return;
    }
    if (swi == kAgChkSvc) {  // ldr w8, [x28, #4] + the check above
        const u64 node = x(28), base = rd<u64>(kAgTableVar);
        const u32 attr = rd<u32>(x(27) - 8), f_old = rd<u32>(node + 4), f_cur = base ? rd<u32>(base + attr + 4) : 0;
        set_x(8, f_old);
        static std::atomic<u64> n{0}, moved{0}, clear{0};
        const bool mv = base + attr != node, cl = !(f_old & 0x10);
        if (mv) moved++;
        if (cl) clear++;
        // the abort path: bit 4 clear and the value type's size (value witness table +0x40 of [type +8]) non-zero
        const u64 meta = cl ? rd<u64>(x(21) + 8) : 0, vsize = meta ? rd<u64>(rd<u64>(meta - 8) + 0x40) : 0;
        if (cl && vsize) {
            const u64 base_at = node - attr;
            logf("agchk: ABORT PATH attr %#x size %lu: flags via x28 %#x (base then %#lx), via base now %#x (base now %#lx), words then %08x %08x %08x now %08x %08x %08x",
                 attr, (unsigned long)vsize, f_old, (unsigned long)base_at, f_cur, (unsigned long)base, rd<u32>(node), rd<u32>(node + 4), rd<u32>(node + 8),
                 base ? rd<u32>(base + attr) : 0, f_cur, base ? rd<u32>(base + attr + 8) : 0);
        }
        if (mv && n++ < 100)
            logf("agchk: attr %#x node(x28) %#lx flags %#x | base now %#lx node now %#lx flags %#x | %s%s (moved %lu, bit4-clear %lu)", attr,
                 (unsigned long)node, f_old, (unsigned long)base, (unsigned long)(base + attr), f_cur, mv ? "TABLE MOVED " : "",
                 cl ? "BIT4 CLEAR" : "", (unsigned long)moved.load(), (unsigned long)clear.load());
        return;
    }
    if (swi == kAgOutSetSvc || swi == kAgOutGetSvc) {
        static const u64 want = strtoull(getenv("X86SIM_A64_AGOUT"), nullptr, 16);
        auto rdv = [](u64 a, void *buf, size_t n) {
            iovec l{buf, n}, r{(void *)a, n};
            return process_vm_readv(getpid(), &l, 1, &r, 1, 0) == (ssize_t)n;
        };
        u64 key = 0, top = ~0ull, st = 0, w[14] = {};
        rdv(kAgKeyVar, &key, 8);
        if (key < kGuestTsdSlots) st = tsd[key] & ~1ull;
        if (st && rdv(st, w, sizeof w) && w[13] && w[13] < 4096) {
            u64 buf = w[12] ? w[12] : st + 32, fr = 0;
            if (rdv(buf + 8 * (w[13] - 1), &fr, 8)) top = fr;
        }
        u64 ring_i;
        {  // ring of the last 64K events for agout_dump (the failing attribute is not known in advance)
            ring_i = g_agout_n++;
            AgOutEv ev;
            ev.frame = top; ev.value = swi == kAgOutSetSvc ? x(0) : 0; ev.type = x(swi == kAgOutSetSvc ? 1 : 0); ev.lr = x(30);
            ev.tid = (u32)gettid(); ev.set = swi == kAgOutSetSvc;
            g_agout_ring[ring_i & (kAgOutRing - 1)] = ev;
        }
        static std::atomic<int> n{0};
        if (want != 1 && ((u32)top == (u32)want || (!want && n < 2000)) && n++ < 20000) {
            if (swi == kAgOutSetSvc) logf("agout: set attr %#x flags %#x value %#lx type %#lx lr %#lx", (unsigned)top, (unsigned)(top >> 32),
                                          (unsigned long)x(0), (unsigned long)x(1), (unsigned long)x(30));
            else logf("agout: get attr %#x flags %#x type %#lx lr %#lx", (unsigned)top, (unsigned)(top >> 32), (unsigned long)x(0), (unsigned long)x(30));
        }
        // Speed 32: for the wanted attribute, also look at its node right after AGGraphSetOutputValue returns (return
        // thunk: the original LR is kept per thread). Node = [AG table base 0x22e74c908] + attribute id (as the set path
        // computes it); +4 is the flags word the set tests (0xc0), +8 the value's table offset.
        if (swi == kAgOutSetSvc && top != ~0ull && (want == 1 || (u32)top == (u32)want)) agout_arm_return(*this, (u32)top, ring_i);
        if (swi == kAgOutSetSvc) jit->SetSP(sp() - 128);  // sub sp, sp, #128
        else {                                              // stp x20, x19, [sp, #-32]!
            const u64 nsp = sp() - 32;
            *(u64 *)nsp = x(20); *(u64 *)(nsp + 8) = x(19);
            jit->SetSP(nsp);
        }
        return;
    }
    if (swi == kAgDlCancelSvc) {  // stp x29, x30, [sp, #-16]!
        const u64 nsp = sp() - 16;
        *(u64 *)nsp = x(29); *(u64 *)(nsp + 8) = x(30);
        jit->SetSP(nsp);
        static std::atomic<int> n{0};
        if (n++ < 200) {
            u64 fp = x(29), lrs[6] = {};
            for (int k = 0; k < 6 && fp > 0x1000 && fp < 0x800000000000ull; k++) { lrs[k] = *(u64 *)(fp + 8); fp = *(u64 *)fp; }
            logf("agdl: %s from lr %#lx; callers %#lx %#lx %#lx %#lx %#lx %#lx", pc0 - 4 == 0x1c950c654 ? "UpdateStack::cancel" : "AGGraphCancelUpdate",
                 (unsigned long)x(30), (unsigned long)lrs[0], (unsigned long)lrs[1], (unsigned long)lrs[2], (unsigned long)lrs[3],
                 (unsigned long)lrs[4], (unsigned long)lrs[5]);
        }
        return;
    }
    if (swi == kAgDlSetSvc || swi == kAgDlPassedSvc) {
        const u64 now = GetCNTPCT();  // mach ticks (24 MHz with the Apple timebase)
        const double tick_ms = timebase_apple() ? 1.0 / 24000.0 : 1e-6;
        if (swi == kAgDlSetSvc) {
            const u64 d = x(1), old = rd<u64>(x(0) + 56);
            set_x(8, old);  // ldr x8, [x0, #56]
            static std::atomic<int> n{0};
            if (d != old && n++ < 400) {
                if (d == ~0ull) logf("agdl: set_deadline none (ctx %#lx)", (unsigned long)x(0));
                else logf("agdl: set_deadline in %.2f ms (ctx %#lx lr %#lx)", ((double)d - (double)now) * tick_ms,
                          (unsigned long)x(0), (unsigned long)x(30));
            }
        } else {
            const u64 d = rd<u64>(x(19) + 392);
            set_x(0, 1);  // mov w0, #1
            static std::atomic<int> n{0};
            if (n++ < 400) logf("agdl: deadline passed by %.2f ms (graph %#lx)", ((double)now - (double)d) * tick_ms, (unsigned long)x(19));
        }
        return;
    }
    if (swi == kLinuxSvc) {  // our in-simulator code's escape to a Linux syscall (x8 = x86_64 number, x0-x5 args)
        set_x(0, (u64)syscall((long)x(8), x(0), x(1), x(2), x(3), x(4), x(5)));
    } else {
    thunk_call:
        svc_count++;
        if (g_profile && (svc_count & 1023) == 0) profile_tick();
        if (swi >= thunk_count()) die("svc #%u at %#lx: no such thunk", swi, (unsigned long)jit->GetPC() - 4);
        if (g_count_thunks) __atomic_fetch_add(&g_thunk_counts[swi], 1, __ATOMIC_RELAXED);
        if (g_trace) {
            const std::string &nm = g_thunks[swi].name;
            bool path = nm.find("open") != std::string::npos || nm.find("stat") != std::string::npos ||
                        nm.find("access") != std::string::npos || nm.find("getattr") != std::string::npos ||
                        nm.find("readlink") != std::string::npos || nm.find("realpath") != std::string::npos;
            // a user-space pointer, not a small int or AT_FDCWD (-2: 0xfffffffe) taken for a string
            auto uptr = [](u64 v) { return v > 0x10000 && v < 0x800000000000ull && v != 0xfffffffeull; };
            if (path && (nm.find("at") != std::string::npos && nm.find("stat") == std::string::npos ? true : false) && uptr(x(1)))
                logf("-> %s(%#lx, \"%.200s\", %#lx)", nm.c_str(), (unsigned long)x(0), (const char *)x(1), (unsigned long)x(2));
            else if (path && nm.find("at") != std::string::npos && nm.find("stat") == std::string::npos)
                logf("-> %s(%#lx, %#lx, %#lx)", nm.c_str(), (unsigned long)x(0), (unsigned long)x(1), (unsigned long)x(2));
            else if (path && uptr(x(0))) logf("-> %s(\"%.200s\", %#lx, %#lx)", nm.c_str(), (const char *)x(0), (unsigned long)x(1), (unsigned long)x(2));
            else logf("-> %s(%#lx, %#lx, %#lx)", nm.c_str(), (unsigned long)x(0), (unsigned long)x(1), (unsigned long)x(2));
        }
        // X86SIM_A64_SVC_TIME=1: accumulate rdtsc around the handler body (excludes dispatcher).
        static const bool svc_time = getenv("X86SIM_A64_SVC_TIME") != nullptr;
        static std::atomic<u64> svc_cycles{0}, svc_timed{0};
        u64 t0 = 0;
        if (svc_time) t0 = __builtin_ia32_rdtsc();
        // Speed 30 debug: X86SIM_A64_THUNK_HIST=sub1,sub2: calls of thunks whose name contains one of the substrings,
        // by (name, lr, caller's lr, x0 low bits for timer arms), the top 20 every 4096 calls
        static const char *th = getenv("X86SIM_A64_THUNK_HIST");
        if (th) {
            const std::string &nm = g_thunks[swi].name;
            bool hit = false;
            for (std::string l = std::string(th) + ","; !l.empty() && !hit;) {
                const std::string sub = l.substr(0, l.find(','));
                l = l.substr(l.find(',') + 1);
                hit = !sub.empty() && nm.find(sub) != std::string::npos;
            }
            if (hit) {
                static std::mutex hm;
                static std::unordered_map<std::string, u64> hist;
                static u64 total = 0;
                const u64 fp = x(29);
                const u64 lr2 = fp > 0x10000 && fp < 0x800000000000ull ? rd<u64>(fp + 8) : 0;
                char key[160];
                snprintf(key, sizeof key, "%s lr=%#lx lr2=%#lx", nm.c_str(), (unsigned long)x(30), (unsigned long)lr2);
                std::lock_guard<std::mutex> g(hm);
                hist[key]++;
                if ((++total & 4095) == 0) {
                    std::vector<std::pair<u64, std::string>> v;
                    for (auto &e : hist) v.push_back({e.second, e.first});
                    std::sort(v.rbegin(), v.rend());
                    timespec tn; clock_gettime(CLOCK_MONOTONIC, &tn);
                    logf("thunkhist t=%lld total=%llu", (long long)tn.tv_sec, (unsigned long long)total);
                    for (size_t k = 0; k < v.size() && k < 20; k++) logf("thunkhist %llu %s", (unsigned long long)v[k].first, v[k].second.c_str());
                    hist.clear();
                }
            }
        }
        susp_safe_point();  // registers are in the Jit at an svc
        if (gbt_on()) gbt_svc_hook();
        int32_t outer_thunk = in_thunk; in_thunk = (int32_t)swi;
        native = true;
        tsd_to_native();
        // Speed 29: X86SIM_A64_MSG_STATS=1: mach_msg* thunk calls and wall time inside them (blocking receives
        // included), logged cumulatively every 512 calls with a CLOCK_MONOTONIC stamp (diff lines around a tap)
        static const bool msg_stats = getenv("X86SIM_A64_MSG_STATS") != nullptr;
        const bool is_msg = msg_stats && g_thunks[swi].name.find("mach_msg") != std::string::npos;
        timespec m0{};
        u64 mh = 0, mopt = 0, mlr = 0; u32 msid = ~0u;
        if (is_msg) {
            clock_gettime(CLOCK_MONOTONIC, &m0);
            const std::string &nm = g_thunks[swi].name;
            if ((nm == "_mach_msg" || nm == "_mach_msg_overwrite") && x(0) > 0x10000) { mh = x(0); mopt = x(1); }
            mlr = x(30);
            if (mh && (mopt & 1)) msid = rd<u32>(mh + 20);
        }
        g_thunks[swi].fn(*this, swi);
        if (is_msg) {
            static std::atomic<u64> n_msg{0}, ns_msg{0};
            timespec m1;
            clock_gettime(CLOCK_MONOTONIC, &m1);
            const u64 dt = (u64)((m1.tv_sec - m0.tv_sec) * 1000000000ll + (m1.tv_nsec - m0.tv_nsec));
            const u64 n = n_msg.fetch_add(1) + 1, ns = ns_msg.fetch_add(dt) + dt;
            // Speed 30: histogram of (sent msgh_id, received msgh_id, guest caller), top entries every 8192 calls
            {
                u32 rid = ~0u;
                if (mh && (mopt & 2) && (u32)x(0) == 0) rid = rd<u32>(mh + 20);
                static std::mutex hm;
                static std::unordered_map<std::string, u64> hist;
                char key[96];
                snprintf(key, sizeof key, "send=%d recv=%d lr=%#lx thr=%s", (int)msid, (int)rid, (unsigned long)mlr,
                         (mopt & 2) && (u32)x(0) == 0x10004003 ? "timeout" : "");
                std::lock_guard<std::mutex> g(hm);
                hist[key]++;
                if ((n & 8191) == 0) {
                    std::vector<std::pair<u64, std::string>> v;
                    for (auto &e : hist) v.push_back({e.second, e.first});
                    std::sort(v.rbegin(), v.rend());
                    for (size_t k = 0; k < v.size() && k < 15; k++) logf("msghist %llu %s", (unsigned long long)v[k].first, v[k].second.c_str());
                    hist.clear();
                }
            }
            if ((n & 511) == 0)
                logf("msgstats t=%lld.%03lld n=%llu inside_ms=%llu", (long long)m1.tv_sec, (long long)m1.tv_nsec / 1000000,
                     (unsigned long long)n, (unsigned long long)(ns / 1000000));
        }
        native = false;
        tsd_from_native();
        in_thunk = outer_thunk;
        susp_safe_point();
        if (svc_time) {
            u64 dt = __builtin_ia32_rdtsc() - t0;
            u64 n = svc_timed.fetch_add(1, std::memory_order_relaxed) + 1;
            u64 sum = svc_cycles.fetch_add(dt, std::memory_order_relaxed) + dt;
            if ((n & 0xfffff) == 0)
                logf("svc timing: %llu calls, avg %.1f cycles (handler+tsd only)",
                     (unsigned long long)n, (double)sum / (double)n);
        }
        if (g_trace) logf("<- %s = %#lx", g_thunks[swi].name.c_str(), (unsigned long)x(0));
    }

    // X86SIM_A64_SKIP_RET=1: when the handler did not redirect and the thunk is "svc; ret", return to X30 here
    // and skip the ret block. Outermost CallSVC only (a nested one runs inside call(), which restores the PC).
    // Reads X30 after the handler. Off by default.
    static const bool skip_ret = getenv("X86SIM_A64_SKIP_RET") && atoi(getenv("X86SIM_A64_SKIP_RET")) == 1;
    if (skip_ret && in_thunk < 0 && jit->GetPC() == pc0 && rd<u32>(pc0) == 0xD65F03C0u) jit->SetPC(x(30));
}

bool fp16_interpret(GuestThread &t, u32 insn);
void GuestThread::InterpreterFallback(u64 pc, size_t n) {
    // FEAT_FP16 SIMD (fp16.cpp): execute and continue after it
    u64 at = pc;
    for (size_t k = 0; k < n && fp16_interpret(*this, rd<uint32_t>(at)); k++) at += 4;
    if (at != pc) { jit->SetPC(at); return; }
    logf("unimplemented instruction %08x at %#lx lr %#lx sp %#lx x0 %#lx x16 %#lx x17 %#lx", rd<uint32_t>(pc), (unsigned long)pc,
         (unsigned long)x(30), (unsigned long)sp(), (unsigned long)x(0), (unsigned long)x(16), (unsigned long)x(17));
    if (FILE *m = fopen("/proc/self/maps", "r")) {
        char line[512];
        while (fgets(line, sizeof line, m)) {
            unsigned long lo, hi;
            if (sscanf(line, "%lx-%lx", &lo, &hi) == 2 && pc >= lo && pc < hi) logf("  in %s", line);
        }
        fclose(m);
    }
    abort();
}

// "file+offset" of a guest address outside the shared cache (from /proc/self/maps), for crash reports.
static std::mutex g_stub_syms_mu;
static std::map<std::string, std::vector<std::pair<u64, std::string>>> g_stub_syms;  // file name -> sorted (offset, export)
void register_stub_symbols(const std::string &file, std::vector<std::pair<u64, std::string>> fn) {
    std::sort(fn.begin(), fn.end());
    std::lock_guard<std::mutex> l(g_stub_syms_mu);
    g_stub_syms[file] = std::move(fn);
}
static std::string stub_symbol(const char *path, u64 off) {  // "/memfd:libsystem_kernel.dylib (deleted)"
    if (strncmp(path, "/memfd:", 7) != 0) return "";
    std::string file(path + 7);
    if (auto sp = file.find(" (deleted)"); sp != std::string::npos) file.resize(sp);
    std::lock_guard<std::mutex> l(g_stub_syms_mu);
    auto it = g_stub_syms.find(file);
    if (it == g_stub_syms.end()) return "";
    auto &v = it->second;
    auto u = std::upper_bound(v.begin(), v.end(), std::make_pair(off, std::string("\xff")));
    if (u == v.begin()) return "";
    --u;
    char b[300]; snprintf(b, sizeof b, " (%s+%#lx)", u->second.c_str(), (unsigned long)(off - u->first));
    return b;
}
std::string where(u64 a) {
    if (a >= 0x1c0000000ull && a < 0x300000000ull) return "cache";
    std::string r;
    if (FILE *m = fopen("/proc/self/maps", "r")) {
        char line[768];
        while (fgets(line, sizeof line, m)) {
            unsigned long lo, hi, off; char path[600] = "";
            if (sscanf(line, "%lx-%lx %*s %lx %*s %*s %599[^\n]", &lo, &hi, &off, path) >= 3 && a >= lo && a < hi) {
                char b[700]; snprintf(b, sizeof b, "%s+%#lx", path[0] ? path : "anon", a - lo + off); r = b;
                r += stub_symbol(path, a - lo + off);
                break;
            }
        }
        fclose(m);
    }
    return r;
}

void guest_backtrace(GuestThread &t) {
    u64 fp = t.x(29);
    logf("  lr %#lx %s", (unsigned long)t.x(30), where(t.x(30)).c_str());
    for (int k = 0; k < 24 && fp > 0x10000 && !(fp & 7); k++) {
        u64 ret = GuestThread::rd<u64>(fp + 8);
        logf("  #%d %#lx %s", k, (unsigned long)ret, where(ret).c_str());
        u64 next = GuestThread::rd<u64>(fp);
        if (next <= fp) break;
        fp = next;
    }
}

void GuestThread::InstructionCacheOperationRaised(Dynarmic::A64::InstructionCacheOperation op, u64 value) {
    // Guest IC IVAU / IALLU after writing instructions (dyld, objc, fishhook). Default dynarmic callback is a
    // no-op; per-thread 8 MB caches masked that by evacuating on full, but the shared cache never frees.
    using Op = Dynarmic::A64::InstructionCacheOperation;
    if (!jit) return;
    static const bool iclog = getenv("X86SIM_A64_ICLOG") != nullptr;
    static const bool ivau_clear = getenv("X86SIM_A64_IVAU_CLEAR") && atoi(getenv("X86SIM_A64_IVAU_CLEAR")) == 1;
    if (iclog) {
        const char *name = "?";
        switch (op) {
        case Op::InvalidateByVAToPoU: name = "IVAU"; break;
        case Op::InvalidateAllToPoU: name = "IALLU"; break;
        case Op::InvalidateAllToPoUInnerSharable: name = "IALLUIS"; break;
        }
        logf("IC %s value=%#lx", name, (unsigned long)value);
    }
    switch (op) {
    case Op::InvalidateByVAToPoU:
        // X86SIM_A64_IVAU_CLEAR=1: treat every line invalidate as a full ClearCache (bisect SMC races).
        if (ivau_clear) {
            jit->ClearCache();
        } else {
            // One cache line; invalidate a 64-byte window covering the VA.
            jit->InvalidateCacheRange(value & ~u64(63), 64);
        }
        break;
    case Op::InvalidateAllToPoU:
    case Op::InvalidateAllToPoUInnerSharable:
        jit->ClearCache();
        break;
    }
}

void GuestThread::ExceptionRaised(u64 pc, Dynarmic::A64::Exception e) {
    using E = Dynarmic::A64::Exception;
    // hints (spin loops: YIELD, WFE in os_unfair_lock/dispatch): continue at the next instruction
    if (e == E::Yield || e == E::WaitForEvent || e == E::WaitForInterrupt) { sched_yield(); return; }
    if (e == E::SendEvent || e == E::SendEventLocal) return;
    uint32_t insn = rd<uint32_t>(pc);
    // FEAT_FP16 scalar GPR<->half (SCVTF/UCVTF h,w): dynarmic raises UnallocatedEncoding; interpret and continue.
    if (e == E::UnallocatedEncoding && fp16_interpret(*this, insn)) {
        jit->SetPC(pc + 4);
        return;
    }
    // brk #0xf... (Swift/clang traps), udf: report like a crash with the guest registers.
    logf("guest exception %d at pc %#lx %s (insn %08x) lr %#lx sp %#lx", (int)e, (unsigned long)pc, where(pc).c_str(), insn,
         (unsigned long)x(30), (unsigned long)sp());
    for (int i = 0; i < 31; i += 4)
        logf("  x%-2d %016lx x%-2d %016lx x%-2d %016lx x%-2d %016lx", i, (unsigned long)x(i), i + 1,
             (unsigned long)(i + 1 < 31 ? x(i + 1) : 0), i + 2, (unsigned long)(i + 2 < 31 ? x(i + 2) : 0), i + 3,
             (unsigned long)(i + 3 < 31 ? x(i + 3) : 0));
    guest_backtrace(*this);
    abort();
}

u64 GuestThread::GetCNTPCT() {
    timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    const u64 ns = ts.tv_sec * 1000000000ull + ts.tv_nsec;
    return timebase_apple() ? tb_ns_to_ticks(ns) : ns;
}

bool g_trace;
void die(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    fputs("arm64host: ", stderr); vfprintf(stderr, fmt, ap); fputc('\n', stderr);
    va_end(ap);
    abort();
}
thread_local bool g_non_darling_thread = false;
void logf(const char *fmt, ...) {
    char buf[1024];
    va_list ap; va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof buf - 1, fmt, ap);
    va_end(ap);
    if (n < 0) return;
    if (n > (int)sizeof buf - 2) n = sizeof buf - 2;
    buf[n++] = '\n';
    if (write(2, "arm64host: ", 11) < 0 || write(2, buf, n) < 0) {}
    // X86SIM_A64_LOG=<Darwin dir>: also append to <dir>/<exe>.<pid>.log (simulator jobs' stderr is often gone)
    // (opened for every line: daemons close all fds at start, a kept fd would end up in another file)
    // a char array, not std::string: lines logged during exit (after static destructors) went to a file named by
    // the freed string's bytes in the cwd
    static char path[512];
    static bool init;
    if (!init) {
        init = true;
        if (const char *dir = getenv("X86SIM_A64_LOG")) {
            static auto *dmkdir = (int (*)(const char *, int))dsym("mkdir");
            const char *exe = getenv("X86SIM_A64_EXE");
            const char *b = exe ? strrchr(exe, '/') : nullptr;
            if (dmkdir) dmkdir(dir, 0777);
            snprintf(path, sizeof path, "%s/%s.%d.log", dir, b ? b + 1 : "guest", (int)getpid());
        }
    }
    if (path[0] && !g_non_darling_thread) {  // Darling's open/write abort on a thread Darling does not know
        static auto *dopen = (int (*)(const char *, int, ...))dsym("open");
        static auto *dwrite = (long (*)(int, const void *, size_t))dsym("write");
        static auto *dclose = (int (*)(int))dsym("close");
        int fd = dopen ? dopen(path, 0x1000209 /* O_WRONLY|O_APPEND|O_CREAT|O_CLOEXEC */, 0644) : -1;
        if (fd >= 0) { dwrite(fd, buf, n); dclose(fd); }
    }
}

// Native -> guest entry (from a64_tramp_entry). Frame: ints[8], fps[8], result[4].
extern "C" void a64_enter_guest(u64 pc, u64 *frame) {
    GuestThread &t = GuestThread::self();
    t.tsd_from_native();
    NRet r = t.call(pc, frame, 8, frame + 8, 8);
    t.tsd_to_native();
    frame[16] = r.rax; frame[17] = r.rdx; frame[18] = r.xmm0; frame[19] = r.xmm1;
}

}  // namespace a64

namespace a64 {
// Speed 31 debug (X86SIM_A64_AGOUT): the recorded output-value gets/sets of one attribute (abort dump, handlers.cpp)
void agout_dump(u32 attr) {
    const u64 n = g_agout_n.load(), lo = n > kAgOutRing ? n - kAgOutRing : 0;
    int shown = 0;
    for (u64 i = lo; i < n; i++) {
        const AgOutEv &e = g_agout_ring[i & (kAgOutRing - 1)];
        if ((u32)e.frame != attr) continue;
        if (shown++ < 200)
        {
            logf("agout dump #%llu: %s attr %#x flags %#x value %#lx type %#lx lr %#lx tid %u", (unsigned long long)(i - lo), e.set ? "set" : "get",
                 (unsigned)e.frame, (unsigned)(e.frame >> 32), (unsigned long)e.value, (unsigned long)e.type, (unsigned long)e.lr, e.tid);
            if (e.ret)  // Speed 32: the node right after the set returned
                logf("agout dump #%llu:   returned %u; node info %08x, flags word +4 %#x -> %#x, value offset +8 %#x -> %#x, value[0] %016lx",
                     (unsigned long long)(i - lo), e.result, e.f0, e.f1, e.f1a, e.v0, e.v0a, (unsigned long)e.val);
            else if (e.set) logf("agout dump #%llu:   (the set has not returned)", (unsigned long long)(i - lo));
        }
    }
    logf("agout dump: %d events for attr %#x in the last %llu", shown, attr, (unsigned long long)(n - lo));
    // Speed 33: the same node now (at the abort), next to the after-set state above: flags word +4, value offset +8,
    // the value's first words, and the table base (a remap moves base: then the node read here is the new copy)
    u32 w[8];
    agout_node(attr, w);
    const u64 base = GuestThread::rd<u64>(kAgTableVar);
    u64 v0 = 0, v1 = 0;
    if (base && w[2]) { v0 = GuestThread::rd<u64>(base + w[2]); v1 = GuestThread::rd<u64>(base + w[2] + 8); }
    logf("agout dump: node at abort: %08x %08x %08x %08x %08x %08x %08x %08x (flags word +4 %#x, value offset +8 %#x), value %016lx %016lx, table %#lx",
         w[0], w[1], w[2], w[3], w[4], w[5], w[6], w[7], w[1], w[2], (unsigned long)v0, (unsigned long)v1, (unsigned long)base);
}
}  // namespace a64
