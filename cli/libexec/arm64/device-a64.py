#!/usr/bin/env python3
"""x86Sim (Speed 22): arm64 devices of other phone models.

    device-a64.py models                         the models (cli/lib/devicetypes-a64.json, from Xcode 27.2: tools/devicetypes/extract-devicetypes.py)
    device-a64.py list                           var/device-a64* with model and screen
    device-a64.py create --model MODEL [--ios 27.x] [NAME]
                                                 new var/device-a64-<name>: <device>/model, runtime (+ name), sim.env
    device-a64.py runtimes                       the iOS versions in runtimes/ (version, build, dir)

A new device gets a copy (reflinks) of var/device-a64's data/ when that has booted once (apps registered, setup
done), so its first boot is a normal boot (device-repath.py moves its absolute paths to the new device); mksimdevice.py writes the model's screen, identifiers and capabilities.
Speed 24: --ios picks the runtime (default 27.2); <device>/runtime names its runtimes/ dir and boot-a64.sh boots the
device on it. Only a 27.0 device gets the copy (another version's data has its own first boot).
Boot one with A64_DEVICE=var/device-a64-<name> cli/libexec/arm64/boot-a64.sh (or the launcher).
"""
import json
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
TYPES = os.path.join(ROOT, "cli/lib/devicetypes-a64.json")
VAR = os.path.join(ROOT, "var")
BASE = os.path.join(VAR, "device-a64")


def models():
    with open(TYPES) as f:
        return json.load(f)


DEFAULT_RT = "ios-27.2-24B8117-arm64"
MAX_SLUG = 24  # device-a64-<slug>: see create


def runtimes():
    """[(version, build, dir)] of the arm64 runtimes in runtimes/, oldest first."""
    out = []
    for d in os.listdir(os.path.join(ROOT, "runtimes")):
        m = re.match(r"ios-([0-9.]+)-([0-9A-Za-z]+)-arm64$", d)
        if m and os.path.isdir(os.path.join(ROOT, "runtimes", d, "RuntimeRoot")):
            out.append((m[1], m[2], d))
    return sorted(out, key=lambda r: ([int(x) for x in r[0].split(".")], bool(restricted_to(r[2])), r[1]))


def restricted_to(rt):
    """Models 2: the model ids a runtime is limited to (its profile's restrictedToDeviceTypes; [] = any). iOS 27.2
    24B91016s is the iPhone Duo's (iPhone19,4) build. The profile is a binary plist; its strings are plain ASCII."""
    root = os.path.realpath(os.path.join(ROOT, "runtimes", rt, "RuntimeRoot"))
    try:
        with open(os.path.join(os.path.dirname(root), "profile.plist"), "rb") as f:
            b = f.read()
    except OSError:
        return []
    if b"restrictedToDeviceTypes" not in b:
        return []
    return sorted({m.decode() for m in re.findall(rb"(?:iPhone|iPad)[0-9]+,[0-9]+", b)})


def runtime_of(dev):
    try:
        return open(os.path.join(dev, "runtime")).read().strip() or DEFAULT_RT
    except OSError:
        return DEFAULT_RT


def env_of(dev):
    try:
        return dict(l.split("=", 1) for l in open(os.path.join(dev, "sim.env")).read().splitlines() if "=" in l)
    except OSError:
        return {}


def cmd_list():
    names = {v["model"]: k for k, v in models().items()}
    for d in sorted(os.listdir(VAR)):
        p = os.path.join(VAR, d)
        if d.startswith("device-a64") and os.path.exists(os.path.join(p, "sim.env")):
            e = env_of(p)
            m = e.get("SIMULATOR_MODEL_IDENTIFIER", "")
            rt = re.match(r"ios-([0-9.]+)-", runtime_of(p))
            print(f"{d:24} {names.get(m, m):24} {e.get('SIMULATOR_MAINSCREEN_WIDTH')}x{e.get('SIMULATOR_MAINSCREEN_HEIGHT')}"
                  f"  iOS {rt[1] if rt else '?':5} {e.get('SIMULATOR_DEVICE_NAME', '')}")


