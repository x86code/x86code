#!/usr/bin/env python3
"""x86Sim MetalCoverage: one HTML page from a run (run.sh's <dir>/results.tsv, covers.tsv) and the SDK inventory:
per-test results, and how much of the iOS Metal protocol API the passing / failing tests exercise.
   report.py <run dir>   -> <run dir>/report.html"""
import collections, csv, html, json, os, subprocess, sys

H = os.path.dirname(os.path.abspath(__file__))
run = sys.argv[1]
rows = list(csv.DictReader(open(os.path.join(run, "results.tsv")), delimiter="\t"))
covers = {}
for line in open(os.path.join(run, "covers.tsv")):
    t, _, c = line.rstrip("\n").partition("\t")
    covers[t] = [x.strip() for x in c.split(";") if x.strip()]
inv = json.loads(subprocess.run([sys.executable, "-I", os.path.join(H, "inventory.py"), "-"], capture_output=True).stdout)
api = {(r["owner"], r["sel"]) for r in inv if r["kind"] == "protocol" and not r["unavailable_ios"]}
status = {r["test"]: r["status"] for r in rows}
by_sel = collections.defaultdict(set)
for t, cs in covers.items():
    for c in cs:
        owner, _, sel = c.partition(" ")
        if (owner, sel) in api: by_sel[(owner, sel)].add(status.get(t, "?"))
passing = {k for k, v in by_sel.items() if "PASS" in v}
failing = {k for k, v in by_sel.items() if "PASS" not in v}
owners = collections.Counter(o for o, _ in api)
cov_rows = []
for o in sorted(owners, key=lambda o: -owners[o]):
    p = sum(1 for k in passing if k[0] == o); f = sum(1 for k in failing if k[0] == o)
    cov_rows.append(f"<tr><td>{o}</td><td>{owners[o]}</td><td class=ok>{p}</td><td class=bad>{f}</td>"
                    f"<td>{owners[o] - p - f}</td><td><span class=bar><i style='width:{100 * p / owners[o]:.0f}%'></i>"
                    f"<b style='width:{100 * f / owners[o]:.0f}%'></b></span></td></tr>")
counts = collections.Counter(r["status"] for r in rows)
hidden = [r for r in rows if r["status"] == "PASS" and r["claimed"] == "0"]
areas = collections.defaultdict(list)
for r in rows: areas[r["test"].split("/")[0]].append(r)
res_rows = []
for a in sorted(areas):
    for r in sorted(areas[a], key=lambda r: r["test"]):
        cls = {"PASS": "ok", "SKIP": "skip", "CLIENT": "skip", "REFUSED": "skip"}.get(r["status"], "bad")
        note = " <span class=hid>works, not claimed</span>" if r["status"] == "PASS" and r["claimed"] == "0" else ""
        res_rows.append(f"<tr><td>{html.escape(r['test'])}</td><td class={cls}>{r['status']}{note}</td><td>{r['ms']}</td>"
                        f"<td class=d>{html.escape(r['detail'])}</td></tr>")
summary = " · ".join(f"{k} {v}" for k, v in sorted(counts.items()))
page = f"""<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Metal Coverage</title><style>
:root{{--bg:#fafaf8;--fg:#1d1d1d;--mut:#666;--line:#ddd;--ok:#1b7a3a;--bad:#b3261e;--warn:#966a00;--card:#fff}}
@media (prefers-color-scheme:dark){{:root:not([data-theme="light"]){{--bg:#141414;--fg:#eee;--mut:#aaa;--line:#333;--ok:#5cc47c;--bad:#ff8a80;--warn:#e6b450;--card:#1e1e1e}}}}
:root[data-theme="dark"]{{--bg:#141414;--fg:#eee;--mut:#aaa;--line:#333;--ok:#5cc47c;--bad:#ff8a80;--warn:#e6b450;--card:#1e1e1e}}
body{{background:var(--bg);color:var(--fg);font:14px/1.45 system-ui,sans-serif;margin:0;padding:16px;max-width:1200px}}
h1{{font-size:20px;margin:0}} h2{{font-size:16px;margin:24px 0 8px}} p{{color:var(--mut)}}
.wrap{{overflow-x:auto}} table{{border-collapse:collapse;width:100%;background:var(--card)}}
td,th{{border-bottom:1px solid var(--line);padding:4px 8px;text-align:left;vertical-align:top}}
.ok{{color:var(--ok);font-weight:600}} .bad{{color:var(--bad);font-weight:600}} .skip{{color:var(--mut)}}
.hid{{color:var(--warn);font-weight:400;font-size:12px}} .d{{font-family:ui-monospace,monospace;font-size:12px;word-break:break-word}}
.bar{{display:inline-flex;width:120px;height:8px;background:var(--line);border-radius:4px;overflow:hidden}}
.bar i{{background:var(--ok)}} .bar b{{background:var(--bad)}}
</style></head><body>
<h1>Metal Coverage</h1><p>{len(rows)} tests · {summary} · {len(hidden)} work on this device though it does not claim them.<br>
iOS Metal protocol API: {len(api)} methods/properties; exercised by a passing test {len(passing)} ({100 * len(passing) / len(api):.0f}%),
only by failing tests {len(failing)}, untested {len(api) - len(passing) - len(failing)}.</p>
<h2>Tests</h2><div class=wrap><table><tr><th>test</th><th>result</th><th>ms</th><th>detail</th></tr>{"".join(res_rows)}</table></div>
<h2>API coverage by protocol</h2><div class=wrap><table><tr><th>protocol</th><th>members</th><th>passing</th><th>failing</th><th>untested</th><th></th></tr>
{"".join(cov_rows)}</table></div></body></html>"""
open(os.path.join(run, "report.html"), "w").write(page)
print(f"{len(rows)} tests {summary}; API {len(passing)}/{len(api)} passing, {len(failing)} failing-only", file=sys.stderr)
