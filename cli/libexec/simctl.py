#!/usr/bin/env python3
"""x86Sim: simctl's developer commands for the Linux simulator (x86sim launch/terminate/get_app_container/listapps/
push/location/addmedia/log/io). Requests go to host/openurl (the com.x86sim.openurl job inside the device, which does
what CoreSimulatorBridge does in a Mac's device) as one line "req <id> <json>" in <data>/tmp/x86sim-openurl; the
answer is the log line "result <id> <json>" in <data>/var/log/x86sim-openurl.log.

  launch [--console|--console-pty] [--stdout=P] [--stderr=P] [-w|--wait-for-debugger] [--terminate-running-process]
         [--oslog] [--env K=V]... <bundle id> [args...]
         as `simctl launch`; SIMCTL_CHILD_<NAME>=value in our environment becomes NAME=value in the app's.
         --console streams the app's stdout/stderr here until Ctrl-C (or --console-secs N) or the app exits;
         --console-pty does it through a pseudo-terminal (the app's stdout/stderr are a tty, as with simctl).
         --oslog: the app's os_log messages go to <data>/var/log/oslog.<executable>.<pid>.log (x86sim log stream)
  terminate <bundle id>
  get_app_container <bundle id> [app|data|groups|<group id>]
  listapps [--json]
  push <bundle id> <payload.json|->     (or a payload with "Simulator Target Bundle" and no bundle id)
  location set <lat>,<lon> | clear | list | run <scenario> | start|run [--speed=] [--distance=|--interval=] <lat>,<lon>...
  addmedia <file>...                    (images and videos into the Photos library)
  log stream [--app <bundle id>] [--process NAME] [--match TEXT]
  io screenshot [out.png] | io recordVideo [--codec h264|hevc] [--secs N] [--fps N] <out.mp4>
"""
import json, os, shutil, signal, subprocess, sys, time, tty, uuid
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "lib"))
import x86config  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = x86config.data()
LOG = os.path.join(DATA, "var/log/x86sim-openurl.log")
Q = os.path.join(DATA, "tmp/x86sim-openurl")


def die(msg, code=1):
    print(msg, file=sys.stderr)
    sys.exit(code)


def request(cmd, timeout=60, **kw):
    """Send one request to host/openurl and return its answer (a dict)."""
    rid = uuid.uuid4().hex[:12]
    kw["cmd"] = cmd
    try:
        start = os.path.getsize(LOG)
    except OSError:
        start = 0
    line = "req %s %s\n" % (rid, json.dumps(kw, separators=(",", ":")))
    # x86Sim: the helper takes the file whole and removes it; wait while an earlier request is still queued
    for _ in range(100):
        if not os.path.exists(Q):
            break
        time.sleep(0.1)
    with open(Q + ".new", "w") as f:
        f.write(line)
    os.rename(Q + ".new", Q)
    key = "result %s " % rid
    end = time.monotonic() + timeout
    # most answers come within tens of ms: poll fast first, then back off to 0.2 s (a fixed 0.2 s added up to that
    # much to every command)
    d = 0.01
    while time.monotonic() < end:
        time.sleep(d)
        d = min(0.2, d * 1.5)
        try:
            with open(LOG, errors="replace") as f:
                f.seek(start)
                for l in f:
                    if l.startswith(key):
                        return json.loads(l[len(key):])
        except OSError:
            pass
    die("x86sim %s: no answer in %d s (is the device booted? see %s)" % (cmd, timeout, LOG))


def check(r, what):
    if not r.get("ok"):
        die("x86sim %s: %s" % (what, r.get("error", r)))
    return r


def app_info(bid):
    return check(request("container", bundle=bid), "get_app_container")["app"]


def oslog_env():
    """Environment for an app whose os_log goes to <data>/var/log/oslog.<executable>.<pid>.log: libsimshim's built-in
    os_log formatter (host/simshim/diag/oslogdiag.m, -DSIMSHIM_OSLOG) turns on for X86SIM_OSLOG, without logd or
    diagnosticd (OS_ACTIVITY_DT_MODE would stream to diagnosticd, which isn't run; the boot doesn't stall on it)."""
    return {"X86SIM_OSLOG": "all", "X86SIM_OSLOG_DIR": x86config.get("X86SIM_DVIEW") + os.path.join(DATA, "var/log")}


