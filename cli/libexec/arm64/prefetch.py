#!/usr/bin/env python3
# x86Sim (Speed 11): warm the host page cache for an arm64 boot. The host runs under memory pressure, and the boot's
# hot file pages (the AOT image .map/.idx and the dyld cache, ~0.9 GB) are often evicted between boots. They then come
# back as thousands of small random page faults from the encrypted disk while dyld_sim and the first processes wait
# (SpringBoard's dyld prepare took 3.5-12 s depending on it).
#
#   prefetch.py record HOTFILE FILE...   save the ranges of each FILE that running processes have mapped in (pagemap)
#   prefetch.py apply HOTFILE...          posix_fadvise(WILLNEED) on those ranges: large sequential reads, in the order
#                                         saved, started before launchd_sim (inside the boot's IO-capped scope)
#   prefetch.py record-seq HOTFILE SECS STEP FILE...
#                                         (Speed 14) snapshot every STEP s for SECS s and save the pages by the time
#                                         they first showed up (then by offset): the boot's first-touch order
#   prefetch.py read HOTFILE...           read those ranges in the saved order (real reads, so the order holds)
# Files that changed size since the record are skipped. No host setting is touched.
import json, os, re, sys

PAGE = os.sysconf("SC_PAGE_SIZE")
GAP = 64 << 10     # merge used runs closer than this (one read instead of many)


# pagemap entry -> 1 if present (bit 63, the top bit of the entry's last byte) else 0, one byte per page
PRESENT = bytes(1 if b & 0x80 else 0 for b in range(256))


def or_into(mask, o, bits):
    """mask[o:o+len(bits)] |= bits (byte masks, 0/1 per page), growing mask as needed; C-speed via big ints"""
    n = len(bits)
    if len(mask) < o + n:
        mask.extend(bytes(o + n - len(mask)))
    v = int.from_bytes(mask[o:o + n], "little") | int.from_bytes(bits, "little")
    mask[o:o + n] = v.to_bytes(n, "little")


