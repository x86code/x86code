// sdkcov functional checks: machine learning and language. Core ML compiles and runs a model built here (a tiny
// protobuf, no model file in the bundle); on-device language models report availability (Apple's simulator uses the
// host Mac's Apple Intelligence: unavailable is a SKIP, not a failure).
import Foundation
#if canImport(CoreML)
import CoreML
#endif
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif
#if canImport(FoundationModels)
import FoundationModels
#endif
#if canImport(Translation)
import Translation
#endif
#if canImport(ImagePlayground)
import ImagePlayground
#endif

/// minimal protobuf writer for the Core ML model spec (coremltools' Model.proto)
struct PB {
    var d = Data()
    mutating func varint(_ v: UInt64) { var v = v; while v >= 0x80 { d.append(UInt8(v & 0x7f) | 0x80); v >>= 7 }; d.append(UInt8(v)) }
    mutating func tag(_ f: Int, _ w: Int) { varint(UInt64(f << 3 | w)) }
    mutating func int(_ f: Int, _ v: Int64) { tag(f, 0); varint(UInt64(bitPattern: v)) }
    mutating func msg(_ f: Int, _ m: PB) { tag(f, 2); varint(UInt64(m.d.count)); d.append(m.d) }
    mutating func str(_ f: Int, _ s: String) { tag(f, 2); varint(UInt64(s.utf8.count)); d.append(contentsOf: s.utf8) }
    mutating func doubles(_ f: Int, _ xs: [Double]) { tag(f, 2); varint(UInt64(xs.count * 8)); for x in xs { withUnsafeBytes(of: x.bitPattern.littleEndian) { d.append(contentsOf: $0) } } }
    mutating func int64s(_ f: Int, _ xs: [Int64]) { var p = PB(); xs.forEach { p.varint(UInt64(bitPattern: $0)) }; tag(f, 2); varint(UInt64(p.d.count)); d.append(p.d) }
}

#if canImport(CoreML)
/// Model { specificationVersion 1, description { input x: multiArray [2] double, output y: double },
///         glmRegressor { weights [[2, 3]], offset [0.5] } }   ->  y = 2 x0 + 3 x1 + 0.5
func linearModelSpec() -> Data {
    var arr = PB(); arr.int64s(1, [2]); arr.int(2, 65600)            // ArrayFeatureType shape [2], DOUBLE
    var tIn = PB(); tIn.msg(5, arr)                                  // FeatureType.multiArrayType
    var tOut = PB(); tOut.msg(2, PB())                               // FeatureType.doubleType
    var fIn = PB(); fIn.str(1, "x"); fIn.msg(3, tIn)
    var fOut = PB(); fOut.str(1, "y"); fOut.msg(3, tOut)
    var desc = PB(); desc.msg(1, fIn); desc.msg(10, fOut); desc.str(11, "y")
    var w = PB(); w.doubles(1, [2, 3])                               // GLMRegressor.DoubleArray
    var glm = PB(); glm.msg(1, w); glm.doubles(2, [0.5])
    var m = PB(); m.int(1, 1); m.msg(2, desc); m.msg(300, glm)       // Model.glmRegressor = 300
    return m.d
}
#endif

extension Registry {
    static var ml: [Check] {
        var c: [Check] = []
        #if canImport(CoreML) && os(watchOS)
        c.append(check("CoreML", "arrays-features") {
            // watchOS cannot compile models on the device (compileModel is unavailable): the runtime types only
            let x = try MLMultiArray(shape: [2, 3], dataType: .float32); x[[1, 2] as [NSNumber]] = 7
            try expect(x[5].floatValue == 7, "MLMultiArray")
            let fp = try MLDictionaryFeatureProvider(dictionary: ["a": 1.5, "b": "s"])
            try expect(fp.featureValue(for: "a")?.doubleValue == 1.5 && fp.featureValue(for: "b")?.stringValue == "s", "features")
            return "\(MLModel.availableComputeDevices.count) compute devices"
        })
        #elseif canImport(CoreML)
        c.append(check("CoreML", "compile-load-predict", timeout: 90) {
            let dir = FileManager.default.temporaryDirectory
            let src = dir.appendingPathComponent("sdkcov-linear.mlmodel")
            try linearModelSpec().write(to: src)
            let compiled = try await MLModel.compileModel(at: src)
            defer { try? FileManager.default.removeItem(at: compiled); try? FileManager.default.removeItem(at: src) }
            for units in [MLComputeUnits.cpuOnly, .all] {
                let cfg = MLModelConfiguration(); cfg.computeUnits = units
                let m = try await MLModel.load(contentsOf: compiled, configuration: cfg)
                let x = try MLMultiArray(shape: [2], dataType: .double); x[0] = 1; x[1] = 2
                let out = try await m.prediction(from: MLDictionaryFeatureProvider(dictionary: ["x": x]))
                let y = out.featureValue(for: "y")?.doubleValue
                try expect(y == 8.5, "prediction \(String(describing: y)) with compute units \(units.rawValue)")
            }
            let sa = MLShapedArray<Float>(scalars: [1, 2, 3, 4], shape: [2, 2])
            try expect(sa.shape == [2, 2], "MLShapedArray")
            return "compiled + predicted 8.5 (cpuOnly, all); \(MLModel.availableComputeDevices.count) compute devices"
        })
        #endif
        #if canImport(NaturalLanguage)
        c.append(check("NaturalLanguage", "language-tokens-tags") {
            let r = NLLanguageRecognizer(); r.processString("Le simulateur fonctionne très bien sur Linux aujourd'hui.")
            try expect(r.dominantLanguage == .french, "language \(String(describing: r.dominantLanguage))")
            let text = "x86sim runs iPhone apps on Linux."
            let tok = NLTokenizer(unit: .word); tok.string = text
            let words = tok.tokens(for: text.startIndex..<text.endIndex).count
            try expect(words == 6, "words \(words)")
            let tg = NLTagger(tagSchemes: [.lexicalClass]); tg.string = text
            var verbs = 0
            tg.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass, options: [.omitWhitespace, .omitPunctuation]) { t, _ in if t == .verb { verbs += 1 }; return true }
            // lexical classes need NL model assets: none in Apple's simulator (0 verbs there too), so informational
            let emb = NLEmbedding.wordEmbedding(for: .english)
            return "fr, \(words) words, \(verbs) verb(s), word embedding \(emb.map { "dim \($0.dimension)" } ?? "not installed")"
        })
        #endif
        #if canImport(FoundationModels) && os(iOS)
        c.append(check("FoundationModels", "system-model-availability", timeout: 60) {
            let m = SystemLanguageModel.default
            guard case .available = m.availability else { throw Skip("model \(m.availability) (Apple's simulator uses the host Mac's Apple Intelligence)") }
            let s = LanguageModelSession()
            let r = try await s.respond(to: "Reply with the single word: pong")
            return "answer '\(r.content.prefix(40))'"
        })
        #endif
        #if canImport(Translation) && os(iOS)
        c.append(check("Translation", "language-availability", timeout: 40) {
            let langs = await LanguageAvailability().supportedLanguages
            return "\(langs.count) supported languages"
        })
        #endif
        #if canImport(ImagePlayground) && os(iOS)
        c.append(check("ImagePlayground", "availability") {
            let ok = await onMain { ImagePlaygroundViewController.isAvailable }
            try skipIf(!ok, "Image Playground needs Apple Intelligence (not in the Simulator here)")
            return "available"
        })
        #endif
        return c
    }
}
