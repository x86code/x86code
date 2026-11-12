#!/usr/bin/env python3
"""x86Sim: a jetsam stand-in. Reclaims what a device's memorystatus would: idle extensions, background apps and clean
idle-exit daemons.

On a device memorystatus keeps every process in a band and, when memory runs short, kills the idle band first (clean
daemons launchd lets exit, suspended apps and extensions), then background apps. The simulator has no jetsam, and here
every process carries ~100-500 MB of private memory (JIT, framework data), so nothing was ever reclaimed: the widget,
poster and file-provider extensions chronod and PosterBoard started (~6 GB at a boot), each app opened, and every daemon
a boot's launch events started (Siri's, Wallet's, Maps': ~1 GB). The phone runs as if memory were always short (a host
runs several phones), so this reclaims as soon as something has been idle a while. What it reads (Darling's
libsystem_kernel records it in the container, cleared at each boot):
  /private/var/run/x86sim-suspended/<pid>   RunningBoard suspended it (pid_suspend; removed on pid_resume)
  /private/var/run/x86sim-jetsam/<pid>      "<band> <dirty flags> <user data> <darwin bg>" (process/memorystatus.c):
      dirty flags as proc_get_dirty: 1 tracked, 2 allows idle exit (launchd: EnablePressuredExit), 4 dirty (an open
      XPC transaction); darwin bg 1 = RunningBoard backgrounded it (PRIO_DARWIN_BG), 0 = brought back; darwin role
      (PRIO_DARWIN_ROLE) 3 = off screen (NON_UI), 6 = DARWIN_BG, 1/2/4 = on screen.
Kills (SIGKILL, as jetsam; launchd / RunningBoard relaunch what is needed on the next lookup or open):
  - an app extension (.appex) suspended for more than X86SIM_JETSAM_EXT s (default 10); RAM 12: not WebKit's WebContent /
    GPU / Networking while an app runs (they go with their host app; X86SIM_JETSAM_WEBKIT=0 off)
  - RAM 12: an app going to the background touches $SIMULATOR_MEMORY_WARNINGS (the simulator's memory-pressure event,
    PRESSURE_WARN to every process), at most every X86SIM_JETSAM_WARN_EVERY s (10); X86SIM_JETSAM_WARN=0 off
  - a background app (.app) after X86SIM_JETSAM_APP s (default 30); the most recently backgrounded one after
    X86SIM_JETSAM_LAST s (default 90), so switching back to the last app soon is a warm resume. X86SIM_JETSAM_KEEP
    (default 1): how many get the longer time. Only on a positive "this is background" signal, never by inference:
    RunningBoard suspended it, PRIO_DARWIN_BG, darwin role NON_UI / DARWIN_BG, or RunningBoard's state of the process
    (com.x86sim.openurl answers it: host/openurl frontmost()) without the frontboard visibility endowment or suspended.
    Never killed (checked again, with a fresh answer, right before the kill): an app RunningBoard reports visible,
    one in SpringBoard's display layout or reported frontmost, and one that was in the foreground when the user last
    touched or typed (<data>/tmp/x86sim-input, simhid) within X86SIM_JETSAM_INPUT s (default 60).
    (RAM 2 fix: SBSCopyFrontmostApplicationDisplayIdentifier answers nil for every app here, which read as "home": every
    app in the foreground past 30 s was taken for a background one and killed 90 s later, Maps in the middle of the
    gate's route test. Maps at the home screen keeps visibility and role UI_FOCAL here, so it is reclaimed only once
    RunningBoard suspends it, i.e. after another app was opened.)
    (RAM 4: openurl also reports FrontBoard's per-scene visibility endowments; an app with none, while it keeps the
    env-less visibility endowment, is one left at the home screen, counted once it is SCENE_SETTLE s old.)
  - Spotlight (UISVC) when RunningBoard shows it nothing (background since boot, or after a search) after
    X86SIM_JETSAM_UISVC s (default 60); never "the foreground app"; SpringBoard relaunches it on the pull-down.
  - an idle-exit daemon (tracked, allows idle exit, clean) that has been clean and used no CPU for X86SIM_JETSAM_IDLE s
    (default 30); the daemons every app launch talks to (HOT, X86SIM_JETSAM_HOT) after X86SIM_JETSAM_IDLE_HOT s
    (default 600), so app opens don't pay their relaunch. While an app is in the foreground every daemon gets the HOT
    time (the app's own daemons, e.g. geod under Maps, stay warm). RAM 9: HOT applies only within X86SIM_JETSAM_IDLE_HOT s
    of the last touch (or of jetsam's start); at an untouched home screen HOT daemons get IDLE too.
  - X86SIM_JETSAM_DEMAND (default below): on-demand daemons without EnablePressuredExit that a basic phone only needs
    for a feature in use (Siri's assets, Wallet's passd): as idle-exit daemons once clean (tracked, not dirty).
    assistantd too (RAM 4: dictation / Siri; the keyboard and Siri look it up and launchd starts it).
  - X86SIM_JETSAM_XPC (default 1): system XPC services (.xpc bundles) as idle-exit daemons once tracked and clean (RAM 10).
  - X86SIM_JETSAM_DIRTY (default siriactionsd, corespeechd): such daemons also when dirty, after X86SIM_JETSAM_DIRTY_IDLE s CPU-idle.
Something relaunched within RELAUNCH s of its kill (a launch event, or a client that needed it) doubles its grace
period each time, up to X86SIM_JETSAM_MAX s (default 1800): it is never kept forever, and never killed in a loop.
X86SIM_JETSAM=0 disables it; X86SIM_JETSAM_DAEMONS=0 leaves daemons alone (extensions and apps only).
    cli/libexec/jetsam.py [--once] [-v] [--status]"""
