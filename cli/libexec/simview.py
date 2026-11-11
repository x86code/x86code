#!/usr/bin/env python3
"""Live window showing the simulator's screen, with input.
Frames come from host/simfb's shared-memory ring (cli/libexec/fbring.py; /dev/shm/x86sim-a64-simfb.ring); without a ring,
from the framebuffer.bgra dump. x86Sim: GTK 4: each new frame becomes a Gdk.MemoryTexture that the GPU scales to the
window, checked on every tick of the display's frame clock (so up to the display's rate, ~60 fps). The Tk version
spent ~200 ms redrawing each 590x1278 photo image (about 5 fps).
    cli/libexec/simview.py [framebuffer.bgra] [scale-divisor]   (default: 2; the window can be resized)
Mouse: click/drag = touch; Ctrl+drag = two-finger pinch around the window centre (fingers mirrored through the
centre); Shift+drag = two-finger pan (fingers 100 px apart at device scale, moving together). Keyboard: typed keys go
to the simulator's hardware keyboard (host/simhid). F1 or Ctrl+H = home button, F2 = lock button, F3/F4 = volume
up/down. Input goes through <device data>/simhid.sock (backboardd's SimulatorHID stand-in).
Console pane (right; SIMVIEW_CONSOLE=0 hides it): last-frame age (stall check), sim up/down + CPU, and the sim's logs, newest line at the top,
followed once a second. Logs: SIMVIEW_LOGS (colon-separated dirs), default the a64 and x86 device log dirs."""
import glob, os, threading, socket, struct, sys, time
import gi
# x86Sim: GTK's GPU renderers (vulkan, the default, and gl) upload the whole frame texture for every
# frame, and on the NVIDIA driver ~75% of that CPU time is kernel time inside the driver's ioctls: 46% of a core at
# 60 fps (40% with gl). The cairo renderer scales the frame into the window's shm buffer on the CPU instead: 13%,
# the compositor's cost unchanged (perf: tests on a synthetic 60 Hz ring). GSK_RENDERER=vulkan|gl still overrides.
os.environ.setdefault("GSK_RENDERER", "cairo")
gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
from gi.repository import Gdk, Gio, GLib, Gtk
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "lib"))
import x86config  # noqa: E402
import fbring

here = os.path.dirname(os.path.abspath(__file__))
src = sys.argv[1] if len(sys.argv) > 1 else os.path.join(x86config.data(), "framebuffer.bgra")
div = int(sys.argv[2]) if len(sys.argv) > 2 else 2
sockpath = os.environ.get("SIMHID_SOCKET", os.path.join(os.path.dirname(src), "simhid.sock"))
# Speed 22: an arm64 boot records its device in var/run-a64/device (boot-a64.sh); input follows the booted device


def booted_device():
    try:
        return open(os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
                                 "var/run-a64/device")).read().strip() or None
    except OSError:
        return None


def current_sock():
    if "SIMHID_SOCKET" not in os.environ or os.environ.get("SIMVIEW_FOLLOW", "1") != "0":
        d = booted_device()
        if d and os.path.exists(os.path.join(d, "data/simhid.sock")):
            return os.path.join(d, "data/simhid.sock")
    return sockpath

ring = fbring.Ring()
STATE_DIR = os.path.join(os.path.dirname(os.path.dirname(here)), "var/run-a64")


def device_ring():
    """The booted device's frame ring (sim.env SIMFB_RING), else fbring's default: each phone has its own."""
    d = booted_device()
    if d and os.environ.get("SIMVIEW_FOLLOW", "1") != "0":
        try:
            for line in open(os.path.join(d, "sim.env")):
                if line.startswith("SIMFB_RING="):
                    return line.split("=", 1)[1].strip().replace("/Volumes/SystemRoot", "", 1)
        except OSError:
            pass
    return fbring.RING


def sim_running():
    """A darlingserver is up (the sim's scope can outlive it: mtlvk stays for the next boot)."""
    for pid in os.listdir("/proc"):
        if pid.isdigit():
            try:
                if open("/proc/%s/comm" % pid).read().strip() == "darlingserver":
                    return True
            except OSError:
                pass
    return False