def follow(paths, until=None, stop=None):
    """tail -F the files (Linux paths) to our stdout/stderr until Ctrl-C, `until` (monotonic time) or stop()."""
    pos = {p: 0 for p in paths}
    try:
        while True:
            for p, out in paths.items():
                try:
                    with open(p, "rb") as f:
                        f.seek(pos[p])
                        b = f.read()
                except OSError:
                    continue
                if b:
                    pos[p] += len(b)
                    out.buffer.write(b)
                    out.flush()
            if until and time.monotonic() > until:
                return
            if stop and stop():
                time.sleep(0.3)
                stop = None
                until = time.monotonic() + 0.5
            time.sleep(0.2)
    except KeyboardInterrupt:
        pass


def app_running(pid):
    """Is the app's process alive? Darling processes are Linux processes; their pid inside is the Linux pid in
    Darling's pid namespace, so look for the executable in /proc instead (pid = the namespace's NSpid)."""
    for d in os.listdir("/proc"):
        if not d.isdigit():
            continue
        try:
            with open("/proc/%s/status" % d) as f:
                for l in f:
                    if l.startswith("NSpid:"):
                        if int(l.split()[-1]) == pid:
                            return True
                        break
        except OSError:
            continue
    return False


def pidof(bid, wait=0):
    """Darwin pid (the pid inside Darling's pid namespace) of the running app, from /proc (executable path), or None."""
    exe = "/" + app_info(bid)["CFBundleExecutable"]
    path = dview_to_linux(app_info(bid)["Path"])
    end = time.monotonic() + wait
    while True:
        for d in os.listdir("/proc"):
            if not d.isdigit():
                continue
            try:
                with open("/proc/%s/cmdline" % d, "rb") as f:
                    a0 = f.read().split(b"\0")[0].decode(errors="replace")
                if a0.endswith(exe) and path in a0:
                    with open("/proc/%s/status" % d) as f:
                        for l in f:
                            if l.startswith("NSpid:"):
                                return int(l.split()[-1])
            except OSError:
                continue
        if time.monotonic() >= end:
            return None
        time.sleep(0.5)


def cmd_pidof(a):
    if len(a) != 1:
        die("usage: x86sim pidof <bundle id>", 2)
    p = pidof(a[0])
    if p is None:
        die("x86sim pidof: %s is not running" % a[0])
    print(p)


def cmd_launch(a):
    o = {"args": [], "env": {}}
    console = False
    oslog = False
    secs = None
    while a and a[0].startswith("-"):
        x = a.pop(0)
        if x == "--console":
            console = True
        elif x == "--console-pty":
            console = "pty"
        elif x.startswith("--console-secs"):
            secs = float(x.split("=", 1)[1] if "=" in x else a.pop(0))
        elif x.startswith("--stdout="):
            o["stdout"] = x.split("=", 1)[1]
        elif x.startswith("--stderr="):
            o["stderr"] = x.split("=", 1)[1]
        elif x in ("-w", "--wait-for-debugger"):
            o["waitForDebugger"] = True
        elif x == "--terminate-running-process":
            o["terminate"] = True
        elif x == "--oslog":
            oslog = True
        elif x == "--env":
            k, v = a.pop(0).split("=", 1)
            o["env"][k] = v
        elif x == "--":
            break
        else:
            die("x86sim launch: unknown option %s" % x, 2)
    if not a:
        die(__doc__, 2)
    o["bundle"] = a[0]
    o["args"] = a[1:]
    # simctl: SIMCTL_CHILD_FOO=bar in the caller's environment -> FOO=bar in the app's
    for k, v in os.environ.items():
        if k.startswith("SIMCTL_CHILD_"):
            o["env"].setdefault(k[len("SIMCTL_CHILD_"):], v)
    if oslog:
        o["env"].update(oslog_env())
    outs = {}
    if console == "pty":
        # x86Sim: as simctl --console-pty: the app's stdout and stderr are a pseudo-terminal (isatty, line-buffered
        # stdio). A Linux pty's slave, opened by path through the container's view of the Linux root.
        master, slave = os.openpty()
        tty.setraw(slave)
        name = os.ttyname(slave)
        o["stdout"] = o["stderr"] = x86config.get("X86SIM_DVIEW") + name
    elif console:
        # x86Sim: simctl --console hands the app a pty / pipe; FrontBoard here takes file paths (as the Bridge's
        # __StandardOutPath), so the app writes files in the device's tmp and we follow them
        d = os.path.join(DATA, "tmp/x86sim-console")
        os.makedirs(d, exist_ok=True)
        for s in ("stdout", "stderr"):
            p = os.path.join(d, "%s.%s" % (o["bundle"], s))
            open(p, "w").close()
            o[s] = "tmp/x86sim-console/%s.%s" % (o["bundle"], s)
            outs[p] = sys.stdout if s == "stdout" else sys.stderr
    r = check(request("launch", timeout=50, **o), "launch")
    if r.get("waiting"):
        r["pid"] = pidof(o["bundle"], wait=20) or -1
    print("%s: %s" % (o["bundle"], r.get("pid")), flush=True)
    if o.get("waitForDebugger"):
        print("x86sim: %s waits for a debugger (pid %s); see README: Debugging" % (o["bundle"], r.get("pid")),
              file=sys.stderr)
    if console == "pty":
        pid = r.get("pid", -1)
        relay_pty(master, slave, until=time.monotonic() + secs if secs else None,
                  stop=(lambda: not app_running(pid)) if pid and pid > 0 else None)
    elif console:
        pid = r.get("pid", -1)
        follow(outs, until=time.monotonic() + secs if secs else None,
               stop=(lambda: not app_running(pid)) if pid and pid > 0 else None)


