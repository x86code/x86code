// sdkcov functional checks: the C libraries in usr/lib that have no Swift module in the SDK (bzip2, xz, iconv, expat,
// libxslt, libarchive, cmark, libffi, tidy, ...). Their functions are looked up by dlsym in the library itself, by its
// install name, so each check exercises exactly the library it is filed under, and each round-trips real data.
import Foundation
import ObjectiveC

/// function `name` of /usr/lib/<lib>.dylib as the C function type T
func cfunc<T>(_ lib: String, _ name: String, _: T.Type) throws -> T {
    guard let h = dlopen("/usr/lib/\(lib).dylib", RTLD_NOW) else { throw Fail("dlopen \(lib): \(String(cString: dlerror()))") }
    guard let p = dlsym(h, name) else { throw Fail("\(lib): no \(name)") }
    return unsafeBitCast(p, to: T.self)
}
/// data symbol `name` of /usr/lib/<lib>.dylib
func csym(_ lib: String, _ name: String) throws -> UnsafeMutableRawPointer {
    guard let h = dlopen("/usr/lib/\(lib).dylib", RTLD_NOW), let p = dlsym(h, name) else { throw Fail("\(lib): no \(name)") }
    return p
}

private let sampleText = String(repeating: "x86sim runs Apple's simulator runtimes on Linux. ", count: 200)