import os, signal, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "lib"))
import x86config  # noqa: E402

PREFIX = x86config.get("X86SIM_DPREFIX")
DIR = os.path.join(PREFIX, "private/var/run/x86sim-suspended")
JDIR = os.path.join(PREFIX, "private/var/run/x86sim-jetsam")
EXT = float(os.environ.get("X86SIM_JETSAM_EXT", "10"))
APP = float(os.environ.get("X86SIM_JETSAM_APP", "30"))
LAST = float(os.environ.get("X86SIM_JETSAM_LAST", "90"))
KEEP = int(os.environ.get("X86SIM_JETSAM_KEEP", "1"))
IDLE = float(os.environ.get("X86SIM_JETSAM_IDLE", "30"))
IDLE_HOT = float(os.environ.get("X86SIM_JETSAM_IDLE_HOT", "600"))
DAEMONS = os.environ.get("X86SIM_JETSAM_DAEMONS", "1") != "0"
BACKOFF_MAX = float(os.environ.get("X86SIM_JETSAM_MAX", "1800"))
# every app launch / the home screen talks to these (containers, code signing, TCC, icons, fonts, extensions, status bar)
HOT = set(os.environ.get("X86SIM_JETSAM_HOT", "containermanagerd,containermanagerd_system,trustd,securityd,"
                         "iconservicesagent,fontservicesd,pkd,appprotectiond,tccd,systemstatusd,usernotificationsd,"
                         "sleepd,diagnosticd,mobilegestalt,UserEventAgent,nsurlsessiond,cloudd").split(","))
# RAM 5: not mobileassetd. Every mobileassetd start posts MobileAsset's STARTUP_ACTIVATED and ATOMIC_INSTANCE_* notifications
# (by design once per boot: it runs for the whole boot on a device), and those are launch events of assistantd, corespeechd,
# siriknowledged, assetsubscriptiond (-> sirittsd, ContextService, localspeechrecognition, STExtractionService). Reclaimed
# idle, it was looked up again within 5 min (fontservicesd's 300 s activity subscription-support asks it for font assets;
# passd at its launch) and each relaunch woke those 8 daemons (~400 MB) for jetsam to reclaim again: a loop.
DEMAND = set(os.environ.get("X86SIM_JETSAM_DEMAND", "passd,assistant_cdmd,ContextService,"
                            "STExtractionService,localspeechrecognition,com.apple.datamigrator,"
                            "com.apple.MobileAsset.DownloadService.Builtin,siriactionsd,"
                            "assetsubscriptiond,AppIntentsLiveEntityService,assistantd").split(",")) - {""}
