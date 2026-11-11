#!/usr/bin/env python3
"""x86Sim: short performance measurements on a running boot (seconds each, normal load).

  tests/perf.py idle [secs]               CPU per process at idle (default 10 s)
  tests/perf.py scroll [secs]             drags up/down on the current screen (a list: open Settings first):
                                          frame-time percentiles, fps, input->frame latency, CPU per process
  tests/perf.py launch BUNDLE [...]       app launch time: openurl/app -> first frame -> screen settled (cold: the
                                          app was not running; terminates it afterwards)
  tests/perf.py all                       idle, Settings launch + scroll, Safari/Maps/News launches

Frame times come from simfb's ring (each slot's publish time, CLOCK_REALTIME), latency is measured from the moment a
touch-moved line is written to simhid's socket to the publish time of the first frame after it (the viewer's own
presentation is not included). CPU: utime+stime from /proc for Darling processes (grouped by program), darlingserver,
mtlvk, the viewer and the stream."""
import os, struct, subprocess, sys, time
L = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "cli", "libexec")
sys.path.insert(0, L)
import fbring  # noqa: E402
import simtouch  # noqa: E402

HZ = os.sysconf("SC_CLK_TCK")
MONO_OFF = time.time_ns() - time.monotonic_ns()
X86SIM = os.path.join(os.path.dirname(L), "x86sim")


def procs():
    """pid -> group name for the processes we account."""
    out = {}
    for p in os.listdir("/proc"):
        if not p.isdigit():
            continue
        try:
            with open("/proc/%s/cmdline" % p, "rb") as f:
                a = f.read().split(b"\0")
            with open("/proc/%s/comm" % p) as f:
                comm = f.read().strip()
        except OSError:
            continue
        a0 = a[0].decode(errors="replace") if a else ""
        if comm == "darlingserver" or "darlingserver" in a0:
            out[int(p)] = "darlingserver"
        elif comm == "mtlvk":
            out[int(p)] = "mtlvk"
        elif b"simview.py" in b" ".join(a):
            out[int(p)] = "simview"
        elif b"simstream.py" in b" ".join(a):
            out[int(p)] = "simstream"
        elif comm == "ffmpeg" and any(b"simfb" in x or b"rawvideo" in x for x in a):
            out[int(p)] = "ffmpeg(stream)"
        elif any(k in b" ".join(a) for k in (b"progress_site.py", b"progress_tunnel.sh", b"mdnsresponder.py",
                                             b"simaudio.py", b"http.server")):
            j = b" ".join(a)
            out[int(p)] = next(k for k in ("progress_site.py", "progress_tunnel.sh", "mdnsresponder.py",
                                                     "simaudio.py", "http.server") if k.encode() in j)
        elif comm == "cloudflared" and b"8765" in b" ".join(a):
            out[int(p)] = "cloudflared(site)"
        elif "/Volumes/SystemRoot" in a0 or "RuntimeRoot" in a0 or comm == "mldr" or a0.startswith("/usr/libexec/darling"):
            name = os.path.basename(a0) or comm
            out[int(p)] = name
    return out


def cpu(pids):
    t = {}
    for p in pids:
        try:
            with open("/proc/%d/stat" % p) as f:
                s = f.read()
            fields = s[s.rindex(")") + 2:].split()
            t[p] = int(fields[11]) + int(fields[12])
        except (OSError, ValueError):
            pass
    return t


def ctxsw(pids):
    """pid -> ({tid: context switches}, RSS kB). Per thread, so threads that exit or start mid-sample do not
    subtract from (or inflate) the total: wakeups() counts only deltas of threads seen at both ends, plus new ones."""
    r = {}
    for p in pids:
        th = {}
        try:
            for t in os.listdir("/proc/%d/task" % p):
                n = 0
                try:
                    with open("/proc/%d/task/%s/status" % (p, t)) as f:
                        for line in f:
                            if line.startswith(("voluntary_ctxt_switches", "nonvoluntary_ctxt_switches")):
                                n += int(line.split()[1])
                except OSError:
                    continue
                th[t] = n
            with open("/proc/%d/status" % p) as f:
                rss = next((int(l.split()[1]) for l in f if l.startswith("VmRSS")), 0)
            r[p] = (th, rss)
        except (OSError, ValueError):
            pass
    return r


def ctx_delta(a, b):
    return sum(max(0, n - a.get(t, 0)) for t, n in b.items())


