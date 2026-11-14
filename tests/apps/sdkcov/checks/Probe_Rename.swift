// sdkcov (x86Sim probe, uncommitted): file IDs follow renames — bookmarks / file reference URLs to a renamed file or
// to a file under a renamed directory resolve to the new path, as XNU's fsgetpath does. The detail string is compared
// with Apple's simulator (ref-mac.sh --only func:Foundation.rename).
import Foundation
import Darwin

private func rel(_ u: URL?, _ base: URL) -> String {
    guard let u = u else { return "nil" }
    let p = u.resolvingSymlinksInPath().path, b = base.resolvingSymlinksInPath().path
    return p.hasPrefix(b + "/") ? String(p.dropFirst(b.count + 1)) : (p == b ? "." : "OUT:" + p)
}

private struct Handle {
    let bm: Data?
    let refString: String?
    let fsid: fsid_t
    let ino: UInt64
}

private func take(_ u: URL) -> Handle {
    let bm = try? u.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    let ref = (u as NSURL).fileReferenceURL()
    var st = stat(), sf = statfs()
    _ = lstat(u.path, &st); _ = statfs(u.path, &sf)
    return Handle(bm: bm, refString: ref?.absoluteString, fsid: sf.f_fsid, ino: UInt64(st.st_ino))
}

private func resolve(_ h: Handle, _ base: URL) -> String {
    var stale = false
    var b = "nil"
    if let bm = h.bm, let u = try? URL(resolvingBookmarkData: bm, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale) {
        b = rel(u, base) + (stale ? "(stale)" : "")
    }
    // a fresh reference URL from its string: resolved through fsgetpath, nothing cached in the object
    var r = "nil"
    if let s = h.refString, let ref = NSURL(string: s), let p = ref.filePathURL { r = rel(p, base) }
    var buf = [CChar](repeating: 0, count: 1024)
    var fsid = h.fsid
    let n = fsgetpath(&buf, buf.count, &fsid, h.ino)
    let f = n > 0 ? rel(URL(fileURLWithPath: String(cString: buf)), base) : "E\(errno)"
    return "\(b)|\(r)|\(f)"
}

private func touch(_ u: URL, _ s: String) throws { try s.data(using: .utf8)!.write(to: u) }

