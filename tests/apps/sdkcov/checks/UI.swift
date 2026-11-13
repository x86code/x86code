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
#if canImport(Accessibility)
import Accessibility
#endif
#if canImport(PaperKit)
import PaperKit
#endif
#if canImport(Social)
import Social
#endif
#if canImport(IntentsUI)
import IntentsUI
#endif
#if canImport(HealthKitUI)
import HealthKitUI
import HealthKit
#endif
#if canImport(CoreAudioKit)
import CoreAudioKit
import AVFAudio
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
        c.append(check("SwiftUICore", "color-path-spring-geometry") {
            // the value types SwiftUI's views are built from, which live in SwiftUICore
            var dark = EnvironmentValues(); dark.colorScheme = .dark
            let light = EnvironmentValues()
            let fixed = Color(.sRGB, red: 0.2, green: 0.4, blue: 0.6), r = fixed.resolve(in: light)
            try expect(abs(r.red - 0.2) < 0.005 && abs(r.blue - 0.6) < 0.005 && abs(r.linearRed - 0.0331) < 0.002, "resolved \(r), linear red \(r.linearRed)")
            try expect(fixed.resolve(in: dark) == r, "a fixed color changed with the scheme")
            // system colors adapt to the scheme (on platforms with a light appearance): informational
            let adapts = Color.red.resolve(in: light) != Color.red.resolve(in: dark)
            let p = Path(roundedRect: CGRect(x: 0, y: 0, width: 100, height: 50), cornerRadius: 10)
            try expect(p.boundingRect == CGRect(x: 0, y: 0, width: 100, height: 50), "bounds \(p.boundingRect)")
            try expect(p.contains(CGPoint(x: 50, y: 25)) && !p.contains(CGPoint(x: 1, y: 1)), "contains (rounded corner)")
            let stroked = p.strokedPath(StrokeStyle(lineWidth: 10)).boundingRect
            try expect(abs(stroked.width - 110) < 0.5, "stroked width \(stroked.width)")
            try expect(!p.trimmedPath(from: 0, to: 0.25).isEmpty && p.trimmedPath(from: 0, to: 0.25).boundingRect.width < 100, "trim")
            let s = Spring(duration: 0.5, bounce: 0)
            let mid = s.value(target: 1.0, initialVelocity: 0, time: 0.1), end = s.value(target: 1.0, initialVelocity: 0, time: 5)
            try expect(mid > 0.05 && mid < 0.95 && abs(end - 1) < 1e-3, "spring at 0.1 s \(mid), at 5 s \(end)")
            try expect(abs(Angle(degrees: 90).radians - .pi / 2) < 1e-12 && UnitPoint.bottomTrailing == UnitPoint(x: 1, y: 1), "Angle / UnitPoint")
            return "spring settles in \(String(format: "%.2f", s.settlingDuration)) s, system red adapts to dark \(adapts)"
        })
        #if canImport(Accessibility)
        c.append(check("Accessibility", "chart-descriptor-custom-content") {
            let x = AXNumericDataAxisDescriptor(title: "Day", range: 0...6, gridlinePositions: []) { "day \(Int($0))" }
            let y = AXNumericDataAxisDescriptor(title: "Steps", range: 0...12000, gridlinePositions: [5000, 10000]) { "\(Int($0)) steps" }
            let pts: [AXDataPoint] = (0..<7).map { (i: Int) -> AXDataPoint in AXDataPoint(x: Double(i), y: Double(4000 + i * 1000)) }
            let chart = AXChartDescriptor(title: "Week", summary: "rising", xAxis: x, yAxis: y, additionalAxes: [], series: [AXDataSeriesDescriptor(name: "steps", isContinuous: true, dataPoints: pts)])
            try expect(chart.series.first?.dataPoints.count == 7 && chart.xAxis.title == "Day", "chart")
            try expect(y.valueDescriptionProvider(8000) == "8000 steps" && y.gridlinePositions == [5000, 10000], "value description")
            let cc = AXCustomContent(label: "Calories", value: "320"); cc.importance = .high
            let d = try NSKeyedArchiver.archivedData(withRootObject: cc, requiringSecureCoding: true)
            let back = try NSKeyedUnarchiver.unarchivedObject(ofClass: AXCustomContent.self, from: d)
            try expect(back?.label == "Calories" && back?.value == "320" && back?.importance == .high, "custom content round trip")
            return "chart \(chart.series.count) series, custom content \(d.count) B"
        })
        #endif
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
        #if canImport(RealityKit) && !os(watchOS)
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
        #if canImport(PaperKit) && (os(iOS) || os(visionOS))
        c.append(check("PaperKit", "markup-insert-archive-draw", timeout: 60) {
            var m = PaperMarkup(bounds: CGRect(x: 0, y: 0, width: 200, height: 100))
            m.insertNewShape(configuration: ShapeConfiguration(type: .rectangle, fillColor: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)), frame: CGRect(x: 10, y: 10, width: 60, height: 60))
            m.insertNewTextbox(attributedText: AttributedString("PaperKit sdkcov"), frame: CGRect(x: 80, y: 10, width: 110, height: 40))
            try expect(m.subelements.count == 2, "\(m.subelements.count) elements")
            let d = try await m.dataRepresentation()
            let back = try PaperMarkup(dataRepresentation: d)
            let n = await back.subelements.count, text = await back.indexableContent ?? ""
            try expect(n == 2 && text.contains("sdkcov"), "round trip: \(n) elements, text '\(text)'")
            let ctx = bitmap(200, 100)
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
            await back.draw(in: ctx, frame: CGRect(x: 0, y: 0, width: 200, height: 100))
            // the rectangle covers (10..70, 10..70) in markup coordinates: its middle is red whichever way y runs
            let px = pixel(ctx, 40, 40)
            try expect(px[0] > 200 && px[1] < 80 && px[2] < 80, "rectangle pixel \(px)")
            return "\(d.count) B markup"
        })
        #endif
        #if canImport(Social) && os(iOS)
        c.append(check("Social", "request-signing-objects") {
            // SLRequest builds the HTTP request locally; no account, no network
            guard let r = SLRequest(forServiceType: SLServiceTypeTwitter, requestMethod: .POST, url: URL(string: "https://api.example.com/1/update.json"), parameters: ["status": "x86sim sdkcov", "n": "1"]) else { throw Fail("SLRequest") }
            r.addMultipartData(Data("payload".utf8), withName: "media", type: "application/octet-stream", filename: "x.bin")
            let u = r.preparedURLRequest()
            try expect(u?.httpMethod == "POST" && u?.url?.host == "api.example.com", "prepared \(String(describing: u))")
            return "\(u?.value(forHTTPHeaderField: "Content-Type")?.prefix(19) ?? "no content type"), compose available \(SLComposeViewController.isAvailable(forServiceType: SLServiceTypeTwitter))"
        })
        #endif
        #if canImport(IntentsUI) && (os(iOS) || os(visionOS))
        c.append(check("IntentsUI", "voice-shortcut-button-controller") {
            try await onMain {
                let sc = INShortcut(userActivity: NSUserActivity(activityType: "com.x86sim.test.sdkcov.activity"))
                let b = INUIAddVoiceShortcutButton(style: .automaticOutline); b.shortcut = sc
                b.frame = CGRect(x: 0, y: 0, width: 300, height: 60); b.layoutIfNeeded()
                let sz = b.intrinsicContentSize
                try expect(sz.width > 50 && sz.height > 20 && b.shortcut != nil, "button \(sz)")
                let vc = INUIAddVoiceShortcutViewController(shortcut: sc); vc.loadViewIfNeeded()
                return "button \(sz)"
            }
        })
        #endif
        #if canImport(HealthKitUI) && (os(iOS) || os(visionOS))
        c.append(check("HealthKitUI", "activity-ring-view") {
            try await onMain {
                let s = HKActivitySummary()
                s.activeEnergyBurned = HKQuantity(unit: .kilocalorie(), doubleValue: 300); s.activeEnergyBurnedGoal = HKQuantity(unit: .kilocalorie(), doubleValue: 400)
                s.appleExerciseTime = HKQuantity(unit: .minute(), doubleValue: 20); s.appleExerciseTimeGoal = HKQuantity(unit: .minute(), doubleValue: 30)
                s.appleStandHours = HKQuantity(unit: .count(), doubleValue: 8); s.appleStandHoursGoal = HKQuantity(unit: .count(), doubleValue: 12)
                let r = HKActivityRingView(frame: CGRect(x: 0, y: 0, width: 120, height: 120)); r.setActivitySummary(s, animated: false); r.layoutIfNeeded()
                try expect(r.activitySummary?.activeEnergyBurned.doubleValue(for: .kilocalorie()) == 300, "summary")
                // the rings draw through Core Animation layers: how much of the view they ink (informational)
                let ctx = bitmap(120, 120); r.layer.render(in: ctx)
                var ink = 0
                for y in stride(from: 0, to: 120, by: 4) { for x in stride(from: 0, to: 120, by: 4) where pixel(ctx, x, y)[3] > 0 { ink += 1 } }
                return "\(r.layer.sublayers?.count ?? 0) layers, \(ink) sampled pixels inked"
            }
        })
        #endif
        #if canImport(CoreAudioKit) && (os(iOS) || os(visionOS))
        c.append(check("CoreAudioKit", "generic-au-view") {
            // the generic parameter view of a real audio unit (an EQ: its bands' parameters)
            try await onMain {
                let eq = AVAudioUnitEQ(numberOfBands: 3)
                let vc = AUGenericViewController(); vc.auAudioUnit = eq.auAudioUnit
                vc.view.frame = CGRect(x: 0, y: 0, width: 400, height: 600); vc.view.layoutIfNeeded()
                let params = eq.auAudioUnit.parameterTree?.allParameters.count ?? 0
                try expect(vc.auAudioUnit === eq.auAudioUnit && params >= 3, "\(params) parameters")
                let midi = CABTMIDICentralViewController(); midi.loadViewIfNeeded()
                return "EQ with \(params) parameters, \(vc.view.subviews.count) subviews"
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
        #if canImport(UIKit) && os(watchOS)
        c.append(check("UIKit", "image-color-font") {
            // watchOS UIKit: images, colors and fonts (no views)
            guard let sym = UIImage(systemName: "heart.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 40)) else { throw Fail("SF Symbol") }
            try expect(sym.size.width > 20, "symbol size \(sym.size)")
            let ctx = bitmap(8, 8); ctx.setFillColor(UIColor(red: 0, green: 0.5, blue: 1, alpha: 1).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            guard let png = UIImage(cgImage: ctx.makeImage()!).pngData(), let back = UIImage(data: png)?.cgImage else { throw Fail("PNG round trip") }
            let c2 = bitmap(8, 8); c2.draw(back, in: CGRect(x: 0, y: 0, width: 8, height: 8))
            try expect(pixel(c2, 4, 4)[2] > 240 && abs(Int(pixel(c2, 4, 4)[1]) - 128) < 3, "PNG pixel \(pixel(c2, 4, 4))")
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            try expect(UIColor(red: 1, green: 0, blue: 0, alpha: 1).getHue(&h, saturation: &s, brightness: &b, alpha: &a) && h == 0 && s == 1, "HSB")
            let f = UIFont.preferredFont(forTextStyle: .body), big = UIFont.systemFont(ofSize: 30, weight: .bold)
            try expect(f.pointSize > 10 && big.lineHeight > 30 && big.fontDescriptor.symbolicTraits.contains(.traitBold), "fonts \(f.pointSize) \(big.lineHeight)")
            return "\(png.count) B PNG, body \(f.pointSize) pt"
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