def relay_pty(master, slave, until=None, stop=None):
    """Copy what the app writes to the pty to our stdout until Ctrl-C, `until`, or stop() (the app exited)."""
    import select
    os.close(slave)  # the app holds its own
    last = 0.0
    try:
        while until is None or time.monotonic() < until:
            r, _, _ = select.select([master], [], [], 0.5)
            if r:
                try:
                    b = os.read(master, 65536)
                except OSError:  # EIO: no process has the slave open any more
                    break
                sys.stdout.buffer.write(b)
                sys.stdout.flush()
            elif stop and time.monotonic() - last > 2:
                last = time.monotonic()
                if stop():
                    break
    except KeyboardInterrupt:
        pass


def cmd_terminate(a):
    if len(a) != 1:
        die("usage: x86sim terminate <bundle id>", 2)
    check(request("terminate", bundle=a[0]), "terminate")


def cmd_container(a):
    if not a:
        die("usage: x86sim get_app_container <bundle id> [app|data|groups|<group id>]", 2)
    info = app_info(a[0])
    kind = a[1] if len(a) > 1 else "app"
    linux = lambda p: dview_to_linux(p)  # noqa: E731
    if kind == "app":
        print(linux(info["Path"]))
    elif kind == "data":
        if "DataContainer" not in info:
            die("x86sim get_app_container: %s has no data container" % a[0])
        print(linux(info["DataContainer"]))
    elif kind == "groups":
        for g, p in sorted(info.get("GroupContainers", {}).items()):
            print("%s\t%s" % (g, linux(p)))
    else:
        g = info.get("GroupContainers", {}).get(kind)
        if not g:
            die("x86sim get_app_container: no group container %s for %s" % (kind, a[0]))
        print(linux(g))


def dview_to_linux(p):
    """A path inside Darling (/Volumes/SystemRoot/<linux path>) as the Linux path."""
    v = x86config.get("X86SIM_DVIEW")
    if p.startswith(v + "/"):
        return p[len(v):]
    if p.startswith("/private" + v + "/"):
        return p[len("/private" + v):]
    return p


def cmd_listapps(a):
    apps = check(request("listapps"), "listapps")["apps"]
    if "--json" in a:
        print(json.dumps(apps, indent=2, sort_keys=True))
        return
    for bid in sorted(apps):
        i = apps[bid]
        print("%-50s %-8s %s" % (bid, i.get("ApplicationType", ""), i.get("CFBundleDisplayName", "")))


def cmd_push(a):
    if len(a) == 1:
        bid, src = None, a[0]
    elif len(a) == 2:
        bid, src = a
    else:
        die("usage: x86sim push [bundle id] <payload.json|->", 2)
    payload = json.load(sys.stdin if src == "-" else open(src))
    bid = bid or payload.get("Simulator Target Bundle")
    if not bid:
        die("x86sim push: no bundle id (argument or \"Simulator Target Bundle\" in the payload)", 2)
    if not isinstance(payload.get("aps"), dict):
        die("x86sim push: the payload has no \"aps\" dictionary", 2)
    check(request("push", bundle=bid, payload=payload), "push")
    print("Notification sent to '%s'" % bid)


