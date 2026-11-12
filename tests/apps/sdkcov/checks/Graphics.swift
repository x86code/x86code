// sdkcov functional checks: 2D / 3D graphics and imaging. Everything renders offscreen and reads pixels back.
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
#if canImport(CoreImage)
import CoreImage
import CoreImage.CIFilterBuiltins
#endif
#if canImport(QuartzCore)
import QuartzCore
#endif
#if canImport(IOSurface)
import IOSurface
#endif
#if canImport(Metal)
import Metal
#endif
#if canImport(MetalKit)
import MetalKit
#endif
#if canImport(MetalPerformanceShaders)
import MetalPerformanceShaders
#endif
#if canImport(MetalPerformanceShadersGraph)
import MetalPerformanceShadersGraph
#endif
#if canImport(SceneKit)
import SceneKit
#endif
#if canImport(SpriteKit)
import SpriteKit
#endif
#if canImport(ModelIO)
import ModelIO
#endif
#if canImport(OpenGLES)
import OpenGLES
#endif
#if canImport(GLKit)
import GLKit
#endif
#if canImport(Vision) && !os(watchOS)
import Vision
#endif
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(CoreVideo)
import CoreVideo
#endif

/// an RGBA8 bitmap context of w x h
func bitmap(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
/// RGBA of pixel (x, y) (y from the top) of an RGBA8 context
func pixel(_ c: CGContext, _ x: Int, _ y: Int) -> [UInt8] {
    let p = c.data!.assumingMemoryBound(to: UInt8.self) + y * c.bytesPerRow + x * 4
    return [p[0], p[1], p[2], p[3]]
}
/// draw text black on white with CoreText into a w x h image (for OCR / PDF checks)
func textImage(_ s: String, _ w: Int = 600, _ h: Int = 160, size: CGFloat = 64) -> CGImage {
    let c = bitmap(w, h)
    c.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
    let a = NSAttributedString(string: s, attributes: [kCTFontAttributeName as NSAttributedString.Key: font,
                                                      kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)])
    c.textPosition = CGPoint(x: 20, y: CGFloat(h) / 2 - size / 3)
    CTLineDraw(CTLineCreateWithAttributedString(a), c)
    return c.makeImage()!
}
func encode(_ img: CGImage, _ type: UTType, props: [CFString: Any] = [:]) throws -> Data {
    let d = NSMutableData()
    guard let dst = CGImageDestinationCreateWithData(d, type.identifier as CFString, 1, nil) else { throw Fail("no \(type.identifier) encoder") }
    CGImageDestinationAddImage(dst, img, props as CFDictionary)
    try expect(CGImageDestinationFinalize(dst), "finalize \(type.identifier)")
    return d as Data
}