# RAM 7: kept resident although idle-exit-able. UserFontManager is fontservicesd's XPC service; fontservicesd's activity
# com.apple.fontservicesd.subscription-support (Interval 300) asks it for the font providers' subscription info every
# 5 min (0.2 s of CPU). Reclaimed 30 s after each ask, every ask relaunched it: ~140 MB PSS (dyld cache fault-around)
# for the ~30 s until libarm64jit's file trim, then the kill. Resident and trimmed it is 7 MB. On a device an idle
# XPC service whose client lives sits in the idle band until real memory pressure.
# RAM 9: nsurlsessiond keeps a file in its plist QueueDirectories (Library/com.apple.nsurlsessiond-launchd/
# nsurlsessiond.launch) while it holds background tasks, so launchd restarts it 0 s after any kill; each restart redid
# its startup (containermanagerd_system, its clients' LaunchOnDemand events: passd -> financed, searchd, tccd ...).
# fontservicesd: HOT kept it (its 300 s activity never let it idle 600 s); with HOT off at an untouched home it would
# be killed between activities and relaunch with UserFontManager (~170 MB at launch) every 5 min.
# axassetsd: its VoiceDatabase deletes voicedb.sqlite at every start and refills it only from loaders not yet run in
# this boot (com.apple.SpeakSelection PreferencesLastLoadedOn = kern.boottime): after an idle kill it came back with an
# empty database for the rest of the boot (AVSpeechSynthesisVoice.speechVoices() empty). A Mac's simulator never
# kills it. ~45 MB.
RESIDENT = set(os.environ.get("X86SIM_JETSAM_RESIDENT", "UserFontManager,fontservicesd,nsurlsessiond,axassetsd").split(",")) - {""}
# RAM 4: on-demand daemons that stay dirty (an XPC transaction nobody ends) with nothing to do: reclaimed once CPU-idle for
# X86SIM_JETSAM_DIRTY_IDLE s anyway, as a device's jetsam takes dirty background daemons under pressure. siriactionsd: a
# relaunch by a launch event (LaunchServices / Biome / defaults notifications) leaves it dirty for good (~80 MB).
# RAM 10: corespeechd: the gate's Siri press starts it; it stays dirty (~30 MB) with nothing to do (no voice trigger here:
# its KeepAlive PathState /var/mobile/Library/VoiceTrigger/KeepAlive does not exist).
DIRTY_OK = set(os.environ.get("X86SIM_JETSAM_DIRTY", "siriactionsd,corespeechd").split(",")) - {""}
XPC_IDLE = os.environ.get("X86SIM_JETSAM_XPC", "1") != "0"
DIRTY_IDLE = float(os.environ.get("X86SIM_JETSAM_DIRTY_IDLE", "300"))
POLL = 2.0
# RAM 2: RunningBoard's and SpringBoard's view of the apps, from com.x86sim.openurl (host/openurl frontmost()): the
# request lists the apps' Darling pids, the answer has per pid "pid <pid> <visible> <task state>", "layout <n> <ids>"
# and SpringBoard's frontmost id on line 1. Asked every FRONT_EVERY s, and again right before an app is killed.
DEVDATA = os.path.join(os.environ.get("X86SIM_DEVICE", ""), "data")
FRONT_REQ = os.path.join(DEVDATA, "tmp/x86sim-frontmost.req")
FRONT = os.path.join(DEVDATA, "tmp/x86sim-frontmost")
INPUT = os.path.join(DEVDATA, "tmp/x86sim-input")   # simhid: mtime = the last touch / key / button
INPUT_KEEP = float(os.environ.get("X86SIM_JETSAM_INPUT", "60"))
FRONT_EVERY = 10.0
WARN = os.environ.get("X86SIM_JETSAM_WARN", "1") != "0"
WARN_EVERY = float(os.environ.get("X86SIM_JETSAM_WARN_EVERY", "10"))
WARN_FILE = os.path.join(DEVDATA, "var/run/memory_warning_simulation")
_warned = {"t": 0.0}
WEBKIT_WITH_APP = os.environ.get("X86SIM_JETSAM_WEBKIT", "1") != "0"
RB_SUSPENDED = 3   # RBSTaskStateRunningSuspended
_front = {"asked": 0.0}
_bundle_ids = {}
CPU_IDLE = 0.2   # CPU seconds a process may use per CPU_WIN and still count as idle
CPU_WIN = 10.0
CLK = os.sysconf("SC_CLK_TCK")
BOOT = time.time() - float(open("/proc/uptime").read().split()[0])
RELAUNCH = 60.0
START = time.time()
# system apps and UI services (angels: the keyboard, Siri's UI) RunningBoard may background: never reclaimed here, and
# never "the app in the foreground"
# Platforms 1: the watch's and the TV's own UI apps too (Carousel and the watch face ClockFace; PineBoard and the
# HeadBoard home screen): always up, so with them "the app in the foreground" every idle daemon waited 600 s, not 30.
NEVER = ("SpringBoard.app/", "PosterBoard.app/", "InputUI.app/", "Campo.app/", "Carousel.app/", "ClockFace.app/",
         "PineBoard.app/", "HeadBoard.app/",
         # Platforms 2: visionOS's SpringBoard (it has no visible scene until the compositor runs: killed at 90 s)
         "SurfBoard.app/", "RealityEnvironment.app/",
         # visionOS's system shell runs as separate apps (keyboard, notifications, HUD, Home View, ...), off screen
         # (role 3) between uses, as SpringBoard-hosted UI is on iOS. Taken for background apps, each was killed every
         # 30-60 s and relaunched at once, with a memory warning each time: RealityKit and CoreAnimation purged their
         # caches every few seconds and the Home View's icons went black for good.
         "RealityLauncher.app/", "RealityChrome.app/", "RealityHUD.app/", "RealityKeyboard.app/",
         "RealityNotifications.app/", "RealityCoverSheet.app/", "RealityControlCenter.app/",
         "RealityBreakthrough.app/", "RealityWidgets.app/")
