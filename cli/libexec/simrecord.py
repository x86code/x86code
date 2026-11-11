#!/usr/bin/env python3
"""x86Sim: record the simulator's frame ring to video at real timing, with touches drawn like Xcode's "Show Touches",
and measure app-open latency frame-accurately.
    simrecord.py capture OUT.frames SECS [SCALE]      copy every published ring frame (slot t_ns, CLOCK_REALTIME) to
                                                      OUT.frames, downscaled by SCALE (default 2); prints the wall
                                                      time span. Run it around a tap/launch.
    simrecord.py render OUT.frames OUT.mp4 [--touches simhid.log] [--fps 60] [--label TEXT]   (SIMRECORD_CLEAN=1: no timer)
                                                      constant-fps mp4 (each output frame shows the newest ring frame
                                                      at that wall time), touch overlay from host/simhid's log lines
                                                      ("<wall ns> simhid: touch down|move|up (x,y)", normalized), and a
                                                      timer (seconds since the first frame, or since --t0 NS).
    simrecord.py open OUT.frames T0_NS                open latency from T0 (tap/launch wall ns): first frame that
                                                      changed (response), first frame matching the final settled screen
                                                      (content shown), as JSON
    simrecord.py mp4open VIDEO.mp4 T0_S               the same for an mp4 (e.g. simctl io recordVideo), T0 in seconds
                                                      of video time
    simrecord.py sbs LEFT.mp4 RIGHT.mp4 OUT.mp4 [--labels "ours|Mac"] [--lt0 S] [--rt0 S] [--pre S] [--secs S]
                                                      side by side, each trimmed to start PRE s before its t0 (video
                                                      seconds) so both t0 line up; shared timer = seconds since t0
File format: per frame u64 t_ns, u32 w, u32 h, then w*h*3 bytes RGB."""
import json, os, re, struct, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np