def cmd_create(args):
    model, name, ios = None, None, None
    while args:
        a = args.pop(0)
        if a in ("--model", "--ios"):
            v = args.pop(0)
            if a == "--model":
                model = v
            else:
                ios = v
        elif a.startswith("--model="):
            model = a.split("=", 1)[1]
        elif a.startswith("--ios="):
            ios = a.split("=", 1)[1]
        else:
            name = a
    types = models()
    if model not in types:
        sys.exit(f"device create: --model one of: {', '.join(types)}")
    rts = runtimes()
    # Models 2: a runtime limited to some models (the iPhone Duo's 27.2 build) is taken for them, never for others
    mid = types[model].get("model", "") if isinstance(types[model], dict) else ""
    fits = [r for r in rts if not restricted_to(r[2]) or mid in restricted_to(r[2])]
    own = [r for r in fits if mid in restricted_to(r[2])]
    rt = DEFAULT_RT if not own else own[0][2]
    if ios:
        hit = [r for r in fits if ios in (r[0], r[1], r[2])]
        if not hit:
            sys.exit(f"device create: --ios one of: {', '.join(r[0] for r in fits)}")
        rt = ([r for r in hit if r in own] or hit)[0][2]
    name = name or model
    # the folder name is capped (the name itself is kept whole in <device>/name): every path in the phone grows with
    # it, and Unix socket paths are short (simhid's socket; host/simhid also handles a path that is still too long)
    full = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    slug = full[:MAX_SLUG].strip("-")
    dev = os.path.join(VAR, "device-a64-" + slug)
    n = 2
    while slug != full and os.path.exists(dev):  # two long names that start alike
        dev = os.path.join(VAR, "device-a64-%s-%d" % (full[:MAX_SLUG - 3].strip("-"), n))
        n += 1
    if os.path.exists(dev):
        sys.exit(f"device create: {dev} exists")
    os.makedirs(dev)
    with open(os.path.join(dev, "model"), "w") as f:
        f.write(model + "\n")
    with open(os.path.join(dev, "name"), "w") as f:
        f.write(name + "\n")
    with open(os.path.join(dev, "runtime"), "w") as f:
        f.write(rt + "\n")
    if rt == runtime_of(BASE) and os.path.isdir(os.path.join(BASE, "data/var/db/lsd")):
        subprocess.run(["cp", "-a", "--reflink=auto", os.path.join(BASE, "data"), os.path.join(dev, "data")], check=True)
        for x in ("var/log", "var/run", "tmp"):
            shutil.rmtree(os.path.join(dev, "data", x), ignore_errors=True)
            os.makedirs(os.path.join(dev, "data", x))
        for x in ("simhid.sock", "framebuffer.bgra"):
            try:
                os.unlink(os.path.join(dev, "data", x))
            except OSError:
                pass
        # the copy's stores keep var/device-a64's absolute paths (lsd's csstore: every app's data container): its
        # apps ran in the base phone's containers. device-repath.py rewrites them / drops the caches that hold them.
        subprocess.run([sys.executable, os.path.join(ROOT, "cli/libexec/arm64/device-repath.py"), dev, BASE])
    env = dict(os.environ, X86SIM_ARCH="arm64", X86SIM_DEVICE=dev,
               X86SIM_RUNTIME=os.path.join(ROOT, "runtimes", rt, "RuntimeRoot"),
               X86SIM_STATE=os.environ.get("A64_STATE", os.path.join(VAR, "run-a64")), X86SIM_JOBLOG="1")
    subprocess.run([sys.executable, os.path.join(ROOT, "cli/libexec/mksimdevice.py"), dev], env=env, check=True,
                   stdout=subprocess.DEVNULL)
    print(dev)


def main():
    a = sys.argv[1:] or ["list"]
    if a[0] == "models":
        for k, v in models().items():
            print(f"{k:24} {v['model']:12} {v['w']}x{v['h']} @{float(v['scale']):g}x")
    elif a[0] == "runtimes":
        for v, b, d in runtimes():
            print(f"{v:6} {b:10} {d}")
    elif a[0] == "list":
        cmd_list()
    elif a[0] == "create":
        cmd_create(a[1:])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