# The wallpaper's poster extension: SpringBoard asks it for the lock screen at every wake and unlock. Reclaimed as a
# suspended extension, it was killed and relaunched in a loop ("came back 0 s after its kill") and an unlock that hit
# the gap never undimmed, then froze. A device keeps the active poster's extension alive too.
NEVER_EXT = ("MercuryPosterExtension.appex/",)
# Platforms 1: parked executables (X86SIM_A64_SLIM_PARK, boot-a64.sh: WidgetRenderer by default) hold no translated
# code and next to no memory, so killing one frees nothing. On a watch Carousel asks for WidgetRenderer_Snapshots again
# at once: it was killed and relaunched in a loop ("came back 0 s after its kill").
def _park_list():
    v = os.environ.get("X86SIM_A64_SLIM_PARK")
    if v is None:
        try:
            v = open(os.path.join(x86config.get("X86SIM_SCRATCH"), "a64-slim-park")).read()
        except OSError:
            v = ""
    return tuple(k for k in v.strip().split(",") if k)
PARKED = _park_list()
def parked(exe):
    base = exe.rsplit("/", 1)[-1]
    return any(k in base for k in PARKED)
# RAM 4: UI services reclaimed like a background app once RunningBoard says they show nothing (no visible scene, not
# visible / NON_UI), after X86SIM_JETSAM_UISVC s, and never counted as "the app in the foreground". Spotlight: SpringBoard
# starts it at boot in the background (role NON_UI, ~170 MB) and draws the home screen's Search pill itself; a pull-down
# relaunches it (search up ~3 s after the swipe, typing intact). As on a device, where it stays suspended / jetsammable.
# RAM 15: DockFolderViewService: the iPhone Duo's home screen runs it for the dock column (a view service in an .app
# bundle); taken for "the app in the foreground", it gave every daemon the foreground's 600 s instead of the home
# screen's 30 s for the whole boot (20 more daemons, ~420 MB at a 15-min idle home).
UISVC = ("Spotlight.app/", "DockFolderViewService.app/")
UISVC_GRACE = float(os.environ.get("X86SIM_JETSAM_UISVC", "60"))
_kills = {}       # executable -> quick relaunches so far (each doubles its grace period)
_killed_at = {}   # executable -> time of its last kill
_seen = {}        # (dpid, start) -> {"bg": since, "clean": since, "cpu": [(t, cpu s)]}


