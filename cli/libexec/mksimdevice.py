#!/usr/bin/env python3
"""Create a simulator device for launchd_sim under Darling.

Usage: mksimdevice.py <device dir> <job label | label=program>...

Writes <device dir>/data (the device's home, like CoreSimulator's
Devices/<UDID>/data), a LaunchDaemons directory holding only the given jobs
(copied from the runtime; label=program adds a RunAtLoad test job running a
host program, logging to data/var/log/<label>.log), launchd_bootstrap.plist and sim.env (the
environment launchd_sim is started with). The layout and keys mirror what
CoreSimulator produced on a Mac (research/macref/launchd_bootstrap.xml).
"""
import json
import os
import plistlib
import re
import shutil
import sys
import uuid

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "lib"))
import x86config  # noqa: E402  (cli/lib/config.sh: repo root, Darling prefix, runtime, state dir)

PROJECT = x86config.ROOT
RUNTIME = x86config.get("X86SIM_RUNTIME")
# x86Sim: jobs that stay eager (RunAtLoad/KeepAlive as Apple ships them); the rest start on first lookup (see below).
# sleepd: Apple ships RunAtLoad; boot-a64 std keeps it for cold-boot BKS/XPC stability. Without EAGER the
# slim-by-default pass below strips RunAtLoad and sleepd never starts under on-demand-only launchd_sim.
EAGER = {"com.apple.SpringBoard", "com.apple.backboardd", "com.apple.runningboardd", "com.apple.configd_sim",
         "com.apple.syslogd", "com.apple.UserEventAgent-System", "com.apple.distnoted.xpc.daemon",
         "com.apple.sleepd",
         # Platforms 1: tvOS's and watchOS's SpringBoard
         "com.apple.Pineboard", "com.apple.Carousel",
         # Platforms 2: visionOS's SpringBoard and the two that put its room on the screen (the simulator's virtual
         # head-mounted display, the hmd presentable server): nothing looks them up before the first frame
         "com.apple.SurfBoard", "com.apple.vhmdd", "com.apple.wakeboardd", "com.apple.RealityEnvironment"}
PREFIX = x86config.get("X86SIM_PREFIX")
MTLVK_SOCKET = os.environ.get("X86SIM_MTLVK_SOCKET") or os.path.join(x86config.get("X86SIM_STATE"), "mtlvk.sock")
# x86Sim: the host side of the simulator's audio (cli/libexec/simaudio.py, started by cli/libexec/arm64/boot-a64.sh)
AUDIO_SOCKET = os.environ.get("X86SIM_AUDIO_SOCKET") or os.path.join(x86config.get("X86SIM_STATE"), "simaudio.sock")
AUDIO = os.environ.get("X86SIM_AUDIO", "0") != "0"  # opt-in until playback works
DARLING_VIEW = "/Volumes/SystemRoot"  # Linux / as seen inside Darling
# x86Sim: a device for the arm64 runtime (iOS 27, run under libarm64jit): arm64 device types, arm64 builds of our
# in-simulator binaries (host/<name>/arm64/...; jobs and shims without one are left out), no libkqueue_sim (the arm64
# process's libsystem_kernel is Darling's own, behind the svc thunks).
# RAM 3: launchd plist XPC activities no code registers any more (see the job loop): label -> activity identifiers
STALE_ACTIVITIES = {"com.apple.searchd": ("com.apple.searchd.loadtrial", "com.apple.searchd.defrag",
                                          "com.apple.searchd.sendmlfeedback")}
DEVTYPE ={"model": "iPhone18,3", "class": "V57", "w": "1206", "h": "2622", "json": "devicetype-iphone18,3.json",
           "version": "27.0", "build": "24A434", "arch": "arm64"}


# Speed 22: arm64 devices of other models. <device>/model names an entry of cli/lib/devicetypes-a64.json (Xcode 27.2's
# device types: identifier, product class, screen, capabilities); written by `x86sim device create --model`. No file:
# iPhone 17, as before.
DEVTYPES = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "lib", "devicetypes-a64.json")


def device_type(device):
    try:
        name = open(os.path.join(device, "model")).read().strip()
    except OSError:
        name = "iPhone 17"
    with open(DEVTYPES) as f:
        dt = dict(DEVTYPE, **json.load(f)[name])
    # the runtime's own version (another iOS 27.x runtime via A64_RUNTIME)
    try:
        with open(os.path.join(RUNTIME, "System/Library/CoreServices/SystemVersion.plist"), "rb") as f:
            sv = plistlib.load(f)
        dt.update(version=sv["ProductVersion"], build=sv["ProductBuildVersion"])
    except (OSError, KeyError, plistlib.InvalidFileException):
        pass
    try:
        dt["name"] = open(os.path.join(device, "name")).read().strip() or "x86sim"
    except OSError:
        pass
    return dt


def runtime_platform(root=None):
    """Platforms 1: "ios", "tvos", "watchos" or (Platforms 2) "xros", from the runtime's SystemVersion.plist ProductName."""
    try:
        with open(os.path.join(root or RUNTIME, "System/Library/CoreServices/SystemVersion.plist"), "rb") as f:
            name = plistlib.load(f).get("ProductName", "")
    except (OSError, plistlib.InvalidFileException):
        return "ios"
    return {"Apple TVOS": "tvos", "Watch OS": "watchos", "xrOS": "xros", "visionOS": "xros"}.get(name, "ios")