extension Registry {
    static var rename_probe: [Check] { [
        check("Foundation", "rename-follows-id") {
            let fm = FileManager.default
            let d = fm.temporaryDirectory.appendingPathComponent("sdkcov-ren-\(UUID().uuidString)")
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: d) }
            func u(_ p: String) -> URL { d.appendingPathComponent(p) }
            var out: [String] = []
            // 1. file rename
            try touch(u("a.txt"), "a"); let ha = take(u("a.txt"))
            try expect(rename(u("a.txt").path, u("b.txt").path) == 0, "rename a")
            out.append("file=" + resolve(ha, d))
            // 2. parent directory rename; a sibling directory sharing the prefix must not move
            try fm.createDirectory(at: u("p"), withIntermediateDirectories: true)
            try fm.createDirectory(at: u("pq"), withIntermediateDirectories: true)
            try touch(u("p/c.txt"), "c"); try touch(u("pq/y.txt"), "y")
            let hc = take(u("p/c.txt")), hy = take(u("pq/y.txt")), hp = take(u("p"))
            try expect(rename(u("p").path, u("p2").path) == 0, "rename dir")
            out.append("dirchild=" + resolve(hc, d)); out.append("prefixsib=" + resolve(hy, d)); out.append("dir=" + resolve(hp, d))
            // 3. nested: directory renamed twice, then the file in it
            try fm.createDirectory(at: u("n1/n2"), withIntermediateDirectories: true)
            try touch(u("n1/n2/z.txt"), "z"); let hz = take(u("n1/n2/z.txt"))
            try expect(rename(u("n1").path, u("m1").path) == 0 && rename(u("m1/n2").path, u("m1/m2").path) == 0
                && rename(u("m1/m2/z.txt").path, u("m1/m2/zz.txt").path) == 0, "nested renames")
            out.append("nested=" + resolve(hz, d))
            // 4. rename over an existing file
            try touch(u("s.txt"), "s"); try touch(u("t.txt"), "t")
            let hs = take(u("s.txt")), ht = take(u("t.txt"))
            try expect(rename(u("s.txt").path, u("t.txt").path) == 0, "rename over")
            out.append("over.src=" + resolve(hs, d)); out.append("over.dst=" + resolve(ht, d))
            // 5. RENAME_SWAP of two files and of two directories with children
            try touch(u("u.txt"), "u"); try touch(u("v.txt"), "v")
            let hu = take(u("u.txt")), hv = take(u("v.txt"))
            let sw = renamex_np(u("u.txt").path, u("v.txt").path, UInt32(RENAME_SWAP))
            out.append("swap.rc=\(sw == 0 ? "0" : "E\(errno)")")
            out.append("swap.u=" + resolve(hu, d)); out.append("swap.v=" + resolve(hv, d))
            try fm.createDirectory(at: u("da"), withIntermediateDirectories: true)
            try fm.createDirectory(at: u("db"), withIntermediateDirectories: true)
            try touch(u("da/f1"), "1"); try touch(u("db/f2"), "2")
            let h1 = take(u("da/f1")), h2 = take(u("db/f2"))
            let sw2 = renamex_np(u("da").path, u("db").path, UInt32(RENAME_SWAP))
            out.append("dswap.rc=\(sw2 == 0 ? "0" : "E\(errno)")")
            out.append("dswap.f1=" + resolve(h1, d)); out.append("dswap.f2=" + resolve(h2, d))
            // 6. RENAME_EXCL onto a free name, and onto an existing one (EEXIST)
            try touch(u("e.txt"), "e"); let he = take(u("e.txt"))
            let ex = renamex_np(u("e.txt").path, u("e2.txt").path, UInt32(RENAME_EXCL))
            try touch(u("e3.txt"), "e3")
            let ex2 = renamex_np(u("e2.txt").path, u("e3.txt").path, UInt32(RENAME_EXCL)); let ex2e = errno
            out.append("excl.rc=\(ex)/\(ex2 == 0 ? "0" : "E\(ex2e)")"); out.append("excl=" + resolve(he, d))
            // 7. delete, then a new file at the old path: the old ID must not resolve to the new file
            try touch(u("r.txt"), "r"); let hr = take(u("r.txt"))
            try fm.removeItem(at: u("r.txt")); try touch(u("r.txt"), "r-new")
            var st = stat(); _ = lstat(u("r.txt").path, &st)
            out.append("recreate=" + resolve(hr, d) + (UInt64(st.st_ino) == hr.ino ? "(sameino)" : ""))
            // 8. renamed away, then a new file at the old path
            try touch(u("w.txt"), "w"); let hw = take(u("w.txt"))
            try expect(rename(u("w.txt").path, u("w2.txt").path) == 0, "rename w"); try touch(u("w.txt"), "w-new")
            out.append("movedaway=" + resolve(hw, d))
            return out.joined(separator: " ")
        },
        check("Foundation", "rename-timing", timeout: 120) {
            let fm = FileManager.default
            let d = fm.temporaryDirectory.appendingPathComponent("sdkcov-rent-\(UUID().uuidString)")
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: d) }
            func ms(_ n: Int, _ a: String, _ b: String) throws -> Int {
                let t0 = DispatchTime.now().uptimeNanoseconds
                for i in 0..<n {
                    let (x, y) = i % 2 == 0 ? (a, b) : (b, a)
                    try expect(rename(d.appendingPathComponent(x).path, d.appendingPathComponent(y).path) == 0, "rename \(i)")
                }
                return Int((DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
            }
            try touch(d.appendingPathComponent("plain"), "x")
            let plain = try ms(10_000, "plain", "plain2")
            try touch(d.appendingPathComponent("known"), "x"); _ = take(d.appendingPathComponent("known"))
            let known = try ms(10_000, "known", "known2")
            try fm.createDirectory(at: d.appendingPathComponent("dir/sub"), withIntermediateDirectories: true)
            try touch(d.appendingPathComponent("dir/sub/f"), "x"); _ = take(d.appendingPathComponent("dir/sub/f"))
            let dir = try ms(10_000, "dir", "dir2")
            return "10k renames: plain \(plain) ms, known-ID \(known) ms, dir \(dir) ms"
        },
    ] }
}