def container_ns():
    """The pid namespace of X86SIM_DPREFIX's container (its darlingserver's children), or None. Several containers can
    run at once (two phones): their Darling pids overlap."""
    prefix = os.path.realpath(PREFIX)
    servers = set()
    kids = {}
    for p in os.listdir("/proc"):
        if not p.isdigit():
            continue
        try:
            with open("/proc/%s/stat" % p) as f:
                kids.setdefault(int(f.read().rsplit(")", 1)[1].split()[1]), []).append(p)
            with open("/proc/%s/comm" % p) as f:
                if f.read().strip() != "darlingserver":
                    continue
            with open("/proc/%s/cmdline" % p, "rb") as f:
                args = f.read().split(b"\0")
            if len(args) > 1 and os.path.realpath(args[1].decode(errors="replace")) == prefix:
                servers.add(int(p))
        except (OSError, ValueError, IndexError):
            pass
    # the namespace most of the server's children are in (one child can be alone in its own: the boot's init helper;
    # taking the first child found made this see 1 process and reclaim nothing)
    count = {}
    for s in servers:
        for k in kids.get(s, []):
            try:
                ns = os.readlink("/proc/%s/ns/pid" % k)
            except OSError:
                continue
            count[ns] = count.get(ns, 0) + 1
    return max(count, key=count.get) if count else None


def darling_pids():
    """Darling pid (the container namespace's) -> (Linux pid, executable path, start time as epoch seconds, CPU s)."""
    out = {}
    ns_want = container_ns()
    for p in os.listdir("/proc"):
        if not p.isdigit():
            continue
        try:
            if ns_want and os.readlink("/proc/%s/ns/pid" % p) != ns_want:
                continue
            with open("/proc/%s/status" % p) as f:
                ns = next((l.split()[1:] for l in f if l.startswith("NSpid:")), [])
            if len(ns) < 2:
                continue
            with open("/proc/%s/cmdline" % p, "rb") as f:
                exe = f.read().split(b"\0")[0].decode(errors="replace")
            with open("/proc/%s/stat" % p) as f:
                st = f.read().rsplit(")", 1)[1].split()
            # a zombie (killed, not reaped yet: the container's init reaps late or never) is not a process to reclaim:
            # its empty cmdline made the sweep SIGKILL "" (healthd's pid) every 2 s forever
            if st[0] in ("Z", "X"):
                continue
            start = BOOT + int(st[19]) / CLK
            out[int(ns[-1])] = (int(p), exe, start, (int(st[11]) + int(st[12])) / CLK)
        except (OSError, ValueError, IndexError):
            pass
    return out


def marks(d):
    """pid -> (mtime, fields) of the files in d."""
    out = {}
    try:
        names = os.listdir(d)
    except OSError:
        return out
    for n in names:
        if not n.isdigit():
            continue
        path = os.path.join(d, n)
        try:
            mt = os.stat(path).st_mtime
            fields = open(path).read().split() if d == JDIR else []
            out[int(n)] = (mt, [int(x) for x in fields])
        except (OSError, ValueError):
            pass
    return out


def _start_of(lpid):
    """A Linux process's start time (epoch s), 0 if gone."""
    try:
        with open("/proc/%d/stat" % lpid) as f:
            return BOOT + int(f.read().rsplit(")", 1)[1].split()[19]) / CLK
    except (OSError, ValueError, IndexError):
        return 0.0


def name_of(exe):
    return exe.rstrip("/").split("/")[-1]


def bundle_id(exe):
    """The CFBundleIdentifier of an app executable (its Info.plist, read on the host)."""
    if exe not in _bundle_ids:
        import plistlib
        path = exe[len("/Volumes/SystemRoot"):] if exe.startswith("/Volumes/SystemRoot/") else exe
        try:
            with open(os.path.join(os.path.dirname(path), "Info.plist"), "rb") as f:
                _bundle_ids[exe] = plistlib.load(f).get("CFBundleIdentifier")
        except Exception:
            _bundle_ids[exe] = None
    return _bundle_ids[exe]


def ask_front(pids, now):
    """Asks openurl about these Darling pids (and the layout); returns the request time."""
    _front["asked"] = now
    try:
        with open(FRONT_REQ + ".new", "w") as f:
            f.write("".join("%d\n" % p for p in pids))
        os.rename(FRONT_REQ + ".new", FRONT_REQ)
    except OSError:
        pass
    return now