class CPU:
    def __enter__(self):
        self.names = procs()
        self.t0 = cpu(self.names)
        self.c0 = ctxsw(self.names)
        self.w0 = time.monotonic()
        return self

    def __exit__(self, *a):
        self.t1 = cpu(self.names)
        self.c1 = ctxsw(self.names)
        self.wall = time.monotonic() - self.w0

    def wakeups(self, top=40):
        """Per group: CPU %, wakeups (context switches) per second, RSS MB, process count; sorted by CPU."""
        g = {}
        for p, v in self.t1.items():
            if p not in self.t0 or p not in self.c0 or p not in self.c1:
                continue
            e = g.setdefault(self.names[p], [0, 0, 0, 0])
            e[0] += v - self.t0[p]
            e[1] += ctx_delta(self.c0[p][0], self.c1[p][0])
            e[2] += self.c1[p][1]
            e[3] += 1
        tot = [sum(e[i] for e in g.values()) for i in range(4)]
        lines = ["    %-34s %6s %9s %8s %3s" % ("process", "CPU%", "wakeups/s", "RSS MB", "n")]
        for k, e in sorted(g.items(), key=lambda kv: (-kv[1][0], -kv[1][1]))[:top]:
            lines.append("    %-34s %6.1f %9.0f %8.0f %3d" % (k[:34], 100.0 * e[0] / HZ / self.wall, e[1] / self.wall, e[2] / 1024, e[3]))
        lines.append("    %-34s %6.1f %9.0f %8.0f %3d" % ("TOTAL", 100.0 * tot[0] / HZ / self.wall, tot[1] / self.wall, tot[2] / 1024, tot[3]))
        return "\n".join(lines)

    def report(self, top=12):
        g = {}
        for p, v in self.t1.items():
            if p in self.t0:
                g[self.names[p]] = g.get(self.names[p], 0) + (v - self.t0[p])
        tot = sum(g.values())
        rows = sorted(g.items(), key=lambda kv: -kv[1])[:top]
        s = "    CPU over %.1f s: total %.0f%% of one core;" % (self.wall, 100.0 * tot / HZ / self.wall)
        return s + " " + ", ".join("%s %.0f%%" % (k, 100.0 * v / HZ / self.wall) for k, v in rows if v)


class Frames:
    """Publish times of every frame (seq -> time_ns), polled from the ring's slots."""
    def __init__(self):
        self.r = fbring.Ring()
        self.t = {}
        self.age = {}   # seq -> submit -> publish (ms), simfb's slot age_us (0 from an older simfb)

    def poll(self):
        mm = self.r.mm if self.r._open() else None
        if mm is None:
            return
        n = struct.unpack_from("<I", mm, 8)[0]
        for i in range(n):
            seq, t, age = struct.unpack_from("<QQ12xI", mm, 64 + 32 * i)
            if seq and seq not in self.t:
                self.t[seq] = t
                self.age[seq] = age / 1000

    def seq(self):
        return self.r.seq()

    def run(self, secs, step=0.001):
        end = time.monotonic() + secs
        while time.monotonic() < end:
            self.poll()
            time.sleep(step)


def pct(v, p):
    v = sorted(v)
    return v[min(len(v) - 1, int(len(v) * p))] if v else 0


def frame_stats(times_ns, label):
    t = sorted(times_ns)
    if len(t) < 3:
        return "    %s: %d frames" % (label, len(t))
    d = [(b - a) / 1e6 for a, b in zip(t, t[1:])]
    # frame times during motion only: gaps over 100 ms are pauses between gestures
    m = [x for x in d if x < 100]
    span = sum(m) / 1000 or 1
    hitches = sum(1 for x in m if x > 25)
    return "    %s: %d frames, %.1f fps while moving; frame time ms p50 %.1f p95 %.1f p99 %.1f max %.1f; >25 ms: %d" % (
        label, len(t), len(m) / span, pct(m, .5), pct(m, .95), pct(m, .99), max(m) if m else 0, hitches)


def hitch_report(f, gestures, limit=25):
    """Each frame interval > limit ms while moving: when it fell (ms after touch-down or touch-up) and whether CA
    submitted late (the late frame's submit -> publish age is small) or the frame was held after submit (GPU, pacing)."""
    items = sorted(f.t.items(), key=lambda kv: kv[1])
    out = []
    for (q0, a), (q1, b) in zip(items, items[1:]):
        d = (b - a) / 1e6
        if not limit < d < 100:
            continue
        age = f.age.get(q1, 0)
        phase = ""
        for down, up in gestures:
            if down <= b and (up is None or b <= up):
                phase = "drag+%.0f" % ((b - down) / 1e6)
            elif up is not None and up < b < up + 1.2e9:
                phase = "fling+%.0f" % ((b - up) / 1e6)
        out.append("%.0f ms (%s, %s, age %.1f%s)" % (d, phase or "?", "CA late" if age < d - 16.7 else "held", age,
                                                  # PERF_MONO=1: the gap's start in CLOCK_MONOTONIC ns (bpftrace's nsecs)
                                                  ", mono %d" % (a - MONO_OFF) if os.environ.get("PERF_MONO") else ""))
    return "    >%d ms intervals: %s" % (limit, "; ".join(out) if out else "none")


