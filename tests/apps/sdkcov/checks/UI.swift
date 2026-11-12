// sdkcov functional checks: UI frameworks. Views render offscreen (ImageRenderer, UIGraphicsImageRenderer) and
// their pixels are read back; view controllers of the UI-only frameworks load their views.
import Foundation
import SwiftUI
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Charts)
import Charts
#endif
#if canImport(WebKit)
import WebKit
#endif
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif
#if canImport(PencilKit)
import PencilKit
#endif
#if canImport(QuickLookThumbnailing)
import QuickLookThumbnailing
#endif
#if canImport(QuickLook)
import QuickLook
#endif
#if canImport(ContactsUI)
import ContactsUI
#endif
#if canImport(EventKitUI)
import EventKitUI
#endif
#if canImport(PhotosUI)
import PhotosUI
#endif
#if canImport(SafariServices)
import SafariServices
#endif
#if canImport(MessageUI)
import MessageUI
#endif
#if canImport(CoreLocationUI)
import CoreLocationUI
#endif
#if canImport(_CoreLocationUI_SwiftUI)
import _CoreLocationUI_SwiftUI   // the SwiftUI cross-import overlay (LocationButton); Apple's driver imports it implicitly
#endif
#if canImport(VisionKit)
import VisionKit
#endif
#if canImport(RealityKit)
import RealityKit
#endif
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif
#if canImport(TVUIKit)
import TVUIKit
#endif
#if canImport(TVServices)
import TVServices
#endif
#if canImport(TVMLKit)
import TVMLKit
#endif
#if canImport(WatchKit)
import WatchKit
#endif
#if canImport(ClockKit)
import ClockKit
#endif

/// render a SwiftUI view to a CGImage and return the RGBA of pixel (x, y) (image pixels, y from the top)
@MainActor func renderPixel<V: View>(_ v: V, size: CGSize, at p: CGPoint) throws -> (CGImage, [UInt8]) {
    let r = ImageRenderer(content: v.frame(width: size.width, height: size.height)); r.scale = 1
    guard let img = r.cgImage else { throw Fail("ImageRenderer produced no image") }
    let ctx = bitmap(img.width, img.height); ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    return (img, pixel(ctx, Int(p.x), Int(p.y)))
}