def front_state(newer_than=0.0):
    """openurl's last answer: {"front": id or None, "layout": set or None, "pids": {pid: (visible, task)}}, or None
    when there is none (or it is stale / older than newer_than)."""
    try:
        mt = os.stat(FRONT).st_mtime
        lines = open(FRONT).read().split("\n")
    except OSError:
        return None
    if time.time() - mt > 3 * FRONT_EVERY or mt < newer_than:
        return None
    out = {"front": lines[0].strip() or None if lines else None, "layout": None, "pids": {}}
    if out["front"] == "?":
        out["front"] = None
    for l in lines[1:]:
        f = l.split()
        try:
            if f[:1] == ["layout"] and int(f[1]) >= 0:
                out["layout"] = set(f[2:])
            elif f[:1] == ["pid"]:
                out["pids"][int(f[1])] = (int(f[2]), int(f[3]), int(f[4]) if len(f) > 4 else -1)
        except (IndexError, ValueError):
            pass
    return out


def wait_front(pids, timeout=4.0):
    """A fresh answer for these pids (right before a kill), None if openurl gives none in time."""
    t = ask_front(pids, time.time())
    while time.time() < t + timeout:
        fs = front_state(newer_than=t)
        if fs is not None:
            return fs
        time.sleep(0.2)
    return None


SCENE_SETTLE = 20.0   # a launching app has no scene yet: the scene signal counts once the process is this old


def app_view(exe, dpid, sm, jm, fs, age=1e9):
    """(background, foreground) evidence for an app: positive signals only. foreground wins over background."""
    bg = jm[1][3] if jm and len(jm[1]) > 3 else -1
    role = jm[1][4] if jm and len(jm[1]) > 4 else -1
    back, fore = [], []
    if sm:
        back.append("suspended")
    if bg == 1:
        back.append("darwin bg")
    if role in (3, 6):
        back.append("role %d" % role)
    if fs is not None:
        bid = bundle_id(exe)
        vis, task, scenes = fs["pids"].get(dpid, (-1, -1, -1))
        # RAM 4: FrontBoard's per-scene visibility endowment is the one signal that tells an app left at the home
        # screen (it keeps the env-less visibility endowment, role UI_FOCAL, BKS state foreground) from one on screen
        if scenes > 0:
            fore.append("scene visible")
        elif scenes == 0 and vis == 1 and age > SCENE_SETTLE:
            back.append("no visible scene")
        elif scenes == 0 and vis == 1:
            fore.append("launching")
        elif vis == 1:
            fore.append("visible")
        elif vis == 0:
            back.append("not visible")
        if task == RB_SUSPENDED:
            back.append("rb suspended")
        if fs["layout"] is not None and bid:
            (fore if bid in fs["layout"] else back).append("layout")
        if fs["front"] and bid:
            (fore if fs["front"] == bid else back).append("frontmost %s" % fs["front"])
    return back, fore


def last_input():
    try:
        return os.stat(INPUT).st_mtime
    except OSError:
        return 0.0


def memory_warning(now):
    """RAM 12: the simulator's memory-pressure event. Its libdispatch makes DISPATCH_SOURCE_TYPE_MEMORYPRESSURE a vnode
    watch (NOTE_ATTRIB) on $SIMULATOR_MEMORY_WARNINGS and reports PRESSURE_WARN to every process watching (libmalloc's
    pressure relief, UIKit's didReceiveMemoryWarning, WebKit's and CoreAnimation's cache purges). Nothing touched it, so
    no guest process ever saw pressure. Touched when an app goes to the background (as a device under load does), at
    most every WARN_EVERY s. X86SIM_JETSAM_WARN=0 off."""
    if not WARN or now - _warned["t"] < WARN_EVERY:
        return
    _warned["t"] = now
    try:
        os.utime(WARN_FILE)
        print("%s jetsam: memory warning" % time.strftime("%H:%M:%S"), flush=True)
    except OSError:
        pass


def grace(exe, base):
    return min(BACKOFF_MAX, base * (2 ** _kills.get(exe, 0)))


