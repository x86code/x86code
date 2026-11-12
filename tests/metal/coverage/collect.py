#!/usr/bin/env python3
"""x86Sim MetalCoverage: the launch logs of one run (<dir>/launch-<from>.log, each from MTLCOV_FROM=<from> until the
app exited) -> <dir>/results.tsv and covers.tsv. A test that began and has no result is charged with how the launch
ended: HANG (the app's watchdog), REFUSED (an assertion of Apple's simulator client or Metal's validation, as on a
Mac's simulator) or CRASH.
   collect.py <dir>"""
import glob, os, re, sys

d = sys.argv[1]
results, covers = {}, {}
for path in sorted(glob.glob(os.path.join(d, "launch-*.log")), key=lambda p: int(re.search(r"launch-(\d+)", p).group(1))):
    text = open(path, "rb").read().decode("utf-8", "replace")
    lines = text.splitlines()
    begun = None
    for ln in lines:
        m = re.match(r"^MTLCOV BEGIN (\d+) (\S+)", ln)
        if m: begun = (int(m.group(1)), m.group(2)); continue
        m = re.match(r"^MTLCOV COVERS (\S+) ?(.*)$", ln)
        if m: covers[m.group(1)] = m.group(2); continue
        m = re.match(r"^MTLCOV RESULT (\d+) (\S+) (\S+) (\d+) claimed=(\d) ?(.*)$", ln)
        if m:
            results[int(m.group(1))] = (m.group(2), m.group(3), m.group(4), m.group(5), m.group(6))
            begun = None
    if begun and begun[0] not in results:
        i, name = begun
        why = "HANG" if re.search(rf"^MTLCOV HANG {i} ", text, re.M) else "CRASH"
        sig = re.search(r"(failed assertion.*|exception reason.*|guest pc in.*|signal \d+ code.*)", text)
        sig = sig.group(1)[:200].replace("\t", " ") if sig else ""
        if why == "CRASH" and "failed assertion" in sig: why = "REFUSED"
        results[i] = (name, why, "0", "1", sig)
with open(os.path.join(d, "results.tsv"), "w") as f:
    f.write("index\ttest\tstatus\tms\tclaimed\tdetail\n")
    for i in sorted(results):
        f.write("\t".join([str(i), *results[i]]) + "\n")
with open(os.path.join(d, "covers.tsv"), "w") as f:
    for t, c in covers.items(): f.write(f"{t}\t{c}\n")
print(f"{len(results)} results", file=sys.stderr)
