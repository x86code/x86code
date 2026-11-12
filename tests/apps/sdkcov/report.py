#!/usr/bin/env python3
"""x86Sim sdkcov: Markdown report of one run (results.txt + coverage.json in the run's OUT dir, from run.sh).
Usage: tests/apps/sdkcov/report.py <out-dir>"""
import collections, json, os, sys

out = sys.argv[1]
res = collections.OrderedDict()
for l in open(os.path.join(out, "results.txt"), errors="replace"):
    f = l.rstrip("\n").split(" ", 4)
    if len(f) >= 4 and f[0] == "X86TEST":
        res[f[2]] = (f[3], f[4] if len(f) > 4 else "")
cov = {}
try:
    cov = json.load(open(os.path.join(out, "coverage.json")))
except (OSError, ValueError):
    pass
cnt = collections.Counter(s for k, (s, _) in res.items() if k.startswith(("load:", "func:")))
loads = [k for k in res if k.startswith("load:")]
funcs = [k for k in res if k.startswith("func:")]
p = cov.get("platform", "?")
print(f"# sdkcov {p}: {cov.get('sdk', '')} on {cov.get('os', '')}\n")
print(f"- runtime `{cov.get('runtime', '')}`, finished: {'yes' if 'done' in res else 'NO'}")
print(f"- {len(loads)} SDK frameworks/libraries: " + ", ".join(f"{n} {s}" for s, n in collections.Counter(res[k][0] for k in loads).most_common()))
print(f"- {len(funcs)} functional checks: " + ", ".join(f"{n} {s}" for s, n in collections.Counter(res[k][0] for k in funcs).most_common()))
if "coverage" in res:
    print(f"- coverage: {res['coverage'][1]}")
items = cov.get("items", [])
if items:
    lv = collections.Counter(i["level"] for i in items)
    print(f"- depth: {lv['functional']} with functional checks, {lv['load']} load + symbol only, {lv['skip']} skipped"
          f"; Swift modules with checks: {', '.join(cov.get('swiftModules', []))}")
print("\n## Failures\n")
fails = [(k, d) for k, (s, d) in res.items() if s == "FAIL"]
print("\n".join(f"- `{k}` {d}" for k, d in fails) or "none")
print("\n## Skipped (not supported in Apple's simulator, or not app API)\n")
print("\n".join(f"- `{k}` {d}" for k, (s, d) in res.items() if s == "SKIP") or "none")
if items:
    print("\n## Per framework\n\n| framework | load | functional |\n|---|---|---|")
    for i in items:
        fs = ", ".join(f"{f['check']} {f['status']}" for f in i["functional"]) or "—"
        print(f"| {i['name']} | {i['load']} | {fs} |")
