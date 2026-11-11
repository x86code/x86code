#!/usr/bin/env python3
"""Send touches/keys/buttons to the simulator (host/simhid, backboardd's virtual HID services).
    cli/libexec/simtouch.py tap <x> <y>                    device pixels (size from the frame ring / device env)
    cli/libexec/simtouch.py swipe <x1> <y1> <x2> <y2> [ms] [hold_ms]   a swipe that starts at a screen edge is an edge
                                                      touch, as in Apple's Simulator (bottom: home indicator; top
                                                      left/right: Notification/Control Center); hold_ms: stay at
                                                      (x2,y2) before lifting (swipe up + hold = app switcher)
    cli/libexec/simtouch.py edgeswipe <edge|none> <x1> <y1> <x2> <y2> [ms] [hold_ms]   the edge given explicitly
    cli/libexec/simtouch.py home | lock                    press + release
    cli/libexec/simtouch.py pinch <cx> <cy> <r1> <r2> [ms]   two fingers on a horizontal line through (cx,cy), their
                                                      distance from it going from r1 to r2 (r2 > r1 = zoom in)
    cli/libexec/simtouch.py pan2 <x1> <y1> <x2> <y2> [ms]   two fingers 200 px apart, moved together from (x1,y1) to (x2,y2)
    cli/libexec/simtouch.py key <usage> | text <ascii>
    cli/libexec/simtouch.py raw "<line>" ...               protocol lines (see host/simhid/simhid.m)
    cli/libexec/simtouch.py app <bundle id>                open an app (also ones the home screen doesn't show); as openurl
    cli/libexec/simtouch.py dismiss [rounds]               answer permission prompts on screen (location: "Allow While Using
                                                      App", notifications/others: "Allow"), found by OCR (tesseract)
    cli/libexec/simtouch.py openurl <url>                  open a URL (as `simctl openurl`); needs the boot's openurl job:
                                                      com.x86sim.openurl (the phone's boot starts it; log:
                                                      var/device/data/var/log/x86sim-openurl.log)"""
import os, socket, struct, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "lib"))
import x86config  # noqa: E402
import fbring  # noqa: E402
SOCK = os.environ.get("SIMHID_SOCKET", os.path.join(x86config.data(), "simhid.sock"))


def device_size():
    """Prefer the live frame ring, then SIMULATOR_MAINSCREEN_*, then the iPhone 17's 1206x2622."""
    try:
        r = fbring.Ring()
        if r._open() and r.mm and r.mm[:4] == b"SFBR":
            w, h = struct.unpack_from("<II", r.mm, 16)
            if w > 0 and h > 0:
                return int(w), int(h)
    except OSError:
        pass
    try:
        w = int(os.environ.get("SIMULATOR_MAINSCREEN_WIDTH", "0"))
        h = int(os.environ.get("SIMULATOR_MAINSCREEN_HEIGHT", "0"))
        if w > 0 and h > 0:
            return w, h
    except ValueError:
        pass
    return 1206, 2622


W, H = device_size()

# US layout: character -> (usage, shift)
KEYS = {c: (4 + i, False) for i, c in enumerate("abcdefghijklmnopqrstuvwxyz")}
KEYS.update({c.upper(): (4 + i, True) for i, c in enumerate("abcdefghijklmnopqrstuvwxyz")})
KEYS.update({c: (0x1e + i, False) for i, c in enumerate("1234567890")})
KEYS.update({" ": (0x2c, False), "\n": (0x28, False), "-": (0x2d, False), "=": (0x2e, False), ".": (0x37, False),
             ",": (0x36, False), "/": (0x38, False), ";": (0x33, False), "'": (0x34, False), "@": (0x1f, True),
             "!": (0x1e, True), "?": (0x38, True), ":": (0x33, True), "_": (0x2d, True)})


def connect():
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(os.path.realpath(SOCK))  # a long device path is a symlink to a short socket (host/simhid listen_thread)
    return s


def send(s, *lines):
    s.sendall("".join(l + "\n" for l in lines).encode())


def touch(s, phase, x, y, edge=None):
    send(s, "touch %s %.5f %.5f%s" % (phase, x / W, y / H, " " + edge if edge else ""))