PLATFORM = runtime_platform()
# Platforms 1: the platform's name in SIMULATOR_VERSION_INFO, as CoreSimulator writes it
PLATFORM_NAME = {"ios": "iOS", "tvos": "tvOS", "watchos": "watchOS", "xros": "xrOS"}[PLATFORM]


def host_path(rel):
    """Linux path of the arm64 build of one of our in-simulator binaries (rel: host/<name>/... -> host/<name>/arm64/...),
    or None if that build doesn't exist. Platforms 1: tvOS / watchOS runtimes take host/<name>/arm64-tvos|-watchos (dyld_sim
    loads only Mach-Os built for its own platform), never the iOS build."""
    a, b, rest = rel.split("/", 2)
    p = "/".join([PROJECT, a, b, "arm64" if PLATFORM == "ios" else "arm64-" + PLATFORM, rest])
    return p if os.path.exists(p) else None


def darling(path):
    return DARLING_VIEW + path


def feature_enabled(name):
    """x86Sim (Speed 25): a FeatureFlags flag "Domain/flag" as the runtime's own code sees it
    (<runtime>/System/Library/FeatureFlags/Domain/<Domain>.plist): its Enabled key, else on when FeatureComplete."""
    dom, _, flag = name.partition("/")
    # a device's own override (<device>/data/Library/Preferences/FeatureFlags/Domain/<Domain>.plist) wins
    dev = os.environ.get("X86SIM_DEVICE", "")
    try:
        with open(os.path.join(dev, "data/Library/Preferences/FeatureFlags/Domain", dom + ".plist"), "rb") as f:
            o = plistlib.load(f).get(flag)
        if isinstance(o, dict) and "Enabled" in o:
            return bool(o["Enabled"])
    except (OSError, plistlib.InvalidFileException):
        pass
    try:
        with open(os.path.join(RUNTIME, "System/Library/FeatureFlags/Domain", dom + ".plist"), "rb") as f:
            e = plistlib.load(f).get(flag)
    except (OSError, plistlib.InvalidFileException):
        return False
    if not isinstance(e, dict):
        return False
    if "Enabled" in e:
        return bool(e["Enabled"])
    return e.get("DevelopmentPhase") == "FeatureComplete"


_COND = ("#IfFeatureFlagEnabled", "#IfFeatureFlagDisabled", "#IfVariant")


def _cond_true(v):
    if "#IfFeatureFlagEnabled" in v:
        return feature_enabled(v["#IfFeatureFlagEnabled"])
    if "#IfFeatureFlagDisabled" in v:
        return not feature_enabled(v["#IfFeatureFlagDisabled"])
    return False   # #IfVariant (HasInternalContent, ...): a customer build has none of them


def resolve_feature_flags(v):
    """x86Sim (Speed 25): resolve launchd's {"#IfFeatureFlagEnabled": flag, "#Then": a, "#Else": b} values with the
    runtime's FeatureFlags. launchd_sim judged them by the host side's flags (no such domain: off), while the code in
    the simulator reads the runtime's: on 27.2 InputUI's com.apple.UIKit.KeyboardManagement.hosted (UIKit/
    kbarbiter_in_inputui, FeatureComplete) was never registered, UIKit looked for the keyboard arbiter in InputUI and
    no keyboard ever appeared. A "#Else": False drops the key.
    Platforms 2: also #IfFeatureFlagDisabled and #IfVariant (launchd_sim rejects a plist with either: "Found unsupported
    directives", visionOS's wakeboardd never loaded), and the merged form where the condition sits among ordinary keys
    ({"#IfVariant": v, "#Then": {...}, "OS_ACTIVITY_DT_MODE": "1"}): the keys plus the chosen branch's."""
    if isinstance(v, dict):
        if any(c in v for c in _COND):
            branch = v.get("#Then" if _cond_true(v) else "#Else", False)
            rest = {k: x for k, x in v.items() if not k.startswith("#")}
            if not rest:
                return resolve_feature_flags(branch)
            out = resolve_feature_flags(rest)
            if isinstance(branch, dict):
                out.update(resolve_feature_flags(branch))
            return out
        out = {}
        for k, x in v.items():
            r = resolve_feature_flags(x)
            if r is False and isinstance(x, dict) and any(c in x for c in _COND):
                continue
            out[k] = r
        return out
    if isinstance(v, list):
        return [resolve_feature_flags(x) for x in v]
    return v


def runtime_climb_depth():
    """Number of /.. needed so xpcproxy_sim's access(RuntimeRoot + program) reaches /.

    RuntimeRoot is often a symlink into extracted/.../RuntimeRoot. access(2) walks the
    physical target before applying '..', so depth must use realpath. The arm64
    ios-27 symlink is 9 components long but 18 physically; with the short depth,
    host jobs (metalhostd, iosurfaced, mtlprobe) failed with exit 78 / ENOENT.
    """
    return len(darling(os.path.realpath(RUNTIME)).strip("/").split("/"))


