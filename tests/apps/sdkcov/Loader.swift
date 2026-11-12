// sdkcov tier 1: every framework / library the SDK offers (manifest.json, gen-manifest.py) is dlopened by its
// install name and its representative exports resolve (Objective-C classes through the runtime, the rest by dlsym).
import Foundation
import ObjectiveC

enum Loader {
    static func load(_ it: ManifestItem) throws -> String {
        guard let path = it.path else { throw Skip(it.reason ?? "no install name") }
        guard let h = dlopen(path, RTLD_LAZY | RTLD_GLOBAL) else {
            throw Fail("dlopen: \(String(cString: dlerror()))")
        }
        var found: [String] = [], missing: [String] = []
        for p in it.probes ?? [] {
            if let c = p["objc"] {
                // a Swift class with resilient ancestry is a class stub: not in the runtime's table until first use,
                // so also its exported class symbol
                (NSClassFromString(c) != nil || dlsym(h, "OBJC_CLASS_$_\(c)") != nil ? { found.append(c) } : { missing.append("class \(c)") })()
            } else if let s = p["sym"] {
                (dlsym(h, s) != nil ? { found.append(s) } : { missing.append("symbol \(s)") })()
            }
        }
        try expect(missing.isEmpty, "loaded, but missing \(missing.joined(separator: ", "))")
        return found.isEmpty ? "loaded" : "loaded; \(found.joined(separator: ", "))"
    }
}