LOCATION_USAGE = ("usage: x86sim location set <lat>,<lon> | clear | list | run <scenario> |\n"
                  "       location start|run [--speed=<m/s>] [--distance=<m>|--interval=<s>] <lat>,<lon> <lat>,<lon>... ('-': stdin)")


def latlon(s):
    try:
        lat, lon = (float(x) for x in s.strip().split(","))
    except ValueError:
        die("x86sim location: not a <lat>,<lon> pair: %r" % s, 2)
    return [lat, lon]


def cmd_location(a):
    """As simctl location: set / clear / list / run <scenario> / start (waypoints, interpolated by locationd)."""
    act, rest = (a[0], a[1:]) if a else ("", [])
    if act == "clear" and not rest:
        check(request("location", clear=True), "location")
    elif act == "set" and len(rest) == 1:
        lat, lon = latlon(rest[0])
        check(request("location", lat=lat, lon=lon), "location")
    elif act == "list" and not rest:
        for n in check(request("location", list=True), "location").get("scenarios", []):
            print(n)
    elif act == "run" and len(rest) == 1 and "," not in rest[0] and rest[0] != "-":
        r = check(request("location", scenario=rest[0]), "location")
        print("Running scenario '%s'" % r.get("scenario"))
    elif act in ("start", "run") and rest:
        opts, pts = {}, []
        for x in rest:
            if x.startswith("--") and "=" in x:
                k, v = x[2:].split("=", 1)
                if k not in ("speed", "distance", "interval"):
                    die(LOCATION_USAGE, 2)
                opts[k] = float(v)
            elif x == "-":
                pts += [latlon(l) for l in sys.stdin if l.strip()]
            else:
                pts.append(latlon(x))
        if len(pts) < 2:
            die("x86sim location %s: at least two waypoints" % act, 2)
        check(request("location", points=pts, **opts), "location")
    else:
        die(LOCATION_USAGE, 2)


def cmd_addmedia(a):
    if not a:
        die("usage: x86sim addmedia <image or video>...", 2)
    d = os.path.join(DATA, "tmp/x86sim-media")
    os.makedirs(d, exist_ok=True)
    rel = []
    for p in a:
        if not os.path.isfile(p):
            die("x86sim addmedia: %s: no such file" % p)
        n = "%s-%s" % (uuid.uuid4().hex[:6], os.path.basename(p))
        shutil.copyfile(p, os.path.join(d, n))
        rel.append("tmp/x86sim-media/" + n)
    r = check(request("addmedia", timeout=120, paths=rel), "addmedia")
    print("x86sim addmedia: added %d" % r.get("added", 0))


def cmd_log(a):
    if a[:1] != ["stream"]:
        die("usage: x86sim log stream [--app <bundle id>] [--process NAME] [--match TEXT]", 2)
    a = a[1:]
    proc = None
    match = a[a.index("--match") + 1] if "--match" in a else None
    if "--process" in a:
        proc = a[a.index("--process") + 1]
    if "--app" in a:
        bid = a[a.index("--app") + 1]
        proc = proc or app_info(bid).get("CFBundleExecutable")
        r = check(request("launch", timeout=50, bundle=bid, env=oslog_env(), terminate=True), "launch")
        print("x86sim: %s relaunched with os_log to a file (pid %s)" % (bid, r.get("pid")), file=sys.stderr, flush=True)
    d = os.path.join(DATA, "var/log")
    # x86Sim: os_log of processes the diag shim formats (liboslogdiag: --oslog launches, X86SIM_INSERT boots with
    # data/oslog.filter): data/var/log/oslog.<prog>.<pid>.log. Follow the ones written from now on.
    t0 = time.time() - 2
    pos = {}
    try:
        while True:
            for n in os.listdir(d):
                if not n.startswith("oslog.") or (proc and not n.startswith("oslog.%s." % proc)):
                    continue
                p = os.path.join(d, n)
                if p not in pos:
                    try:
                        pos[p] = 0 if os.path.getmtime(p) >= t0 else os.path.getsize(p)
                    except OSError:
                        continue
                with open(p, "rb") as f:
                    f.seek(pos[p])
                    b = f.read()
                if b:
                    pos[p] += len(b)
                    tag = n[len("oslog."):-len(".log")]
                    for l in b.decode(errors="replace").splitlines():
                        if match and match not in l:
                            continue
                        print("%s  %s" % (tag, l), flush=True)
            time.sleep(0.3)
    except KeyboardInterrupt:
        pass