def edge_at(x, y, w, h):
    """The screen edge a touch at device pixel (x, y) begins on, like Apple's Simulator marks it (within ~16 pt of the
    edge; the top and bottom win in the corners), or None."""
    m = 0.04 * w
    if y >= h - m: return "bottom"
    if y <= m: return "top"
    if x <= m: return "left"
    if x >= w - m: return "right"
    return None


# x86Sim: permission prompts are answered here: OCR the frame, tap the allowing button.
# Preference order: the location prompt's "Allow While Using App", then a lone "Allow" (notifications, TCC).
def find_allow_button():
    import subprocess
    d = os.path.dirname(os.path.abspath(__file__))
    png = os.path.join(x86config.get("X86SIM_SCRATCH"), "simtouch-dismiss.png")
    subprocess.run([sys.executable, os.path.join(d, "fb2png.py"),
                    os.path.join(os.path.dirname(SOCK), "framebuffer.bgra"), png, "1"], capture_output=True)
    env = dict(os.environ)
    td = os.path.join(x86config.get("X86SIM_SCRATCH"), "tessdata")  # eng.traineddata (tessdata_fast) if the system has none
    if os.path.exists(td + "/eng.traineddata"):
        env["TESSDATA_PREFIX"] = td
    outs = [subprocess.run(["tesseract", png, "stdout", "-c", "tessedit_create_tsv=1"], capture_output=True,
                           text=True, env=env).stdout]
    try:  # light text on a dark alert (dark-mode apps such as Fitness): OCR the inverted frame too
        from PIL import Image, ImageOps
        ImageOps.invert(Image.open(png).convert("RGB")).save(png + ".inv.png")
        outs.append(subprocess.run(["tesseract", png + ".inv.png", "stdout", "-c", "tessedit_create_tsv=1"],
                                   capture_output=True, text=True, env=env).stdout)
    except ImportError:
        pass
    words = []
    for k, out in enumerate(outs):
        for line in out.splitlines():
            f = line.split("\t")
            if len(f) == 12 and f[11].strip() and f[2].isdigit():
                words.append((f[11].strip(), (k, int(f[2])), int(f[3]), int(f[4]), int(f[5]), int(f[6]), int(f[7]),
                              int(f[8]), int(f[9])))
    lines = {}
    for w in words:
        lines.setdefault((w[1], w[2], w[3]), []).append(w)
    best = None
    for ws in lines.values():
        ws.sort(key=lambda w: w[5])
        for i, w in enumerate(ws):
            if w[0].strip(".,") != "Allow":
                continue
            prev = ws[i - 1][0].lower() if i > 0 else ""
            if prev.startswith("don"):
                # "Don't Allow" (the left button of a two-button prompt): its mirror image is "Allow", in case OCR
                # missed that one
                cand = (0.5, W - (w[5] + w[7] / 2), w[6] + w[8] / 2, "(mirror of) " + " ".join(v[0] for v in ws))
                if (w[5] + w[7] / 2) < W / 2 and (best is None or best[0] < 0.5):
                    best = cand
                continue
            nxt = ws[i + 1][0] if i + 1 < len(ws) else ""
            if i == 0 and len(ws) > 1 and nxt not in ("While", "Full"):
                continue  # "Allow “Maps” to use ..." (the title) or "Allow Once"
            rank = 2 if nxt == "While" else 1
            x = (w[5] + (ws[i + 2][5] + ws[i + 2][7] if rank == 2 and i + 2 < len(ws) else w[5] + w[7])) / 2
            y = w[6] + w[8] / 2
            # a lone "Allow": the right-hand one (notification prompts put "Don't Allow" on the left, and OCR can
            # drop the "Don't")
            if best is None or rank > best[0] or (rank == best[0] and x > best[1]):
                best = (rank, x, y, " ".join(v[0] for v in ws))
    return best