def main():
    device = os.path.abspath(sys.argv[1])
    jobs = sys.argv[2:]
    udid = str(uuid.uuid5(uuid.NAMESPACE_URL, device)).upper()
    data = device + "/data"

    for d in ["tmp", "var/run", "var/db", "var/log", "Library/Preferences", "Library/Logs",
              "Library/Application Support/Simulator", "Library/LaunchDaemons"]:
        os.makedirs(os.path.join(data, d), exist_ok=True)
    open(data + "/var/run/memory_warning_simulation", "a").close()
    # Platforms 1: the photo library's folder. On iOS assetsd makes it; tvOS / watchOS run no photos daemon, and the
    # watch's nanotimekitd (the Photos face) opened Media/PhotoData/Photos.sqlite at every start and threw ("Error
    # validating url for store": CoreData could not statfs the missing folder).
    if PLATFORM != "ios":
        os.makedirs(os.path.join(data, "Media/PhotoData"), exist_ok=True)

    # x86Sim: Siri's session language, as a Mac's simulator device has it (assistantd sets it there; it doesn't run
    # here). Without it AFPreferences logs "No language code saved, but Assistant is enabled" and recomputes the
    # language in a loop on the main thread: Spotlight and Safari spun at 100% CPU and Safari's typing stalled.
    ap = os.path.join(data, "Library/Preferences/com.apple.assistant.backedup.plist")
    try:
        with open(ap, "rb") as f:
            prefs = plistlib.load(f)
    except Exception:
        prefs = {}
    if "Session Language" not in prefs:
        prefs["Session Language"] = "en-US"
        with open(ap, "wb") as f:
            plistlib.dump(prefs, f, fmt=plistlib.FMT_BINARY)

    # x86Sim: the device's language and region, which CoreSimulator writes into a new device's .GlobalPreferences
    # (AppleLanguages + AppleLocale, from the Mac user's settings; seen in a fresh `simctl create` before any boot).
    # Here from the Linux locale, only when the device has none yet. Without them (the tvOS and watchOS devices had
    # none) the locale was en_001 (region "001", the world) and region-dependent API failed: DataDetection found no
    # phone numbers, CNPostalAddressFormatter returned "" for an address without a country.
    gp = os.path.join(data, "Library/Preferences/.GlobalPreferences.plist")
    try:
        with open(gp, "rb") as f:
            prefs = plistlib.load(f)
    except FileNotFoundError:
        prefs = {}
    except Exception:
        prefs = None  # unreadable: left alone
    if prefs is not None and ("AppleLanguages" not in prefs or "AppleLocale" not in prefs):
        loc = ""
        for v in ("LC_ALL", "LC_MESSAGES", "LANG"):
            loc = os.environ.get(v, "")
            if loc:
                break
        loc = loc.split(".")[0].split("@")[0]
        if not re.fullmatch(r"[a-z]{2,3}_[A-Z]{2}", loc):
            loc = "en_US"
        prefs.setdefault("AppleLocale", loc)
        prefs.setdefault("AppleLanguages", [loc.replace("_", "-")])
        with open(gp, "wb") as f:
            plistlib.dump(prefs, f, fmt=plistlib.FMT_BINARY)

    daemons = device + "/LaunchDaemons"
    shutil.rmtree(daemons, ignore_errors=True)
    os.makedirs(daemons)
    # x86Sim: LaunchAngels (UI services launched on demand, e.g. PosterBoard, which draws the wallpaper) live
    # in their own directory; CoreSimulator hands launchd_sim that path too. arm64 (Speed 16): if
    # launchd_sim does not see them as angels, RunningBoard says osservice<com.apple.campo> is no angel, FrontBoard gives
    # Campo a plain FBProcess and SpringBoard's Siri scene transaction asserts ("process was nil").
    angels = device + "/LaunchAngels"
    # launchd_sim takes a plist's path from the open file (F_GETPATH: canonical) and makes the job an angel only
    # if it starts with <SimulatorRuntimeRoot>/System/Library/LaunchAngels/. So the device's angels go into its
    # own hidden subdirectory of the runtime's (real) LaunchAngels directory, and SimulatorRuntimeRoot (below)
    # is the canonical runtime path, as the cryptex mount is on a Mac.
    shutil.rmtree(angels, ignore_errors=True)
    angels = os.path.join(os.path.realpath(os.path.join(RUNTIME, "System/Library/LaunchAngels")),
                          ".x86sim-" + os.path.basename(os.path.abspath(device)))
    shutil.rmtree(angels, ignore_errors=True)
    os.makedirs(angels)
    for job in jobs:
        if "=" in job:
            # x86Sim: label=program[|arg|...|mach:<service name>|env:K=V]: extra arguments; mach: entries become MachServices
            label, program = job.split("=", 1)
            parts = program.split("|")
            program, extra = parts[0], parts[1:]
            # x86Sim: env:K=V entries become EnvironmentVariables
            envs = dict(a[4:].split("=", 1) for a in extra if a.startswith("env:"))
            args = [a for a in extra if not a.startswith("mach:") and not a.startswith("env:")]
            mach = {a[5:]: True for a in extra if a.startswith("mach:")}
            log = darling(data + "/var/log/" + label + ".log")
            # xpcproxy_sim prefixes program paths with the runtime root: climb exactly back out of it
            depth = runtime_climb_depth()
            program = "/.." * depth + darling(os.path.abspath(program))
            job_plist = {"Label": label, "ProgramArguments": [program] + args,
                         "RunAtLoad": True, "StandardOutPath": log, "StandardErrorPath": log,
                         # X86SIM_KEEPALIVE=1: respawn every 10 s (to attach debuggers)
                         "KeepAlive": os.environ.get("X86SIM_KEEPALIVE") == "1", "ThrottleInterval": 10}
            if mach:
                job_plist["MachServices"] = mach
            if envs:
                job_plist["EnvironmentVariables"] = envs
            with open(os.path.join(daemons, label + ".plist"), "wb") as f:
                plistlib.dump(job_plist, f)
            continue
        src, dst = os.path.join(RUNTIME, "System/Library/LaunchDaemons", job + ".plist"), daemons
        if not os.path.exists(src):
            src, dst = os.path.join(RUNTIME, "System/Library/LaunchAngels", job + ".plist"), angels
        with open(src, "rb") as f:
            plist = plistlib.load(f)
            # X86SIM_FF_SKIP=label,...: leave these jobs' feature-flag conditionals to launchd_sim (experiments)
            if job not in os.environ.get("X86SIM_FF_SKIP", "").split(","):
                plist = resolve_feature_flags(plist)
        # launchd_sim's system domain never leaves bootstrap mode here (on a Mac something,
        # presumably CoreSimulator, ends it), so system-only jobs are loaded into the user
        # domain instead, where all lookups from the device's jobs resolve.
        if plist.get("LimitLoadToSessionType") == "System":
            del plist["LimitLoadToSessionType"]
        # x86Sim: slim by default. launchd_sim starts a job with MachServices at the first lookup of one of them; what
        # RunAtLoad / KeepAlive (true, or SuccessfulExit) starts eagerly at boot runs whether anything uses it or not
        # (assistantd, locationd, identityservicesd, ids_simd, navd, revisiond, amsaccountsd: ~100 MB each
        # here). Those become on-demand, except what the home screen itself needs (EAGER). X86SIM_EAGER=1: Apple's.
        if os.environ.get("X86SIM_EAGER") != "1" and job not in EAGER and plist.get("MachServices"):
            plist.pop("RunAtLoad", None)
            ka = plist.get("KeepAlive")
            if ka is True or (isinstance(ka, dict) and "SuccessfulExit" in ka):
                del plist["KeepAlive"]
        # arm64: launchd_sim never leaves on-demand-only; SpringBoard is still spawned as "system support"
        # immediately while backboardd stays pending then speculative. If launchd_sim later aborts, SB's
        # late BKSHIDEventDeliveryManager init sees a nil connection and brk#0. Keep RunAtLoad for now
        # (home needs SB); sleepd EAGER above is the cold-boot BKS stabilizer. Optional delay: set
        # X86SIM_DELAY_SB=1 to drop SpringBoard RunAtLoad (caller must kickstart after backboardd).
        if job == "com.apple.SpringBoard" and os.environ.get("X86SIM_DELAY_SB") == "1":
            plist.pop("RunAtLoad", None)
        if os.environ.get("X86SIM_JOBLOG") == "1":
            # X86SIM_JOBLOG=1: job output and os_log (OS_ACTIVITY_DT_MODE) to data/var/log/<label>.log
            log = darling(data + "/var/log/" + job + ".log")
            plist.update({"StandardOutPath": log, "StandardErrorPath": log})
            # X86SIM_NODT=label,...|all: not for these (DT mode also streams every log line to
            # diagnosticd, and a sender blocks when diagnosticd stops draining)
            nodt = os.environ.get("X86SIM_NODT", "").split(",")
            # x86Sim: "all,-label" keeps DT mode (os_log in the job's log) for that label only
            if ("-" + job) in nodt or (job not in nodt and "all" not in nodt):
                plist.setdefault("EnvironmentVariables", {})["OS_ACTIVITY_DT_MODE"] = "1"
            else:
                # no logd here either: without this libtrace streams to diagnosticd anyway
                plist.setdefault("EnvironmentVariables", {})["OS_ACTIVITY_MODE"] = "disable"
        # x86Sim arm64: assistantd is Apple's plist (Speed 26). Speed 13 kept only com.apple.assistant.dictation; on
        # iOS 27.2 the keyboard's dictation availability check also asks com.apple.assistant.settings, and each failed
        # lookup posted "availability changed": the keyboard dock re-checked, the app's main thread spun (~75% CPU),
        # hardware keys never reached the text field, and Siri had no assistant. X86SIM_ASSISTANTD=dictation: the old
        # slim plist (experiments only; it turns features off).
        if job == "com.apple.assistantd" and os.environ.get("X86SIM_ASSISTANTD") == "dictation":
            plist.pop("LaunchEvents", None)
            keep = os.environ.get("X86SIM_ASSISTANTD_MACH", "com.apple.assistant.dictation").split(",")
            plist["MachServices"] = {k: True for k in plist.get("MachServices", {}) if k in keep}
        # x86Sim RAM 3: XPC activities the plist declares but the daemon's code no longer registers (no
        # xpc_activity_register of that identifier anywhere in iOS 27.2). launchd_sim runs one once its Delay has passed
        # (searchd's loadtrial: at every launch after the first hour of a device), libxpc holds a transaction for it
        # until the process checks it in, which never happens: searchd stayed dirty for good and was never
        # reclaimed (~100 MB). On a device dasd expires an activity nobody checks in.
        for act in STALE_ACTIVITIES.get(job, ()):
            plist.get("LaunchEvents", {}).get("com.apple.xpc.activity", {}).pop(act, None)
        # x86Sim: X86SIM_JOBENV="label:K=V;label:K=V": extra environment for runtime jobs (experiments)
        for kv in filter(None, os.environ.get("X86SIM_JOBENV", "").split(";")):
            lab, _, ev = kv.partition(":")
            if lab == job and "=" in ev:
                k, v = ev.split("=", 1)
                plist.setdefault("EnvironmentVariables", {})[k] = v
        with open(os.path.join(dst, job + ".plist"), "wb") as f:
            plistlib.dump(plist, f)

    # x86Sim arm64 (Speed 26): the canonical runtime path (runtimes/<rt>/RuntimeRoot is a symlink into extracted/...), as a
    # Mac's mounted runtime has none. dyld_sim takes its simulator root as the realpath and strips only that prefix, so
    # with the symlinked root _dyld_shared_cache_contains_path("<root>/System/Library/Frameworks/WebKit.framework/WebKit")
    # was false: CFBundle found no executable for cache-only frameworks and WebKit's WebContent/Networking/GPU services
    # exited at once ("Unable to find entry point in WebKit.framework"): Safari never loaded a page.
    rt, home = darling(os.path.realpath(RUNTIME)), darling(data)
    # x86Sim: the device type's capabilities (cli/lib/devicetype-<model>.json), written as a plist for MobileGestalt
    capabilities = device + "/capabilities.plist"
    dt = device_type(device)
    with open(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "lib", dt["json"])) as f:
        caps = json.load(f)
    # Platforms 1: device types sharing a model's capabilities but not its screen (Apple TV 4K "at 1080p": the 4K
    # model's file says 3840x2160): the main display takes the device type's own size
    disp = caps.get("capabilities", {}).get("displays") or []
    if disp and str(disp[0].get("width")) != dt["w"]:
        disp[0]["width"], disp[0]["height"] = int(dt["w"]), int(dt["h"])
        sd = caps["capabilities"].get("ScreenDimensionsCapability", {})
        sd["main-screen-width"], sd["main-screen-height"] = dt["w"], dt["h"]
        # Platforms 2: Apple Vision Pro "at 1080p" also halves the scale (the same 1920x1080 points, a quarter of
        # the pixels to composite, read back and show)
        scale = float(dt["scale"])
        if "scale" in disp[0] and disp[0]["scale"] != scale:
            disp[0]["scale"] = int(scale) if scale.is_integer() else scale
            sd["main-screen-scale"] = disp[0]["scale"]
            sd["main-screen-pitch"] = float(dt["pitch"])
    # x86Sim: no always-on display. With always-on-time (iPhone Pro, Apple Watch) a sleeping device's dimmed lock
    # screen / watch face is rendered ahead as a flipbook, one frame per coming minute, which the hardware shows when
    # each minute arrives. SimFramebuffer shows every frame as it is drawn, so the asleep screen (and the first frame
    # after waking) showed clocks minutes ahead, then the real time. Asleep is now a dark screen, as on a phone
    # without always-on. X86SIM_ALWAYS_ON=1 keeps the device type's value.
    if os.environ.get("X86SIM_ALWAYS_ON") != "1" and "always-on-time" in caps.get("capabilities", {}):
        caps["capabilities"]["always-on-time"] = False
    with open(capabilities, "wb") as f:
        plistlib.dump(caps, f)
    # Stand-in for the host's configd: configd_sim's SimulatorSupport plugin opens the
    # Mac's dynamic store (com.apple.SystemConfiguration.configd) to mirror network
    # state. A second configd_sim without plugins, registered under that name, serves it.
    hostcfg = {"Label": "com.x86sim.host-configd",
               "ProgramArguments": ["/usr/libexec/configd_sim", "-b"],
               "EnvironmentVariables": {"SCD_SERVER": "com.apple.SystemConfiguration.configd"},
               "MachServices": {"com.apple.SystemConfiguration.configd": True}}
    if os.environ.get("X86SIM_JOBLOG") == "1":
        log = darling(data + "/var/log/com.x86sim.host-configd.log")
        hostcfg.update({"StandardOutPath": log, "StandardErrorPath": log})
        hostcfg["EnvironmentVariables"]["OS_ACTIVITY_DT_MODE"] = "1"
    with open(os.path.join(daemons, "com.x86sim.host-configd.plist"), "wb") as f:
        plistlib.dump(hostcfg, f)

    # x86Sim: the host's network configuration in that store (what a Mac's configd publishes: Setup:/State: service
    # and interface keys of the primary interface), from Linux (linux/hostnet/hostnet.py), loaded by netconfig.
    # configd_sim's SimulatorSupport mirrors it into the simulator, whose IPMonitor derives State:/Network/Global/IPv4,
    # DNS and the nw_path/reachability state from it. X86SIM_NETCONFIG=0 leaves it out.
    if os.environ.get("X86SIM_NETCONFIG", "1") != "0" and host_path("host/netconfig/netconfig"):
        import subprocess
        hostnet = data + "/var/run/x86sim-hostnet.plist"
        subprocess.run([sys.executable, PROJECT + "/linux/hostnet/hostnet.py", hostnet], check=False)
        depth = runtime_climb_depth()
        log = darling(data + "/var/log/com.x86sim.netconfig.log")
        with open(os.path.join(daemons, "com.x86sim.netconfig.plist"), "wb") as f:
            plistlib.dump({"Label": "com.x86sim.netconfig",
                           "ProgramArguments": ["/.." * depth + darling(host_path("host/netconfig/netconfig")),
                                                darling(hostnet)],
                           "EnvironmentVariables": {"X86SIM_HOST_STORE": "1",
                                                    "OS_ACTIVITY_MODE": "disable"},
                           "RunAtLoad": True, "StandardOutPath": log, "StandardErrorPath": log}, f)

    # x86Sim: the Metal stand-in (host/metalhostd): metalhostd serves the simulator's Metal transport on mtlvk
    # (Vulkan, a Linux process started by cli/libexec/arm64/boot-a64.sh; the launcher passes X86SIM_METAL=all).
    # Opt-in: X86SIM_METAL=1 registers
    # it for the test client (process "mtlprobe"), X86SIM_METAL=name,name for those processes,
    # X86SIM_METAL=all also under the generic com.apple.metal.simulator, which hands a device to every process
    # (CoreAnimation, the wallpaper poster, apps).
    metal = os.environ.get("X86SIM_METAL", "")
    if metal and metal != "0" and host_path("host/metalhostd/metalhostd"):
        procs = ["mtlprobe"] if metal == "1" else [p for p in metal.split(",") if p and p != "all"]
        names = ["com.apple.metal.simulator." + p for p in procs]
        if "all" in metal.split(","):
            names.append("com.apple.metal.simulator")
        log = darling(data + "/var/log/com.x86sim.metalhostd.log")
        depth = runtime_climb_depth()
        menv = {"X86SIM_METAL_NAMES": ",".join(names), "OS_ACTIVITY_MODE": "disable",
                # x86Sim: mtlvk's socket (Linux path; metalhostd prefixes /Volumes/SystemRoot)
                "X86SIM_MTLVK_SOCKET": MTLVK_SOCKET}
        for k in ("X86SIM_VKMTL_LOG", "X86SIM_VKMTL_DUMP", "X86SIM_METAL_PROFILE"):
            if os.environ.get(k):
                menv[k] = os.environ[k]
        with open(os.path.join(daemons, "com.x86sim.metalhostd.plist"), "wb") as f:
            # RunAtLoad: under the A64 JIT, on-demand spawn+warmup of metalhostd is slow enough that
            # CoreAnimation can time out waiting for com.apple.metal.simulator.*; start it at boot.
            plistlib.dump({"Label": "com.x86sim.metalhostd",
                           "ProgramArguments": ["/.." * depth + darling(host_path("host/metalhostd/metalhostd"))],
                           "MachServices": {n: True for n in names}, "EnvironmentVariables": menv,
                           "RunAtLoad": True, "KeepAlive": True,
                           "StandardOutPath": log, "StandardErrorPath": log}, f)
        # x86Sim: iOS 27 MTLCompiler lives on disk as Metal.framework/XPCServices/MTLCompilerService.xpc
        # (moved out of the dyld cache). launchd_sim discovers it as a multi-instance Application XPC
        # service. Do NOT install a single-instance LaunchDaemon for the
        # same label: that makes "create copy of service" fail with error 137 and every pipeline dies.
        # A64: Metal.framework's executable is cache-only; without an on-disk Metal binary, xpc_bundle
        # cannot resolve the framework and MTLCompiler lookups are "No such process" (error 3).
        # cli/libexec/arm64/ensure-metal-framework.sh extracts Metal from the dyld cache into the
        # framework (runtimes/ is gitignored; never commit the binary).

    # x86Sim: cross-process IOSurfaces (host/iosurfaced): iosurfaced serves com.apple.IOSurface.Remote (what
    # CoreSimulator's SimRenderServer does on a Mac) and IOSURFACE_REMOTE_EMULATED is not set, so every process's
    # IOSurface.framework uses it. X86SIM_IOSURFACE=0 goes back to per-process emulation.
    iosurface = os.environ.get("X86SIM_IOSURFACE", "1") not in ("", "0") and bool(host_path("host/iosurfaced/iosurfaced"))
    if iosurface:
        log = darling(data + "/var/log/com.x86sim.iosurfaced.log")
        depth = runtime_climb_depth()
        ienv = {"OS_ACTIVITY_MODE": "disable"}
        if os.environ.get("X86SIM_IOSURFACE_LOG"):
            ienv["X86SIM_IOSURFACE_LOG"] = "1"
        with open(os.path.join(daemons, "com.x86sim.iosurfaced.plist"), "wb") as f:
            plistlib.dump({"Label": "com.x86sim.iosurfaced",
                           "ProgramArguments": ["/.." * depth + darling(host_path("host/iosurfaced/iosurfaced"))],
                           "MachServices": {"com.apple.IOSurface.Remote": True}, "EnvironmentVariables": ienv,
                           "KeepAlive": True, "StandardOutPath": log, "StandardErrorPath": log}, f)

    if os.environ.get("X86SIM_BOOTSTRAP_SYSTEM") == "1":
        # X86SIM_BOOTSTRAP_SYSTEM=1: experimental job asking launchd_sim to bootstrap the
        # system domain (on a Mac it leaves bootstrap mode; here it never does)
        log = darling(data + "/var/log/com.x86sim.bootstrap-system.log")
        with open(os.path.join(daemons, "com.x86sim.bootstrap-system.plist"), "wb") as f:
            plistlib.dump({"Label": "com.x86sim.bootstrap-system",
                           "ProgramArguments": ["/bin/launchctl", "bootstrap", "system", darling(daemons)],
                           "RunAtLoad": True, "StandardOutPath": log, "StandardErrorPath": log}, f)
    child_defaults = {
        # X86SIM_INSERT: extra ':'-separated dylibs (host paths) for diagnostics
        # simshim: stand-ins for host services (host/simshim/compat/simshim.c)
        # simaudio: the audio devices (host/simaudio, opt-in: X86SIM_AUDIO=1)
        "DYLD_INSERT_LIBRARIES": ":".join(
                                          [darling(p) for p in [host_path("host/simshim/compat/libsimshim.dylib")] if p] +
                                          [darling(p) for p in [host_path("host/simaudio/libsimaudio.dylib")] if p and AUDIO] + [darling(os.path.abspath(p))
                                          for p in os.environ.get("X86SIM_INSERT", "").split(":") if p]),
        "CFFIXED_USER_HOME": home,
        "HOME": home,
        "TMPDIR": home + "/tmp/",
        "DYLD_FALLBACK_FRAMEWORK_PATH": rt + "/System/Library/Frameworks",
        "DYLD_FALLBACK_LIBRARY_PATH": rt + "/usr/lib",
    }
    env = dict(child_defaults)
    env.update({
        "DYLD_ROOT_PATH": rt,
        "IPHONE_SIMULATOR_ROOT": rt,
        "SIMULATOR_ROOT": rt,
        "IPHONE_SHARED_RESOURCES_DIRECTORY": home,
        "SIMULATOR_SHARED_RESOURCES_DIRECTORY": home,
        "PATH": ":".join(rt + p for p in ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]),
        "SIMULATOR_ARCHS": DEVTYPE["arch"],
        # x86Sim: libarm64jit's log (guest crashes, unimplemented thunks) per process, inside the container
        "X86SIM_A64_LOG": "/private/var/tmp/x86sim-a64",
        # x86Sim: glibc malloc of libarm64jit/dynarmic (the ELF side): one arena per thread kept tens of MB of freed
        # JIT metadata resident per thread; two arenas for the process
        # RAM 1: A64_GLIBC_TUNABLES_EXTRA appends tunables (e.g. glibc.mem.decorate_maps=1 names arenas/stacks in smaps)
        "GLIBC_TUNABLES": ":".join(filter(None, ["glibc.malloc.arena_max=2:glibc.malloc.trim_threshold=1048576",
                                                 os.environ.get("A64_GLIBC_TUNABLES_EXTRA", "")])),
        # Speed 8: in /run/user/<uid> (the arm64 container's /dev/shm is private, X86SIM_PRIVATE_SHM); boot-a64.sh links
        # /dev/shm/x86sim-a64-simfb.ring to it for the host's viewers
        # one ring per phone, named like the launcher's ring_for (instance.rs): device-a64 -> x86sim-a64-simfb.ring,
        # device-a64-<name> -> x86sim-a64-<name>-simfb.ring. A shared default let a second phone's boot recreate the
        # main phone's ring, freezing its screen while its apps ran on.
        "SIMFB_RING": os.environ.get("SIMFB_RING") or "/Volumes/SystemRoot/run/user/%d/x86sim-%s-simfb.ring" % (
            os.getuid(), os.path.basename(device.rstrip("/")).removeprefix("device-")),
        # Speed 3: launchd jobs only see Bootstrap.Child, so the JIT flags must be copied here to reach backboardd and
        # SpringBoard. Speed 6: every X86SIM_A64_* flag (was a list that missed new ones, e.g. PERFMAP). X86SIM_SCRATCH: the
        # JIT's scratch dir (a64-penv, a64-slim-park, gbt, crash dumps); without it the JIT falls back to the home of its
        # uid, which in a user-namespace phone (the AppImage's) is 0: /root/scratch, unreadable, and all of those were off.
        **{k: v for k, v in os.environ.items()
           if (k.startswith("X86SIM_A64_") and k not in ("X86SIM_A64_EXE", "X86SIM_A64_LOG"))
           or k in ("SIMFB_HZ", "X86SIM_SCRATCH", "X86SIM_OSLOG", "X86SIM_OSLOG_DIR")},   # X86SIM_OSLOG: every os_log level of those programs (libsimshim)
        "SIMULATOR_UDID": udid,
        "SIMULATOR_DEVICE_NAME": dt.get("name", "x86sim"),
        "SIMULATOR_RUNTIME_VERSION": dt["version"],
        "SIMULATOR_RUNTIME_BUILD_VERSION": dt["build"],
        "SIMULATOR_MODEL_IDENTIFIER": dt["model"],
        "SIMULATOR_PRODUCT_CLASS": dt["class"],
        "SIMULATOR_MAINSCREEN_WIDTH": dt["w"],
        "SIMULATOR_MAINSCREEN_HEIGHT": dt["h"],
        "SIMULATOR_MAINSCREEN_SCALE": dt["scale"],
        "SIMULATOR_MAINSCREEN_PITCH": dt["pitch"],
        "SIMULATOR_LEGACY_ASSET_SUFFIX": dt["suffix"],
        # x86Sim: the device type's capabilities (CoreSimulator: <device type>.simdevicetype/Contents/Resources/
        # capabilities.plist), which libMobileGestalt answers from (ArtworkTraits, displays, DeviceCornerRadius, ...).
        # Without it the runtime's apps got by, but an installed app aborted in UIKit's
        # -[_UIScreenComplexBoundingPathUtilities _loadBitmapForScreen:type:] (no kMGArtworkDeviceIdiom).
        "SIMULATOR_CAPABILITIES": darling(capabilities),
        "SIMULATOR_HOST_HOME": home,
        "SIMULATOR_LOG_ROOT": home + "/Library/Logs",
        # x86Sim: the simulator's libdispatch implements DISPATCH_SOURCE_TYPE_MEMORYPRESSURE as an EVFILT_VNODE watch
        # (NOTE_ATTRIB) on this file (CoreSimulator touches it for "Simulate Memory Warning"); without it the source
        # is registered on fd -1 and libdispatch crashes the process (fileproviderd in LaunchServices' memory warning
        # listener). A Mac's device has the same empty file and variable.
        "SIMULATOR_MEMORY_WARNINGS": home + "/var/run/memory_warning_simulation",
        "SIMULATOR_BOOT_TIME": str(int(os.path.getmtime(data))),
        "SIMULATOR_VERSION_INFO": "x86Sim - Device: x86sim (%s) - Runtime: %s %s (%s)" % (udid, PLATFORM_NAME, dt["version"],
                                                                                               dt["build"]),
        "XPC_SIMULATOR_LAUNCHD_NAME": "com.apple.CoreSimulator.SimDevice." + udid,
        # x86Sim: no XPC_SERVICE_NAME here. launchd_sim gives each job XPC_SERVICE_NAME=<label> only when its own
        # environment has none, so every job inherited the device's name: lsd's [NSProcessInfo bs_jobLabel] wasn't
        # com.apple.lsd and FrontBoardServices' "LaunchServices-only" assertion aborted lsd on every openURL.
        "LS_ENABLE_BUNDLE_LOCALIZATION_CACHING": "1",
        # x86Sim: no CoreSimulator host; IOSurface allocates in-process, our SimFramebuffer fakes the display
        **({} if iosurface else {"IOSURFACE_REMOTE_EMULATED": "1"}),
        # x86Sim: metalhostd is in-sim (not Mac SimMetalHost). simshim skips sim2host framing for
        # com.apple.metal.simulator* and, when this is set, for enable_sim2host calls before set_name (iOS 27).
        **({"X86SIM_METAL_IN_SIM": "1"} if metal else {}),
        **({"X86SIM_SIMSHIM_XPC_LOG": "1"} if os.environ.get("X86SIM_SIMSHIM_XPC_LOG") else {}),
        # X86SIM_SHIMLOG=1: simshim logs what it intercepts
        **({"X86SIM_SHIMLOG": "1"} if os.environ.get("X86SIM_SHIMLOG") else {}),
        **({"X86SIM_AUDIO_SOCKET": darling(AUDIO_SOCKET)} if AUDIO else {}),
        **({"X86SIM_AUDIO_LOG": "1"} if os.environ.get("X86SIM_AUDIO_LOG") else {}),
        **({"SIMULATOR_FRAMEBUFFER_FRAMEWORK": darling(host_path("host/simfb/SimFramebuffer.framework/SimFramebuffer"))}
           if host_path("host/simfb/SimFramebuffer.framework/SimFramebuffer") else {}),
        # x86Sim: our SimulatorHID stand-in (host/simhid): backboardd's virtual touchscreen/buttons/keyboard,
        # fed through <data>/simhid.sock by cli/libexec/simview.py / cli/libexec/simtouch.py. X86SIM_HID=0 leaves it out.
        **({} if os.environ.get("X86SIM_HID") == "0" or not host_path("host/simhid/SimulatorHID.framework") else
           {"SIMULATOR_HID_SYSTEM_MANAGER": darling(host_path("host/simhid/SimulatorHID.framework"))}),
    })

    bootstrap = {
        "AbortOnUnknownIPC": True,
        "CrashOnSIGTERMTimeout": False,
        "ExtensionWatchdog": 0,
        "LogServiceLifecycle": True,
        "LogToFlatFile": True,
        "RequireDomainBinding": True,
        "SIGTERMTimeout": 3,
        "UseGuardMalloc": False,
        "Bootstrap": {
            "BinaryOrderPreference": DEVTYPE["arch"],
            "CheckedAllocationsPosixSpawnFlagsGlobal": False,
            # As CoreSimulator's: HOME, CFFIXED_USER_HOME and TMPDIR are only defaults, so an
            # app's own values (its data container, set by RunningBoard) win; "Child" would force them
            "Child": {k: v for k, v in env.items() if k not in ("HOME", "CFFIXED_USER_HOME", "TMPDIR")},
            "ChildDefaults": child_defaults,
            "Self": env,
            "Paths": [darling(daemons), darling(angels)],
            "SimulatorRuntimeRoot": rt,
        },
    }
    # X86SIM_LAUNCHD_LOGIPC=1: launchd_sim logs its IPC and every bootstrap error (debugging)
    if os.environ.get("X86SIM_LAUNCHD_LOGIPC") == "1":
        bootstrap.update(LogIPC=True, LogAllBootstrapErrors=True)
    with open(data + "/var/run/launchd_bootstrap.plist", "wb") as f:
        plistlib.dump(bootstrap, f)
    with open(device + "/sim.env", "w") as f:
        for k, v in env.items():
            f.write("%s=%s\n" % (k, v))
    print(device, udid)


if __name__ == "__main__":
    main()