def cpu_idle(st, now, cpu):
    """Records a CPU sample; True when the process used under CPU_IDLE s over the last CPU_WIN s."""
    h = st.setdefault("cpu", [])
    h.append((now, cpu))
    while len(h) > 2 and h[1][0] <= now - CPU_WIN:
        h.pop(0)
    return h[0][0] <= now - CPU_WIN + POLL and cpu - h[0][1] < CPU_IDLE


def sweep(verbose=False, status=False):
    now = time.time()
    susp = marks(DIR)
    js = marks(JDIR)
    procs = darling_pids()
    for _, exe, start, _ in procs.values():   # relaunched soon after its kill: something needs it, back off
        k = _killed_at.get(exe)
        if k is not None and k < start < k + RELAUNCH:
            _kills[exe] = _kills.get(exe, 0) + 1
            _killed_at[exe] = None
            print("%s jetsam: %s came back %.0f s after its kill; grace now x%d" % (
                time.strftime("%H:%M:%S"), name_of(exe), start - k, 2 ** _kills[exe]), flush=True)
        elif k is not None and start >= k + RELAUNCH:
            _killed_at[exe] = None
    live = {(d, p[2]) for d, p in procs.items()}
    for key in list(_seen):
        if key not in live:
            del _seen[key]
    rows = []
    for dpid, (lpid, exe, start, cpu) in procs.items():
        st = _seen.setdefault((dpid, start), {})
        sm = susp.get(dpid)
        sm = sm if sm is not None and sm[0] + 1 >= start else None   # (a mark older than the process: a reused pid's)
        jm = js.get(dpid)
        jm = jm if jm is not None and jm[0] + 1 >= start else None
        rows.append((dpid, lpid, exe, st, sm, jm, cpu_idle(st, now, cpu)))
    apps, killed = [], []
    fg_app = False
    rows = [r for r in rows if not parked(r[2])]
    app_rows = [r for r in rows if ".app/" in r[2] and ".appex/" not in r[2] and not any(k in r[2] for k in NEVER)]
    if app_rows and now - _front["asked"] > FRONT_EVERY:
        ask_front([r[0] for r in app_rows], now)
    fs = front_state()
    inp = last_input()
    for dpid, lpid, exe, st, sm, jm, idle in app_rows:
        back, fore = app_view(exe, dpid, sm, jm, fs, now - procs[dpid][2])
        if back and not fore:
            if "bg" not in st:
                memory_warning(now)
            since = st.setdefault("bg", sm[0] if sm else now)
            st["why"] = ", ".join(back)
            if any(k in exe for k in UISVC):
                st["uisvc"] = True
            apps.append((since, lpid, dpid, exe, st))
            continue
        st.pop("bg", None)
        st["fg_seen"] = now
        if not any(k in exe for k in UISVC):
            fg_app = True
    # most recently backgrounded first; UI services last (their own grace, they never take an app's longer one)
    apps.sort(key=lambda a: (not a[4].get("uisvc"), a[0]), reverse=True)
    due = []
    for i, (since, lpid, dpid, exe, st) in enumerate(apps):
        g = grace(exe, UISVC_GRACE if st.get("uisvc") else LAST if i < KEEP else APP)
        # the user touched or typed while this app was in the foreground: not reclaimed for INPUT_KEEP s
        used = inp and now - inp < INPUT_KEEP and st.get("fg_seen", 0) >= inp - 2 * POLL
        if now - since > g and not used:
            due.append((lpid, dpid, exe, st, "app in the background %.0f s (%s)" % (now - since, st.get("why"))))
        elif status:
            print("  app    %-40s %5.0f s of %.0f (%s)%s" % (name_of(exe), now - since, g, st.get("why"),
                                                         ", in use" if used else ""))
    if due and not status:
        # right before the kill: RunningBoard's / SpringBoard's state again, fresh; anything foreground now is kept
        fresh = wait_front([d[1] for d in due])
        susp2, js2 = marks(DIR), marks(JDIR)
        for lpid, dpid, exe, st, why in due:
            sm2, jm2 = susp2.get(dpid), js2.get(dpid)
            sm2 = sm2 if sm2 is not None and sm2[0] + 1 >= _start_of(lpid) else None
            jm2 = jm2 if jm2 is not None and jm2[0] + 1 >= _start_of(lpid) else None
            back, fore = app_view(exe, dpid, sm2, jm2, fresh if fresh is not None else fs, time.time() - _start_of(lpid))
            if fore or not back:
                print("%s jetsam: kept %s (pid %d): %s" % (time.strftime("%H:%M:%S"), name_of(exe), dpid,
                      "foreground (%s)" % ", ".join(fore) if fore else "no background signal any more"), flush=True)
                st.pop("bg", None)
                continue
            killed.append((lpid, dpid, exe, why))
    # RAM 9: HOT's long grace is for app opens. At home with no touch or app for IDLE_HOT s (and IDLE_HOT after the
    # phone came up) it no longer applies: the HOT daemons that background launch waves (passd every few minutes, the
    # Siri / MobileAsset set) relaunch then exit after IDLE like the rest, not 10 min later (~100 MB at fresh home).
    warm = now - max(last_input(), START) < IDLE_HOT
    host_apps = [r for r in app_rows if not any(k in r[2] for k in UISVC)]
    for dpid, lpid, exe, st, sm, jm, idle in rows:
        if ".appex/" in exe:
            # RAM 12: WebKit's WebContent / GPU / Networking go with their host app (launchd's teardown of its
            # process-scoped services when the app is killed), not 10 s after RunningBoard suspends them: Safari kept
            # running in the background, its page's process killed, then sometimes relaunched (~200 MB at launch).
            if WEBKIT_WITH_APP and "com.apple.WebKit." in exe and host_apps:
                continue
            if any(k in exe for k in NEVER_EXT):
                continue
            if sm and now - sm[0] > grace(exe, EXT):
                killed.append((lpid, dpid, exe, "extension suspended %.0f s" % (now - sm[0])))
            continue
        if ".app/" in exe or not DAEMONS or not jm or len(jm[1]) < 2:
            continue
        dirty, name = jm[1][1], name_of(exe)
        if name in RESIDENT:
            continue
        # RAM 10: a system XPC service (a framework's .xpc bundle, ServiceType System: mediaaccessibilityd,
        # VideoSubscriberAccount.DeveloperService) is tracked without idle exit here, so the one an app's use started stayed
        # for good once the app was gone; on a device an idle XPC service is in the idle band and the first jetsam takes.
        if not (dirty & 1) or not ((dirty & 2) or name in DEMAND or (XPC_IDLE and ".xpc/" in exe)):
            continue
        if not idle or ((dirty & 4) and name not in DIRTY_OK):
            st.pop("clean", None)
            continue
        since = max(jm[0], st.setdefault("clean", now))   # clean since its last dirty flip and since we saw it idle
        g = grace(exe, max(DIRTY_IDLE, IDLE_HOT if fg_app else 0) if (dirty & 4) else IDLE_HOT if (fg_app or (name in HOT and warm)) else IDLE)
        if now - since > g:
            killed.append((lpid, dpid, exe, "daemon %s and idle %.0f s" % ("dirty" if dirty & 4 else "clean", now - since)))
        elif status:
            print("  daemon %-40s %5.0f s of %.0f" % (name, now - since, g))
    if status:
        print("  foreground app: %s" % fg_app)
        return []
    for lpid, dpid, exe, why in killed:
        try:
            os.kill(lpid, signal.SIGKILL)
            _killed_at[exe] = time.time()
            print("%s jetsam: killed %s (pid %d, %s)" % (time.strftime("%H:%M:%S"), name_of(exe), dpid, why), flush=True)
        except OSError:
            pass
    if verbose:
        print("%d suspended, %d tracked, %d killed" % (len(susp), len(js), len(killed)), flush=True)
    return killed


def main(a):
    if os.environ.get("X86SIM_JETSAM", "1") == "0":
        return
    if "--status" in a:   # what would be reclaimed and when (samples CPU over CPU_WIN first)
        t0 = time.time()
        while time.time() < t0 + CPU_WIN + POLL:
            for dpid, (lpid, exe, start, cpu) in darling_pids().items():
                cpu_idle(_seen.setdefault((dpid, start), {}), time.time(), cpu)
            time.sleep(POLL)
        sweep(status=True)
        return
    if "--once" in a:
        sweep("-v" in a)
        return
    while True:
        sweep("-v" in a)
        time.sleep(POLL)


if __name__ == "__main__":
    main(sys.argv[1:])