extension Registry {
    static var libraries: [Check] {
        var c: [Check] = [
        check("libbz2.1.0", "buffer-roundtrip") {
            typealias Comp = @convention(c) (UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<CChar>?, UInt32, Int32, Int32, Int32) -> Int32
            typealias Decomp = @convention(c) (UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<CChar>?, UInt32, Int32, Int32) -> Int32
            let comp = try cfunc("libbz2.1.0", "BZ2_bzBuffToBuffCompress", Comp.self)
            let decomp = try cfunc("libbz2.1.0", "BZ2_bzBuffToBuffDecompress", Decomp.self)
            var src = Array(sampleText.utf8CString)
            var out = [CChar](repeating: 0, count: src.count + 1024); var n = UInt32(out.count)
            try expect(comp(&out, &n, &src, UInt32(src.count), 9, 0, 30) == 0, "compress")   // BZ_OK
            try expect(n > 0 && Int(n) < src.count / 10, "compressed \(src.count) to \(n) B")
            var back = [CChar](repeating: 0, count: src.count); var bn = UInt32(back.count)
            try expect(decomp(&back, &bn, &out, n, 0, 0) == 0 && back == src, "decompress \(bn) B")
            return "\(src.count) -> \(n) B"
        },
        check("liblzma.5", "xz-buffer-roundtrip") {
            typealias Enc = @convention(c) (UInt32, Int32, OpaquePointer?, UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<Int>?, Int) -> Int32
            typealias Dec = @convention(c) (UnsafeMutablePointer<UInt64>?, UInt32, OpaquePointer?, UnsafePointer<UInt8>?, UnsafeMutablePointer<Int>?, Int, UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<Int>?, Int) -> Int32
            let enc = try cfunc("liblzma.5", "lzma_easy_buffer_encode", Enc.self), dec = try cfunc("liblzma.5", "lzma_stream_buffer_decode", Dec.self)
            let ver = try cfunc("liblzma.5", "lzma_version_string", (@convention(c) () -> UnsafePointer<CChar>).self)
            let src = Array(sampleText.utf8)
            var out = [UInt8](repeating: 0, count: src.count + 1024); var n = 0
            try expect(enc(6, 4 /* LZMA_CHECK_CRC64 */, nil, src, src.count, &out, &n, out.count) == 0, "encode")   // LZMA_OK
            try expect(n > 0 && n < src.count / 10 && out[0] == 0xfd && out[1] == 0x37, "xz stream \(n) B, magic \(out.prefix(2))")
            var back = [UInt8](repeating: 0, count: src.count); var inPos = 0, outPos = 0, limit = UInt64.max
            try expect(dec(&limit, 0, nil, out, &inPos, n, &back, &outPos, back.count) == 0 && back == src, "decode \(outPos) B")
            return "xz \(String(cString: ver())): \(src.count) -> \(n) B"
        },
        check("libiconv.2", "charset-conversion") {
            typealias Open = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> UnsafeMutableRawPointer?
            typealias Conv = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, UnsafeMutablePointer<Int>?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, UnsafeMutablePointer<Int>?) -> Int
            let open = try cfunc("libiconv.2", "iconv_open", Open.self), conv = try cfunc("libiconv.2", "iconv", Conv.self)
            let close = try cfunc("libiconv.2", "iconv_close", (@convention(c) (UnsafeMutableRawPointer?) -> Int32).self)
            func convert(_ bytes: [UInt8], from: String, to: String) throws -> [UInt8] {
                guard let cd = open(to, from), Int(bitPattern: cd) != -1 else { throw Fail("iconv_open \(from) -> \(to)") }
                defer { _ = close(cd) }
                var inb = bytes.map { CChar(bitPattern: $0) }, out = [CChar](repeating: 0, count: bytes.count * 4 + 16)
                var il = inb.count, ol = out.count
                let r = inb.withUnsafeMutableBufferPointer { ib in out.withUnsafeMutableBufferPointer { ob -> Int in
                    var ip: UnsafeMutablePointer<CChar>? = ib.baseAddress, op: UnsafeMutablePointer<CChar>? = ob.baseAddress
                    return conv(cd, &ip, &il, &op, &ol) } }
                try expect(r != -1 && il == 0, "iconv \(from) -> \(to): errno \(errno)")
                return out.prefix(out.count - ol).map { UInt8(bitPattern: $0) }
            }
            let latin1 = try convert(Array("Grüße, café".utf8), from: "UTF-8", to: "ISO-8859-1")
            try expect(latin1 == [0x47, 0x72, 0xfc, 0xdf, 0x65, 0x2c, 0x20, 0x63, 0x61, 0x66, 0xe9], "Latin-1 \(latin1)")
            let sjis = try convert(Array("日本".utf8), from: "UTF-8", to: "SHIFT_JIS")
            try expect(sjis == [0x93, 0xfa, 0x96, 0x7b], "Shift_JIS \(sjis)")
            let back = try convert(latin1, from: "ISO-8859-1", to: "UTF-8")
            try expect(String(decoding: back, as: UTF8.self) == "Grüße, café", "back to UTF-8")
            return "UTF-8 <-> Latin-1, Shift_JIS"
        },
        check("libcharset.1", "locale-charset") {
            let f = try cfunc("libcharset.1", "locale_charset", (@convention(c) () -> UnsafePointer<CChar>).self)
            let s = String(cString: f())
            try expect(!s.isEmpty, "empty charset name")
            return s
        },
        check("libexpat.1", "parse-elements-attributes") {
            typealias Create = @convention(c) (UnsafePointer<CChar>?) -> OpaquePointer?
            typealias Start = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Void
            typealias End = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void
            typealias SetHandlers = @convention(c) (OpaquePointer?, Start?, End?) -> Void
            typealias SetUser = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Void
            typealias Parse = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int32, Int32) -> Int32
            let create = try cfunc("libexpat.1", "XML_ParserCreate", Create.self), handlers = try cfunc("libexpat.1", "XML_SetElementHandler", SetHandlers.self)
            let user = try cfunc("libexpat.1", "XML_SetUserData", SetUser.self), parse = try cfunc("libexpat.1", "XML_Parse", Parse.self)
            let free = try cfunc("libexpat.1", "XML_ParserFree", (@convention(c) (OpaquePointer?) -> Void).self)
            let ver = try cfunc("libexpat.1", "XML_ExpatVersion", (@convention(c) () -> UnsafePointer<CChar>).self)
            // counts: [elements started, elements ended, sum of the n="" attributes]
            var counts = [0, 0, 0]
            guard let p = create(nil) else { throw Fail("XML_ParserCreate") }
            defer { free(p) }
            handlers(p, { u, _, atts in
                let c = u!.assumingMemoryBound(to: Int.self); c[0] += 1
                var i = 0
                while let k = atts?[i], let v = atts?[i + 1] { if String(cString: k) == "n" { c[2] += Int(String(cString: v)) ?? 0 }; i += 2 }
            }, { u, _ in u!.assumingMemoryBound(to: Int.self)[1] += 1 })
            let xml = "<?xml version='1.0'?><r><i n='1'/><i n='20'>&amp;<j n='300'/></i></r>"
            let st = counts.withUnsafeMutableBufferPointer { b -> Int32 in user(p, b.baseAddress); return parse(p, xml, Int32(xml.utf8.count), 1) }
            try expect(st == 1, "XML_Parse status \(st)")   // XML_STATUS_OK
            try expect(counts == [4, 4, 321], "elements / attributes \(counts)")
            return String(cString: ver())
        },
        check("libxslt.1", "transform") {
            let out = try xslt("<xsl:stylesheet version='1.0' xmlns:xsl='http://www.w3.org/1999/XSL/Transform'><xsl:output method='text'/>" +
                               "<xsl:template match='/'><xsl:for-each select='//n'><xsl:sort select='.' data-type='number' order='descending'/><xsl:value-of select='.'/>,</xsl:for-each>" +
                               "<xsl:value-of select='sum(//n)'/></xsl:template></xsl:stylesheet>", exslt: false)
            try expect(out == "30,20,10,60", "result '\(out)'")
            return out
        },
        check("libexslt.0", "math-strings-extensions") {
            let out = try xslt("<xsl:stylesheet version='1.0' xmlns:xsl='http://www.w3.org/1999/XSL/Transform' xmlns:math='http://exslt.org/math' " +
                               "xmlns:str='http://exslt.org/strings' extension-element-prefixes='math str'><xsl:output method='text'/>" +
                               "<xsl:template match='/'><xsl:value-of select='math:max(//n)'/>|<xsl:value-of select='count(str:tokenize(\"a,b;c\", \",;\"))'/>|" +
                               "<xsl:value-of select='str:padding(3, \"x\")'/></xsl:template></xsl:stylesheet>", exslt: true)
            try expect(out == "30|3|xxx", "result '\(out)'")
            return out
        },
        check("libcmark-gfm", "markdown-to-html") {
            let md = try cfunc("libcmark-gfm", "cmark_markdown_to_html", (@convention(c) (UnsafePointer<CChar>?, Int, Int32) -> UnsafeMutablePointer<CChar>?).self)
            let ver = try cfunc("libcmark-gfm", "cmark_version_string", (@convention(c) () -> UnsafePointer<CChar>).self)
            let src = "# x86sim\n\nRuns *simulator* runtimes:\n\n- iOS\n- tvOS\n\n`code`\n"
            guard let h = md(src, src.utf8.count, 0) else { throw Fail("no output") }
            let html = String(cString: h); Foundation.free(h)
            try expect(html == "<h1>x86sim</h1>\n<p>Runs <em>simulator</em> runtimes:</p>\n<ul>\n<li>iOS</li>\n<li>tvOS</li>\n</ul>\n<p><code>code</code></p>\n", "html '\(html)'")
            return "cmark \(String(cString: ver()))"
        },
        check("libarchive.2", "tar-gzip-memory-roundtrip") {
            let L = "libarchive.2"
            typealias A = OpaquePointer?
            let wnew = try cfunc(L, "archive_write_new", (@convention(c) () -> A).self)
            let wfmt = try cfunc(L, "archive_write_set_format_pax_restricted", (@convention(c) (A) -> Int32).self)
            let wgz = try cfunc(L, "archive_write_add_filter_gzip", (@convention(c) (A) -> Int32).self)
            let wopen = try cfunc(L, "archive_write_open_memory", (@convention(c) (A, UnsafeMutableRawPointer?, Int, UnsafeMutablePointer<Int>?) -> Int32).self)
            let whdr = try cfunc(L, "archive_write_header", (@convention(c) (A, A) -> Int32).self)
            let wdata = try cfunc(L, "archive_write_data", (@convention(c) (A, UnsafeRawPointer?, Int) -> Int).self)
            let wclose = try cfunc(L, "archive_write_close", (@convention(c) (A) -> Int32).self)
            let wfree = try cfunc(L, "archive_write_free", (@convention(c) (A) -> Int32).self)
            let enew = try cfunc(L, "archive_entry_new", (@convention(c) () -> A).self)
            let efree = try cfunc(L, "archive_entry_free", (@convention(c) (A) -> Void).self)
            let epath = try cfunc(L, "archive_entry_set_pathname", (@convention(c) (A, UnsafePointer<CChar>?) -> Void).self)
            let esize = try cfunc(L, "archive_entry_set_size", (@convention(c) (A, Int64) -> Void).self)
            let etype = try cfunc(L, "archive_entry_set_filetype", (@convention(c) (A, UInt32) -> Void).self)
            let eperm = try cfunc(L, "archive_entry_set_perm", (@convention(c) (A, mode_t) -> Void).self)
            let rnew = try cfunc(L, "archive_read_new", (@convention(c) () -> A).self)
            let rfilters = try cfunc(L, "archive_read_support_filter_all", (@convention(c) (A) -> Int32).self)
            let rformats = try cfunc(L, "archive_read_support_format_all", (@convention(c) (A) -> Int32).self)
            let ropen = try cfunc(L, "archive_read_open_memory", (@convention(c) (A, UnsafeRawPointer?, Int) -> Int32).self)
            let rnext = try cfunc(L, "archive_read_next_header", (@convention(c) (A, UnsafeMutablePointer<A>?) -> Int32).self)
            let rdata = try cfunc(L, "archive_read_data", (@convention(c) (A, UnsafeMutableRawPointer?, Int) -> Int).self)
            let rfree = try cfunc(L, "archive_read_free", (@convention(c) (A) -> Int32).self)
            let gpath = try cfunc(L, "archive_entry_pathname", (@convention(c) (A) -> UnsafePointer<CChar>?).self)
            let ver = try cfunc(L, "archive_version_string", (@convention(c) () -> UnsafePointer<CChar>).self)
            let files = [("a/one.txt", Array(sampleText.utf8)), ("a/two.bin", (0..<5000).map { UInt8($0 % 251) })]
            var buf = [UInt8](repeating: 0, count: 64 << 10); var used = 0
            let w = wnew()
            try expect(wfmt(w) == 0 && wgz(w) == 0, "write setup")
            try buf.withUnsafeMutableBytes { b in
                try expect(wopen(w, b.baseAddress, b.count, &used) == 0, "archive_write_open_memory")
                for (name, data) in files {
                    let e = enew(); epath(e, name); esize(e, Int64(data.count)); etype(e, 0o100000); eperm(e, 0o644)
                    try expect(whdr(w, e) == 0, "header \(name)"); efree(e)
                    try expect(wdata(w, data, data.count) == data.count, "data \(name)")
                }
                try expect(wclose(w) == 0, "close")
            }
            _ = wfree(w)
            try expect(used > 0 && buf[0] == 0x1f && buf[1] == 0x8b, "gzip output \(used) B")
            let r = rnew(); _ = rfilters(r); _ = rformats(r)
            defer { _ = rfree(r) }
            try expect(ropen(r, buf, used) == 0, "archive_read_open_memory")
            var got: [(String, [UInt8])] = []; var e: A = nil
            while rnext(r, &e) == 0 {
                var all: [UInt8] = [], d = [UInt8](repeating: 0, count: 4096)
                while case let n = rdata(r, &d, d.count), n > 0 { all += d.prefix(n) }
                got.append((String(cString: gpath(e)!), all))
            }
            try expect(got.map(\.0) == files.map(\.0) && zip(got, files).allSatisfy { $0.1 == $1.1 }, "read back \(got.map { "\($0.0) \($0.1.count) B" })")
            return "\(String(cString: ver())): 2 files, \(used) B tar.gz"
        },
        check("libresolv.9", "dns-message-build-parse") {
            typealias MkQuery = @convention(c) (Int32, UnsafePointer<CChar>?, Int32, Int32, UnsafePointer<UInt8>?, Int32, UnsafePointer<UInt8>?, UnsafeMutablePointer<UInt8>?, Int32) -> Int32
            typealias InitParse = @convention(c) (UnsafePointer<UInt8>?, Int32, UnsafeMutableRawPointer?) -> Int32
            typealias ParseRR = @convention(c) (UnsafeMutableRawPointer?, Int32, Int32, UnsafeMutableRawPointer?) -> Int32
            let mk = try cfunc("libresolv.9", "res_9_mkquery", MkQuery.self)
            let ip = try cfunc("libresolv.9", "res_9_ns_initparse", InitParse.self), prr = try cfunc("libresolv.9", "res_9_ns_parserr", ParseRR.self)
            var msg = [UInt8](repeating: 0, count: 512)
            let n = mk(0 /* QUERY */, "www.example.com", 1 /* C_IN */, 28 /* T_AAAA */, nil, 0, nil, &msg, Int32(msg.count))
            try expect(n == 12 + 17 + 4, "query length \(n)")   // header + 3www7example3com0 + type/class
            try expect(msg[4] == 0 && msg[5] == 1 && msg[12] == 3 && msg[Int(n) - 3] == 28, "wire format \(msg.prefix(Int(n)))")
            // ns_msg (~80 B) and ns_rr (name[1025] first): generous buffers instead of the struct definitions
            let handle = UnsafeMutableRawPointer.allocate(byteCount: 512, alignment: 16), rr = UnsafeMutableRawPointer.allocate(byteCount: 2048, alignment: 16)
            defer { handle.deallocate(); rr.deallocate() }
            try expect(ip(msg, n, handle) == 0, "ns_initparse")
            try expect(prr(handle, 0 /* ns_s_qd */, 0, rr) == 0, "ns_parserr")
            let name = String(cString: rr.assumingMemoryBound(to: CChar.self))
            try expect(name == "www.example.com", "question name '\(name)'")
            return "\(n) B query for \(name) AAAA"
        },
        check("libobjc.A", "runtime-class-building") {
            let name = "SDKCovDynamic\(UInt32.random(in: 0...UInt32.max))"
            guard let cls = objc_allocateClassPair(NSObject.self, name, 0) else { throw Fail("objc_allocateClassPair") }
            let triple: @convention(block) (AnyObject, Int) -> Int = { _, x in x * 3 }
            let sel = sel_registerName("sdkcovTriple:")
            try expect(class_addMethod(cls, sel, imp_implementationWithBlock(triple), "q@:q"), "class_addMethod")
            objc_registerClassPair(cls)
            try expect(NSClassFromString(name) === cls, "registered class lookup")
            let o = (cls as! NSObject.Type).init()
            typealias F = @convention(c) (AnyObject, Selector, Int) -> Int
            let r = unsafeBitCast(class_getMethodImplementation(cls, sel), to: F.self)(o, sel, 14)
            try expect(r == 42, "dynamic method returned \(r)")
            try expect(o.responds(to: sel), "respondsToSelector")
            var key: UInt8 = 0
            objc_setAssociatedObject(o, &key, "sdkcov" as NSString, .OBJC_ASSOCIATION_RETAIN)
            try expect(objc_getAssociatedObject(o, &key) as? String == "sdkcov", "associated object")
            var count: UInt32 = 0; let ms = class_copyMethodList(cls, &count); Foundation.free(ms)
            try expect(count >= 1, "method list \(count)")
            return "\(name): 1 method, associated object"
        },
        check("libffi", "call-c-functions") {
            typealias PrepCif = @convention(c) (UnsafeMutableRawPointer?, UInt32, UInt32, UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> UInt32
            typealias Call = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Void
            let prep = try cfunc("libffi", "ffi_prep_cif", PrepCif.self), call = try cfunc("libffi", "ffi_call", Call.self)
            let tSInt64 = try csym("libffi", "ffi_type_sint64"), tSInt32 = try csym("libffi", "ffi_type_sint32")
            let tPtr = try csym("libffi", "ffi_type_pointer"), tDouble = try csym("libffi", "ffi_type_double")
            #if arch(arm64)
            let abi: UInt32 = 1   // FFI_SYSV, aarch64's FFI_DEFAULT_ABI
            #else
            let abi: UInt32 = 2   // FFI_UNIX64
            #endif
            let cif = UnsafeMutableRawPointer.allocate(byteCount: 128, alignment: 16); cif.initializeMemory(as: UInt8.self, repeating: 0, count: 128)
            defer { cif.deallocate() }
            // long strtol(const char *, char **, int)
            var at1: [UnsafeMutableRawPointer?] = [tPtr, tPtr, tSInt32]
            try expect(prep(cif, abi, 3, tSInt64, &at1) == 0, "ffi_prep_cif strtol")   // FFI_OK
            let s = strdup("  -12345xyz")!; defer { Foundation.free(s) }
            var a0: UnsafeMutablePointer<CChar>? = s, a1: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? = nil, a2: Int32 = 10
            var r1: Int64 = 0
            try withUnsafeMutablePointer(to: &a0) { p0 in try withUnsafeMutablePointer(to: &a1) { p1 in try withUnsafeMutablePointer(to: &a2) { p2 in
                var args: [UnsafeMutableRawPointer?] = [UnsafeMutableRawPointer(p0), UnsafeMutableRawPointer(p1), UnsafeMutableRawPointer(p2)]
                guard let fn = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "strtol") else { throw Fail("strtol") }   // RTLD_DEFAULT
                call(cif, fn, &r1, &args)
            } } }
            try expect(r1 == -12345, "strtol via ffi_call: \(r1)")
            // double pow(double, double): arguments in floating-point registers
            var at2: [UnsafeMutableRawPointer?] = [tDouble, tDouble]
            try expect(prep(cif, abi, 2, tDouble, &at2) == 0, "ffi_prep_cif pow")
            var x = 2.0, y = 10.0, r2 = 0.0
            try withUnsafeMutablePointer(to: &x) { px in try withUnsafeMutablePointer(to: &y) { py in
                var args: [UnsafeMutableRawPointer?] = [UnsafeMutableRawPointer(px), UnsafeMutableRawPointer(py)]
                guard let fn = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "pow") else { throw Fail("pow") }
                call(cif, fn, &r2, &args)
            } }
            try expect(r2 == 1024, "pow via ffi_call: \(r2)")
            return "strtol -12345, pow 1024"
        },
        check("libbsm.0", "audit-token") {
            let toPid = try cfunc("libbsm.0", "audit_token_to_pid", (@convention(c) (audit_token_t) -> pid_t).self)
            let toEuid = try cfunc("libbsm.0", "audit_token_to_euid", (@convention(c) (audit_token_t) -> uid_t).self)
            var tok = audit_token_t(), n = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
            let kr = withUnsafeMutablePointer(to: &tok) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { task_info(mach_task_self_, task_flavor_t(TASK_AUDIT_TOKEN), $0, &n) } }
            try expect(kr == KERN_SUCCESS, "task_info(TASK_AUDIT_TOKEN) \(kr)")
            try expect(toPid(tok) == getpid() && toEuid(tok) == geteuid(), "token pid \(toPid(tok)) / \(getpid()), euid \(toEuid(tok)) / \(geteuid())")
            return "pid \(getpid()), euid \(geteuid())"
        },
        check("libutil", "expand-humanize-number") {
            let expand = try cfunc("libutil", "expand_number", (@convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<UInt64>?) -> Int32).self)
            typealias Humanize = @convention(c) (UnsafeMutablePointer<CChar>?, Int, Int64, UnsafePointer<CChar>?, Int32, Int32) -> Int32
            let humanize = try cfunc("libutil", "humanize_number", Humanize.self)
            var n: UInt64 = 0
            try expect(expand("10k", &n) == 0 && n == 10240, "expand_number 10k = \(n)")
            try expect(expand("3M", &n) == 0 && n == 3 << 20, "expand_number 3M = \(n)")
            // len 5 ("10K" and its NUL, with room for one more digit): autoscale picks the unit that fits
            var b = [CChar](repeating: 0, count: 16)
            _ = humanize(&b, 5, 10240, "", 0x20 /* HN_AUTOSCALE */, 0x02 | 0x04 /* HN_NOSPACE | HN_B */)
            let h = String(cString: b)
            try expect(h == "10K", "humanize_number '\(h)'")
            return "10k = 10240, 10240 = \(h)"
        },
        check("libtidy.A", "html-clean-repair") {
            let L = "libtidy.A"
            let create = try cfunc(L, "tidyCreate", (@convention(c) () -> OpaquePointer?).self)
            let release = try cfunc(L, "tidyRelease", (@convention(c) (OpaquePointer?) -> Void).self)
            let optId = try cfunc(L, "tidyOptGetIdForName", (@convention(c) (UnsafePointer<CChar>?) -> Int32).self)
            let setBool = try cfunc(L, "tidyOptSetBool", (@convention(c) (OpaquePointer?, Int32, Int32) -> Int32).self)
            let parse = try cfunc(L, "tidyParseString", (@convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> Int32).self)
            let repair = try cfunc(L, "tidyCleanAndRepair", (@convention(c) (OpaquePointer?) -> Int32).self)
            let save = try cfunc(L, "tidySaveString", (@convention(c) (OpaquePointer?, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<UInt32>?) -> Int32).self)
            let doc = create(); defer { release(doc) }
            _ = setBool(doc, optId("output-xhtml"), 1); _ = setBool(doc, optId("quiet"), 1); _ = setBool(doc, optId("show-warnings"), 0)
            try expect(parse(doc, "<title>sdkcov</title><p>one<b>bold<p>two") >= 0, "tidyParseString")
            try expect(repair(doc) >= 0, "tidyCleanAndRepair")
            var buf = [CChar](repeating: 0, count: 8192); var len = UInt32(buf.count)
            let st = save(doc, &buf, &len)   // 0, or 1 / 2: the input had warnings / errors (it has: tidy repaired them)
            try expect(st >= 0 && len > 0, "tidySaveString \(st)")
            let out = String(decoding: buf.prefix(Int(len)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            // XHTML output, the unclosed <b> closed inside its paragraph, the missing <html> / <body> added
            try expect(out.contains("<html xmlns=\"http://www.w3.org/1999/xhtml\"") && out.contains("<title>sdkcov</title>") && out.contains("<b>bold</b>") && out.contains("<body>"), "output '\(out)'")
            return "\(len) B XHTML"
        },
        check("libc++abi", "demangle") {
            let dm = try cfunc("libc++abi", "__cxa_demangle", (@convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UnsafeMutablePointer<Int32>?) -> UnsafeMutablePointer<CChar>?).self)
            var st: Int32 = -9
            guard let p = dm("_ZNSt3__16vectorIiNS_9allocatorIiEEE9push_backERKi", nil, nil, &st) else { throw Fail("__cxa_demangle status \(st)") }
            let s = String(cString: p); Foundation.free(p)
            try expect(st == 0 && s.hasPrefix("std::__1::vector<int, std::__1::allocator<int>") && s.hasSuffix("::push_back(int const&)"), "'\(s)'")
            _ = dm("not a symbol", nil, nil, &st)
            try expect(st == -2, "invalid name status \(st)")
            return s
        },
        check("libcmph", "minimal-perfect-hash") {
            let L = "libcmph"
            let adapter = try cfunc(L, "cmph_io_vector_adapter", (@convention(c) (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, UInt32) -> OpaquePointer?).self)
            let adapterFree = try cfunc(L, "cmph_io_vector_adapter_destroy", (@convention(c) (OpaquePointer?) -> Void).self)
            let cfgNew = try cfunc(L, "cmph_config_new", (@convention(c) (OpaquePointer?) -> OpaquePointer?).self)
            let cfgAlgo = try cfunc(L, "cmph_config_set_algo", (@convention(c) (OpaquePointer?, Int32) -> Void).self)
            let cfgFree = try cfunc(L, "cmph_config_destroy", (@convention(c) (OpaquePointer?) -> Void).self)
            let new = try cfunc(L, "cmph_new", (@convention(c) (OpaquePointer?) -> OpaquePointer?).self)
            let search = try cfunc(L, "cmph_search", (@convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UInt32) -> UInt32).self)
            let size = try cfunc(L, "cmph_size", (@convention(c) (OpaquePointer?) -> UInt32).self)
            let destroy = try cfunc(L, "cmph_destroy", (@convention(c) (OpaquePointer?) -> Void).self)
            let keys = ["ios", "tvos", "watchos", "xros", "macos", "linux", "x86", "arm64", "metal", "vulkan", "sdkcov", "swift"]
            // the adapter keeps the key vector: a buffer that outlives it
            let cs = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: keys.count)
            for (i, k) in keys.enumerated() { cs[i] = strdup(k) }
            defer { for i in 0..<keys.count { Foundation.free(cs[i]) }; cs.deallocate() }
            let src = adapter(cs, UInt32(keys.count)); defer { adapterFree(src) }
            let cfg = cfgNew(src); cfgAlgo(cfg, 5 /* CMPH_BDZ */)
            guard let h = new(cfg) else { cfgFree(cfg); throw Fail("cmph_new") }
            cfgFree(cfg); defer { destroy(h) }
            let ids = keys.map { search(h, $0, UInt32($0.utf8.count)) }
            try expect(size(h) == UInt32(keys.count) && Set(ids).count == keys.count && ids.allSatisfy { $0 < UInt32(keys.count) }, "ids \(ids)")
            return "\(keys.count) keys -> 0..<\(keys.count)"
        },
        check("libapple_nghttp2", "hpack-roundtrip") {
            let L = "libapple_nghttp2"
            let dnew = try cfunc(L, "nghttp2_hd_deflate_new", (@convention(c) (UnsafeMutablePointer<OpaquePointer?>?, Int) -> Int32).self)
            let dhd = try cfunc(L, "nghttp2_hd_deflate_hd", (@convention(c) (OpaquePointer?, UnsafeMutablePointer<UInt8>?, Int, UnsafeRawPointer?, Int) -> Int).self)
            let ddel = try cfunc(L, "nghttp2_hd_deflate_del", (@convention(c) (OpaquePointer?) -> Void).self)
            let inew = try cfunc(L, "nghttp2_hd_inflate_new", (@convention(c) (UnsafeMutablePointer<OpaquePointer?>?) -> Int32).self)
            let ihd = try cfunc(L, "nghttp2_hd_inflate_hd2", (@convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, UnsafeMutablePointer<Int32>?, UnsafePointer<UInt8>?, Int, Int32) -> Int).self)
            let iend = try cfunc(L, "nghttp2_hd_inflate_end_headers", (@convention(c) (OpaquePointer?) -> Int32).self)
            let idel = try cfunc(L, "nghttp2_hd_inflate_del", (@convention(c) (OpaquePointer?) -> Void).self)
            let headers = [(":method", "GET"), (":path", "/x86sim"), ("user-agent", "sdkcov")]
            // nghttp2_nv: name, value, namelen, valuelen, flags (40 B on 64-bit)
            let strs = headers.flatMap { [strdup($0.0)!, strdup($0.1)!] }; defer { strs.forEach { Foundation.free($0) } }
            let nva = UnsafeMutableRawPointer.allocate(byteCount: 40 * headers.count, alignment: 8); defer { nva.deallocate() }
            nva.initializeMemory(as: UInt8.self, repeating: 0, count: 40 * headers.count)
            for (i, h) in headers.enumerated() {
                nva.storeBytes(of: strs[2 * i], toByteOffset: 40 * i, as: UnsafeMutablePointer<CChar>.self)
                nva.storeBytes(of: strs[2 * i + 1], toByteOffset: 40 * i + 8, as: UnsafeMutablePointer<CChar>.self)
                nva.storeBytes(of: h.0.utf8.count, toByteOffset: 40 * i + 16, as: Int.self); nva.storeBytes(of: h.1.utf8.count, toByteOffset: 40 * i + 24, as: Int.self)
            }
            var d: OpaquePointer?; try expect(dnew(&d, 4096) == 0, "deflate_new"); defer { ddel(d) }
            var block = [UInt8](repeating: 0, count: 256)
            let n = dhd(d, &block, block.count, nva, headers.count)
            try expect(n > 0 && n < 40 && block[0] == 0x82, "HPACK block \(n) B, first byte \(block[0])")   // 0x82: static table entry 2, :method GET
            var inf: OpaquePointer?; try expect(inew(&inf) == 0, "inflate_new"); defer { idel(inf) }
            var got: [(String, String)] = []; var pos = 0
            let nv = UnsafeMutableRawPointer.allocate(byteCount: 40, alignment: 8); defer { nv.deallocate() }
            while true {
                var flags: Int32 = 0
                let r = block.withUnsafeBufferPointer { ihd(inf, nv, &flags, $0.baseAddress! + pos, n - pos, 1) }
                try expect(r >= 0, "inflate \(r)"); pos += r
                if flags & 0x02 != 0 {   // NGHTTP2_HD_INFLATE_EMIT
                    func str(_ o: Int, _ l: Int) -> String { String(decoding: UnsafeBufferPointer(start: nv.load(fromByteOffset: o, as: UnsafePointer<UInt8>.self), count: nv.load(fromByteOffset: l, as: Int.self)), as: UTF8.self) }
                    got.append((str(0, 16), str(8, 24)))
                }
                if flags & 0x01 != 0 { _ = iend(inf); break }   // FINAL
                if r == 0 && flags & 0x02 == 0 { break }
            }
            try expect(got.map { "\($0.0)=\($0.1)" } == headers.map { "\($0.0)=\($0.1)" }, "decoded \(got)")
            return "\(headers.count) headers in \(n) B"
        },
        check("libffi-trampolines", "closure-as-qsort-comparator") {
            // a libffi closure: a C function pointer made at run time (its code is a trampoline from
            // libffi-trampolines.dylib), handed to qsort
            typealias PrepCif = @convention(c) (UnsafeMutableRawPointer?, UInt32, UInt32, UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> UInt32
            typealias Fun = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?, UnsafeMutableRawPointer?) -> Void
            typealias PrepClosure = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Fun, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> UInt32
            let prep = try cfunc("libffi", "ffi_prep_cif", PrepCif.self), prepClosure = try cfunc("libffi", "ffi_prep_closure_loc", PrepClosure.self)
            let alloc = try cfunc("libffi", "ffi_closure_alloc", (@convention(c) (Int, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> UnsafeMutableRawPointer?).self)
            let free = try cfunc("libffi", "ffi_closure_free", (@convention(c) (UnsafeMutableRawPointer?) -> Void).self)
            let tSInt32 = try csym("libffi", "ffi_type_sint32"), tPtr = try csym("libffi", "ffi_type_pointer")
            #if arch(arm64)
            let abi: UInt32 = 1   // FFI_SYSV
            #else
            let abi: UInt32 = 2   // FFI_UNIX64
            #endif
            let cif = UnsafeMutableRawPointer.allocate(byteCount: 128, alignment: 16); cif.initializeMemory(as: UInt8.self, repeating: 0, count: 128)
            defer { cif.deallocate() }
            var argTypes: [UnsafeMutableRawPointer?] = [tPtr, tPtr]
            var calls = 0
            try argTypes.withUnsafeMutableBufferPointer { at in
                try expect(prep(cif, abi, 2, tSInt32, at.baseAddress) == 0, "ffi_prep_cif")
                var code: UnsafeMutableRawPointer?
                guard let cl = alloc(256, &code), let code else { throw Fail("ffi_closure_alloc") }
                defer { free(cl) }
                // int cmp(const void *a, const void *b), descending; the result is widened to ffi_arg
                let cmp: Fun = { _, ret, args, user in
                    let a = args![0]!.load(as: UnsafeRawPointer.self).load(as: Int32.self), b = args![1]!.load(as: UnsafeRawPointer.self).load(as: Int32.self)
                    ret!.storeBytes(of: Int64(a < b ? 1 : a > b ? -1 : 0), as: Int64.self)
                    user!.assumingMemoryBound(to: Int.self).pointee += 1
                }
                try withUnsafeMutablePointer(to: &calls) { cp in
                    try expect(prepClosure(cl, cif, cmp, UnsafeMutableRawPointer(cp), code) == 0, "ffi_prep_closure_loc")
                    var xs: [Int32] = [5, -3, 42, 0, 17, 8, -40, 23]
                    let f = unsafeBitCast(code, to: (@convention(c) (UnsafeRawPointer?, UnsafeRawPointer?) -> Int32).self)
                    qsort(&xs, xs.count, 4, f)
                    try expect(xs == [42, 23, 17, 8, 5, 0, -3, -40], "sorted \(xs)")
                }
            }
            try expect(calls > 7, "comparator calls \(calls)")
            return "qsort through a closure: \(calls) calls"
        },
        check("libobjc-trampolines", "block-imps") {
            // imp_implementationWithBlock hands out IMPs from libobjc-trampolines' trampoline pages: enough of them to
            // need several pages, each calling its own block
            let sel = sel_registerName("sdkcovAdd:")
            typealias F = @convention(c) (AnyObject, Selector, Int) -> Int
            var imps: [IMP] = []
            for i in 0..<3000 {
                let b: @convention(block) (AnyObject, Int) -> Int = { _, x in x + i }
                imps.append(imp_implementationWithBlock(b))
            }
            defer { imps.forEach { imp_removeBlock($0) } }
            let o = NSObject()
            var bad = 0
            for (i, imp) in imps.enumerated() where unsafeBitCast(imp, to: F.self)(o, sel, 1000) != 1000 + i { bad += 1 }
            try expect(bad == 0, "\(bad) of \(imps.count) trampolines called the wrong block")
            try expect(imp_getBlock(imps[1234]) != nil, "imp_getBlock")
            return "\(imps.count) block IMPs, \(Set(imps.map { UInt(bitPattern: unsafeBitCast($0, to: Int.self)) >> 14 }).count) 16 KB pages"
        },
        check("libedit.3", "readline-history") {
            let add = try cfunc("libedit.3", "add_history", (@convention(c) (UnsafePointer<CChar>?) -> Int32).self)
            let get = try cfunc("libedit.3", "history_get", (@convention(c) (Int32) -> UnsafeMutablePointer<UnsafePointer<CChar>?>?).self)
            let expand = try cfunc("libedit.3", "history_expand", (@convention(c) (UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32).self)
            let clear = try cfunc("libedit.3", "clear_history", (@convention(c) () -> Void).self)
            let using = try cfunc("libedit.3", "using_history", (@convention(c) () -> Void).self)
            let length = try csym("libedit.3", "history_length").assumingMemoryBound(to: Int32.self)
            let base = try csym("libedit.3", "history_base").assumingMemoryBound(to: Int32.self)
            using(); clear()   // using_history sets up the readline state (clear_history before it crashes, on Apple's too)
            for l in ["ls -l /tmp", "echo x86sim", "make sdkcov"] { _ = add(l) }
            try expect(length.pointee == 3, "history_length \(length.pointee)")
            let second = get(base.pointee + 1)?.pointee.map { String(cString: $0) }
            try expect(second == "echo x86sim", "history_get \(String(describing: second))")
            var out: UnsafeMutablePointer<CChar>?
            let line = strdup("!ec --verbose")!; defer { Foundation.free(line) }
            let r = expand(line, &out)
            let ex = out.map { String(cString: $0) }; Foundation.free(out)
            try expect(r == 1 && ex == "echo x86sim --verbose", "history_expand \(r) '\(ex ?? "nil")'")
            clear()
            return "!ec -> \(ex!)"
        },
        check("libboringssl", "sha256-hmac-x25519-vectors") {
            let L = "libboringssl"
            let sha = try cfunc(L, "SHA256", (@convention(c) (UnsafeRawPointer?, Int, UnsafeMutablePointer<UInt8>?) -> UnsafeMutablePointer<UInt8>?).self)
            let evpSha256 = try cfunc(L, "EVP_sha256", (@convention(c) () -> OpaquePointer?).self)
            let hmac = try cfunc(L, "HMAC", (@convention(c) (OpaquePointer?, UnsafeRawPointer?, Int, UnsafeRawPointer?, Int, UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<UInt32>?) -> UnsafeMutablePointer<UInt8>?).self)
            let x25519 = try cfunc(L, "X25519", (@convention(c) (UnsafeMutablePointer<UInt8>?, UnsafePointer<UInt8>?, UnsafePointer<UInt8>?) -> Int32).self)
            func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
            func unhex(_ s: String) -> [UInt8] { stride(from: 0, to: s.count, by: 2).map { UInt8(s.dropFirst($0).prefix(2), radix: 16)! } }
            var d = [UInt8](repeating: 0, count: 32)
            _ = sha("abc", 3, &d)
            try expect(hex(d) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA256 \(hex(d))")
            // RFC 4231 test case 2
            var n: UInt32 = 0; let msg = "what do ya want for nothing?"
            _ = hmac(evpSha256(), "Jefe", 4, msg, msg.utf8.count, &d, &n)
            try expect(n == 32 && hex(d) == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843", "HMAC-SHA256 \(hex(d))")
            // RFC 7748 section 5.2, first vector
            let k = unhex("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4"), u = unhex("e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c")
            try expect(x25519(&d, k, u) == 1 && hex(d) == "c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552", "X25519 \(hex(d))")
            return "SHA-256, HMAC, X25519 test vectors"
        },
        ]
        #if os(iOS) || os(visionOS)   // tvOS and watchOS do not ship libsbuf or libmd
        c.append(check("libsbuf", "autoextend-build") {
            let L = "libsbuf"
            typealias S = OpaquePointer?
            let new = try cfunc(L, "usbuf_new", (@convention(c) (S, UnsafeMutablePointer<CChar>?, Int32, Int32) -> S).self)
            let cat = try cfunc(L, "usbuf_cat", (@convention(c) (S, UnsafePointer<CChar>?) -> Int32).self)
            let putc = try cfunc(L, "usbuf_putc", (@convention(c) (S, Int32) -> Int32).self)
            let trim = try cfunc(L, "usbuf_trim", (@convention(c) (S) -> Int32).self)
            let finish = try cfunc(L, "usbuf_finish", (@convention(c) (S) -> Int32).self)
            let data = try cfunc(L, "usbuf_data", (@convention(c) (S) -> UnsafeMutablePointer<CChar>?).self)
            let len = try cfunc(L, "usbuf_len", (@convention(c) (S) -> Int).self)
            let delete = try cfunc(L, "usbuf_delete", (@convention(c) (S) -> Void).self)
            guard let sb = new(nil, nil, 16, 1 /* SBUF_AUTOEXTEND */) else { throw Fail("usbuf_new") }
            defer { delete(sb) }
            for i in 0..<500 { _ = cat(sb, "x86sim"); _ = putc(sb, Int32(UInt8(ascii: i % 2 == 0 ? "," : ";"))) }
            _ = cat(sb, "   \n\t"); _ = trim(sb)
            try expect(finish(sb) == 0, "usbuf_finish")
            let s = String(cString: data(sb)!)
            try expect(len(sb) == 3500 && s.count == 3500 && s.hasPrefix("x86sim,x86sim;") && s.hasSuffix("x86sim;"), "built \(len(sb)) B")
            return "\(len(sb)) B grown from 16"
        })
        #endif
        #if os(iOS) || os(visionOS)
        c.append(check("libmd", "digests") {
            let md5 = try cfunc("libmd", "MD5Data", (@convention(c) (UnsafeRawPointer?, UInt32, UnsafeMutablePointer<CChar>?) -> UnsafeMutablePointer<CChar>?).self)
            let sha = try cfunc("libmd", "SHA256_Data", (@convention(c) (UnsafeRawPointer?, UInt32, UnsafeMutablePointer<CChar>?) -> UnsafeMutablePointer<CChar>?).self)
            var b = [CChar](repeating: 0, count: 65)
            _ = md5("abc", 3, &b); let m = String(cString: b)
            try expect(m == "900150983cd24fb0d6963f7d28e17f72", "MD5 \(m)")
            _ = sha("abc", 3, &b); let s = String(cString: b)
            try expect(s == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA256 \(s)")
            return "MD5, SHA-256"
        })
        #endif
        return c
    }
}

/// apply an XSLT stylesheet to a fixed document with libxslt (libxml2 parses both); exslt: register the EXSLT functions
private func xslt(_ sheet: String, exslt: Bool) throws -> String {
    let doc = "<r><n>20</n><n>10</n><n>30</n></r>"
    typealias Ptr = OpaquePointer?
    let read = try cfunc("libxml2.2", "xmlReadMemory", (@convention(c) (UnsafePointer<CChar>?, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32) -> Ptr).self)
    let freeDoc = try cfunc("libxml2.2", "xmlFreeDoc", (@convention(c) (Ptr) -> Void).self)
    let parseSheet = try cfunc("libxslt.1", "xsltParseStylesheetDoc", (@convention(c) (Ptr) -> Ptr).self)
    let apply = try cfunc("libxslt.1", "xsltApplyStylesheet", (@convention(c) (Ptr, Ptr, UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Ptr).self)
    let save = try cfunc("libxslt.1", "xsltSaveResultToString", (@convention(c) (UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?, UnsafeMutablePointer<Int32>?, Ptr, Ptr) -> Int32).self)
    let freeSheet = try cfunc("libxslt.1", "xsltFreeStylesheet", (@convention(c) (Ptr) -> Void).self)
    if exslt { try cfunc("libexslt.0", "exsltRegisterAll", (@convention(c) () -> Void).self)() }
    guard let sd = read(sheet, Int32(sheet.utf8.count), "sheet.xsl", nil, 0), let style = parseSheet(sd) else { throw Fail("stylesheet did not parse") }
    defer { freeSheet(style) }   // frees its document too
    guard let d = read(doc, Int32(doc.utf8.count), "doc.xml", nil, 0) else { throw Fail("document did not parse") }
    defer { freeDoc(d) }
    guard let res = apply(style, d, nil) else { throw Fail("xsltApplyStylesheet") }
    defer { freeDoc(res) }
    var out: UnsafeMutablePointer<UInt8>?; var len: Int32 = 0
    try expect(save(&out, &len, res, style) == 0 && out != nil, "xsltSaveResultToString")
    defer { Foundation.free(out) }
    return String(decoding: UnsafeBufferPointer(start: out, count: Int(len)), as: UTF8.self)
}