def motion_hitches(f, gestures, limit=25, settle_ms=600):
    """Slow intervals while the content is in motion: from the first frame after touch-down + 50 ms to touch-up +
    settle_ms. Outside that window CA/UIKit lower the rate on purpose (FINDINGS 3.20: the end of a fling, scroll
    indicator fades and Liquid Glass luma updates run at ~15-30 Hz; a touch-down interrupts the settle)."""
    t = sorted(f.t.values())
    n = slow = 0
    for a, b in zip(t, t[1:]):
        if any(down + 50e6 <= a and b <= (up or b) + settle_ms * 1e6 for down, up in gestures):
            n += 1
            slow += (b - a) / 1e6 > limit
    return n, slow


def idle(secs=10):
    f = Frames()
    with CPU() as c:
        f.run(secs, 0.01)
    print("idle %.0f s: %d frames published" % (secs, len(f.t)))
    print(c.wakeups(int(os.environ.get("PERF_TOP", "25"))))


def scroll(secs=8):
    s = simtouch.connect()
    f = Frames()
    lat = []
    gestures = []
    end = time.monotonic() + secs
    with CPU() as c:
        k = 0
        while time.monotonic() < end:
            up = k % 2 == 0
            y0, y1 = (1900, 700) if up else (700, 1900)
            x = 590
            gestures.append([time.time_ns(), None])
            simtouch.touch(s, "down", x, y0)
            f.run(0.03)
            steps = 20
            sent = []
            base = f.seq()
            for i in range(1, steps + 1):
                y = y0 + (y1 - y0) * i / steps
                tw = time.time_ns()
                simtouch.touch(s, "move", x, y)
                sent.append(tw)
                f.run(0.008)
            simtouch.touch(s, "up", x, y1)
            gestures[-1][1] = time.time_ns()
            f.run(float(os.environ.get("PERF_PAUSE", "0.9")))   # PERF_PAUSE=2: each fling ends before the next drag
            # latency: first frame published after the first move
            newer = sorted(t for q, t in f.t.items() if q > base)
            if newer and sent:
                first = next((t for t in newer if t >= sent[0]), None)
                if first:
                    lat.append((first - sent[0]) / 1e6)
            k += 1
    s.close()
    print("scroll %.0f s, %d gestures:" % (secs, k))
    print(frame_stats(f.t.values(), "frames"))
    print(hitch_report(f, gestures))
    n, slow = motion_hitches(f, gestures)
    print("    in motion (touch-down+50 ms .. touch-up+600 ms): %d intervals, >25 ms: %d" % (n, slow))
    if lat:
        print("    input->frame latency ms (first move -> first new frame published): p50 %.1f max %.1f (%s)" % (
            pct(lat, .5), max(lat), " ".join("%.0f" % x for x in lat)))
    print(c.report())


def settled(f, quiet=0.6, limit=20):
    """Wait until no frame was published for `quiet` s; returns the time of the last frame (monotonic-ish ns)."""
    end = time.monotonic() + limit
    last = time.monotonic()
    seq = f.seq()
    while time.monotonic() < end:
        f.poll()
        s2 = f.seq()
        if s2 != seq:
            seq = s2
            last = time.monotonic()
        elif time.monotonic() - last > quiet:
            return last
        time.sleep(0.005)
    return None


def launch(bundle):
    f = Frames()
    subprocess.run([X86SIM, "home"], capture_output=True)
    settled(f)
    base = f.seq()
    t0 = time.monotonic()
    tw = time.time_ns()
    with CPU() as c:
        subprocess.Popen([X86SIM, "app", bundle], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        lim = time.monotonic() + 15      # the first frame may come later than the quiet period
        while f.seq() == base and time.monotonic() < lim:
            f.poll()
            time.sleep(0.002)
        end = settled(f, quiet=1.0, limit=30)
    first = min((t for q, t in f.t.items() if q > base), default=None)
    print("launch %s: first frame %.0f ms, settled %.0f ms (last frame before 1 s without frames)" % (
        bundle, (first - tw) / 1e6 if first else -1, (end - t0) * 1000 if end else -1))
    print(frame_stats([t for q, t in f.t.items() if q > base], "frames"))
    print(c.report(8))
    terminate(bundle)   # apps launched by a test don't stay behind (each costs ~300 MB here)


def terminate(bundle):
    try:
        subprocess.run([X86SIM, "terminate", bundle], capture_output=True, timeout=30)
    except subprocess.TimeoutExpired:
        print("    (terminate %s timed out)" % bundle)


def main(a):
    if not a or a[0] == "idle":
        idle(float(a[1]) if len(a) > 1 else 10)
    elif a[0] == "scroll":
        scroll(float(a[1]) if len(a) > 1 else 8)
    elif a[0] == "launch":
        for b in a[1:]:
            launch(b)
    elif a[0] == "all":
        idle(10)
        for b in ["com.apple.Preferences"]:
            terminate(b)
            launch(b)
        scroll(8)
        for b in ["com.apple.mobilesafari", "com.apple.Maps", "com.apple.news"]:
            terminate(b)
            launch(b)
        subprocess.run([X86SIM, "home"], capture_output=True)
    else:
        print(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
