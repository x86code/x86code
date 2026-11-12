#!/usr/bin/env python3
"""Every Metal protocol/class method and property the iOS-simulator SDK declares, with its iOS availability, from clang's
AST of <Metal/Metal.h>: the checklist MetalCoverage's tests are measured against (report.py).
   inventory.py [out.json|-]   (X86SIM_SDK: another SDK, e.g. XRSimulator.sdk; default the repo's sdks/iPhoneSimulator.sdk)
The iOS simulator SDK's MTL4*.h are empty stubs: no Metal 4 on the simulator.
   [{"kind": "protocol"|"interface", "owner": "MTLDevice", "sel": "newBufferWithLength:options:", "prop": bool,
     "ios": "8.0" | null, "unavailable_ios": bool, "header": "MTLDevice.h"}]"""
# x86Sim: tests/metal/coverage (MetalCoverage)
import json, os, re, subprocess, sys
SDK = os.environ.get("X86SIM_SDK") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../../sdks/iPhoneSimulator.sdk")
OUT = sys.argv[1] if len(sys.argv) > 1 else "-"
src = "#import <Metal/Metal.h>\n"
ast = subprocess.run(["clang", "-x", "objective-c", "-fsyntax-only", "--target=arm64-apple-ios27.0-simulator",
                      "-isysroot", SDK, "-Xclang", "-ast-dump=json", "-Xclang", "-ast-dump-filter=MTL", "-"],
                     input=src.encode(), capture_output=True)
# -ast-dump-filter prints several JSON documents back to back
dec = json.JSONDecoder(); text = ast.stdout.decode(); i = 0; docs = []
while i < len(text):
    while i < len(text) and text[i] in " \r\n\t": i += 1
    if i >= len(text): break
    o, i = dec.raw_decode(text, i); docs.append(o)


def avail(node):
    ios, unavail = None, False
    for a in node.get("inner", []):
        if a.get("kind") == "AvailabilityAttr":
            pass
    return ios, unavail


def header_of(node):
    loc = node.get("loc", {})
    f = loc.get("file") or loc.get("spellingLoc", {}).get("file") or loc.get("expansionLoc", {}).get("file") or ""
    return f


rows, seen = [], set()
for d in docs:
    k = d.get("kind")
    if k not in ("ObjCProtocolDecl", "ObjCInterfaceDecl"): continue
    owner = d.get("name", "")
    if not owner.startswith("MTL"): continue
    for m in d.get("inner", []):
        mk = m.get("kind")
        if mk not in ("ObjCMethodDecl", "ObjCPropertyDecl"): continue
        sel = m.get("name")
        key = (owner, sel, mk)
        if key in seen: continue
        seen.add(key)
        if mk == "ObjCMethodDecl" and m.get("isImplicit"): continue
        rows.append({"kind": "protocol" if k == "ObjCProtocolDecl" else "interface", "owner": owner, "sel": sel,
                     "prop": mk == "ObjCPropertyDecl", "class_method": m.get("instance") is False})
# availability: clang's JSON dump omits AvailabilityAttr details, so read API_AVAILABLE/API_UNAVAILABLE from the text
H = os.path.join(SDK, "System/Library/Frameworks/Metal.framework/Headers")
text_by_owner = {}
for fn in sorted(os.listdir(H)):
    if not fn.endswith(".h"): continue
    t = open(os.path.join(H, fn), errors="replace").read()
    for m in re.finditer(r"@(protocol|interface)\s+(MTL\w+)(.*?)@end", t, re.S):
        text_by_owner.setdefault(m.group(2), []).append((fn, m.group(3), t[max(0, m.start() - 400):m.start()]))
for r in rows:
    r["header"] = None; r["ios"] = None; r["unavailable_ios"] = False
    first = r["sel"].split(":")[0]
    for fn, body, pre in text_by_owner.get(r["owner"], []):
        r["header"] = fn
        # the declaration's line (methods: the first keyword; properties: the name)
        pat = (r"\b" + re.escape(first) + (r"\s*;" if r["prop"] else (r"\s*:" if ":" in r["sel"] else r"\b")))
        mm = re.search(pat, body)
        if not mm: continue
        line_start = body.rfind(";", 0, mm.start()) + 1
        decl = body[line_start:body.find(";", mm.end() - 1) + 1]
        scope = decl + " " + pre  # declaration's own attributes, else the owner's
        if re.search(r"API_UNAVAILABLE\([^)]*\bios\b", decl): r["unavailable_ios"] = True
        v = re.search(r"\bios\((\d+(?:\.\d+)*)\)", decl) or re.search(r"\bios\((\d+(?:\.\d+)*)\)", pre)
        if v: r["ios"] = v.group(1)
        if not v and re.search(r"API_UNAVAILABLE\([^)]*\bios\b", pre): r["unavailable_ios"] = True
        break
json.dump(rows, sys.stdout if OUT == "-" else open(OUT, "w"), indent=0)
by = {}
for r in rows:
    if r["unavailable_ios"]: continue
    by[r["owner"]] = by.get(r["owner"], 0) + 1
print(f"{len(rows)} declarations, {sum(by.values())} available on iOS, {len(by)} owners -> {OUT}", file=sys.stderr)
for o, n in sorted(by.items(), key=lambda x: -x[1])[:25]:
    print(f"  {o:45s} {n}", file=sys.stderr)