def cmd_io(a):
    if a[:1] == ["screenshot"]:
        out = a[1] if len(a) > 1 else "screenshot.png"
        subprocess.run([sys.executable, os.path.join(HERE, "fb2png.py"), "ring", out, "1"], check=True,
                       stdout=subprocess.DEVNULL)
        print(out)
    elif a[:1] == ["recordVideo"]:
        record(a[1:])
    else:
        die("usage: x86sim io screenshot [out.png] | io recordVideo [--codec h264|hevc] [--secs N] [--fps N] <out.mp4>", 2)


def record(a):
    """MP4 from simfb's frame ring (as simctl io recordVideo): constant frame rate, the newest frame repeated while
    nothing changes. Ends with Ctrl-C (SIGINT) or after --secs."""
    import fbring
    codec, secs, fps = "h264", None, 60
    while a and a[0].startswith("--"):
        x = a.pop(0)
        v = x.split("=", 1)[1] if "=" in x else a.pop(0)
        if x.startswith("--codec"):
            codec = v
        elif x.startswith("--secs"):
            secs = float(v)
        elif x.startswith("--fps"):
            fps = int(v)
    if len(a) != 1:
        die("usage: x86sim io recordVideo [--codec h264|hevc] [--secs N] [--fps N] <out.mp4>", 2)
    out = a[0]
    ring = fbring.Ring()
    f = ring.latest()
    if not f:
        die("x86sim io recordVideo: no frames (is the device booted?)")
    w, h, stride = f[0], f[1], f[2]
    nv = subprocess.run(["ffmpeg", "-hide_banner", "-encoders"], capture_output=True, text=True).stdout
    enc = {"h264": "h264_nvenc", "hevc": "hevc_nvenc"}[codec]
    if enc not in nv:
        enc = {"h264": "libx264", "hevc": "libx265"}[codec]
    ff = subprocess.Popen(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                           "-f", "rawvideo", "-pix_fmt", "bgra", "-s", "%dx%d" % (stride // 4, h), "-r", str(fps),
                           "-i", "-", "-vf", "crop=%d:%d:0:0" % (w - w % 2, h - h % 2), "-c:v", enc, "-pix_fmt",
                           "yuv420p", "-movflags", "+faststart", out], stdin=subprocess.PIPE,
                          preexec_fn=lambda: signal.signal(signal.SIGINT, signal.SIG_IGN))
    stop = []
    signal.signal(signal.SIGINT, lambda *_: stop.append(1))
    print("x86sim: recording %s (Ctrl-C to stop)" % out, file=sys.stderr, flush=True)
    frame, seq, n = f[5], f[3], 0
    period = 1.0 / fps
    t0 = time.monotonic()
    nxt = t0
    while not stop and (secs is None or time.monotonic() - t0 < secs):
        s = ring.seq()
        if s and s != seq:
            g = ring.latest()
            if g and g[2] == stride and g[1] == h:
                frame, seq = g[5], g[3]
        try:
            ff.stdin.write(frame)
        except BrokenPipeError:
            break
        n += 1
        nxt += period
        d = nxt - time.monotonic()
        if d > 0:
            time.sleep(d)
        else:
            nxt = time.monotonic()
    ff.stdin.close()
    ff.wait()
    print("x86sim: wrote %s (%d frames, %.1f s)" % (out, n, n / fps), file=sys.stderr)


CMDS = {"launch": cmd_launch, "terminate": cmd_terminate, "get_app_container": cmd_container, "listapps": cmd_listapps,
        "push": cmd_push, "pidof": cmd_pidof, "location": cmd_location, "addmedia": cmd_addmedia, "log": cmd_log, "io": cmd_io}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in CMDS:
        die(__doc__, 2)
    CMDS[sys.argv[1]](sys.argv[2:])