extension Registry {
    static var ui: [Check] {
        var c: [Check] = [
            check("SwiftUI", "image-renderer-layout") {
                try await onMain {
                    let v = HStack(spacing: 0) { Color(red: 1, green: 0, blue: 0); Color(red: 0, green: 0, blue: 1) }   // Color.red is the system red
                    let (img, left) = try renderPixel(v, size: CGSize(width: 100, height: 40), at: CGPoint(x: 10, y: 20))
                    let ctx = bitmap(img.width, img.height); ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
                    let right = pixel(ctx, 90, 20)
                    try expect(left[0] > 200 && left[2] < 60, "left \(left)")
                    try expect(right[2] > 200 && right[0] < 60, "right \(right)")
                    // text, SF Symbols, shapes and a List-like stack lay out and render
                    let t = VStack { Text("x86sim").font(.largeTitle); Image(systemName: "star.fill"); Circle().fill(.green).frame(width: 10) }
                    let tr = ImageRenderer(content: t); try expect(tr.cgImage != nil, "text + symbol render")
                    return "\(img.width)x\(img.height)"
                }
            },
        ]
        #if canImport(Charts)
        c.append(check("Charts", "bar-line-render") {
            try await onMain {
                struct P: Identifiable { let id: Int; let v: Double }
                let data = (0..<6).map { P(id: $0, v: Double($0 * $0)) }
                let chart = Chart(data) { BarMark(x: .value("x", $0.id), y: .value("v", $0.v)); LineMark(x: .value("x", $0.id), y: .value("v", $0.v)) }
                let r = ImageRenderer(content: chart.frame(width: 300, height: 200)); r.scale = 1
                guard let img = r.cgImage else { throw Fail("no image") }
                // count non-background pixels: bars must be drawn
                let ctx = bitmap(img.width, img.height); ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
                var ink = 0
                for y in stride(from: 0, to: img.height, by: 4) { for x in stride(from: 0, to: img.width, by: 4) where pixel(ctx, x, y)[3] > 0 { ink += 1 } }
                try expect(ink > 100, "chart drew \(ink) sampled pixels")
                return "\(ink) sampled pixels inked"
            }
        })
        #endif
        #if canImport(UIKit) && !os(watchOS)
        c.append(check("UIKit", "views-autolayout-render-symbols") {
            try await onMain {
                let v = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 100)); v.backgroundColor = .white
                let l = UILabel(); l.text = "x86sim"; l.font = .preferredFont(forTextStyle: .headline); l.translatesAutoresizingMaskIntoConstraints = false
                let b = UIView(); b.backgroundColor = UIColor(red: 1, green: 0, blue: 0, alpha: 1); b.translatesAutoresizingMaskIntoConstraints = false
                v.addSubview(l); v.addSubview(b)
                NSLayoutConstraint.activate([l.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8), l.centerYAnchor.constraint(equalTo: v.centerYAnchor),
                                             b.trailingAnchor.constraint(equalTo: v.trailingAnchor), b.topAnchor.constraint(equalTo: v.topAnchor),
                                             b.widthAnchor.constraint(equalToConstant: 50), b.heightAnchor.constraint(equalToConstant: 50)])
                v.layoutIfNeeded()
                try expect(b.frame == CGRect(x: 150, y: 0, width: 50, height: 50), "auto layout \(b.frame)")
                try expect(l.intrinsicContentSize.width > 30, "label size")
                let img = UIGraphicsImageRenderer(bounds: v.bounds, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }()).image { v.layer.render(in: $0.cgContext) }
                let ctx = bitmap(200, 100); ctx.draw(img.cgImage!, in: CGRect(x: 0, y: 0, width: 200, height: 100))
                try expect(pixel(ctx, 175, 25)[0] > 200 && pixel(ctx, 175, 25)[1] < 60, "red box \(pixel(ctx, 175, 25))")
                try expect(UIImage(systemName: "gearshape.fill") != nil, "SF Symbol")
                let dyn = UIColor { $0.userInterfaceStyle == .dark ? .black : .white }
                try expect(dyn.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)) == .black, "dynamic color")
                let tv = UITableView(); final class DS: NSObject, UITableViewDataSource {
                    func tableView(_ t: UITableView, numberOfRowsInSection s: Int) -> Int { 100 }
                    func tableView(_ t: UITableView, cellForRowAt i: IndexPath) -> UITableViewCell { UITableViewCell() } }
                let ds = DS(); tv.dataSource = ds; tv.frame = CGRect(x: 0, y: 0, width: 200, height: 400); tv.layoutIfNeeded()
                try expect(tv.numberOfRows(inSection: 0) == 100 && !tv.visibleCells.isEmpty, "table view")
                #if os(visionOS)   // no UIScreen: windows live in space, sized by their scene
                let ws = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
                return "\(UIDevice.current.model) \(UIDevice.current.systemName) \(UIDevice.current.systemVersion), scene \(ws?.coordinateSpace.bounds.size ?? .zero), traits \(UITraitCollection.current.displayScale)"
                #else
                return "\(UIDevice.current.model) \(UIDevice.current.systemName) \(UIDevice.current.systemVersion), screen \(UIScreen.main.bounds.size) @\(UIScreen.main.scale)x (native \(UIScreen.main.nativeScale)), traits \(UITraitCollection.current.displayScale)"
                #endif
            }
        })
        c.append(check("UIKit", "window-scene-viewcontroller") {
            try await onMain {
                let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                guard let ws = scenes.first else { throw Fail("no window scene") }
                let w = ws.windows.first { $0.isKeyWindow } ?? ws.windows.first
                try expect(w != nil, "no window")
                let vc = UIViewController(); vc.loadViewIfNeeded()
                let nav = UINavigationController(rootViewController: vc); nav.loadViewIfNeeded()
                return "\(scenes.count) scenes, state \(ws.activationState.rawValue), \(ws.windows.count) windows"
            }
        })
        #endif
        #if canImport(UIKit) && (os(iOS) || os(visionOS))
        c.append(check("UIKit", "pasteboard-text-input") {
            try await onMain {
                UIPasteboard.general.string = "sdkcov"
                try expect(UIPasteboard.general.string == "sdkcov", "pasteboard")
                let tf = UITextField(); tf.text = "abc"; tf.text?.append("d")
                try expect(tf.text == "abcd" && tf.hasText, "text field")
                return "ok"
            }
        })
        #endif
        #if canImport(WebKit) && (os(iOS) || os(visionOS))
        c.append(check("WebKit", "webview-load-javascript", timeout: 120) {
            // in the key window, as an app shows one (WebKit throttles a web view that is in no window)
            let v = await onMain { () -> WKWebView in
                let v = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
                let w = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.windows.first }.first
                w?.addSubview(v); v.alpha = 0.01
                return v
            }
            defer { Task { @MainActor in v.removeFromSuperview() } }
            final class N: NSObject, WKNavigationDelegate { var cont: CheckedContinuation<Void, Error>?
                func webView(_ w: WKWebView, didFinish n: WKNavigation!) { cont?.resume(); cont = nil }
                func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { cont?.resume(throwing: e); cont = nil }
                func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { cont?.resume(throwing: e); cont = nil } }
            let n = N()
            try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
                Task { @MainActor in n.cont = k; v.navigationDelegate = n
                    v.loadHTMLString("<html><head><title>sdkcov</title></head><body><div id=d>x86</div><script>document.getElementById('d').textContent += 'sim'</script></body></html>", baseURL: nil) }
            }
            let r = try await Task { @MainActor in try await v.evaluateJavaScript("document.title + '|' + document.getElementById('d').textContent + '|' + (6*7)") }.value
            try expect(r as? String == "sdkcov|x86sim|42", "JS result \(String(describing: r))")
            return "WebContent ran JS: \(r!)"
        })
        #endif
        #if canImport(JavaScriptCore) && !os(watchOS)
        c.append(check("JavaScriptCore", "context-bridge") {
            guard let ctx = JSContext() else { throw Fail("JSContext") }
            let mul: @convention(block) (Int, Int) -> Int = { $0 * $1 }
            ctx.setObject(mul, forKeyedSubscript: "mul" as NSString)
            let r = ctx.evaluateScript("[1,2,3].map(x => mul(x, 10)).reduce((a,b)=>a+b, 0) + JSON.parse('{\"a\":2}').a")
            try expect(r?.toInt32() == 62, "result \(String(describing: r))")
            try expect(ctx.exception == nil, "exception \(String(describing: ctx.exception))")
            return "62"
        })
        #endif
        #if canImport(PencilKit) && (os(iOS) || os(visionOS))
        c.append(check("PencilKit", "drawing-roundtrip-image") {
            try await onMain {
                let pts = (0..<20).map { PKStrokePoint(location: CGPoint(x: $0 * 5, y: $0 * 3), timeOffset: Double($0) * 0.01, size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2) }
                let d = PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: pts, creationDate: .now))])
                let back = try PKDrawing(data: d.dataRepresentation())
                try expect(back.strokes.count == 1, "round trip")
                let img = d.image(from: d.bounds, scale: 1); try expect(img.size.width > 50, "image \(img.size)")
                let cv = PKCanvasView(); cv.drawing = d
                return "bounds \(d.bounds.integral)"
            }
        })
        #endif
        #if canImport(QuickLookThumbnailing) && (os(iOS) || os(visionOS))
        c.append(check("QuickLookThumbnailing", "png-thumbnail", timeout: 60) {
            let u = FileManager.default.temporaryDirectory.appendingPathComponent("sdkcov-thumb.png")
            try encode(textImage("QL", 400, 400, size: 120), .png).write(to: u)
            defer { try? FileManager.default.removeItem(at: u) }
            let r = QLThumbnailGenerator.Request(fileAt: u, size: CGSize(width: 64, height: 64), scale: 1, representationTypes: .thumbnail)
            let t = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: r)
            try expect(t.cgImage.width > 0, "thumbnail")
            return "\(t.cgImage.width)x\(t.cgImage.height) type \(t.type.rawValue)"
        })
        #endif
        #if canImport(QuickLook) && (os(iOS) || os(visionOS))
        c.append(check("QuickLook", "preview-controller") { try await onMain { let q = QLPreviewController(); q.loadViewIfNeeded(); return "\(QLPreviewController.canPreview(URL(fileURLWithPath: "/x.pdf") as QLPreviewItem))" } })
        #endif
        #if canImport(ContactsUI) && (os(iOS) || os(visionOS))
        c.append(check("ContactsUI", "contact-view-controller") { try await onMain { let v = CNContactViewController(forNewContact: nil); v.loadViewIfNeeded(); return "ok" } })
        #endif
        #if canImport(EventKitUI) && (os(iOS) || os(visionOS))
        c.append(check("EventKitUI", "edit-view-controller") { try await onMain { let v = EKEventEditViewController(); v.loadViewIfNeeded(); return "ok" } })
        #endif
        #if canImport(PhotosUI) && (os(iOS) || os(visionOS))
        c.append(check("PhotosUI", "picker") {
            try await onMain { var cfg = PHPickerConfiguration(); cfg.selectionLimit = 2; cfg.filter = .images
                let p = PHPickerViewController(configuration: cfg); p.loadViewIfNeeded(); return "ok" }
        })
        #endif
        #if canImport(SafariServices) && (os(iOS) || os(visionOS))
        c.append(check("SafariServices", "safari-view-controller") {
            try await onMain { let s = SFSafariViewController(url: URL(string: "https://example.com")!); s.loadViewIfNeeded(); return "ok" }
        })
        #endif
        #if canImport(MessageUI) && (os(iOS) || os(visionOS))
        c.append(check("MessageUI", "can-send") {
            let mail = MFMailComposeViewController.canSendMail(), text = MFMessageComposeViewController.canSendText()
            try skipIf(!mail && !text, "no Mail account / Messages in the Simulator")
            return "mail \(mail), text \(text)"
        })
        #endif
        #if canImport(CoreLocationUI) && os(iOS)
        c.append(check("CoreLocationUI", "location-button-layout") {
            // LocationButton (SwiftUI) wraps this UIKit control; ImageRenderer cannot draw UIKit-backed views
            try await onMain {
                let b = CLLocationButton(frame: CGRect(x: 0, y: 0, width: 220, height: 50)); b.icon = .arrowFilled; b.label = .currentLocation; b.cornerRadius = 10
                b.layoutIfNeeded()
                let sz = b.sizeThatFits(CGSize(width: 1000, height: 1000))
                try expect(sz.width > 20 && sz.height > 20, "size \(sz)")
                return "\(sz)"
            }
        })
        #endif
        #if canImport(VisionKit) && (os(iOS) || os(visionOS))
        c.append(check("VisionKit", "analyzer-scanner-support") {
            let scan = await onMain { DataScannerViewController.isSupported }
            let doc = VNDocumentCameraViewController.isSupported
            try skipIf(!scan && !doc && !ImageAnalyzer.isSupported, "no camera / Live Text in the Simulator")
            return "scanner \(scan), document camera \(doc), image analyzer \(ImageAnalyzer.isSupported)"
        })
        #endif
        #if canImport(RealityKit) && (os(iOS) || os(visionOS))
        c.append(check("RealityKit", "entities-meshes") {
            try await onMain {
                let box = ModelEntity(mesh: .generateBox(size: 0.1), materials: [SimpleMaterial(color: .red, isMetallic: false)])
                let anchor = AnchorEntity(world: .zero); anchor.addChild(box)
                box.position = [0, 0.5, 0]
                try expect(box.position(relativeTo: nil).y == 0.5, "transform")
                let sphere = MeshResource.generateSphere(radius: 1)
                try expect(sphere.bounds.extents.x > 1.9, "mesh bounds \(sphere.bounds.extents)")
                return "ok"
            }
        })
        #endif
        #if canImport(AuthenticationServices) && (os(iOS) || os(visionOS))
        c.append(check("AuthenticationServices", "web-auth-session") {
            let s = ASWebAuthenticationSession(url: URL(string: "https://example.com/auth")!, callback: .customScheme("sdkcov")) { _, _ in }
            return "canStart \(await onMain { s.canStart })"
        })
        #endif
        return c
    }

    static var platform: [Check] {
        var c: [Check] = []
        #if canImport(TVUIKit) && os(tvOS)
        c.append(check("TVUIKit", "poster-lockup") {
            try await onMain {
                let p = TVPosterView(image: UIImage(systemName: "tv")); p.title = "sdkcov"; p.frame = CGRect(x: 0, y: 0, width: 200, height: 300); p.layoutIfNeeded()
                let m = TVMonogramView(); m.title = "x86"
                return "ok"
            }
        })
        #endif
        #if canImport(TVServices) && os(tvOS)
        c.append(check("TVServices", "top-shelf-content") {
            let item = TVTopShelfSectionedItem(identifier: "sdkcov"); item.title = "sdkcov"
            let col = TVTopShelfItemCollection(items: [item]); col.title = "x86"
            let content = TVTopShelfSectionedContent(sections: [col])
            try expect(content.sections.first?.items.count == 1, "content")
            return "ok"
        })
        #endif
        #if canImport(TVMLKit) && os(tvOS)
        c.append(check("TVMLKit", "application-context") {
            let ctx = TVApplicationControllerContext(); ctx.javaScriptApplicationURL = URL(string: "data:text/javascript,App.onLaunch=function(){}")!
            return "ok"
        })
        #endif
        #if canImport(WatchKit) && os(watchOS)
        c.append(check("WatchKit", "device-application") {
            try await onMain {
                let d = WKInterfaceDevice.current()
                try expect(d.screenBounds.width > 100, "screen \(d.screenBounds)")
                let st = WKApplication.shared().applicationState
                d.play(.click)   // haptic: a no-op in the simulator
                return "\(d.model) \(d.systemVersion), screen \(d.screenBounds.size) @\(d.screenScale)x, state \(st.rawValue), wrist \(d.wristLocation.rawValue)"
            }
        })
        #endif
        #if canImport(ClockKit) && os(watchOS)
        c.append(check("ClockKit", "complication-server") {
            let s = CLKComplicationServer.sharedInstance()
            return "\(s.activeComplications?.count ?? 0) active complications"
        })
        #endif
        return c
    }
}