def main(a):
    if a[0] == "dismiss":
        for _ in range(int(a[1]) if len(a) > 1 else 3):
            b = find_allow_button()
            if not b:
                return
            print("simtouch: prompt: tapping %r at %d,%d" % (b[3], b[1], b[2]))
            s = connect()
            touch(s, "down", b[1], b[2]); time.sleep(0.08); touch(s, "up", b[1], b[2])
            s.close()
            time.sleep(2)
        return
    if a[0] in ("openurl", "app"):
        # x86Sim: host/openurl/openurl (a launchd job in the device) takes URLs from this file
        q = os.path.join(os.path.dirname(SOCK), "tmp/x86sim-openurl")
        with open(q + ".new", "w") as f:
            f.write(("app " if a[0] == "app" else "") + " ".join(a[1:]) + "\n")
        os.rename(q + ".new", q)
        return
    s = connect()
    if a[0] == "tap":
        x, y = float(a[1]), float(a[2])
        touch(s, "down", x, y); time.sleep(0.08); touch(s, "up", x, y)
    elif a[0] in ("swipe", "edgeswipe"):
        edge = None
        if a[0] == "edgeswipe":
            edge, a = a[1], a[1:]
        x1, y1, x2, y2 = map(float, a[1:5])
        ms = float(a[5]) if len(a) > 5 else 300
        hold = float(a[6]) if len(a) > 6 else 0
        if edge is None:
            edge = edge_at(x1, y1, W, H)
        n = max(int(ms / 16), 2)
        touch(s, "down", x1, y1, edge)
        for i in range(1, n + 1):
            time.sleep(ms / 1000 / n)
            # with a hold the finger slows down into the stop (ease-out), as a hand does: UIKit's pan velocity only
            # changes when the touch moves, so a constant-speed drag that stops dead keeps its full velocity and
            # SpringBoard never sees the pause (pauseVelocityThresholdForAppSwitcher) that opens the app switcher
            f = i / n if not hold else 1 - (1 - i / n) ** 3
            touch(s, "move", x1 + (x2 - x1) * f, y1 + (y2 - y1) * f)
        t = time.time() + hold / 1000
        while time.time() < t:   # a still finger: a digitizer keeps reporting it at its scan rate (~60 Hz)
            time.sleep(0.016)
            touch(s, "move", x2, y2)
        touch(s, "up", x2, y2)
    elif a[0] in ("pinch", "pan2"):
        ms = float(a[5]) if len(a) > 5 else 500
        n = max(int(ms / 16), 2)
        v = list(map(float, a[1:5]))
        def pts(t):
            if a[0] == "pinch":
                cx, cy, r1, r2 = v
                r = r1 + (r2 - r1) * t
                return cx - r, cy, cx + r, cy
            x = v[0] + (v[2] - v[0]) * t
            y = v[1] + (v[3] - v[1]) * t
            return x - 100, y, x + 100, y
        def touch2(phase, p):
            send(s, "touch2 %s %.5f %.5f %.5f %.5f" % (phase, p[0] / W, p[1] / H, p[2] / W, p[3] / H))
        touch2("down", pts(0))
        for i in range(1, n + 1):
            time.sleep(ms / 1000 / n)
            touch2("move", pts(i / n))
        time.sleep(0.05)
        touch2("up", pts(1))
    elif a[0] in ("home", "lock"):
        send(s, "button %s down" % a[0]); time.sleep(0.1); send(s, "button %s up" % a[0])
    elif a[0] == "key":
        # a usage (page 7: 0x28 = return) or a name
        named = {"return": 0x28, "enter": 0x28, "escape": 0x29, "esc": 0x29, "delete": 0x2a, "backspace": 0x2a,
                 "tab": 0x2b, "space": 0x2c, "right": 0x4f, "left": 0x50, "down": 0x51, "up": 0x52}
        u = named[a[1].lower()] if a[1].lower() in named else int(a[1], 0)
        send(s, "key down %d" % u, "key up %d" % u)
    elif a[0] == "text":
        for c in " ".join(a[1:]):
            u, shift = KEYS[c]
            if shift: send(s, "key down 225")
            send(s, "key down %d" % u, "key up %d" % u)
            if shift: send(s, "key up 225")
            time.sleep(0.02)
    elif a[0] == "raw":
        send(s, *a[1:])
    else:
        sys.exit(__doc__)
    time.sleep(0.05)
    s.close()


if __name__ == "__main__":
    main(sys.argv[1:] or ["help"])