def boot_started():
    """When the current boot began (boot-a64.sh rewrites var/run-a64/device at every start)."""
    try:
        return os.path.getmtime(os.path.join(STATE_DIR, "device"))
    except OSError:
        return 0.0


def frame_is_current(t):
    """A ring outlives its sim: only frames published by this boot of a running sim are the screen."""
    return sim_running() and t >= boot_started() - 2


ring.path = device_ring()


def initial_size():
    """Device pixels from the live ring, else SIMULATOR_MAINSCREEN_*, else the iPhone 17's 1206x2622."""
    try:
        if ring._open() and ring.mm and ring.mm[:4] == b"SFBR":
            w, h = struct.unpack_from("<II", ring.mm, 16)
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


state = {"mtime": None, "size": initial_size(), "sock": None, "seq": None, "key": None, "fps": [], "mode": "one", "start": (0, 0)}


def send(line):
    for _ in range(2):
        try:
            if state["sock"] is None:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.settimeout(0.5)
                s.connect(os.path.realpath(current_sock()))  # long paths: a symlink to a short socket
                # keep simhid's on-demand keyboard attached 5 min after our last key (its default is 30 s, then
                # the next key pays a re-attach + 1.5 s settle); see host/simhid/simhid.m kbidle
                s.sendall(("kbidle %s\n" % os.environ.get("X86SIM_VIEWER_KB_IDLE_S", "300")).encode())
                state["sock"] = s
            state["sock"].sendall((line + "\n").encode())
            return
        except OSError:
            if state["sock"]:
                state["sock"].close()
            state["sock"] = None


# Tk keysym names (GDK's keyval names are the same X keysyms) -> HID keyboard usage (page 7)
USAGES = {"Return": 0x28, "Escape": 0x29, "BackSpace": 0x2a, "Tab": 0x2b, "space": 0x2c, "minus": 0x2d,
          "equal": 0x2e, "bracketleft": 0x2f, "bracketright": 0x30, "backslash": 0x31, "semicolon": 0x33,
          "apostrophe": 0x34, "grave": 0x35, "comma": 0x36, "period": 0x37, "slash": 0x38, "Caps_Lock": 0x39,
          "Right": 0x4f, "Left": 0x50, "Down": 0x51, "Up": 0x52, "Delete": 0x4c, "Home": 0x4a, "End": 0x4d,
          "Prior": 0x4b, "Next": 0x4e, "Page_Up": 0x4b, "Page_Down": 0x4e, "Shift_L": 0xe1, "Shift_R": 0xe5,
          "Control_L": 0xe0, "Control_R": 0xe4, "Alt_L": 0xe2, "Alt_R": 0xe6, "Super_L": 0xe3, "Super_R": 0xe7}
SHIFTED = {"exclam": "1", "at": "2", "numbersign": "3", "dollar": "4", "percent": "5", "asciicircum": "6",
           "ampersand": "7", "asterisk": "8", "parenleft": "9", "parenright": "0", "underscore": "minus",
           "plus": "equal", "braceleft": "bracketleft", "braceright": "bracketright", "bar": "backslash",
           "colon": "semicolon", "quotedbl": "apostrophe", "asciitilde": "grave", "less": "comma",
           "greater": "period", "question": "slash"}
BUTTONS = {"F1": "home", "F2": "lock", "F3": "volup", "F4": "voldown"}


def usage(sym):
    sym = SHIFTED.get(sym, sym)
    if len(sym) == 1 and sym.isalpha():
        return 4 + ord(sym.lower()) - ord("a")
    if len(sym) == 1 and sym.isdigit():
        return 0x27 if sym == "0" else 0x1e + int(sym) - 1
    return USAGES.get(sym)