extension Registry {
    static var graphics: [Check] {
        var c: [Check] = [
            check("CoreGraphics", "bitmap-paths-gradients-pdf") {
                let ctx = bitmap(64, 64)
                ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 64))
                let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1), CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)] as CFArray, locations: nil)!
                ctx.saveGState(); ctx.clip(to: CGRect(x: 32, y: 0, width: 32, height: 64))
                ctx.drawLinearGradient(g, start: CGPoint(x: 32, y: 0), end: CGPoint(x: 64, y: 0), options: []); ctx.restoreGState()
                let p = CGMutablePath(); p.addEllipse(in: CGRect(x: 8, y: 8, width: 16, height: 16))
                ctx.addPath(p); ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); ctx.fillPath()
                try expect(pixel(ctx, 2, 2) == [255, 0, 0, 255], "red fill \(pixel(ctx, 2, 2))")
                try expect(pixel(ctx, 16, 47) == [255, 255, 255, 255], "ellipse \(pixel(ctx, 16, 47))")   // y from top: CG origin is bottom-left
                let gp = pixel(ctx, 62, 30); try expect(gp[1] > 200 && gp[2] < 60, "gradient end \(gp)")
                try expect(p.contains(CGPoint(x: 16, y: 16)) && !p.contains(CGPoint(x: 1, y: 1)), "path hit test")
                // PDF
                let d = NSMutableData(); var box = CGRect(x: 0, y: 0, width: 200, height: 200)
                let pdf = CGContext(consumer: CGDataConsumer(data: d)!, mediaBox: &box, nil)!
                for _ in 0..<3 { pdf.beginPDFPage(nil); pdf.fill(CGRect(x: 10, y: 10, width: 50, height: 50)); pdf.endPDFPage() }
                pdf.closePDF()
                let doc = CGPDFDocument(CGDataProvider(data: d)!)
                try expect(doc?.numberOfPages == 3, "PDF pages \(doc?.numberOfPages ?? -1)")
                return "\(d.length) B PDF"
            },
            check("CoreText", "fonts-layout") {
                let f = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
                try expect((CTFontCopyFamilyName(f) as String) == "Helvetica", "Helvetica: \(CTFontCopyFamilyName(f))")
                let a = NSAttributedString(string: "x86sim lays out text", attributes: [kCTFontAttributeName as NSAttributedString.Key: f])
                let w = CTLineGetTypographicBounds(CTLineCreateWithAttributedString(a), nil, nil, nil)
                try expect(w > 150 && w < 400, "line width \(w)")
                let fs = CTFramesetterCreateWithAttributedString(a)
                let sz = CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRange(), nil, CGSize(width: 80, height: 1000), nil)
                try expect(sz.height > 50, "wrapped height \(sz.height)")
                let fams = (CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? []
                try expect(fams.count > 20, "families \(fams.count)")
                let emoji = CTFontCreateForString(f, "😀" as CFString, CFRange(location: 0, length: 2))
                try expect((CTFontCopyPostScriptName(emoji) as String).contains("Emoji"), "emoji fallback \(CTFontCopyPostScriptName(emoji))")
                return "\(fams.count) families, width \(Int(w))"
            },
            check("ImageIO", "encode-decode-formats") {
                let img = textImage("ImageIO", 256, 96, size: 40)
                var out: [String] = []
                for t in [UTType.png, .jpeg, .tiff, .gif, .bmp, .heic] {
                    let types = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
                    guard types.contains(t.identifier) else { out.append("\(t.preferredFilenameExtension ?? "?") no encoder"); continue }
                    let d = try encode(img, t, props: [kCGImageDestinationLossyCompressionQuality: 0.8])
                    guard let src = CGImageSourceCreateWithData(d as CFData, nil), let back = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw Fail("decode \(t.identifier)") }
                    try expect(back.width == 256 && back.height == 96, "\(t.identifier) size")
                    out.append("\(t.preferredFilenameExtension ?? "?") \(d.count)")
                }
                // EXIF / properties
                let j = try encode(img, .jpeg, props: [kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "x86sim"]])
                let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(j as CFData, nil)!, 0, nil) as? [CFString: Any]
                let exif = props?[kCGImagePropertyExifDictionary] as? [CFString: Any]
                try expect((exif?[kCGImagePropertyExifUserComment] as? String) == "x86sim", "EXIF round trip")
                // animated GIF
                let gd = NSMutableData(); let g = CGImageDestinationCreateWithData(gd, UTType.gif.identifier as CFString, 3, nil)!
                for _ in 0..<3 { CGImageDestinationAddImage(g, img, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary) }
                CGImageDestinationFinalize(g)
                try expect(CGImageSourceGetCount(CGImageSourceCreateWithData(gd, nil)!) == 3, "GIF frames")
                // thumbnail
                let th = CGImageSourceCreateThumbnailAtIndex(CGImageSourceCreateWithData(j as CFData, nil)!, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 64] as CFDictionary)
                try expect(th?.width == 64, "thumbnail \(th?.width ?? 0)")
                return out.joined(separator: ", ")
            },
        ]
        #if canImport(CoreImage)
        c.append(check("CoreImage", "filters-context-qr") {
            let ctx = CIContext()
            let qr = CIFilter.qrCodeGenerator(); qr.message = Data("x86sim".utf8); qr.correctionLevel = "M"
            guard let code = qr.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { throw Fail("QR generator") }
            let blur = CIFilter.gaussianBlur(); blur.inputImage = CIImage(cgImage: textImage("CI")); blur.radius = 4
            let mono = CIFilter.photoEffectMono(); mono.inputImage = blur.outputImage
            guard let out = mono.outputImage, let cg = ctx.createCGImage(out, from: CGRect(x: 0, y: 0, width: 600, height: 160)) else { throw Fail("render") }
            try expect(cg.width == 600, "render size")
            var px = [UInt8](repeating: 0, count: 4)
            ctx.render(CIImage(color: CIColor(cgColor: CGColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1))).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1)), toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            try expect(abs(Int(px[0]) - 51) <= 2 && abs(Int(px[2]) - 153) <= 2, "constant color \(px)")
            #if !os(watchOS)
            let det = CIDetector(ofType: CIDetectorTypeQRCode, context: ctx, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
            let f = det?.features(in: code.composited(over: CIImage(color: .white).cropped(to: code.extent.insetBy(dx: -40, dy: -40)))).first as? CIQRCodeFeature
            try expect(f?.messageString == "x86sim", "QR detect: \(f?.messageString ?? "nothing")")
            #endif
            return "\(CIFilter.filterNames(inCategory: nil).count) filters"
        })
        #endif
        #if canImport(QuartzCore) && !os(watchOS)
        c.append(check("QuartzCore", "layers-render-animation") {
            try await onMain {
                let root = CALayer(); root.frame = CGRect(x: 0, y: 0, width: 64, height: 64); root.backgroundColor = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
                let sh = CAShapeLayer(); sh.path = CGPath(rect: CGRect(x: 0, y: 0, width: 32, height: 64), transform: nil)
                sh.fillColor = CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1); root.addSublayer(sh)
                let gl = CAGradientLayer(); gl.frame = CGRect(x: 32, y: 32, width: 32, height: 32); root.addSublayer(gl)
                let a = CABasicAnimation(keyPath: "opacity"); a.fromValue = 0; a.toValue = 1; a.duration = 1; root.add(a, forKey: "fade")
                try expect(root.animation(forKey: "fade") != nil, "animation")
                CATransaction.begin(); CATransaction.setDisableActions(true); root.position = CGPoint(x: 40, y: 40); CATransaction.commit()
                let ctx = bitmap(64, 64); root.position = CGPoint(x: 32, y: 32); root.render(in: ctx)
                try expect(pixel(ctx, 4, 4)[1] == 255, "shape layer \(pixel(ctx, 4, 4))")
                try expect(pixel(ctx, 48, 4)[2] == 255, "background \(pixel(ctx, 48, 4))")
                var t = CATransform3DIdentity; t.m34 = -1 / 500; t = CATransform3DRotate(t, .pi / 4, 0, 1, 0)
                try expect(!CATransform3DIsIdentity(t), "transform")
                return "CACurrentMediaTime \(Int(CACurrentMediaTime()))"
            }
        })
        #endif
        #if canImport(IOSurface)
        c.append(check("IOSurface", "create-lock-write") {
            guard let s = IOSurface(properties: [.width: 64, .height: 64, .bytesPerElement: 4, .pixelFormat: 0x42475241 /* BGRA */]) else { throw Fail("create") }
            s.lock(options: [], seed: nil)
            s.baseAddress.assumingMemoryBound(to: UInt32.self)[10] = 0xdeadbeef
            s.unlock(options: [], seed: nil)
            s.lock(options: .readOnly, seed: nil); let v = s.baseAddress.assumingMemoryBound(to: UInt32.self)[10]; s.unlock(options: .readOnly, seed: nil)
            try expect(v == 0xdeadbeef, "read back \(String(v, radix: 16))")
            return "id \(IOSurfaceGetID(s)), \(s.allocationSize) B"
        })
        #endif
        #if canImport(Metal)
        c.append(check("Metal", "compute-runtime-compiled", timeout: 90) {
            guard let dev = MTLCreateSystemDefaultDevice() else { throw Fail("no MTLDevice") }
            let src = """
            #include <metal_stdlib>
            using namespace metal;
            kernel void mad(device const float *a [[buffer(0)]], device float *b [[buffer(1)]], uint i [[thread_position_in_grid]]) { b[i] = a[i] * 2.0f + 1.0f; }
            """
            let lib = try await dev.makeLibrary(source: src, options: nil)
            let pso = try await dev.makeComputePipelineState(function: lib.makeFunction(name: "mad")!)
            let n = 4096
            let a = dev.makeBuffer(bytes: (0..<n).map(Float.init), length: n * 4, options: .storageModeShared)!
            let b = dev.makeBuffer(length: n * 4, options: .storageModeShared)!
            let q = dev.makeCommandQueue()!, cb = q.makeCommandBuffer()!, e = cb.makeComputeCommandEncoder()!
            e.setComputePipelineState(pso); e.setBuffer(a, offset: 0, index: 0); e.setBuffer(b, offset: 0, index: 1)
            e.dispatchThreads(MTLSize(width: n, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: min(pso.maxTotalThreadsPerThreadgroup, 256), height: 1, depth: 1))
            e.endEncoding(); cb.commit(); cb.waitUntilCompleted()
            try expect(cb.status == .completed, "command buffer \(cb.status.rawValue) \(String(describing: cb.error))")
            let r = b.contents().assumingMemoryBound(to: Float.self)
            try expect(r[0] == 1 && r[4095] == 8191, "results \(r[0]) \(r[4095])")
            return "\(dev.name)"
        })
        c.append(check("Metal", "render-to-texture-readback", timeout: 90) {
            guard let dev = MTLCreateSystemDefaultDevice() else { throw Fail("no MTLDevice") }
            let src = """
            #include <metal_stdlib>
            using namespace metal;
            struct V { float4 p [[position]]; float4 c; };
            vertex V vs(uint i [[vertex_id]]) { float2 p[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) }; V v; v.p = float4(p[i], 0, 1); v.c = float4(1, 0.5, 0, 1); return v; }
            fragment float4 fs(V v [[stage_in]]) { return v.c; }
            """
            let lib = try await dev.makeLibrary(source: src, options: nil)
            let d = MTLRenderPipelineDescriptor(); d.vertexFunction = lib.makeFunction(name: "vs"); d.fragmentFunction = lib.makeFunction(name: "fs")
            d.colorAttachments[0].pixelFormat = .rgba8Unorm
            let pso = try await dev.makeRenderPipelineState(descriptor: d)
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 32, height: 32, mipmapped: false)
            td.usage = [.renderTarget, .shaderRead]; td.storageMode = .shared
            let tex = dev.makeTexture(descriptor: td)!
            let rp = MTLRenderPassDescriptor(); rp.colorAttachments[0].texture = tex; rp.colorAttachments[0].loadAction = .clear
            rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 1, alpha: 1); rp.colorAttachments[0].storeAction = .store
            let cb = dev.makeCommandQueue()!.makeCommandBuffer()!, e = cb.makeRenderCommandEncoder(descriptor: rp)!
            e.setRenderPipelineState(pso); e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); e.endEncoding()
            cb.commit(); cb.waitUntilCompleted()
            var px = [UInt8](repeating: 0, count: 4)
            tex.getBytes(&px, bytesPerRow: 32 * 4, from: MTLRegionMake2D(16, 16, 1, 1), mipmapLevel: 0)
            try expect(px[0] == 255 && abs(Int(px[1]) - 128) <= 2 && px[2] == 0, "pixel \(px)")
            return "triangle drawn, pixel \(px)"
        })
        #endif
        #if canImport(MetalKit)
        c.append(check("MetalKit", "texture-loader-mesh") {
            guard let dev = MTLCreateSystemDefaultDevice() else { throw Fail("no MTLDevice") }
            let t = try MTKTextureLoader(device: dev).newTexture(cgImage: textImage("MTK", 128, 64, size: 30), options: [.SRGB: false])
            try expect(t.width == 128 && t.height == 64, "texture \(t.width)x\(t.height)")
            #if canImport(ModelIO)
            let alloc = MTKMeshBufferAllocator(device: dev)
            let m = try MTKMesh(mesh: MDLMesh(sphereWithExtent: [1, 1, 1], segments: [16, 16], inwardNormals: false, geometryType: .triangles, allocator: alloc), device: dev)
            try expect(m.vertexCount > 200, "mesh vertices \(m.vertexCount)")
            #endif
            return "ok"
        })
        #endif
        #if canImport(MetalPerformanceShaders)
        c.append(check("MetalPerformanceShaders", "blur-matmul", timeout: 90) {
            guard let dev = MTLCreateSystemDefaultDevice() else { throw Fail("no MTLDevice") }
            try skipIf(!MPSSupportsMTLDevice(dev), "MPS does not support this MTLDevice")
            let q = dev.makeCommandQueue()!
            // 2x2 matrix multiply
            let desc = MPSMatrixDescriptor(rows: 2, columns: 2, rowBytes: 8, dataType: .float32)
            func mat(_ v: [Float]) -> MPSMatrix { MPSMatrix(buffer: dev.makeBuffer(bytes: v, length: 16, options: .storageModeShared)!, descriptor: desc) }
            let a = mat([1, 2, 3, 4]), b = mat([5, 6, 7, 8]), r = mat([0, 0, 0, 0])
            let mm = MPSMatrixMultiplication(device: dev, resultRows: 2, resultColumns: 2, interiorColumns: 2)
            let cb = q.makeCommandBuffer()!; mm.encode(commandBuffer: cb, leftMatrix: a, rightMatrix: b, resultMatrix: r)
            // blur a texture
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 64, height: 64, mipmapped: false)
            td.usage = [.shaderRead, .shaderWrite]; td.storageMode = .shared
            let s = dev.makeTexture(descriptor: td)!, d = dev.makeTexture(descriptor: td)!
            MPSImageGaussianBlur(device: dev, sigma: 2).encode(commandBuffer: cb, sourceTexture: s, destinationTexture: d)
            cb.commit(); cb.waitUntilCompleted()
            let out = Array(UnsafeBufferPointer(start: r.data.contents().assumingMemoryBound(to: Float.self), count: 4))
            try expect(out == [19, 22, 43, 50], "matmul \(out)")
            return "ok"
        })
        #endif
        #if canImport(MetalPerformanceShadersGraph)
        c.append(check("MetalPerformanceShadersGraph", "graph-run", timeout: 90) {
            // Apple's iOS 27.2 simulator (24B8117) aborts in +[MPSGraphDevice deviceWithMTLDevice:] (nil inserted into an
            // array) exactly as x86Sim does: not supported in the simulator. SDKCOV_MPSGRAPH=1 runs it anyway.
            try skipIf(ProcessInfo.processInfo.environment["SDKCOV_MPSGRAPH"] != "1", "MPSGraph aborts in Apple's simulator too (MPSGraphDevice init)")
            guard let dev = MTLCreateSystemDefaultDevice() else { throw Fail("no MTLDevice") }
            let g = MPSGraph()
            let x = g.placeholder(shape: [4], dataType: .float32, name: "x")
            let y = g.addition(g.multiplication(x, g.constant(3, dataType: .float32), name: nil), g.constant(1, dataType: .float32), name: nil)
            let gd = MPSGraphDevice(mtlDevice: dev)
            let inp = MPSGraphTensorData(device: gd, data: Data(bytes: [Float](arrayLiteral: 1, 2, 3, 4), count: 16), shape: [4], dataType: .float32)
            let res = g.run(feeds: [x: inp], targetTensors: [y], targetOperations: nil)
            var out = [Float](repeating: 0, count: 4); res[y]!.mpsndarray().readBytes(&out, strideBytes: nil)
            try expect(out == [4, 7, 10, 13], "\(out)")
            return "ok"
        })
        #endif
        #if canImport(SceneKit)
        c.append(check("SceneKit", "offscreen-render", timeout: 90) {
            let scene = SCNScene()
            let box = SCNNode(geometry: SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0.1))
            box.geometry?.firstMaterial?.diffuse.contents = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
            box.runAction(SCNAction.rotateBy(x: 0, y: 1, z: 0, duration: 1)); scene.rootNode.addChildNode(box)
            let cam = SCNNode(); cam.camera = SCNCamera(); cam.position = SCNVector3(0, 0, 4); scene.rootNode.addChildNode(cam)
            let light = SCNNode(); light.light = SCNLight(); light.light?.type = .omni; light.position = SCNVector3(2, 2, 4); scene.rootNode.addChildNode(light)
            scene.physicsWorld.gravity = SCNVector3(0, -9.8, 0)
            box.physicsBody = .dynamic()
            #if os(watchOS)
            return "scene graph \(scene.rootNode.childNodes.count) nodes (no SCNRenderer on watchOS)"
            #else
            guard let dev = MTLCreateSystemDefaultDevice() else { throw Fail("no MTLDevice") }
            let r = SCNRenderer(device: dev, options: nil); r.scene = scene; r.pointOfView = cam
            let img = r.snapshot(atTime: 0, with: CGSize(width: 64, height: 64), antialiasingMode: .none)
            guard let cg = img.cgImage else { throw Fail("snapshot has no image") }
            let ctx = bitmap(64, 64); ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 64, height: 64))
            let p = pixel(ctx, 32, 32)
            try expect(p[0] > 60 && p[1] < 40 && p[2] < 40, "center pixel not red: \(p)")
            return "center \(p)"
            #endif
        })
        #endif
        #if canImport(SpriteKit)
        c.append(check("SpriteKit", "scene-physics-actions", timeout: 60) {
            try await onMain {
                let s = SKScene(size: CGSize(width: 200, height: 200))
                s.physicsWorld.gravity = CGVector(dx: 0, dy: -9.8)
                let n = SKShapeNode(rectOf: CGSize(width: 20, height: 20)); n.position = CGPoint(x: 100, y: 150)
                n.physicsBody = SKPhysicsBody(rectangleOf: CGSize(width: 20, height: 20)); s.addChild(n)
                let lbl = SKLabelNode(text: "x86"); s.addChild(lbl)
                n.run(SKAction.sequence([.fadeOut(withDuration: 0.1), .removeFromParent()]))
                try expect(lbl.frame.width > 0, "label layout")
                try expect(s.children.count == 2, "children")
                let tex = SKTexture(cgImage: textImage("SK", 64, 64, size: 30)); try expect(tex.size() == CGSize(width: 64, height: 64), "texture")
                return "ok"
            }
        })
        #endif
        #if canImport(ModelIO)
        c.append(check("ModelIO", "mesh-asset-export") {
            let m = MDLMesh(boxWithExtent: [1, 1, 1], segments: [2, 2, 2], inwardNormals: false, geometryType: .triangles, allocator: nil)
            try expect(m.vertexCount > 0, "vertices")
            let a = MDLAsset(); a.add(m)
            let u = FileManager.default.temporaryDirectory.appendingPathComponent("sdkcov-\(UUID().uuidString).obj")
            defer { try? FileManager.default.removeItem(at: u) }
            try skipIf(!MDLAsset.canExportFileExtension("obj"), "no OBJ exporter")
            try a.export(to: u)
            let back = MDLAsset(url: u)
            try expect(back.count == 1, "re-imported objects \(back.count)")
            return "\(m.vertexCount) vertices"
        })
        #endif
        #if canImport(OpenGLES) && !os(visionOS)   // visionOS ships the module, every API in it unavailable
        c.append(check("OpenGLES", "context-fbo-clear-readpixels", timeout: 60) {
            try await onMain {
                guard let ctx = EAGLContext(api: .openGLES3) ?? EAGLContext(api: .openGLES2) else { throw Fail("no EAGLContext") }
                try expect(EAGLContext.setCurrent(ctx), "setCurrent")
                defer { EAGLContext.setCurrent(nil) }
                var fb: GLuint = 0, rb: GLuint = 0
                glGenFramebuffers(1, &fb); glBindFramebuffer(GLenum(GL_FRAMEBUFFER), fb)
                glGenRenderbuffers(1, &rb); glBindRenderbuffer(GLenum(GL_RENDERBUFFER), rb)
                glRenderbufferStorage(GLenum(GL_RENDERBUFFER), GLenum(GL_RGBA8), 16, 16)
                glFramebufferRenderbuffer(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_RENDERBUFFER), rb)
                try expect(glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER)) == GLenum(GL_FRAMEBUFFER_COMPLETE), "framebuffer incomplete")
                glViewport(0, 0, 16, 16); glClearColor(0, 1, 0, 1); glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
                var px = [UInt8](repeating: 0, count: 4)
                glReadPixels(8, 8, 1, 1, GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), &px)
                try expect(px == [0, 255, 0, 255], "pixel \(px)")
                let ver = String(cString: glGetString(GLenum(GL_VERSION)))
                glDeleteRenderbuffers(1, &rb); glDeleteFramebuffers(1, &fb)
                return ver
            }
        })
        #endif
        #if canImport(GLKit)
        c.append(check("GLKit", "math") {
            let p = GLKMatrix4MakePerspective(GLKMathDegreesToRadians(65), 1.5, 0.1, 100)
            let v = GLKMatrix4MultiplyVector4(GLKMatrix4MakeTranslation(1, 2, 3), GLKVector4Make(0, 0, 0, 1))
            try expect(v.x == 1 && v.y == 2 && v.z == 3 && p.m11 > 0, "matrix")
            return "ok"
        })
        #endif
        #if canImport(Vision) && !os(watchOS)
        c.append(check("Vision", "ocr-rectangles-featureprint", timeout: 120) {
            let img = textImage("HELLO X86SIM 2026", 900, 200, size: 72)
            // a filled square on white: one rectangle (geometry, no neural network)
            let c = bitmap(200, 200); c.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
            c.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)); c.fill(CGRect(x: 50, y: 50, width: 100, height: 100))
            let r2 = VNDetectRectanglesRequest(); try VNImageRequestHandler(cgImage: c.makeImage()!).perform([r2])
            try expect((r2.results ?? []).count >= 1, "rectangle not found")
            // text recognition and feature prints run neural networks (espresso): Apple's simulator fails them with
            // "Failed to create espresso context" (-1), as x86Sim does
            let ocr = VNRecognizeTextRequest(); ocr.recognitionLevel = .accurate; ocr.usesLanguageCorrection = false
            let fp = VNGenerateImageFeaturePrintRequest()
            do { try VNImageRequestHandler(cgImage: img).perform([ocr, fp]) }
            catch let e as NSError where e.code == -1 && e.localizedDescription.contains("espresso") {
                return "rectangles; OCR / feature print need the neural engine (not in Apple's simulator either)"
            }
            let text = (ocr.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            try expect(text.uppercased().contains("X86SIM"), "OCR read '\(text)'")
            try expect(fp.results?.first?.elementCount ?? 0 > 0, "feature print")
            return "rectangles, OCR '\(text)'"
        })
        #endif
        #if canImport(PDFKit)
        c.append(check("PDFKit", "document-text-render") {
            // a one-page PDF with real text (CoreText into a PDF context), read back through PDFKit
            let d = NSMutableData(); var box = CGRect(x: 0, y: 0, width: 400, height: 200)
            let pdf = CGContext(consumer: CGDataConsumer(data: d)!, mediaBox: &box, nil)!
            pdf.beginPDFPage(nil)
            let a = NSAttributedString(string: "PDFKit x86sim", attributes: [kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName("Helvetica" as CFString, 24, nil)])
            pdf.textPosition = CGPoint(x: 20, y: 100); CTLineDraw(CTLineCreateWithAttributedString(a), pdf)
            pdf.endPDFPage(); pdf.closePDF()
            guard let doc = PDFDocument(data: d as Data) else { throw Fail("PDFDocument") }
            try expect(doc.pageCount == 1, "pages")
            let s = doc.string ?? ""
            try expect(s.contains("x86sim"), "text '\(s)'")
            try expect(!doc.findString("PDFKit", withOptions: .caseInsensitive).isEmpty, "find")
            let th = doc.page(at: 0)!.thumbnail(of: CGSize(width: 100, height: 50), for: .mediaBox)
            try expect(th.size.width > 0, "thumbnail")
            return "'\(s)'"
        })
        #endif
        #if canImport(CoreVideo) && canImport(Metal)
        c.append(check("CoreVideo", "pixelbuffer-pool-metal-cache") {
            var pool: CVPixelBufferPool?
            let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64,
                                        kCVPixelBufferHeightKey as String: 64, kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true]
            try expect(CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool) == kCVReturnSuccess, "pool")
            var pb: CVPixelBuffer?; try expect(CVPixelBufferPoolCreatePixelBuffer(nil, pool!, &pb) == kCVReturnSuccess, "buffer")
            try expect(CVPixelBufferGetIOSurface(pb!) != nil, "IOSurface-backed")
            guard let dev = MTLCreateSystemDefaultDevice() else { throw Fail("no MTLDevice") }
            var cache: CVMetalTextureCache?; CVMetalTextureCacheCreate(nil, nil, dev, nil, &cache)
            var mt: CVMetalTexture?
            try expect(CVMetalTextureCacheCreateTextureFromImage(nil, cache!, pb!, nil, .bgra8Unorm, 64, 64, 0, &mt) == kCVReturnSuccess, "metal texture")
            try expect(CVMetalTextureGetTexture(mt!)?.width == 64, "texture width")
            return "ok"
        })
        #endif
        return c
    }
}
