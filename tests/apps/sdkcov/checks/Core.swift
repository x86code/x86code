// sdkcov functional checks: Foundation and the Swift runtime modules, security / crypto, compression, networking on
// loopback (no internet needed), the C libraries.
import Foundation
import Combine
import Observation
import os
import RegexBuilder
import Synchronization
import Distributed
import simd
import Accelerate
import Security
import CryptoKit
import Compression
import Network
#if canImport(SystemConfiguration)
import SystemConfiguration
#endif
import UniformTypeIdentifiers
import CoreTransferable
import SQLite3
import zlib
#if canImport(AppleArchive)
import AppleArchive
import System
#endif
#if canImport(OSLog)
import OSLog
#endif

@Observable final class ObsBox { var n = 0 }
distributed actor Greeter {
    typealias ActorSystem = LocalTestingDistributedActorSystem
    distributed func hi(_ s: String) -> String { "hi \(s)" }
}

extension Registry {
    static var core: [Check] {
        var c: [Check] = [
        check("Foundation", "json-dates-formatters") {
            struct P: Codable, Equatable { var name: String; var d: Date; var xs: [Double] }
            let p = P(name: "x86", d: Date(timeIntervalSince1970: 1_800_000_000), xs: [1.5, -2])
            let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
            let data = try e.encode(p)
            let dc = JSONDecoder(); dc.dateDecodingStrategy = .iso8601
            try expect(try dc.decode(P.self, from: data) == p, "JSON round trip")
            let pl = try PropertyListEncoder().encode(p)
            try expect(try PropertyListDecoder().decode(P.self, from: pl) == p, "plist round trip")
            let f = NumberFormatter(); f.locale = Locale(identifier: "de_DE"); f.numberStyle = .decimal
            try expect(f.string(from: 1234.5) == "1.234,5", "de_DE number \(f.string(from: 1234.5) ?? "nil")")
            let s = Date(timeIntervalSince1970: 0).formatted(.iso8601)
            try expect(s == "1970-01-01T00:00:00Z", "iso8601 \(s)")
            let m = Measurement(value: 1, unit: UnitLength.miles).converted(to: .kilometers)
            try expect(abs(m.value - 1.609344) < 1e-9, "miles")
            return "\(data.count) B JSON, \(pl.count) B plist"
        },
        check("Foundation", "calendar-timezones-locale") {
            var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/New_York")!
            let d = c.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12))!
            try expect(c.timeZone.isDaylightSavingTime(for: d), "DST on 2026-03-08 noon in New York")
            try expect(TimeZone.knownTimeZoneIdentifiers.count > 300, "tz database")
            try expect(Locale.availableIdentifiers.count > 500, "ICU locales")
            let h = Calendar(identifier: .hebrew).component(.year, from: d)
            try expect(h == 5786, "hebrew year \(h)")
            return "\(TimeZone.knownTimeZoneIdentifiers.count) zones, \(Locale.availableIdentifiers.count) locales"
        },
        check("Foundation", "files-urls-processinfo") {
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("sdkcov-\(UUID().uuidString)")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: dir) }
            let f = dir.appendingPathComponent("a b.txt")
            try Data(repeating: 0x41, count: 100_000).write(to: f, options: .atomic)
            let h = try FileHandle(forUpdating: f); try h.seek(toOffset: 50_000); try h.write(contentsOf: Data([0x42])); try h.close()
            let back = try Data(contentsOf: f, options: .mappedIfSafe)
            try expect(back.count == 100_000 && back[50_000] == 0x42, "file handle write")
            try fm.copyItem(at: f, to: dir.appendingPathComponent("c.txt"))
            let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey])!.allObjects.count
            try expect(en == 2, "enumerator \(en)")
            let u = URL(string: "https://user@example.com:8443/a/b?q=1#f")!
            let cs = URLComponents(url: u, resolvingAgainstBaseURL: false)!
            try expect(cs.port == 8443 && cs.queryItems?.first?.value == "1", "URLComponents")
            let pi = ProcessInfo.processInfo
            try expect(pi.processorCount > 0 && pi.physicalMemory > 0, "ProcessInfo")
            return "\(pi.processorCount) cpus, \(pi.physicalMemory >> 20) MB, \(pi.operatingSystemVersionString)"
        },
        check("Foundation", "runloop-timer-notification-kvo") {
            final class K: NSObject { @objc dynamic var v = 0 }
            let k = K(); var seen = 0
            let obs = k.observe(\.v) { _, _ in seen += 1 }
            k.v = 1; k.v = 2; obs.invalidate()
            try expect(seen == 2, "KVO \(seen)")
            let name = Notification.Name("sdkcov")
            var got = false
            let t = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in got = true }
            NotificationCenter.default.post(name: name, object: nil)
            NotificationCenter.default.removeObserver(t)
            try expect(got, "NotificationCenter")
            let fired: Bool = await withCheckedContinuation { c in
                DispatchQueue.main.async {
                    Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { _ in c.resume(returning: true) }
                }
            }
            try expect(fired, "Timer")
            let pred = NSPredicate(format: "age > 30 AND name BEGINSWITH 'A'")
            try expect(pred.evaluate(with: ["age": 40, "name": "Ann"]), "NSPredicate")
            let ex = NSExpression(format: "sum:({1,2,3})").expressionValue(with: nil, context: nil) as? Int
            try expect(ex == 6, "NSExpression")
            let r = try NSRegularExpression(pattern: "(\\d+)-(\\d+)")
            try expect(r.numberOfMatches(in: "1-2 33-44", range: NSRange(location: 0, length: 9)) == 2, "NSRegularExpression")
            let attr = try AttributedString(markdown: "**bold** _it_")
            try expect(String(attr.characters) == "bold it", "markdown")
            return "ok"
        },
        check("Foundation", "operationqueue-progress-undo") {
            let q = OperationQueue(); q.maxConcurrentOperationCount = 4
            let sum = Mutex(0)
            for i in 1...100 { q.addOperation { sum.withLock { $0 += i } } }
            q.waitUntilAllOperationsAreFinished()
            try expect(sum.withLock { $0 } == 5050, "OperationQueue")
            let p = Progress(totalUnitCount: 10); p.completedUnitCount = 5
            try expect(p.fractionCompleted == 0.5, "Progress")
            final class B: NSObject { var v = 0 }
            let v = await onMain { () -> Int in
                let um = UndoManager(); um.groupsByEvent = false
                let b = B()
                um.beginUndoGrouping(); um.registerUndo(withTarget: b) { $0.v = 0 }; b.v = 7; um.endUndoGrouping()
                um.undo(); return b.v
            }
            try expect(v == 0, "UndoManager")
            return "ok"
        },
        check("Dispatch", "queues-groups-semaphores") {
            let g = DispatchGroup(); let n = Atomic<Int>(0)
            DispatchQueue.concurrentPerform(iterations: 1000) { _ in n.add(1, ordering: .relaxed) }
            for _ in 0..<50 { DispatchQueue.global().async(group: g) { n.add(1, ordering: .relaxed) } }
            try expect(g.wait(timeout: .now() + 10) == .success, "group")
            try expect(n.load(ordering: .relaxed) == 1050, "atomic \(n.load(ordering: .relaxed))")
            let s = DispatchSemaphore(value: 0)
            let src = DispatchSource.makeTimerSource(queue: .global()); src.schedule(deadline: .now() + 0.02)
            src.setEventHandler { s.signal() }; src.resume()
            try expect(s.wait(timeout: .now() + 5) == .success, "timer source"); src.cancel()
            let wi = DispatchWorkItem {}; DispatchQueue.global().async(execute: wi)
            try expect(wi.wait(timeout: .now() + 5) == .success, "work item")
            return "ok"
        },
        check("Swift", "concurrency-actors-streams") {
            actor C { var n = 0; func inc() { n += 1 } }
            let c = C()
            await withTaskGroup(of: Void.self) { g in for _ in 0..<200 { g.addTask { await c.inc() } } }
            let n = await c.n
            try expect(n == 200, "actor \(n)")
            let s = AsyncStream<Int> { k in for i in 0..<10 { k.yield(i) }; k.finish() }
            var t = 0; for await i in s { t += i }
            try expect(t == 45, "AsyncStream")
            let clock = ContinuousClock(); let el = try await clock.measure { try await Task.sleep(for: .milliseconds(20)) }
            try expect(el >= .milliseconds(15), "Task.sleep \(el)")
            let r = try await withThrowingTaskGroup(of: Int.self) { g in
                for i in 1...10 { g.addTask { i * i } }; return try await g.reduce(0, +)
            }
            try expect(r == 385, "task group")
            return "ok"
        },
        check("Swift", "stdlib-unicode-regex") {
            let s = "naïve café 👨‍👩‍👧 x86"
            try expect(s.count == 16 && s.unicodeScalars.count == 20, "grapheme \(s.count)/\(s.unicodeScalars.count)")
            let rx = Regex { Capture { OneOrMore(.digit) }; "-"; Capture { OneOrMore(.word) } }
            let m = try rx.firstMatch(in: "id 42-abc")
            try expect(m?.1 == "42" && m?.2 == "abc", "RegexBuilder")
            let lit = try #/(?<y>\d{4})-(?<m>\d\d)/#.wholeMatch(in: "2026-11")
            try expect(lit?.y == "2026", "regex literal")
            var d: [String: Int] = [:]; for w in "a b a c a b".split(separator: " ") { d[String(w), default: 0] += 1 }
            try expect(d == ["a": 3, "b": 2, "c": 1], "dictionary")
            let big = (1...20).reduce(UInt64(1), *)
            try expect(big == 2_432_902_008_176_640_000, "UInt64")
            let f16: Float16 = 1.5; try expect(Float(f16 * 2) == 3, "Float16")
            let i128: Int128 = Int128(Int64.max) * 4; try expect(i128 > Int128(Int64.max), "Int128")
            return "ok"
        },
        check("Observation", "tracking") {
            let b = ObsBox(); var changed = false
            withObservationTracking { _ = b.n } onChange: { changed = true }
            b.n = 1
            try expect(changed, "onChange")
            return "ok"
        },
        check("Distributed", "local-actor-system") {
            let sys = LocalTestingDistributedActorSystem()
            let g = Greeter(actorSystem: sys)
            let r = try await g.hi("x86")
            try expect(r == "hi x86", r)
            return r
        },
        check("Combine", "publishers") {
            var out: [Int] = []
            let subj = PassthroughSubject<Int, Never>()
            let c = subj.filter { $0 % 2 == 0 }.map { $0 * 10 }.scan(0, +).sink { out.append($0) }
            for i in 1...6 { subj.send(i) }
            c.cancel()
            try expect(out == [20, 60, 120], "\(out)")
            // async bridge. Not .delay(...).values: that races in Combine itself (a value is occasionally lost on
            // Apple silicon too, measured 3/6000 natively); a sequence publisher emits on demand, deterministically
            var sum = 0
            for try await v in (1...100).publisher.values { sum += v }
            try expect(sum == 5050, "async values sum \(sum)")
            let late = try await Future<Int, Never> { p in DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) { p(.success(7)) } }.value
            try expect(late == 7, "Future.value \(late)")
            return "ok"
        },
        check("os", "logger-signpost") {
            let l = Logger(subsystem: "com.x86sim.test.sdkcov", category: "check")
            l.info("sdkcov logger \(42, privacy: .public)")
            let sp = OSSignposter(logger: l)
            let st = sp.beginInterval("work"); sp.endInterval("work", st)
            let u = OSAllocatedUnfairLock(initialState: 0); u.withLock { $0 += 1 }
            try expect(u.withLock { $0 } == 1, "unfair lock")
            return "ok"
        },
        check("OSLog", "store-read-own-entries", timeout: 45) {
            let marker = "sdkcov-marker-\(UUID().uuidString.prefix(8))"
            Logger(subsystem: "com.x86sim.test.sdkcov", category: "store").notice("\(marker, privacy: .public)")
            try await Task.sleep(for: .milliseconds(500))
            let st = try OSLogStore(scope: .currentProcessIdentifier)
            let pos = st.position(date: Date().addingTimeInterval(-60))
            let found = try st.getEntries(at: pos).contains { ($0 as? OSLogEntryLog)?.composedMessage.contains(marker) == true }
            try expect(found, "own log entry not found in OSLogStore")
            return "found \(marker)"
        },
        check("Security", "random-keychain-certs") {
            var b = [UInt8](repeating: 0, count: 32)
            try expect(SecRandomCopyBytes(kSecRandomDefault, 32, &b) == errSecSuccess && b.contains { $0 != 0 }, "SecRandomCopyBytes")
            let svc = "com.x86sim.test.sdkcov"; let acct = "probe-\(UUID().uuidString)"
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: svc, kSecAttrAccount as String: acct]
            var add = q; add[kSecValueData as String] = Data("secret".utf8)
            let st = SecItemAdd(add as CFDictionary, nil)
            try expect(st == errSecSuccess, "SecItemAdd \(st)")
            var get = q; get[kSecReturnData as String] = true; var r: CFTypeRef?
            let gs = SecItemCopyMatching(get as CFDictionary, &r)
            try expect(gs == errSecSuccess && (r as? Data) == Data("secret".utf8), "SecItemCopyMatching \(gs)")
            try expect(SecItemDelete(q as CFDictionary) == errSecSuccess, "SecItemDelete")
            // RSA key generation, sign + verify
            let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits as String: 256]
            var err: Unmanaged<CFError>?
            guard let k = SecKeyCreateRandomKey(attrs as CFDictionary, &err), let pub = SecKeyCopyPublicKey(k) else { throw Fail("SecKeyCreateRandomKey \(String(describing: err))") }
            let msg = Data("x86sim".utf8) as CFData
            guard let sig = SecKeyCreateSignature(k, .ecdsaSignatureMessageX962SHA256, msg, &err) else { throw Fail("sign") }
            try expect(SecKeyVerifySignature(pub, .ecdsaSignatureMessageX962SHA256, msg, sig, &err), "verify")
            return "keychain + EC P-256 sign/verify"
        },
        check("CryptoKit", "hash-aead-ecc") {
            let d = SHA256.hash(data: Data("abc".utf8)).map { String(format: "%02x", $0) }.joined()
            try expect(d == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA256 \(d)")
            let key = SymmetricKey(size: .bits256)
            let box = try AES.GCM.seal(Data("payload".utf8), using: key)
            try expect(try AES.GCM.open(box, using: key) == Data("payload".utf8), "AES-GCM")
            let cc = try ChaChaPoly.seal(Data("x".utf8), using: key)
            try expect(try ChaChaPoly.open(cc, using: key) == Data("x".utf8), "ChaChaPoly")
            let a = Curve25519.KeyAgreement.PrivateKey(), b = Curve25519.KeyAgreement.PrivateKey()
            let s1 = try a.sharedSecretFromKeyAgreement(with: b.publicKey), s2 = try b.sharedSecretFromKeyAgreement(with: a.publicKey)
            try expect(s1 == s2, "X25519")
            let p = P256.Signing.PrivateKey(); let sig = try p.signature(for: Data("m".utf8))
            try expect(p.publicKey.isValidSignature(sig, for: Data("m".utf8)), "P256")
            let mac = HMAC<SHA512>.authenticationCode(for: Data("m".utf8), using: key)
            try expect(HMAC<SHA512>.isValidAuthenticationCode(mac, authenticating: Data("m".utf8), using: key), "HMAC")
            let kem = try MLKEM768.PrivateKey(); let enc = try kem.publicKey.encapsulate()
            try expect(try kem.decapsulate(enc.encapsulated) == enc.sharedSecret, "ML-KEM")
            return "SHA256, AES-GCM, ChaChaPoly, X25519, P256, HMAC, ML-KEM"
        },
        check("libcompression", "lzfse-zlib-lzma-lz4") {
            let src = [UInt8](String(repeating: "x86sim compresses ", count: 2000).utf8)
            var res: [String] = []
            for (n, a) in [("lzfse", COMPRESSION_LZFSE), ("zlib", COMPRESSION_ZLIB), ("lzma", COMPRESSION_LZMA), ("lz4", COMPRESSION_LZ4), ("brotli", COMPRESSION_BROTLI)] {
                var dst = [UInt8](repeating: 0, count: src.count + 1024)
                let c = compression_encode_buffer(&dst, dst.count, src, src.count, nil, a)
                try expect(c > 0 && c < src.count, "\(n) encode \(c)")
                var back = [UInt8](repeating: 0, count: src.count)
                let dn = compression_decode_buffer(&back, back.count, dst, c, nil, a)
                try expect(dn == src.count && back == src, "\(n) decode")
                res.append("\(n) \(c)")
            }
            let nsd = try (Data(src) as NSData).compressed(using: .zlib)
            try expect(try nsd.decompressed(using: .zlib) as Data == Data(src), "NSData")
            return res.joined(separator: ", ")
        },
        check("libz.1", "deflate-crc") {
            let s = [UInt8]("hello hello hello hello".utf8)
            var out = [UInt8](repeating: 0, count: 128); var ol = uLongf(out.count)
            try expect(compress(&out, &ol, s, uLong(s.count)) == Z_OK, "compress")
            var back = [UInt8](repeating: 0, count: s.count); var bl = uLongf(back.count)
            try expect(uncompress(&back, &bl, out, ol) == Z_OK && back == s, "uncompress")
            let crc = crc32(0, s, uInt(s.count))
            return "zlib \(String(cString: zlibVersion())), crc \(String(crc, radix: 16))"
        },
        check("libsqlite3", "sql") {
            var db: OpaquePointer?
            try expect(sqlite3_open(":memory:", &db) == SQLITE_OK, "open")
            defer { sqlite3_close(db) }
            try expect(sqlite3_exec(db, "create table t(a integer, b text); insert into t values(1,'x'),(2,'y'); create virtual table f using fts5(c); insert into f values('hello x86sim');", nil, nil, nil) == SQLITE_OK, String(cString: sqlite3_errmsg(db)))
            var st: OpaquePointer?
            sqlite3_prepare_v2(db, "select sum(a), (select count(*) from f where f match 'x86sim'), json_extract('{\"k\":[1,2]}', '$.k[1]') from t", -1, &st, nil)
            try expect(sqlite3_step(st) == SQLITE_ROW, "step")
            let r = (sqlite3_column_int(st, 0), sqlite3_column_int(st, 1), sqlite3_column_int(st, 2)); sqlite3_finalize(st)
            try expect(r == (3, 1, 2), "result \(r)")
            return "sqlite \(String(cString: sqlite3_libversion())), FTS5 + JSON"
        },
        check("libxml2.2", "sax-parse") {
            // Foundation's XMLParser is libxml2's SAX parser
            final class D: NSObject, XMLParserDelegate { var ns: [String] = []
                func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) { if let n = a["n"] { ns.append(n) } } }
            let p = XMLParser(data: Data("<r><i n='1'/><i n='2'>&amp;</i></r>".utf8)); let d = D(); p.delegate = d
            try expect(p.parse() && d.ns == ["1", "2"], "\(d.ns) \(String(describing: p.parserError))")
            return "ok"
        },
        check("libicucore.A", "collation-transliteration") {
            let s = "Ελληνικά".applyingTransform(.toLatin, reverse: false) ?? ""
            try expect(s.hasPrefix("Ellēnik"), "transliterate \(s)")
            let sorted = ["ä", "a", "z"].sorted { $0.compare($1, locale: Locale(identifier: "sv_SE")) == .orderedAscending }
            try expect(sorted == ["a", "z", "ä"], "sv collation \(sorted)")
            return s
        },
        check("libAppleArchive", "archive-roundtrip") {
            #if canImport(AppleArchive)
            let fm = FileManager.default
            let base = fm.temporaryDirectory.appendingPathComponent("aa-\(UUID().uuidString)")
            let src = base.appendingPathComponent("src"), dst = base.appendingPathComponent("dst")
            try fm.createDirectory(at: src, withIntermediateDirectories: true); try fm.createDirectory(at: dst, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: base) }
            try Data(repeating: 7, count: 50_000).write(to: src.appendingPathComponent("f.bin"))
            let arc = FilePath(base.appendingPathComponent("a.aar").path)
            guard let w = ArchiveByteStream.fileStream(path: arc, mode: .writeOnly, options: [.create], permissions: [.ownerReadWrite]),
                  let c = ArchiveByteStream.compressionStream(using: .lzfse, writingTo: w),
                  let e = ArchiveStream.encodeStream(writingTo: c) else { throw Fail("open for writing") }
            try e.writeDirectoryContents(archiveFrom: FilePath(src.path), keySet: ArchiveHeader.FieldKeySet("TYP,PAT,DAT,MOD")!)
            try e.close(); try c.close(); try w.close()
            guard let r = ArchiveByteStream.fileStream(path: arc, mode: .readOnly, options: [], permissions: []),
                  let d = ArchiveByteStream.decompressionStream(readingFrom: r),
                  let de = ArchiveStream.decodeStream(readingFrom: d),
                  let x = ArchiveStream.extractStream(extractingTo: FilePath(dst.path)) else { throw Fail("open for reading") }
            _ = try ArchiveStream.process(readingFrom: de, writingTo: x)
            try x.close(); try de.close(); try d.close(); try r.close()
            try expect(try Data(contentsOf: dst.appendingPathComponent("f.bin")).count == 50_000, "extracted")
            return "aar lzfse round trip"
            #else
            throw Skip("AppleArchive not in this SDK")
            #endif
        },
        check("Accelerate", "vdsp-vimage-blas-sparse") {
            let n = 1024
            let x = (0..<n).map { Float(sin(2 * .pi * 8 * Double($0) / Double(n))) }
            let fft = vDSP.FFT(log2n: 10, radix: .radix2, ofType: DSPSplitComplex.self)!
            var re = [Float](repeating: 0, count: n / 2), im = re, ore = re, oim = re
            x.withUnsafeBufferPointer { xb in
                re.withUnsafeMutableBufferPointer { rb in im.withUnsafeMutableBufferPointer { ib in
                    var sc = DSPSplitComplex(realp: rb.baseAddress!, imagp: ib.baseAddress!)
                    xb.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { vDSP_ctoz($0, 2, &sc, 1, vDSP_Length(n / 2)) }
                    ore.withUnsafeMutableBufferPointer { orb in oim.withUnsafeMutableBufferPointer { oib in
                        var o = DSPSplitComplex(realp: orb.baseAddress!, imagp: oib.baseAddress!)
                        fft.forward(input: sc, output: &o)
                    } }
                } }
            }
            let mags = zip(ore, oim).map { $0 * $0 + $1 * $1 }
            let peak = mags.indices.max { mags[$0] < mags[$1] }!
            try expect(peak == 8, "FFT peak bin \(peak)")
            try expect(vDSP.sum([1, 2, 3] as [Float]) == 6, "vDSP.sum")
            // BLAS sgemm 2x2
            let a: [Float] = [1, 2, 3, 4], b: [Float] = [5, 6, 7, 8]; var c = [Float](repeating: 0, count: 4)
            cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, 2, 2, 2, 1, a, 2, b, 2, 0, &c, 2)
            try expect(c == [19, 22, 43, 50], "sgemm \(c)")
            // vImage scale
            var src = try vImage_Buffer(width: 64, height: 64, bitsPerPixel: 32), dst = try vImage_Buffer(width: 32, height: 32, bitsPerPixel: 32)
            defer { src.free(); dst.free() }
            try expect(vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError, "vImageScale")
            // simd
            let q = simd_quatf(angle: .pi / 2, axis: [0, 0, 1]); let v = q.act([1, 0, 0])
            try expect(simd_distance(v, [0, 1, 0]) < 1e-5, "simd quat")
            let m = simd_float4x4(diagonal: [2, 2, 2, 1]); try expect(simd_determinant(m) == 8, "simd det")
            return "FFT, sgemm, vImage, simd"
        },
        check("Network", "path-monitor") {
            let m = NWPathMonitor()
            let p: NWPath = await withCheckedContinuation { c in
                var once = false
                m.pathUpdateHandler = { p in if !once { once = true; c.resume(returning: p) } }
                m.start(queue: .global())
            }
            m.cancel()
            return "\(p.status) \(p.availableInterfaces.map { "\($0.name)" }.joined(separator: ","))"
        },
        check("Network", "tcp-loopback-echo", timeout: 30) {
            let l = try NWListener(using: .tcp, on: .any)
            l.newConnectionHandler = { c in
                c.start(queue: .global())
                c.receive(minimumIncompleteLength: 1, maximumLength: 1000) { d, _, _, _ in
                    c.send(content: d.map { Data($0.reversed()) }, completion: .contentProcessed { _ in c.cancel() })
                }
            }
            let port: NWEndpoint.Port = try await withCheckedThrowingContinuation { cont in
                var done = false
                l.stateUpdateHandler = { s in
                    guard !done else { return }
                    switch s { case .ready: done = true; cont.resume(returning: l.port!)
                    case .failed(let e): done = true; cont.resume(throwing: e)
                    default: break }
                }
                l.start(queue: .global())
            }
            defer { l.cancel() }
            let c = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
            c.start(queue: .global())
            c.send(content: Data("x86sim".utf8), completion: .idempotent)
            let back: Data = try await withCheckedThrowingContinuation { cont in
                c.receive(minimumIncompleteLength: 6, maximumLength: 100) { d, _, _, e in
                    if let d { cont.resume(returning: d) } else { cont.resume(throwing: e ?? Fail("no data")) }
                }
            }
            c.cancel()
            try expect(String(decoding: back, as: UTF8.self) == "mis68x", "echo \(back)")
            return "port \(port)"
        },
        check("libSystem.B", "bsd-sockets-udp-tcp") {
            // plain BSD sockets on loopback: UDP datagram, then TCP connect/accept/send
            let u = socket(AF_INET, SOCK_DGRAM, 0); defer { close(u) }
            var a = sockaddr_in(); a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET); a.sin_addr.s_addr = inet_addr("127.0.0.1")
            var al = socklen_t(MemoryLayout<sockaddr_in>.size)
            try withUnsafeMutablePointer(to: &a) { p in try p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try expect(bind(u, $0, al) == 0, "bind \(errno)"); try expect(getsockname(u, $0, &al) == 0, "getsockname") } }
            let s = socket(AF_INET, SOCK_DGRAM, 0); defer { close(s) }
            let sent = withUnsafePointer(to: &a) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(s, "ping", 4, 0, $0, al) } }
            try expect(sent == 4, "sendto \(sent) errno \(errno)")
            var tv = timeval(tv_sec: 5, tv_usec: 0); setsockopt(u, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var buf = [UInt8](repeating: 0, count: 16); let n = recv(u, &buf, 16, 0)
            try expect(n == 4 && String(decoding: buf[0..<4], as: UTF8.self) == "ping", "recv \(n) errno \(errno)")
            var hints = addrinfo(); hints.ai_family = AF_INET; var res: UnsafeMutablePointer<addrinfo>?
            try expect(getaddrinfo("localhost", "80", &hints, &res) == 0, "getaddrinfo localhost"); freeaddrinfo(res)
            return "UDP port \(UInt16(bigEndian: a.sin_port))"
        },
        check("libSystem.B", "udp-kqueue-readiness", timeout: 30) {
            // a UDP socket's read readiness through kqueue (DispatchSource), as Network.framework waits for datagrams:
            // IPv4, and IPv6 dual-stack (V6ONLY 0) receiving from 127.0.0.1
            var out: [String] = []
            for v6 in [false, true] {
                let fd = socket(v6 ? AF_INET6 : AF_INET, SOCK_DGRAM, 0); defer { close(fd) }
                var port: UInt16 = 0
                if v6 {
                    var off: Int32 = 0; setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &off, 4)
                    var a = sockaddr_in6(); a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size); a.sin6_family = sa_family_t(AF_INET6)
                    var al = socklen_t(a.sin6_len)
                    try withUnsafeMutablePointer(to: &a) { p in try p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        try expect(bind(fd, $0, al) == 0, "bind6 \(errno)"); getsockname(fd, $0, &al) } }
                    port = UInt16(bigEndian: a.sin6_port)
                } else {
                    var a = sockaddr_in(); a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET); a.sin_addr.s_addr = inet_addr("127.0.0.1")
                    var al = socklen_t(a.sin_len)
                    try withUnsafeMutablePointer(to: &a) { p in try p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        try expect(bind(fd, $0, al) == 0, "bind \(errno)"); getsockname(fd, $0, &al) } }
                    port = UInt16(bigEndian: a.sin_port)
                }
                let fired = DispatchSemaphore(value: 0)
                let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global()); src.setEventHandler { fired.signal(); src.suspend() }
                src.resume()
                let s = socket(AF_INET, SOCK_DGRAM, 0); defer { close(s) }
                var to = sockaddr_in(); to.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); to.sin_family = sa_family_t(AF_INET); to.sin_addr.s_addr = inet_addr("127.0.0.1"); to.sin_port = port.bigEndian
                _ = withUnsafePointer(to: &to) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(s, "x", 1, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
                let ok = fired.wait(timeout: .now() + 3) == .success
                var b = [UInt8](repeating: 0, count: 8); let n = recv(fd, &b, 8, MSG_DONTWAIT)
                src.cancel(); if !ok { src.resume() }
                out.append("\(v6 ? "v6 dual" : "v4"): event \(ok ? "yes" : "NO"), queued \(n == 1 ? "yes" : "no")")
            }
            try expect(!out.contains { $0.contains("NO") || $0.contains("queued no") }, out.joined(separator: "; "))
            return out.joined(separator: "; ")
        },
        check("libSystem.B", "large-allocations", timeout: 60) {
            // big buffers, every page touched (codecs and image pipelines allocate tens of MB at once)
            var out: [String] = []
            for mb in [64, 256, 512] {
                let n = mb << 20
                guard let p = malloc(n) else { throw Fail("malloc \(mb) MB returned NULL") }
                for o in stride(from: 0, to: n, by: 16384) { p.storeBytes(of: UInt8(1), toByteOffset: o, as: UInt8.self) }
                free(p)
                var a: vm_address_t = 0
                let kr = vm_allocate(mach_task_self_, &a, vm_size_t(n), VM_FLAGS_ANYWHERE)
                try expect(kr == KERN_SUCCESS && a != 0, "vm_allocate \(mb) MB: kr \(kr)")
                UnsafeMutableRawPointer(bitPattern: UInt(a))!.storeBytes(of: 1, toByteOffset: n - 1, as: UInt8.self)
                vm_deallocate(mach_task_self_, a, vm_size_t(n))
                let m = mmap(nil, n, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)
                try expect(m != MAP_FAILED && m != nil, "mmap \(mb) MB: errno \(errno)")
                m!.storeBytes(of: 1, toByteOffset: n - 1, as: UInt8.self); munmap(m, n)
                out.append("\(mb) MB")
            }
            return out.joined(separator: ", ")
        },
        check("Network", "udp-loopback", timeout: 30) {
            let l = try NWListener(using: .udp, on: .any)
            let got = Mutex<String?>(nil)
            l.newConnectionHandler = { c in
                c.start(queue: .global())
                c.receiveMessage { d, _, _, _ in got.withLock { $0 = d.map { String(decoding: $0, as: UTF8.self) } } }
            }
            l.start(queue: .global())
            for _ in 0..<50 where l.port == nil || l.port == 0 { try await Task.sleep(for: .milliseconds(50)) }
            defer { l.cancel() }
            // over IPv4 and IPv6 loopback (the listener on .any is one dual-stack IPv6 socket)
            var via: [String] = []
            for host in ["127.0.0.1", "::1"] {
                got.withLock { $0 = nil }
                let c = NWConnection(host: NWEndpoint.Host(host), port: l.port!, using: .udp); c.start(queue: .global())
                for _ in 0..<20 {
                    c.send(content: Data("dgram".utf8), completion: .idempotent)
                    try await Task.sleep(for: .milliseconds(100))
                    if got.withLock({ $0 }) != nil { break }
                }
                c.cancel()
                via.append("\(host) \(got.withLock { $0 } == "dgram" ? "ok" : "nothing")")
            }
            try expect(!via.contains { $0.hasSuffix("nothing") }, via.joined(separator: ", "))
            return via.joined(separator: ", ")
        },
        check("CFNetwork", "urlsession-loopback-http", timeout: 40) {
            // a tiny HTTP/1.1 server on NWListener; URLSession fetches from it (no internet needed)
            let body = String(repeating: "x86sim ", count: 1000)
            let l = try NWListener(using: .tcp, on: .any)
            l.newConnectionHandler = { c in
                c.start(queue: .global())
                c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                    let r = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nX-Sdkcov: 1\r\nConnection: close\r\n\r\n\(body)"
                    c.send(content: Data(r.utf8), completion: .contentProcessed { _ in c.cancel() })
                }
            }
            l.start(queue: .global())
            for _ in 0..<50 where l.port == nil || l.port == 0 { try await Task.sleep(for: .milliseconds(50)) }
            defer { l.cancel() }
            let u = URL(string: "http://127.0.0.1:\(l.port!.rawValue)/probe")!
            let (d, resp) = try await URLSession.shared.data(from: u)
            let h = resp as! HTTPURLResponse
            try expect(h.statusCode == 200 && h.value(forHTTPHeaderField: "X-Sdkcov") == "1", "status \(h.statusCode)")
            try expect(d.count == body.utf8.count, "body \(d.count)")
            let (f, _) = try await URLSession.shared.download(from: u)
            try expect((try FileManager.default.attributesOfItem(atPath: f.path)[.size] as? Int) == body.utf8.count, "download")
            return "\(d.count) B over loopback"
        },
        check("UniformTypeIdentifiers", "types") {
            try expect(UTType.png.conforms(to: .image) && UTType.png.preferredMIMEType == "image/png", "png")
            try expect(UTType(filenameExtension: "swift")?.conforms(to: .sourceCode) == true, "swift")
            try expect(UTType("com.apple.quicktime-movie")?.conforms(to: .movie) == true, "mov")
            return "ok"
        },
        check("CoreTransferable", "transfer-representation") {
            struct T: Transferable, Codable { var s: String
                static var transferRepresentation: some TransferRepresentation { CodableRepresentation(contentType: .json) } }
            let d = try await T(s: "x").exported(as: .json)
            try expect(try await T(importing: d, contentType: .json).s == "x", "round trip")
            return "\(d.count) B"
        },
        ]
        #if canImport(SystemConfiguration)
        c.append(
        check("SystemConfiguration", "reachability") {
            var addr = sockaddr_in(); addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); addr.sin_family = sa_family_t(AF_INET)
            guard let r = withUnsafePointer(to: &addr, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { SCNetworkReachabilityCreateWithAddress(nil, $0) } }) else { throw Fail("create") }
            var f = SCNetworkReachabilityFlags(); try expect(SCNetworkReachabilityGetFlags(r, &f), "GetFlags")
            return "flags \(f.rawValue)\(f.contains(.reachable) ? " reachable" : "")"
        })
        #endif
        return c
    }
}