def on_activate(app):
    win = Gtk.ApplicationWindow(application=app, title="x86Sim iOS Simulator")
    pic = Gtk.Picture()
    pic.set_content_fit(Gtk.ContentFit.FILL)
    dw, dh = state["size"]
    pic.set_size_request(dw // div, dh // div)
    pic.set_can_shrink(True)
    console = os.environ.get("SIMVIEW_CONSOLE", "1") != "0"
    if console:
        box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        pic.set_hexpand(True)
        box.append(pic)
        side = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        side.set_size_request(560, -1)
        status = Gtk.Label(xalign=0)
        status.set_markup("<tt>waiting for frames</tt>")
        side.append(status)
        tv = Gtk.TextView(editable=False, cursor_visible=False, monospace=True, wrap_mode=Gtk.WrapMode.CHAR)
        sw = Gtk.ScrolledWindow(vexpand=True)
        sw.set_child(tv)
        side.append(sw)
        box.append(side)
        win.set_child(box)
        win.set_default_size(dw // div + 560, dh // div)
        buf = tv.get_buffer()
        root = os.path.dirname(here)
        dirs = os.environ.get("SIMVIEW_LOGS") or ":".join([
            os.path.join(booted_device() or os.path.join(os.path.dirname(root), "var/device-a64"), "data/var/log"),
            os.path.join(os.environ.get("X86SIM_SCRATCH") or os.path.expanduser("~/scratch/x86sim"),
                         "a64prefix/private/var/tmp/x86sim-a64"),
            os.path.join(x86config.data(), "var/log")])
        offs = {}

        def poll():
            now = time.monotonic()
            last = state.get("frame_at")
            age = "no frame yet" if last is None else "%.0f s ago" % (now - last)
            if state.get("frame_t"):   # the frame's own publish time (simfb, CLOCK_REALTIME): its real age
                age += ", frame is %.0f s old" % (time.time() - state["frame_t"])
            if state.get("noframe") and now - state["noframe"] > 3:
                age += ", ring seq %d but no valid frame" % ring.seq()
            stalled = last is not None and now - last > 10
            # the stack's systemd scope (cli/libexec/limited.sh): gone = sim down; cpu.stat delta = how busy it is
            scopes = glob.glob("/sys/fs/cgroup/user.slice/user-%d.slice/user@%d.service/app.slice/x86sim-*.scope"
                               % (os.getuid(), os.getuid()))
            if not scopes:
                age += ", sim not running (frame is stale)"
                stalled = False
            else:
                try:
                    use = int(open(scopes[0] + "/cpu.stat").read().split()[1])
                    prev = state.get("cpu")
                    state["cpu"] = (now, use)
                    if prev:
                        age += ", sim CPU %d%%" % (100 * (use - prev[1]) / 1e6 / max(now - prev[0], 0.1))
                except (OSError, ValueError, IndexError):
                    pass
            status.set_markup("<tt>frame %s, last %s%s</tt>" % (state["seq"], GLib.markup_escape_text(age),
                              "  <span foreground='red'>STALLED?</span>" if stalled else ""))
            new = []
            for d in dirs.split(":"):
                try:
                    names = os.listdir(d)
                except OSError:
                    continue
                for n in names:
                    if not n.endswith(".log"):
                        continue
                    f = os.path.join(d, n)
                    try:
                        size = os.path.getsize(f)
                    except OSError:
                        continue
                    o = offs.get(f)
                    if o is None or size < o:   # first sight: only the tail; truncated: from the start
                        o = max(0, size - 2048) if o is None else 0
                    if size > o:
                        with open(f, "rb") as fh:
                            fh.seek(o)
                            chunk = fh.read(min(size - o, 65536)).decode("utf-8", "replace")
                        tag = n[:-4].replace("com.apple.", "")
                        new += ["[%s] %s" % (tag, l) for l in chunk.splitlines() if l.strip()]
                    offs[f] = size
            if new:
                buf.insert(buf.get_start_iter(), "\n".join(reversed(new[-300:])) + "\n")   # newest first, at the top
                if buf.get_line_count() > 2000:
                    buf.delete(buf.get_iter_at_line(2000)[1], buf.get_end_iter())
                sw.get_vadjustment().set_value(0)
            return GLib.SOURCE_CONTINUE

        GLib.timeout_add_seconds(1, poll)
    else:
        win.set_child(pic)
        win.set_default_size(dw // div, dh // div)

    def norm(x, y):
        w, h = pic.get_width() or 1, pic.get_height() or 1
        return min(max(x / w, 0.0), 1.0), min(max(y / h, 0.0), 1.0)

    def emit(phase, x, y):
        x, y = norm(x, y)
        if state["mode"] == "one":
            edge = ""
            if phase == "down":
                # an edge touch, as Apple's Simulator marks one (begins within ~16 pt of the edge; top/bottom win in
                # the corners): home indicator gestures, Notification/Control Center (see host/simhid/simhid.m)
                mx, my = 0.04, 0.04 * state["size"][0] / max(state["size"][1], 1)
                edge = " bottom" if y >= 1 - my else " top" if y <= my else " left" if x <= mx else " right" if x >= 1 - mx else ""
            send("touch %s %.5f %.5f%s" % (phase, x, y, edge))
            return
        if state["mode"] == "pinch":
            x2, y2 = 1.0 - x, 1.0 - y          # mirrored through the centre
        else:
            dx = 50.0 / state["size"][0]       # 100 device px apart
            x, x2, y2 = x - dx, x + dx, y
        send("touch2 %s %.5f %.5f %.5f %.5f" % (phase, x, y, x2, y2))

    drag = Gtk.GestureDrag()
    drag.set_button(1)

    def begin(g, x, y):
        m = g.get_current_event_state()
        state["mode"] = "pinch" if m & Gdk.ModifierType.CONTROL_MASK else "pan" if m & Gdk.ModifierType.SHIFT_MASK else "one"
        state["start"] = (x, y)
        emit("down", x, y)

    def update(g, dx, dy):
        emit("move", state["start"][0] + dx, state["start"][1] + dy)

    def end(g, dx, dy):
        emit("up", state["start"][0] + dx, state["start"][1] + dy)
        state["mode"] = "one"

    drag.connect("drag-begin", begin)
    drag.connect("drag-update", update)
    drag.connect("drag-end", end)
    pic.add_controller(drag)

    keys = Gtk.EventControllerKey()

    def key(down, keyval, mods):
        name = Gdk.keyval_name(keyval) or ""
        if name in BUTTONS:
            send("button %s %s" % (BUTTONS[name], "down" if down else "up"))
            return True
        if name.lower() == "h" and mods & Gdk.ModifierType.CONTROL_MASK:   # Ctrl+H: home
            send("button home %s" % ("down" if down else "up"))
            return True
        u = usage(name)
        if u is not None:
            send("key %s %d" % ("down" if down else "up", u))
        return True

    keys.connect("key-pressed", lambda c, kv, code, mods: key(True, kv, mods))
    keys.connect("key-released", lambda c, kv, code, mods: key(False, kv, mods))
    win.add_controller(keys)

    def show(w, h, stride, seq, px):
        tex = Gdk.MemoryTexture.new(w, h, Gdk.MemoryFormat.B8G8R8A8_PREMULTIPLIED, GLib.Bytes.new(px), stride)
        pic.set_paintable(tex)
        if state["size"] != (w, h):
            # Speed 22: another phone model booted: size the window to its screen
            print("simview: screen %dx%d" % (w, h), flush=True)
            state["size"] = (w, h)
            pic.set_size_request(w // div, h // div)
            win.set_default_size(w // div + (560 if console else 0), h // div)
        state["size"] = (w, h)
        now = time.monotonic()
        state["frame_at"] = now
        f = state["fps"] = [t for t in state["fps"] if t > now - 1.0] + [now]
        win.set_title("x86Sim iOS Simulator — frame %d, %d fps" % (seq, len(f)))
        state["shown"] = state.get("shown", 0) + 1
        if now - state.setdefault("logged", now) >= 5:   # the draw rate, every 5 s while frames come (stdout)
            print("simview: %d of %d frames drawn in %.1f s (peak 1 s: %d fps)" % (state["shown"],
                  seq - state.get("logseq", seq - state["shown"]), now - state["logged"], max(state.get("peak", 0), len(f))),
                  flush=True)
            state["shown"], state["logged"], state["peak"], state["logseq"] = 0, now, 0, seq
        state["peak"] = max(state.get("peak", 0), len(f))

    def blank():
        """Black screen instead of a stale frame: "Starting…" while a boot is on its way, else "Off"."""
        why = "Starting…" if sim_running() else "Off"
        if state.get("blank") == why:
            return
        state["blank"] = why
        print("simview: screen cleared (%s)" % why, flush=True)
        w, h = state["size"]
        pic.set_paintable(Gdk.MemoryTexture.new(w, h, Gdk.MemoryFormat.B8G8R8A8_PREMULTIPLIED,
                                                GLib.Bytes.new(bytes(w * h * 4)), w * 4))
        state["frame_t"] = None
        win.set_title("x86Sim iOS Simulator — %s" % why)

    def watch():
        """Once a second: follow the booted phone's ring, and drop the picture when the sim stops or reboots."""
        p = device_ring()
        if p != ring.path:
            ring.path, ring.mm, ring.ino, state["key"] = p, None, None, None
        t = state.get("frame_t")
        if state.get("blank") is None and (t is None and state.get("seq") is None or t is not None and not frame_is_current(t)):
            blank()
        elif state.get("blank") and state["blank"] != ("Starting…" if sim_running() else "Off"):
            state["blank"] = None
            blank()
        if state.get("blank"):
            state["key"] = None   # retry the ring: a frame from the new boot replaces the black screen
        return GLib.SOURCE_CONTINUE

    GLib.timeout_add_seconds(1, watch)
    blank() if not ring.seq() else None

    # x86Sim: event-driven. A thread sleeps on the ring (fbring.Ring.wait: a futex simfb wakes at every publish) and
    # hands each new frame to the GTK main loop; nothing runs while the screen doesn't change (the frame-clock tick of
    # before woke the process at the display's rate all the time). Without a ring: framebuffer.bgra every 0.5 s.
    def update(done):
        try:
            seq = ring.seq()
            if seq:
                if (ring.ino, seq) != state["key"]:
                    f = ring.latest()
                    if f and not frame_is_current(f[4] / 1e9):   # an old session's frame: not the screen
                        blank()
                        state["key"] = (ring.ino, seq)
                    elif f:   # None: torn read (simfb reused the slot mid-copy), or no frame copied yet; retried
                        show(f[0], f[1], f[2], f[3], f[5])
                        state["blank"] = None
                        state["seq"], state["key"], state["frame_t"] = seq, (ring.ino, seq), f[4] / 1e9
                        state.pop("noframe", None)
                    else:
                        state.setdefault("noframe", time.monotonic())
            else:
                st = os.stat(src)
                # only a live dump: an old file (another device's, or a dead sim's) would pass for the screen
                if st.st_mtime_ns != state["mtime"] and time.time() - st.st_mtime < 10:
                    data = open(src, "rb").read()
                    w, h, stride, seq = struct.unpack("<4I", data[:16])
                    show(w, h, stride, seq, data[16:16 + stride * h])
                    state["mtime"] = st.st_mtime_ns
        except (OSError, struct.error, ValueError, GLib.Error):
            pass
        done.set()
        return GLib.SOURCE_REMOVE

    # The shown frame is keyed by (ring inode, seq), not seq alone: a rebooted sim's new ring restarts its count. Any
    # mismatch (new frame, a torn read that got skipped, a new ring) is retried at least once a second, so the window
    # never sits on an old frame while the ring holds a newer one.
    def waiter():
        while True:
            seq = ring.seq()
            if not seq:   # no ring (yet): the file
                GLib.idle_add(update, threading.Event())
                time.sleep(0.5)
                continue
            if (ring.ino, seq) != state["key"]:
                done = threading.Event()
                GLib.idle_add(update, done)
                done.wait(1.0)   # one update in flight at a time
                if (ring.ino, seq) != state["key"]:
                    time.sleep(0.02)
                    continue
            ring.wait(seq, 1.0)

    threading.Thread(target=waiter, daemon=True).start()
    win.present()


app = Gtk.Application(application_id="org.x86sim.simview", flags=Gio.ApplicationFlags.NON_UNIQUE)
app.connect("activate", on_activate)
app.run([sys.argv[0]])