def capture(out, secs, scale=2):
    import fbring
    r = fbring.Ring()
    end = time.time() + secs
    last = r.seq() or 0
    n = 0
    with open(out, "wb") as f:
        # include the current frame as the "before" picture
        fr = r.latest()
        while time.time() < end:
            if fr:
                w, h, stride, seq, t, px = fr
                a = np.frombuffer(px, np.uint8, h * stride).reshape(h, stride // 4, 4)[:, :w]
                a = a[::scale, ::scale, 2::-1]   # BGRA -> RGB
                a = np.ascontiguousarray(a)
                f.write(struct.pack("<QII", t, a.shape[1], a.shape[0])); f.write(a.tobytes()); n += 1
                last = seq
            cur = r.wait(last, timeout=min(0.5, max(0.01, end - time.time())))
            fr = r.latest() if cur != last else None
    print(json.dumps({"frames": n, "out": out}))


def read_frames(path):
    fs = []
    with open(path, "rb") as f:
        while True:
            hd = f.read(16)
            if len(hd) < 16:
                break
            t, w, h = struct.unpack("<QII", hd)
            fs.append((t, np.frombuffer(f.read(w * h * 3), np.uint8).reshape(h, w, 3)))
    return fs


def touches(log, t_lo, t_hi):
    ev = []
    if not log or not os.path.exists(log):
        return ev
    rx = re.compile(r"^(\d+) simhid: touch (down|move|up) \(([\d.]+),([\d.]+)\)")
    for line in open(log, errors="replace"):
        m = rx.match(line)
        if m and t_lo - 2e9 <= int(m.group(1)) <= t_hi + 2e9:
            ev.append((int(m.group(1)), m.group(2), float(m.group(3)), float(m.group(4))))
    return ev


def draw_touches(img, ev, t):
    """Xcode-like: a translucent gray dot while the finger is down, a ring that expands on press and fades on release."""
    h, w = img.shape[:2]
    R = max(8, w // 18)
    yy, xx = np.ogrid[:h, :w]
    down, pos = False, None
    for et, ph, x, y in ev:
        if et > t:
            break
        pos = (x * w, y * h)
        down = ph != "up"
        last_ph, last_t = ph, et
    if pos is None:
        return img
    img = img.astype(np.float32)
    d2 = (xx - pos[0]) ** 2 + (yy - pos[1]) ** 2
    if down:
        m = d2 <= R * R
        img[m] = img[m] * 0.45 + np.array([235, 235, 235]) * 0.55
        rim = (d2 <= (R + 2) ** 2) & ~m
        img[rim] = img[rim] * 0.3 + 60 * 0.7
    age = (t - last_t) / 1e9
    if last_ph in ("down", "up") and age < 0.35:
        rr = R * (1.0 + age * 3) if last_ph == "down" else R * (1.0 + age * 1.5)
        a = 0.8 * (1 - age / 0.35)
        ring = (d2 <= (rr + 3) ** 2) & (d2 >= (rr - 1) ** 2)
        col = np.array([255, 255, 255]) if last_ph == "down" else np.array([80, 160, 255])
        img[ring] = img[ring] * (1 - a) + col * a
    return img.clip(0, 255).astype(np.uint8)


def render(src, out, tlog=None, fps=60, label=None, t0=None):
    fs = read_frames(src)
    if not fs:
        sys.exit("no frames")
    ts = [t for t, _ in fs]
    start, stop = ts[0], ts[-1] + int(0.5e9)
    ev = touches(tlog, start, stop)
    h, w = fs[0][1].shape[:2]
    w2, h2 = w - w % 2, h - h % 2
    t0 = t0 or start
    fs_ = max(14, w // 20)
    vf = "drawtext=text='t=%%{pts\\:flt\\:%.3f}':x=10:y=10:fontsize=%d:fontcolor=white:box=1:boxcolor=black@0.6" % ((start - t0) / 1e9, fs_)
    if os.environ.get("SIMRECORD_CLEAN"):   # demo videos: no timer overlay
        vf = "null"
    if label:
        vf += ",drawtext=text='%s':x=w-tw-10:y=10:fontsize=%d:fontcolor=white:box=1:boxcolor=black@0.6" % (label, max(14, w // 20))
    p = subprocess.Popen(["ffmpeg", "-loglevel", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", "%dx%d" % (w2, h2),
                          "-r", str(fps), "-i", "-", "-vf", vf,
                          "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "23", out], stdin=subprocess.PIPE)
    k = 0
    n = int((stop - start) / 1e9 * fps)
    for j in range(n):
        t = start + int(j * 1e9 / fps)
        while k + 1 < len(fs) and fs[k + 1][0] <= t:
            k += 1
        img = fs[k][1]
        if img.shape[:2] != (h, w):
            img = np.zeros((h, w, 3), np.uint8)
        img = draw_touches(img, ev, t)[:h2, :w2]
        p.stdin.write(np.ascontiguousarray(img).tobytes())
    p.stdin.close(); p.wait()
    print(json.dumps({"out": out, "secs": round((stop - start) / 1e9, 2), "frames_in": len(fs), "touch_events": len(ev)}))


def small(img):
    g = img.mean(axis=2) if img.ndim == 3 else img
    h, w = g.shape
    sh, sw = h // 64, w // 32
    return g[:sh * 64, :sw * 32].reshape(64, sh, 32, sw).mean(axis=(1, 3))


def open_metrics(seq, t0):
    """seq: [(t_seconds, small_gray)]. Response = first frame after t0 differing from the last frame before t0;
    content = first frame after t0 within tolerance of the settled final frame (and staying so)."""
    before = [s for t, s in seq if t <= t0]
    base = before[-1] if before else seq[0][1]
    after = [(t, s) for t, s in seq if t > t0]
    if not after:
        return {"error": "no frames after t0"}
    final = after[-1][1]
    resp = next((t for t, s in after if np.abs(s - base).mean() > 2.0), None)
    # content: first frame after the response that resembles the final screen and then stays unchanged for 0.5 s (a
    # blank launch screen doesn't count; a later prompt or live update doesn't move it). Fallback: first frame matching the final screen.
    content = None
    if resp is not None:
        aft = [(t, s) for t, s in after if t >= resp]
        for i, (t, s) in enumerate(aft):
            nxt = [(t2, s2) for t2, s2 in aft[i + 1:] if t2 <= t + 0.5]
            if np.abs(s - base).mean() > 2.0 and np.abs(s - final).mean() < 8.0 and all(np.abs(s2 - s).mean() < 3.0 for _, s2 in nxt) and \
                    (aft[-1][0] >= t + 0.5 or i == len(aft) - 1):
                content = t; break
    if content is None:
        for i, (t, s) in enumerate(after):
            if all(np.abs(s2 - final).mean() < 4.0 for _, s2 in after[i:]):
                content = t; break
    changed = np.abs(final - base).mean()
    return {"response_s": None if resp is None else round(resp - t0, 3),
            "content_s": None if content is None else round(content - t0, 3),
            "final_vs_before": round(float(changed), 1), "frames_after": len(after),
            "fps_during_open": round(len([1 for t, _ in after if content and t <= content]) / max(1e-3, (content or t0) - t0), 1) if content else None}


def mp4_frames(path):
    pts = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v", "-show_entries", "frame=pts_time", "-of", "csv=p=0", path],
                         capture_output=True, text=True).stdout.split()
    raw = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", path, "-vf", "scale=128:256,format=gray", "-fps_mode", "passthrough",
                          "-f", "rawvideo", "-"], capture_output=True).stdout
    n = len(raw) // (128 * 256)
    return [(float(pts[i].strip(",")), small(np.frombuffer(raw[i * 32768:(i + 1) * 32768], np.uint8).reshape(256, 128).astype(np.float32)))
            for i in range(min(n, len(pts)))]


def sbs(left, right, out, labels="ours|Mac", lt0=0.0, rt0=0.0, pre=1.0, secs=None):
    """left|right side by side; each starts `pre` s before its own t0 (video seconds), so the two t0 moments line up;
    the shared timer shows seconds since t0."""
    l1, l2 = labels.split("|")
    lab = "drawtext=text='%s':x=(w-tw)/2:y=h-50:fontsize=30:fontcolor=white:box=1:boxcolor=black@0.6"
    fc = ("[0:v]fps=60,trim=start=%.3f,setpts=PTS-STARTPTS,scale=440:956,%s[a];"
          "[1:v]fps=60,trim=start=%.3f,setpts=PTS-STARTPTS,scale=440:956,%s[b];"
          "[a][b]hstack=inputs=2,drawtext=text='%%{pts\\:flt\\:%.3f}':x=(w-tw)/2:y=8:fontsize=34:fontcolor=yellow:box=1:boxcolor=black@0.7") % (
        max(0, lt0 - pre), lab % l1, max(0, rt0 - pre), lab % l2, -pre)
    cmd = ["ffmpeg", "-loglevel", "error", "-y", "-i", left, "-i", right, "-filter_complex", fc]
    if secs:
        cmd += ["-t", str(secs)]
    subprocess.run(cmd + ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "24", out], check=True)
    print(json.dumps({"out": out}))


def main(a):
    if not a:
        print(__doc__); return
    c = a[0]
    opt = lambda k, d=None: a[a.index(k) + 1] if k in a else d
    if c == "capture":
        capture(a[1], float(a[2]), int(a[3]) if len(a) > 3 else 2)
    elif c == "render":
        render(a[1], a[2], opt("--touches"), int(opt("--fps", 60)), opt("--label"), int(opt("--t0", 0)) or None)
    elif c == "open":
        print(json.dumps(open_metrics([(t / 1e9, small(i.astype(np.float32))) for t, i in read_frames(a[1])], int(a[2]) / 1e9)))
    elif c == "mp4open":
        print(json.dumps(open_metrics(mp4_frames(a[1]), float(a[2]))))
    elif c == "sbs":
        sbs(a[1], a[2], a[3], opt("--labels", "ours|Mac"), float(opt("--lt0", 0)), float(opt("--rt0", 0)), float(opt("--pre", 1)),
            opt("--secs"))
    else:
        print(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