def used_pages(paths):
    """{path: bytearray, one byte per file page: 1 = present in some process's mapping of that file (/proc/PID/pagemap
    bit 63)}. Speed (2026-11-13): the pages were tested one by one in Python: a record-seq pass over a booting device
    (~100 processes mapping the multi-GB dyld cache) took 15+ CPU s per boot; the masks are built with
    bytes.translate and big-int ORs instead."""
    want = {os.path.realpath(p): p for p in paths if not p.endswith("/")}
    dirs = tuple(os.path.realpath(p) + "/" for p in paths if p.endswith("/"))  # every mapped file under these
    used = {p: bytearray() for p in want.values()}
    for pid in filter(str.isdigit, os.listdir("/proc")):
        try:
            maps = open(f"/proc/{pid}/maps").read().splitlines()
            pm = None
            for l in maps:
                f = l.split(None, 5)
                # a file replaced while mapped ("... (deleted)", e.g. libarm64jit.so after a rebuild): its pages are
                # not the file's on disk, and getsize() on that name crashed the recording
                if len(f) < 6 or f[5].endswith(" (deleted)"):
                    continue
                if f[5] not in want:
                    if not (dirs and f[5].startswith(dirs)):
                        continue
                    want[f[5]] = f[5]
                    used[f[5]] = bytearray()
                lo, hi = (int(x, 16) for x in f[0].split("-"))
                off = int(f[2], 16)
                if pm is None:
                    pm = open(f"/proc/{pid}/pagemap", "rb")
                pm.seek(lo // PAGE * 8)
                ents = pm.read((hi - lo) // PAGE * 8)
                bits = ents[7::8].translate(PRESENT)
                if 1 in bits:
                    or_into(used[want[f[5]]], off // PAGE, bits)
            if pm:
                pm.close()
        except OSError:
            continue
    return used


def ranges_of(mask, size):
    """byte ranges [a, b) of the pages set in mask, runs closer than GAP merged"""
    ranges = []
    for m in re.finditer(rb"\x01+", mask):
        a, b = m.start() * PAGE, min(m.end() * PAGE, size)
        if a >= b:
            continue
        if ranges and a - ranges[-1][1] <= GAP:
            ranges[-1][1] = b
        else:
            ranges.append([a, b])
    return ranges


def existing(files):
    """The files that exist (a shell glob that matched nothing arrives literally, e.g. jc/*.map before the image's
    first load has made its map: that crashed the recording, so the next boot prefetched nothing)."""
    return [f for f in files if f.endswith("/") or os.path.exists(f)]


def record(hot, files):
    files = existing(files)
    out = []
    for p, mask in used_pages(files).items():
        try:
            size = os.path.getsize(p)
        except OSError:
            continue
        rs = ranges_of(mask, size)
        out.append({"path": p, "size": size, "ranges": rs})
        print(f"prefetch: {os.path.basename(p)}: {mask.count(1) * PAGE >> 20} MB used, {sum(b - a for a, b in rs) >> 20} MB in {len(rs)} ranges")
    tmp = hot + ".new"
    with open(tmp, "w") as f:
        json.dump(out, f)
    os.replace(tmp, hot)


def record_seq(hot, secs, step, files):
    files = existing(files)
    import time
    seen = {}    # path -> int bitmask (byte per page) of the pages seen so far
    first = {}   # path -> {step bucket: bytes mask of the pages first present in it}
    t0 = time.monotonic()
    while True:
        t = time.monotonic() - t0
        k = int(t // step)
        for p, mask in used_pages(files).items():
            cur = int.from_bytes(mask, "little")
            new = cur & ~seen.get(p, 0)
            if new:
                first.setdefault(p, {})[k] = new.to_bytes(len(mask), "little")
                seen[p] = seen.get(p, 0) | cur
        if t >= secs:
            break
        time.sleep(max(0.0, step - (time.monotonic() - t0 - t)))
    out = []
    total = 0
    for p, buckets in first.items():
        try:
            size = os.path.getsize(p)
        except OSError:  # gone since it was mapped (an image rebuilt during the recording)
            continue
        # ranges per step bucket, so each range carries the time its pages were first needed
        rs = [[a, b, k * step] for k, m in buckets.items() for a, b in ranges_of(m, size)]
        out.append({"path": p, "size": size, "ranges": sorted([a, b] for a, b, _ in rs), "timed": rs})
        n = sum(m.count(1) for m in buckets.values())
        total += n
        if n * PAGE < (4 << 20):
            continue
        print(f"prefetch: {os.path.basename(p)}: {n * PAGE >> 20} MB used by {secs:.0f} s, "
              + " ".join(f"{k * step:.0f}s:{m.count(1) * PAGE >> 20}" for k, m in sorted(buckets.items())))
    print(f"prefetch: {len(out)} files, {total * PAGE >> 20} MB by {secs:.0f} s")
    tmp = hot + ".new"
    with open(tmp, "w") as f:
        json.dump(out, f)
    os.replace(tmp, hot)


def read_ordered(hot):
    try:
        entries = json.load(open(hot))
    except (OSError, ValueError):
        return
    work = []
    for e in entries:
        try:
            fd = os.open(e["path"], os.O_RDONLY)
        except OSError:
            continue
        if os.fstat(fd).st_size != e["size"]:
            os.close(fd)
            continue
        work += [(t, fd, a, b) for a, b, t in e.get("timed", [[a, b, 0] for a, b in e["ranges"]])]
    total = 0
    buf = bytearray(1 << 20)
    for t, fd, a, b in sorted(work, key=lambda w: (w[0], w[1], w[2])):
        while a < b:
            n = os.preadv(fd, [memoryview(buf)[:min(len(buf), b - a)]], a)
            if n <= 0:
                break
            a += n
            total += n
    for fd in {w[1] for w in work}:
        os.close(fd)
    print(f"prefetch: read {total >> 20} MB")


def apply(hot):
    try:
        entries = json.load(open(hot))
    except (OSError, ValueError):
        return
    total = 0
    for e in entries:
        try:
            fd = os.open(e["path"], os.O_RDONLY)
        except OSError:
            continue
        try:
            if os.fstat(fd).st_size != e["size"]:
                continue
            for a, b in e["ranges"]:
                os.posix_fadvise(fd, a, b - a, os.POSIX_FADV_WILLNEED)
                total += b - a
        finally:
            os.close(fd)
    print(f"prefetch: requested {total >> 20} MB")


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "record":
        record(sys.argv[2], sys.argv[3:])
    elif len(sys.argv) >= 6 and sys.argv[1] == "record-seq":
        record_seq(sys.argv[2], float(sys.argv[3]), float(sys.argv[4]), sys.argv[5:])
    elif len(sys.argv) >= 3 and sys.argv[1] == "read":
        for h in sys.argv[2:]:
            read_ordered(h)
    elif len(sys.argv) >= 3 and sys.argv[1] == "apply":
        for h in sys.argv[2:]:
            apply(h)
    else:
        sys.exit(__doc__ or "usage: prefetch.py record HOTFILE FILE... | apply HOTFILE")
