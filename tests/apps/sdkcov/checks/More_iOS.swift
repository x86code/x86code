// sdkcov functional checks added by the iOS coverage round: frameworks and APIs the shared groups don't reach yet.
// Only built into the iOS app (#if os(iOS)); checks shared with other platforms belong in the group files.
// UI checks put their views on screen as an app does: in a second UIWindow on the app's window scene (iosShow), and
// read pixels back with drawHierarchy (the render server's copy), not only offscreen renderers.
import Foundation
#if os(iOS)
import UIKit
import SwiftUI
import Network
import Synchronization
import AVFoundation
import AVKit
import _AVKit_SwiftUI
import MapKit
import _MapKit_SwiftUI
import SceneKit
import _SceneKit_SwiftUI
import SpriteKit
import _SpriteKit_SwiftUI
import WebKit
import _WebKit_SwiftUI
import AuthenticationServices
import _AuthenticationServices_SwiftUI
import PassKit
import _PassKit_SwiftUI
import UserNotifications
import ActivityKit
import Metal
import TouchController
import GameController
import AlarmKit
import FamilyControls
import DeviceActivity
import ProximityReader
import BackgroundAssets
import AdServices
import AddressBookUI
import ClassKit
import NotificationCenter
import SensorKit
import ExposureNotification
import AccessorySetupKit
import DeclaredAgeRange
import MetalKit
import PhotosUI
import SafariServices
import UniformTypeIdentifiers

// MARK: helpers

/// poll `cond` on the main actor every 30 ms for up to `secs`
private func iosWait(_ secs: Double, _ cond: @escaping @MainActor () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(secs)
    while Date() < end {
        if await MainActor.run(body: { cond() }) { return true }
        try? await Task.sleep(for: .milliseconds(30))
    }
    return await MainActor.run(body: { cond() })
}

/// run `body` in its own task and wait up to `secs` for it; Fail naming the stage when it does not finish (it may stay blocked)
private func iosStage<T: Sendable>(_ name: String, _ secs: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    let r = Mutex<Result<T, Error>?>(nil)
    Task.detached { do { let v = try await body(); r.withLock { $0 = .success(v) } } catch { r.withLock { $0 = .failure(error) } } }
    let t0 = Date()
    while Date().timeIntervalSince(t0) < secs {
        if let v = r.withLock({ $0 }) { return try v.get() }
        try await Task.sleep(for: .milliseconds(50))
    }
    throw Fail("\(name): no answer in \(Int(secs)) s")
}

/// present `vc` modally over a white root in its own window, as an app presents a system sheet (share sheet, document
/// picker, photo picker, Safari: their content is a remote view from another process); waits `settle` s for that
/// content, then reports the remote views found and how much of the window is drawn, and dismisses it
private func iosPresentSystem(_ vc: @escaping @MainActor () -> UIViewController, settle: Double = 4) async throws -> (remote: [String], ink: Double, size: CGSize, grid: String) {
    let (root, done) = try await onMain { () -> (UIViewController, () -> Void) in
        let r = UIViewController(); r.view.backgroundColor = .white
        let (_, done) = try iosShow(r); return (r, done)
    }
    defer { Task { @MainActor in done() } }
    try await iosCheck(await iosWait(3) { root.view.window != nil }) { "root not in a window" }
    let shown = Mutex(false)
    let p = await onMain { () -> UIViewController in
        let p = vc(); p.popoverPresentationController?.sourceView = root.view
        root.present(p, animated: true) { shown.withLock { $0 = true } }
        return p
    }
    try await iosCheck(await iosWait(10) { shown.withLock { $0 } }) { "present completion never ran for \(type(of: p))" }
    try await Task.sleep(for: .seconds(settle))
    let (remote, ink, size, grid) = await onMain { () -> ([String], Double, CGSize, String) in
        var names: [String] = []
        func walk(_ v: UIView) {
            let n = NSStringFromClass(type(of: v))
            if n.contains("Remote") && !v.bounds.isEmpty { names.append("\(n) \(Int(v.bounds.width))x\(Int(v.bounds.height))") }
            v.subviews.forEach(walk)
        }
        if let w = p.view.window { walk(w) }
        let img = p.view.window.flatMap { iosSnapshot($0) }
        let ink = img.map { iosInk($0, bg: [255, 255, 255, 255]) } ?? 0
        // a coarse 8x12 luminance map (hex digit per cell) of the window, to compare what the sheet shows
        var grid = ""
        if let img {
            let ctx = bitmap(img.width, img.height); ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            for gy in 0..<12 { for gx in 0..<8 {
                var sum = 0, n = 0
                for y in stride(from: gy * img.height / 12, to: (gy + 1) * img.height / 12, by: 6) { for x in stride(from: gx * img.width / 8, to: (gx + 1) * img.width / 8, by: 6) {
                    let q = pixel(ctx, x, y); sum += (Int(q[0]) * 3 + Int(q[1]) * 6 + Int(q[2])) / 10; n += 1 } }
                grid += String(min(15, sum / max(n, 1) / 16), radix: 16)
            }; grid += gy < 11 ? "/" : "" }
        }
        return (names, ink, p.view.bounds.size, grid)
    }
    let gone = Mutex(false)
    await onMain { p.dismiss(animated: false) { gone.withLock { $0 = true } } }
    _ = await iosWait(5) { gone.withLock { $0 } }
    return (remote, ink, size, grid)
}

/// throw Fail(msg()) unless ok, the message built on the main actor (it reads UI state)
private func iosCheck(_ ok: Bool, _ msg: @escaping @MainActor () -> String) async throws {
    if !ok { throw Fail(await MainActor.run(body: { msg() })) }
}

@MainActor private func iosScene() throws -> UIWindowScene {
    guard let ws = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { throw Fail("no window scene") }
    return ws
}

/// show `vc` full screen in a new window above the app's own; the returned closure takes it down again
@MainActor private func iosShow(_ vc: UIViewController) throws -> (UIWindow, () -> Void) {
    let ws = try iosScene()
    let w = UIWindow(windowScene: ws)
    w.frame = ws.coordinateSpace.bounds
    w.windowLevel = .normal + 1
    w.rootViewController = vc
    w.isHidden = false
    w.layoutIfNeeded()
    return (w, { w.isHidden = true; w.rootViewController = nil })
}

/// the view's pixels as the screen shows them (drawHierarchy after a commit), scale 1
@MainActor private func iosSnapshot(_ v: UIView) -> CGImage? {
    let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = false
    let img = UIGraphicsImageRenderer(bounds: v.bounds, format: f).image { _ in _ = v.drawHierarchy(in: v.bounds, afterScreenUpdates: true) }
    return img.cgImage
}

/// RGBA at (x, y) of an image, through an RGBA8 sRGB bitmap
private func iosPixel(_ img: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
    let ctx = bitmap(img.width, img.height); ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    return pixel(ctx, x, y)
}

/// fraction of sampled pixels (every 4th) whose colour differs from `bg` by more than 40 in some channel
private func iosInk(_ img: CGImage, bg: [UInt8]) -> Double {
    let ctx = bitmap(img.width, img.height); ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    var ink = 0, n = 0
    for y in stride(from: 0, to: img.height, by: 4) { for x in stride(from: 0, to: img.width, by: 4) {
        n += 1; let p = pixel(ctx, x, y)
        if (0..<3).contains(where: { abs(Int(p[$0]) - Int(bg[$0])) > 40 }) { ink += 1 }
    } }
    return n == 0 ? 0 : Double(ink) / Double(n)
}

private func near(_ p: [UInt8], _ r: Int, _ g: Int, _ b: Int, _ tol: Int = 12) -> Bool {
    abs(Int(p[0]) - r) <= tol && abs(Int(p[1]) - g) <= tol && abs(Int(p[2]) - b) <= tol
}

/// a view controller that records its appearance callbacks
private final class IOSTrackVC: UIViewController {
    var log: [String] = []
    let color: UIColor
    init(_ c: UIColor) { color = c; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() { super.viewDidLoad(); view.backgroundColor = color; log.append("load") }
    override func viewWillAppear(_ a: Bool) { super.viewWillAppear(a); log.append("willAppear") }
    override func viewDidAppear(_ a: Bool) { super.viewDidAppear(a); log.append("didAppear") }
    override func viewWillDisappear(_ a: Bool) { super.viewWillDisappear(a); log.append("willDisappear") }
    override func viewDidDisappear(_ a: Bool) { super.viewDidDisappear(a); log.append("didDisappear") }
}

/// a UIDocument holding one string
private final class IOSTextDoc: UIDocument {
    var text = ""
    override func contents(forType t: String) throws -> Any { Data(text.utf8) }
    override func load(fromContents c: Any, ofType t: String?) throws {
        guard let d = c as? Data else { throw Fail("contents \(type(of: c))") }
        text = String(decoding: d, as: UTF8.self)
    }
}

/// a minimal HTTP/1.1 server on loopback (NWListener): GET /data/<n> answers n bytes with Cache-Control max-age,
/// POST echoes the body back reversed; counts the requests it served
private final class IOSHTTPServer: @unchecked Sendable {
    let listener: NWListener
    let served = Mutex(0)
    init() throws { listener = try NWListener(using: .tcp, on: .any) }
    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] c in c.start(queue: .global()); self?.read(c, Data()) }
        return try await withCheckedThrowingContinuation { cont in
            let once = Mutex(false)
            listener.stateUpdateHandler = { [listener] s in
                switch s {
                case .ready: if !once.withLock({ let o = $0; $0 = true; return o }) { cont.resume(returning: listener.port!.rawValue) }
                case .failed(let e): if !once.withLock({ let o = $0; $0 = true; return o }) { cont.resume(throwing: e) }
                default: break
                }
            }
            listener.start(queue: .global())
        }
    }
    private func read(_ c: NWConnection, _ buf: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] d, _, fin, err in
            guard let self else { return }
            var b = buf; if let d { b.append(d) }
            if let r = b.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: b[..<r.lowerBound], as: UTF8.self)
                let lines = head.components(separatedBy: "\r\n")
                let len = lines.first { $0.lowercased().hasPrefix("content-length:") }.flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                let body = b[r.upperBound...]
                if body.count >= len { self.answer(c, lines.first ?? "", Data(body.prefix(len))); return }
            }
            if err != nil || fin { c.cancel(); return }
            self.read(c, b)
        }
    }
    private func answer(_ c: NWConnection, _ req: String, _ body: Data) {
        served.withLock { $0 += 1 }
        let parts = req.split(separator: " ")
        var out = Data(), status = "200 OK", extra = ""
        if parts.first == "POST" { out = Data(body.reversed()) }
        else if parts.count > 1, parts[1] == "/page" {
            out = Data("<!doctype html><html><head><title>sdkcov</title></head><body style='background:#f00'><h1>x86sim</h1></body></html>".utf8)
            extra = "Content-Type: text/html; charset=utf-8\r\n"
        } else if parts.count > 1, parts[1].hasPrefix("/data/"), let n = Int(parts[1].dropFirst(6)) {
            out = Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 7) }); extra = "Cache-Control: max-age=600\r\nETag: \"sdkcov\"\r\n"
        } else { status = "404 Not Found" }
        let ctype = extra.contains("Content-Type") ? "" : "Content-Type: application/octet-stream\r\n"
        let head = "HTTP/1.1 \(status)\r\n\(ctype)Content-Length: \(out.count)\r\n\(extra)Connection: keep-alive\r\n\r\n"
        c.send(content: Data(head.utf8) + out, completion: .contentProcessed { [weak self] _ in self?.read(c, Data()) })
    }
    deinit { listener.cancel() }
}

/// records UNUserNotificationCenter willPresent calls
private final class IOSNotifDelegate: NSObject, UNUserNotificationCenterDelegate {
    let presented = Mutex<[String]>([])
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions {
        presented.withLock { $0.append(n.request.identifier) }
        return [.list, .banner]
    }
}

/// a SpriteKit scene that counts its update() calls
private final class IOSCountScene: SKScene {
    let frames = Mutex(0)
    override func update(_ t: TimeInterval) { frames.withLock { $0 += 1 } }
}

/// an observable model a hosted SwiftUI view reads and writes
private final class IOSModel: ObservableObject {
    @Published var count = 0
    @Published var path: [Int] = []
    var appeared: [String] = []
    var bodies = 0
}

private struct IOSNavView: View {
    @ObservedObject var m: IOSModel
    var body: some View {
        let _ = { m.bodies += 1 }()
        NavigationStack(path: $m.path) {
            List(0..<40, id: \.self) { i in
                Text("row \(i) count \(m.count)").onAppear { if i == 0 { m.appeared.append("row0") } }
            }
            .navigationTitle("sdkcov")
            .navigationDestination(for: Int.self) { n in
                Color(red: 0, green: 1, blue: 0).onAppear { m.appeared.append("detail\(n)") }
            }
        }
    }
}

private struct IOSLiveAttributes: ActivityAttributes { struct ContentState: Codable, Hashable { var step: Int } ; var name: String }
#endif

extension Registry {
    static var more_ios: [Check] {
        var c: [Check] = []
        #if os(iOS)
        // MARK: UIKit on screen
        c.append(check("UIKit", "window-drawhierarchy-pixels") {
            try await onMain {
                let vc = UIViewController(); vc.view.backgroundColor = UIColor(red: 0, green: 0, blue: 1, alpha: 1)
                let red = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100)); red.backgroundColor = UIColor(red: 1, green: 0, blue: 0, alpha: 1)
                let lbl = UILabel(frame: CGRect(x: 0, y: 200, width: 300, height: 80)); lbl.text = "x86sim"; lbl.font = .boldSystemFont(ofSize: 60)
                lbl.textColor = .white; lbl.backgroundColor = .black
                vc.view.addSubview(red); vc.view.addSubview(lbl)
                let (w, done) = try iosShow(vc); defer { done() }
                guard let img = iosSnapshot(w) else { throw Fail("no snapshot") }
                let r = iosPixel(img, 50, 50), b = iosPixel(img, 200, 150)
                try expect(near(r, 255, 0, 0) && near(b, 0, 0, 255), "red \(r), blue \(b)")
                guard let li = iosSnapshot(lbl) else { throw Fail("no label snapshot") }
                let ink = iosInk(li, bg: [0, 0, 0, 255])
                try expect(ink > 0.05 && ink < 0.7, "label text ink \(ink)")
                return "\(img.width)x\(img.height) window, label ink \(String(format: "%.2f", ink))"
            }
        })
        c.append(check("UIKit", "collection-diffable-list") {
            try await onMain {
                let vc = UIViewController()
                let layout = UICollectionViewCompositionalLayout.list(using: UICollectionLayoutListConfiguration(appearance: .insetGrouped))
                let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
                cv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                vc.view.addSubview(cv)
                let reg = UICollectionView.CellRegistration<UICollectionViewListCell, Int> { cell, _, n in
                    var cfg = cell.defaultContentConfiguration(); cfg.text = "item \(n)"; cfg.secondaryText = "\(n * n)"
                    cfg.image = UIImage(systemName: "star"); cell.contentConfiguration = cfg
                    cell.accessories = [.disclosureIndicator()]
                }
                let ds = UICollectionViewDiffableDataSource<Int, Int>(collectionView: cv) { cv, ip, n in
                    cv.dequeueConfiguredReusableCell(using: reg, for: ip, item: n)
                }
                var snap = NSDiffableDataSourceSnapshot<Int, Int>(); snap.appendSections([0, 1])
                snap.appendItems(Array(0..<30), toSection: 0); snap.appendItems(Array(100..<130), toSection: 1)
                ds.apply(snap, animatingDifferences: false)
                let (w, done) = try iosShow(vc); defer { done() }
                cv.frame = vc.view.bounds; w.layoutIfNeeded(); cv.layoutIfNeeded()
                let vis = cv.visibleCells.count
                try expect(vis >= 8, "visible cells \(vis)")
                try expect(cv.numberOfItems(inSection: 1) == 30, "items in section 1 \(cv.numberOfItems(inSection: 1))")
                let first = (cv.cellForItem(at: IndexPath(item: 3, section: 0)) as? UICollectionViewListCell)?.contentConfiguration as? UIListContentConfiguration
                try expect(first?.text == "item 3", "cell 3 text \(String(describing: first?.text))")
                // a diff: delete, move and insert; the data source keeps index paths straight
                var s2 = ds.snapshot(); s2.deleteItems([0, 1, 2]); s2.moveItem(29, beforeItem: 3); s2.insertItems([999], beforeItem: 100)
                ds.apply(s2, animatingDifferences: false)
                try expect(ds.indexPath(for: 29) == IndexPath(item: 0, section: 0) && ds.indexPath(for: 999) == IndexPath(item: 0, section: 1),
                           "after diff: 29 at \(String(describing: ds.indexPath(for: 29))), 999 at \(String(describing: ds.indexPath(for: 999)))")
                cv.scrollToItem(at: IndexPath(item: 30, section: 1), at: .bottom, animated: false); cv.layoutIfNeeded()
                try expect(cv.indexPathsForVisibleItems.contains(IndexPath(item: 30, section: 1)), "scrolled to the last item: \(cv.indexPathsForVisibleItems.count) visible")
                cv.selectItem(at: IndexPath(item: 5, section: 1), animated: false, scrollPosition: .centeredVertically)
                try expect(cv.indexPathsForSelectedItems == [IndexPath(item: 5, section: 1)], "selection")
                return "\(vis) visible cells, content \(Int(cv.contentSize.width))x\(Int(cv.contentSize.height))"
            }
        })
        c.append(check("UIKit", "table-reload-select-scroll") {
            try await onMain {
                final class DS: NSObject, UITableViewDataSource, UITableViewDelegate {
                    var rows = 200, made = 0, selected: [IndexPath] = []
                    func tableView(_ t: UITableView, numberOfRowsInSection s: Int) -> Int { rows }
                    func tableView(_ t: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
                        made += 1
                        let c = t.dequeueReusableCell(withIdentifier: "c", for: ip); c.textLabel?.text = "row \(ip.row)"; return c
                    }
                    func tableView(_ t: UITableView, didSelectRowAt ip: IndexPath) { selected.append(ip) }
                }
                let ds = DS(), vc = UIViewController()
                let tv = UITableView(frame: .zero, style: .plain); tv.register(UITableViewCell.self, forCellReuseIdentifier: "c")
                tv.dataSource = ds; tv.delegate = ds; tv.autoresizingMask = [.flexibleWidth, .flexibleHeight]; vc.view.addSubview(tv)
                let (w, done) = try iosShow(vc); defer { done() }
                tv.frame = vc.view.bounds; w.layoutIfNeeded(); tv.reloadData(); tv.layoutIfNeeded()
                let firstMade = ds.made
                try expect(firstMade > 5 && firstMade < 100, "cells made for one screen: \(firstMade) (reuse)")
                tv.scrollToRow(at: IndexPath(row: 199, section: 0), at: .bottom, animated: false); tv.layoutIfNeeded()
                try expect(tv.indexPathsForVisibleRows?.contains(IndexPath(row: 199, section: 0)) == true, "last row visible")
                try expect(tv.cellForRow(at: IndexPath(row: 199, section: 0))?.textLabel?.text == "row 199", "last row text")
                ds.rows = 50; tv.reloadData(); tv.layoutIfNeeded()
                try expect(tv.numberOfRows(inSection: 0) == 50 && tv.contentSize.height > 0, "after reload \(tv.numberOfRows(inSection: 0)) rows, height \(tv.contentSize.height)")
                tv.selectRow(at: IndexPath(row: 3, section: 0), animated: false, scrollPosition: .none)
                try expect(tv.indexPathForSelectedRow == IndexPath(row: 3, section: 0), "selected row")
                tv.performBatchUpdates { ds.rows = 51; tv.insertRows(at: [IndexPath(row: 0, section: 0)], with: .automatic) }
                try expect(tv.numberOfRows(inSection: 0) == 51, "batch insert")
                return "\(firstMade) cells for the first screen, \(ds.made) made in all"
            }
        })
        c.append(check("UIKit", "navigation-push-present-dismiss", timeout: 40) {
            let (nav, a, b, m, done) = try await onMain { () -> (UINavigationController, IOSTrackVC, IOSTrackVC, IOSTrackVC, () -> Void) in
                let a = IOSTrackVC(.red), b = IOSTrackVC(.green), m = IOSTrackVC(.blue)
                let nav = UINavigationController(rootViewController: a)
                let (_, done) = try iosShow(nav)
                return (nav, a, b, m, done)
            }
            defer { Task { @MainActor in done() } }
            try await iosCheck(await iosWait(5) { a.log.contains("didAppear") }) { "root never appeared: \(a.log)" }
            // animated push / pop: the transition's completion (Core Animation timing) drives viewDidAppear
            await onMain { nav.pushViewController(b, animated: true) }
            try await iosCheck(await iosWait(5) { b.log.contains("didAppear") && a.log.contains("didDisappear") }) { "push: \((a.log, b.log))" }
            await onMain { _ = nav.popViewController(animated: true) }
            try await iosCheck(await iosWait(5) { b.log.contains("didDisappear") && nav.topViewController === a }) { "pop: \(b.log)" }
            // modal presentation with completion handlers
            let presented = Mutex(false), dismissed = Mutex(false)
            await onMain { m.modalPresentationStyle = .pageSheet; nav.present(m, animated: true) { presented.withLock { $0 = true } } }
            try await iosCheck(await iosWait(5) { presented.withLock { $0 } && m.log.contains("didAppear") }) { "present completion: \(m.log)" }
            try await onMain { try expect(nav.presentedViewController === m && m.presentingViewController === nav, "presented vc") }
            await onMain { m.dismiss(animated: true) { dismissed.withLock { $0 = true } } }
            try await expect(iosWait(5) { dismissed.withLock { $0 } && nav.presentedViewController == nil }, "dismiss completion")
            return await onMain { "root \(a.log.joined(separator: ",")); modal \(m.log.joined(separator: ","))" }
        })
        c.append(check("UIKit", "animation-displaylink-rate", timeout: 30) {
            final class Tick: NSObject { var n = 0, first = 0.0, last = 0.0, maxFPS = 0
                @objc func tick(_ l: CADisplayLink) { if n == 0 { first = l.timestamp }; last = l.timestamp; n += 1; maxFPS = l.preferredFrameRateRange.maximum > 0 ? Int(l.preferredFrameRateRange.maximum) : 0 } }
            let (v, link, t, done) = try await onMain { () -> (UIView, CADisplayLink, Tick, () -> Void) in
                let vc = UIViewController(); let v = UIView(frame: CGRect(x: 0, y: 0, width: 50, height: 50)); v.backgroundColor = .orange; vc.view.addSubview(v)
                let (_, done) = try iosShow(vc)
                let t = Tick(); let l = CADisplayLink(target: t, selector: #selector(Tick.tick(_:))); l.add(to: .main, forMode: .common)
                return (v, l, t, done)
            }
            defer { Task { @MainActor in link.invalidate(); done() } }
            let finished = Mutex<Bool?>(nil)
            await onMain { UIView.animate(withDuration: 0.3, animations: { v.center = CGPoint(x: 200, y: 300); v.alpha = 0.5 }, completion: { f in finished.withLock { $0 = f } }) }
            try await expect(iosWait(5) { finished.withLock { $0 } != nil }, "UIView.animate completion never ran")
            try await onMain { try expect(finished.withLock { $0 } == true && v.center == CGPoint(x: 200, y: 300) && v.layer.presentation()?.opacity ?? 0.5 == 0.5, "animation finished \(String(describing: finished.withLock { $0 })), center \(v.center)") }
            // a property animator scrubbed by hand, then run to the end
            let animDone = Mutex<UIViewAnimatingPosition?>(nil)
            try await onMain {
                let pa = UIViewPropertyAnimator(duration: 1, curve: .linear) { v.transform = CGAffineTransform(scaleX: 2, y: 2) }
                pa.addCompletion { p in animDone.withLock { $0 = p } }
                pa.pauseAnimation(); pa.fractionComplete = 0.5
                try expect(abs(pa.fractionComplete - 0.5) < 0.01 && pa.state == .active, "scrub \(pa.fractionComplete) state \(pa.state.rawValue)")
                pa.continueAnimation(withTimingParameters: nil, durationFactor: 0.2)
            }
            try await expect(iosWait(5) { animDone.withLock { $0 } == .end }, "property animator never ended")
            let (n0, s0) = await onMain { (t.n, Date()) }
            try await Task.sleep(for: .seconds(1))
            let (n1, span) = await onMain { (t.n, Date().timeIntervalSince(s0)) }
            let fps = Double(n1 - n0) / span
            let maxRate = await onMain { UIScreen.main.maximumFramesPerSecond }
            try expect(fps > 20, "display link \(String(format: "%.1f", fps)) Hz (screen max \(maxRate))")
            return "display link \(String(format: "%.0f", fps)) Hz, screen max \(maxRate) fps"
        })
        c.append(check("UIKit", "alert-actionsheet-present", timeout: 30) {
            let (root, done) = try await onMain { () -> (UIViewController, () -> Void) in
                let r = UIViewController(); r.view.backgroundColor = .white
                let (_, done) = try iosShow(r); return (r, done)
            }
            defer { Task { @MainActor in done() } }
            try await expect(iosWait(3) { root.view.window != nil }, "root not in a window")
            var out: [String] = []
            for style in [UIAlertController.Style.alert, .actionSheet] {
                let shown = Mutex(false)
                let ac = await onMain { () -> UIAlertController in
                    let ac = UIAlertController(title: "sdkcov", message: "x86sim", preferredStyle: style)
                    ac.addAction(UIAlertAction(title: "OK", style: .default)); ac.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                    if style == .alert { ac.addTextField { $0.placeholder = "name" } }
                    ac.popoverPresentationController?.sourceView = root.view
                    root.present(ac, animated: true) { shown.withLock { $0 = true } }
                    return ac
                }
                try await expect(iosWait(5) { shown.withLock { $0 } && ac.viewIfLoaded?.window != nil }, "\(style.rawValue): not shown")
                let size = await onMain { ac.view.bounds.size }
                try expect(size.width > 100 && size.height > 50, "\(style.rawValue) size \(size)")
                let gone = Mutex(false)
                await onMain { ac.dismiss(animated: true) { gone.withLock { $0 = true } } }
                try await expect(iosWait(5) { gone.withLock { $0 } && root.presentedViewController == nil }, "\(style.rawValue): not dismissed")
                out.append("\(style == .alert ? "alert" : "sheet") \(Int(size.width))x\(Int(size.height))")
            }
            return out.joined(separator: ", ")
        })
        c.append(check("UIKit", "textview-textkit2-sizing") {
            try await onMain {
                let tv = UITextView(usingTextLayoutManager: true)
                try expect(tv.textLayoutManager != nil, "no TextKit 2 layout manager")
                tv.font = .systemFont(ofSize: 17)
                tv.text = String(repeating: "x86sim runs Apple's simulator runtimes on Linux. ", count: 40)
                let narrow = tv.sizeThatFits(CGSize(width: 200, height: CGFloat.greatestFiniteMagnitude))
                let wide = tv.sizeThatFits(CGSize(width: 800, height: CGFloat.greatestFiniteMagnitude))
                try expect(narrow.height > wide.height * 2.5 && wide.height > 50, "heights narrow \(narrow.height) wide \(wide.height)")
                // attributed text with an attachment and a link; layout fragments enumerate
                let a = NSMutableAttributedString(string: "Bold ", attributes: [.font: UIFont.boldSystemFont(ofSize: 20)])
                a.append(NSAttributedString(string: "link", attributes: [.link: URL(string: "https://example.com")!]))
                a.append(NSAttributedString(attachment: NSTextAttachment(image: UIImage(systemName: "star.fill")!)))
                tv.attributedText = a; tv.frame = CGRect(x: 0, y: 0, width: 300, height: 200); tv.layoutIfNeeded()
                var frags = 0
                tv.textLayoutManager?.enumerateTextLayoutFragments(from: tv.textLayoutManager?.documentRange.location, options: [.ensuresLayout]) { _ in frags += 1; return true }
                try expect(frags >= 1, "layout fragments \(frags)")
                // UILabel multi-line sizing and NSString measuring agree on a line count
                let l = UILabel(); l.numberOfLines = 0; l.font = .systemFont(ofSize: 17); l.text = tv.text.isEmpty ? "" : String(repeating: "word ", count: 60)
                let ls = l.sizeThatFits(CGSize(width: 200, height: CGFloat.greatestFiniteMagnitude))
                let br = (l.text! as NSString).boundingRect(with: CGSize(width: 200, height: CGFloat.greatestFiniteMagnitude), options: [.usesLineFragmentOrigin], attributes: [.font: l.font!], context: nil)
                try expect(abs(ls.height - ceil(br.height)) < 3 && ls.height > 17 * 5, "label \(ls.height) vs boundingRect \(br.height)")
                return "narrow \(Int(narrow.height)) / wide \(Int(wide.height)) pt, \(frags) fragments, label \(Int(ls.height)) pt"
            }
        })
        c.append(check("UIKit", "dynamic-type-traits-colors") {
            try await onMain {
                let big = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraLarge), small = UITraitCollection(preferredContentSizeCategory: .extraSmall)
                let fb = UIFont.preferredFont(forTextStyle: .body, compatibleWith: big), fs = UIFont.preferredFont(forTextStyle: .body, compatibleWith: small)
                try expect(fb.pointSize > fs.pointSize * 2, "body \(fs.pointSize) -> \(fb.pointSize)")
                let scaled = UIFontMetrics(forTextStyle: .title1).scaledValue(for: 10, compatibleWith: big)
                try expect(scaled > 15, "UIFontMetrics scaled 10 -> \(scaled)")
                let dark = UITraitCollection(userInterfaceStyle: .dark), light = UITraitCollection(userInterfaceStyle: .light)
                var dw: CGFloat = 0, lw: CGFloat = 0
                UIColor.label.resolvedColor(with: dark).getWhite(&dw, alpha: nil); UIColor.label.resolvedColor(with: light).getWhite(&lw, alpha: nil)
                try expect(dw > 0.9 && lw < 0.1, "label colour dark \(dw) light \(lw)")
                let dyn = UIColor { $0.userInterfaceStyle == .dark ? .black : .white }
                try expect(dyn.resolvedColor(with: dark) == .black, "dynamic provider")
                // trait override on a view controller reaches its views
                let vc = UIViewController(); vc.traitOverrides.userInterfaceStyle = .dark
                let (w, done) = try iosShow(vc); defer { done() }
                w.layoutIfNeeded()
                try expect(vc.view.traitCollection.userInterfaceStyle == .dark, "trait override: \(vc.view.traitCollection.userInterfaceStyle.rawValue)")
                let sc = w.traitCollection
                return "body \(fs.pointSize)..\(fb.pointSize) pt, window: \(sc.preferredContentSizeCategory.rawValue), style \(sc.userInterfaceStyle.rawValue), scale \(sc.displayScale), gamut \(sc.displayGamut.rawValue)"
            }
        })
        c.append(check("UIKit", "image-symbols-pdf-thumbnail") {
            try await onMain {
                let s = UIImage(systemName: "heart.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20))!
                let l = UIImage(systemName: "heart.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 80, weight: .bold))!
                try expect(l.size.width > s.size.width * 3, "symbol sizes \(s.size) \(l.size)")
                let tinted = l.withTintColor(.red, renderingMode: .alwaysOriginal)
                let f = UIGraphicsImageRendererFormat(); f.scale = 1
                let img = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 120), format: f).image { ctx in
                    UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
                    tinted.draw(in: CGRect(x: 10, y: 10, width: 100, height: 100))
                }
                let center = iosPixel(img.cgImage!, 60, 60)
                try expect(near(center, 255, 0, 0, 40), "tinted symbol centre \(center)")
                guard let png = img.pngData(), let back = UIImage(data: png), let jpg = img.jpegData(compressionQuality: 0.8) else { throw Fail("PNG / JPEG encode") }
                try expect(back.size == img.size && jpg.count > 100, "roundtrip \(back.size)")
                let thumb = img.preparingThumbnail(of: CGSize(width: 30, height: 30))
                try expect(thumb?.size == CGSize(width: 30, height: 30), "thumbnail \(String(describing: thumb?.size))")
                let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 200)).pdfData { ctx in
                    ctx.beginPage(); ("sdkcov" as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 30)])
                    ctx.beginPage()
                }
                try expect(pdf.starts(with: Data("%PDF".utf8)), "PDF header")
                let doc = CGPDFDocument(CGDataProvider(data: pdf as CFData)!)
                try expect(doc?.numberOfPages == 2, "PDF pages \(String(describing: doc?.numberOfPages))")
                let res = UIImage(named: "AppIcon") == nil ? "no asset catalog" : "asset"
                return "symbol \(Int(l.size.width))x\(Int(l.size.height)), PNG \(png.count) B, PDF \(pdf.count) B, \(res)"
            }
        })
        c.append(check("UIKit", "scrollview-zoom-offset") {
            try await onMain {
                final class D: NSObject, UIScrollViewDelegate { var scrolls = 0, zooms = 0; let content: UIView
                    init(_ c: UIView) { content = c }
                    func scrollViewDidScroll(_ s: UIScrollView) { scrolls += 1 }
                    func scrollViewDidZoom(_ s: UIScrollView) { zooms += 1 }
                    func viewForZooming(in s: UIScrollView) -> UIView? { content } }
                let vc = UIViewController()
                let sv = UIScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
                let content = UIView(frame: CGRect(x: 0, y: 0, width: 1000, height: 3000)); content.backgroundColor = .yellow
                sv.addSubview(content); sv.contentSize = content.bounds.size; sv.minimumZoomScale = 0.25; sv.maximumZoomScale = 4
                let d = D(content); sv.delegate = d; vc.view.addSubview(sv)
                let (w, done) = try iosShow(vc); defer { done() }
                w.layoutIfNeeded()
                sv.setContentOffset(CGPoint(x: 100, y: 2000), animated: false)
                try expect(sv.contentOffset == CGPoint(x: 100, y: 2000) && d.scrolls > 0, "offset \(sv.contentOffset), scrolls \(d.scrolls)")
                sv.setZoomScale(2, animated: false)
                try expect(sv.zoomScale == 2 && d.zooms > 0 && abs(sv.contentSize.width - 2000) < 1, "zoom \(sv.zoomScale), content \(sv.contentSize)")
                sv.zoom(to: CGRect(x: 0, y: 0, width: 600, height: 600), animated: false)
                try expect(abs(sv.zoomScale - 0.5) < 0.01, "zoom to rect \(sv.zoomScale)")
                let hit = vc.view.hitTest(vc.view.convert(CGPoint(x: 150, y: 150), from: sv), with: nil)
                try expect(hit === content, "hit test \(String(describing: hit))")
                return "\(d.scrolls) scroll / \(d.zooms) zoom callbacks"
            }
        })
        c.append(check("UIKit", "document-save-open", timeout: 30) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("sdkcov-doc.txt")
            try? FileManager.default.removeItem(at: url)
            let doc = await onMain { IOSTextDoc(fileURL: url) }
            await onMain { doc.text = "x86sim document" }
            let saved = await doc.save(to: url, for: .forCreating)
            try expect(saved, "save forCreating")
            _ = await doc.close()
            let d2 = await onMain { IOSTextDoc(fileURL: url) }
            let opened = await d2.open()
            try await iosCheck(opened) { "open (state \(d2.documentState.rawValue))" }
            let text = await onMain { d2.text }
            try expect(text == "x86sim document", "read back \(text)")
            await onMain { d2.text += " edited"; d2.updateChangeCount(.done) }
            _ = await d2.close()   // autosaves the change
            let disk = try String(contentsOf: url, encoding: .utf8)
            try expect(disk == "x86sim document edited", "on disk after close: \(disk)")
            return "saved, reopened, autosaved on close"
        })
        c.append(check("UIKit", "device-screen-openurl", timeout: 20) {
            try await onMain {
                let d = UIDevice.current, s = UIScreen.main
                try expect(d.systemName == "iOS" && d.userInterfaceIdiom == .phone, "\(d.systemName) idiom \(d.userInterfaceIdiom.rawValue)")
                try expect(d.systemVersion.hasPrefix("27."), "systemVersion \(d.systemVersion)")
                try expect(s.scale == 3 && s.nativeBounds.width == 1206 && s.nativeBounds.height == 2622, "screen \(s.bounds) native \(s.nativeBounds) @\(s.scale)")
                d.isBatteryMonitoringEnabled = true
                let batt = "\(d.batteryState.rawValue) \(d.batteryLevel)"
                d.isBatteryMonitoringEnabled = false
                let app = UIApplication.shared
                // foreground: active, or inactive while a system sheet / banner from an earlier check is up (Apple's too)
                try expect(app.applicationState != .background, "state \(app.applicationState.rawValue)")
                app.isIdleTimerDisabled = true; app.isIdleTimerDisabled = false
                try expect(app.canOpenURL(URL(string: "https://www.apple.com")!), "canOpenURL https")
                try expect(URL(string: UIApplication.openSettingsURLString) != nil, "settings URL")
                return "\(d.model) \(d.name) \(d.systemVersion), screen \(Int(s.bounds.width))x\(Int(s.bounds.height))@\(Int(s.scale)) max \(s.maximumFramesPerSecond) fps, battery \(batt), proximity \(d.isProximityMonitoringEnabled), orientation \(d.orientation.rawValue)"
            }
        })
        c.append(check("UIKit", "first-responder-text-input", timeout: 20) {
            final class K: NSObject { var shown: CGRect?
                @objc func show(_ n: Notification) { shown = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue } }
            let k = K()
            let (tf, done) = try await onMain { () -> (UITextField, () -> Void) in
                NotificationCenter.default.addObserver(k, selector: #selector(K.show(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
                let vc = UIViewController(); vc.view.backgroundColor = .white
                let tf = UITextField(frame: CGRect(x: 20, y: 100, width: 250, height: 40)); tf.borderStyle = .roundedRect
                vc.view.addSubview(tf)
                let (w, done) = try iosShow(vc); w.makeKey()
                return (tf, done)
            }
            defer { Task { @MainActor in tf.resignFirstResponder(); NotificationCenter.default.removeObserver(k); done() } }
            try await onMain { try expect(tf.becomeFirstResponder() && tf.isFirstResponder, "becomeFirstResponder") }
            let kb = await iosWait(3) { k.shown != nil }
            return try await onMain {
                tf.insertText("x86"); tf.insertText("sim"); tf.deleteBackward()
                try expect(tf.text == "x86si", "typed \(String(describing: tf.text))")
                tf.selectedTextRange = tf.textRange(from: tf.beginningOfDocument, to: tf.position(from: tf.beginningOfDocument, offset: 3)!)
                tf.replace(tf.selectedTextRange!, withText: "ARM")
                try expect(tf.text == "ARMsi", "replace selection \(String(describing: tf.text))")
                tf.undoManager?.undo()
                return "text input ok, undo -> \(tf.text ?? "nil"), software keyboard \(kb ? "shown \(k.shown!.size)" : "not shown (hardware keyboard)")"
            }
        })

        // MARK: SwiftUI hosted in a window
        c.append(check("SwiftUI", "hosting-navigation-state-list", timeout: 30) {
            let m = IOSModel()
            let (hc, done) = try await onMain { () -> (UIHostingController<IOSNavView>, () -> Void) in
                let hc = UIHostingController(rootView: IOSNavView(m: m)); let (_, done) = try iosShow(hc); return (hc, done)
            }
            defer { Task { @MainActor in done() } }
            try await expect(iosWait(5) { m.appeared.contains("row0") }, "the first List row never appeared")
            let b0 = await onMain { m.bodies }
            await onMain { m.count = 5 }
            try await expect(iosWait(3) { m.bodies > b0 }, "state change did not re-render")
            await onMain { m.path = [7] }
            try await iosCheck(await iosWait(5) { m.appeared.contains("detail7") }) { "navigationDestination never appeared: \(m.appeared)" }
            // the pushed green detail fills the screen below the navigation bar once the push transition ends
            var p: [UInt8] = []
            let t0 = Date()
            while Date().timeIntervalSince(t0) < 4 {
                let img = try await onMain { () -> CGImage in guard let i = iosSnapshot(hc.view) else { throw Fail("no snapshot") }; return i }
                p = iosPixel(img, img.width / 2, img.height * 2 / 3)
                if near(p, 0, 255, 0, 40) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            try expect(near(p, 0, 255, 0, 40), "detail pixel \(p) after 4 s")
            let pushMs = Int(Date().timeIntervalSince(t0) * 1000)
            await onMain { m.path = [] }
            try await expect(iosWait(5) { (hc.children.first as? UINavigationController)?.viewControllers.count ?? 1 <= 1 || m.path.isEmpty }, "pop")
            return await onMain { "\(m.bodies) body evaluations, appeared \(m.appeared.joined(separator: ",")), detail on screen after \(pushMs) ms" }
        })
        c.append(check("_MapKit_SwiftUI", "map-camera-markers", timeout: 40) {
            let changes = Mutex(0)
            let center = CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090)
            let (hc, done) = try await onMain { () -> (UIViewController, () -> Void) in
                let v = Map(initialPosition: .region(MKCoordinateRegion(center: center, latitudinalMeters: 2000, longitudinalMeters: 2000))) {
                    Marker("sdkcov", coordinate: center)
                    MapCircle(center: center, radius: 300).foregroundStyle(.blue.opacity(0.3))
                }.onMapCameraChange(frequency: .onEnd) { _ in changes.withLock { $0 += 1 } }
                let hc = UIHostingController(rootView: v); let (_, done) = try iosShow(hc); return (hc, done)
            }
            defer { Task { @MainActor in done() } }
            try await expect(iosWait(15) { changes.withLock { $0 } > 0 }, "onMapCameraChange never called")
            // the MKMapView SwiftUI made, and where it put the region
            let (mv, r) = await onMain { () -> (MKMapView?, MKCoordinateRegion?) in
                func find(_ v: UIView) -> MKMapView? { (v as? MKMapView) ?? v.subviews.lazy.compactMap(find).first }
                let mv = find(hc.view); return (mv, mv?.region)
            }
            try expect(mv != nil, "no MKMapView in the hosting view")
            try expect(abs(r!.center.latitude - center.latitude) < 0.01 && abs(r!.center.longitude - center.longitude) < 0.01, "region centre \(r!.center)")
            let ann = await onMain { mv!.annotations.count }
            return "\(changes.withLock { $0 }) camera changes, \(ann) annotations, span \(String(format: "%.4f", r!.span.latitudeDelta))"
        })
        c.append(check("AVFoundation", "player-playback-video-output", timeout: 60) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("sdkcov-play.mov")
            try await writeMovie(url, frames: 45, size: 160)   // 1.5 s
            let item = AVPlayerItem(url: url)
            let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            item.add(out)
            let player = AVPlayer(playerItem: item)
            let ended = Mutex(false)
            let obs = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: nil) { _ in ended.withLock { $0 = true } }
            defer { NotificationCenter.default.removeObserver(obs) }
            let periodic = Mutex(0)
            let tobs = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { _ in periodic.withLock { $0 += 1 } }
            defer { player.removeTimeObserver(tobs) }
            for _ in 0..<100 where item.status == .unknown { try await Task.sleep(for: .milliseconds(50)) }
            try expect(item.status == .readyToPlay, "item status \(item.status.rawValue): \(String(describing: item.error))")
            player.play()
            var frames = 0, lastT = -1.0
            let t0 = Date()
            while !ended.withLock({ $0 }) && Date().timeIntervalSince(t0) < 15 {
                let t = out.itemTime(forHostTime: CACurrentMediaTime())
                if out.hasNewPixelBuffer(forItemTime: t), let pb = out.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) {
                    frames += 1; lastT = t.seconds
                    try expect(CVPixelBufferGetWidth(pb) == 160, "frame width \(CVPixelBufferGetWidth(pb))")
                }
                try await Task.sleep(for: .milliseconds(15))
            }
            let wall = Date().timeIntervalSince(t0)
            try expect(ended.withLock { $0 }, "never played to the end in \(Int(wall)) s (time \(player.currentTime().seconds), rate \(player.rate), \(frames) frames)")
            try expect(frames >= 5, "only \(frames) video frames from AVPlayerItemVideoOutput")
            try expect(wall > 1.2 && wall < 6, "1.5 s movie took \(String(format: "%.2f", wall)) s")
            return "\(frames) frames, played in \(String(format: "%.2f", wall)) s, last frame at \(String(format: "%.2f", lastT)), \(periodic.withLock { $0 }) periodic callbacks"
        })
        c.append(check("_AVKit_SwiftUI", "video-player-view", timeout: 40) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("sdkcov-vp.mov")
            try await writeMovie(url, frames: 60, size: 128)
            let player = AVPlayer(url: url)
            let (hc, done) = try await onMain { () -> (UIViewController, () -> Void) in
                let hc = UIHostingController(rootView: VideoPlayer(player: player)); let (_, done) = try iosShow(hc); return (hc, done)
            }
            defer { Task { @MainActor in player.pause(); done() } }
            await onMain { player.play() }
            try await expect(iosWait(10) { player.currentTime().seconds > 0.5 }, "time never advanced: \(player.currentTime().seconds), rate \(player.rate), \(String(describing: player.currentItem?.error))")
            let pvc = await onMain { () -> String in
                func find(_ v: UIViewController) -> AVPlayerViewController? { (v as? AVPlayerViewController) ?? v.children.lazy.compactMap(find).first }
                return find(hc).map { "AVPlayerViewController, video bounds \($0.videoBounds.size)" } ?? "no AVPlayerViewController child"
            }
            return "\(String(format: "%.2f", player.currentTime().seconds)) s played; \(pvc)"
        })
        c.append(check("AVFAudio", "audio-player-playback", timeout: 30) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("sdkcov-ap.m4a")
            try? FileManager.default.removeItem(at: url)
            try writeM4A(sine(660, secs: 0.8), to: url)
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            final class D: NSObject, AVAudioPlayerDelegate { let ok = Mutex<Bool?>(nil)
                func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully f: Bool) { ok.withLock { $0 = f } } }
            let d = D()
            let p = try AVAudioPlayer(contentsOf: url); p.delegate = d; p.isMeteringEnabled = true
            try expect(abs(p.duration - 0.8) < 0.1, "duration \(p.duration)")
            try expect(p.prepareToPlay() && p.play(), "play")
            try await Task.sleep(for: .milliseconds(300))
            p.updateMeters(); let level = p.averagePower(forChannel: 0)
            let t0 = Date()
            while d.ok.withLock({ $0 }) == nil && Date().timeIntervalSince(t0) < 8 { try await Task.sleep(for: .milliseconds(50)) }
            try expect(d.ok.withLock { $0 } == true, "didFinishPlaying \(String(describing: d.ok.withLock { $0 })) after \(Int(Date().timeIntervalSince(t0))) s (current time \(p.currentTime))")
            return "played 0.8 s, meter \(String(format: "%.1f", level)) dB, output \(AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType.rawValue))"
        })
        c.append(check("_SceneKit_SwiftUI", "scene-view-render", timeout: 30) {
            let scene = SCNScene()
            let box = SCNNode(geometry: SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0))
            box.geometry?.firstMaterial?.diffuse.contents = UIColor.red; box.geometry?.firstMaterial?.lightingModel = .constant
            scene.rootNode.addChildNode(box); scene.background.contents = UIColor.blue
            let cam = SCNNode(); cam.camera = SCNCamera(); cam.position = SCNVector3(0, 0, 3); scene.rootNode.addChildNode(cam)
            let (hc, done) = try await onMain { () -> (UIViewController, () -> Void) in
                let hc = UIHostingController(rootView: SceneView(scene: scene, pointOfView: cam, options: [])); let (_, done) = try iosShow(hc); return (hc, done)
            }
            defer { Task { @MainActor in done() } }
            let sv = await onMain { () -> SCNView? in func f(_ v: UIView) -> SCNView? { (v as? SCNView) ?? v.subviews.lazy.compactMap(f).first }; return f(hc.view) }
            guard let sv else { throw Fail("no SCNView in SceneView") }
            try await Task.sleep(for: .milliseconds(500))
            let img = await onMain { sv.snapshot() }
            guard let cg = img.cgImage else { throw Fail("no snapshot") }
            let mid = iosPixel(cg, cg.width / 2, cg.height / 2), corner = iosPixel(cg, 5, 5)
            try expect(near(mid, 255, 0, 0, 30) && near(corner, 0, 0, 255, 30), "centre \(mid), corner \(corner)")
            return "\(cg.width)x\(cg.height), renderer \(sv.renderingAPI.rawValue)"
        })
        c.append(check("_SpriteKit_SwiftUI", "sprite-view-updates", timeout: 30) {
            let (scene, node, done) = try await onMain { () -> (IOSCountScene, SKSpriteNode, () -> Void) in
                let scene = IOSCountScene(size: CGSize(width: 300, height: 300)); scene.backgroundColor = .purple
                let node = SKSpriteNode(color: .yellow, size: CGSize(width: 50, height: 50)); node.position = CGPoint(x: 50, y: 150)
                scene.addChild(node); node.run(.moveTo(x: 250, duration: 0.5))
                let hc = UIHostingController(rootView: SpriteView(scene: scene, preferredFramesPerSecond: 60)); let (_, done) = try iosShow(hc); return (scene, node, done)
            }
            defer { Task { @MainActor in done() } }
            try await Task.sleep(for: .seconds(1.5))
            let n = scene.frames.withLock { $0 }, x = await onMain { node.position.x }
            try expect(n > 30, "scene update() called \(n) times in 1.5 s")
            try expect(abs(x - 250) < 1, "move action: x \(x)")
            return "\(n) frames in 1.5 s, sprite at x \(Int(x))"
        })
        c.append(check("_WebKit_SwiftUI", "webpage-webview-javascript", timeout: 120) {
            let page = await onMain { WebPage() }
            let (_, done) = try await onMain { () -> (UIViewController, () -> Void) in
                let hc = UIHostingController(rootView: WebView(page)); let (_, done) = try iosShow(hc); return (hc, done)
            }
            defer { Task { @MainActor in done() } }
            var events: [String] = []
            let seq = await MainActor.run { page.load(html: "<html><head><title>sdkcov</title></head><body><p id=p>x86</p></body></html>") }
            for try await e in seq {
                events.append("\(e)")
            }
            let title = await onMain { page.title }
            try expect(title == "sdkcov", "title \(title) after \(events)")
            let r = try await Task { @MainActor in try await page.callJavaScript("return document.getElementById('p').textContent + a * 2", arguments: ["a": 21]) }.value
            try expect(r as? String == "x8642", "callJavaScript \(String(describing: r))")
            return "events \(events.joined(separator: ",")), JS \(r!)"
        })
        c.append(check("_AuthenticationServices_SwiftUI", "sign-in-button", timeout: 20) {
            try await onMain {
                let v = SignInWithAppleButton(.continue, onRequest: { $0.requestedScopes = [.email] }, onCompletion: { _ in })
                    .signInWithAppleButtonStyle(.black).frame(width: 280, height: 50)
                let hc = UIHostingController(rootView: v.padding(40).background(Color.white))
                let (w, done) = try iosShow(hc); defer { done() }
                w.layoutIfNeeded()
                guard let img = iosSnapshot(hc.view) else { throw Fail("no snapshot") }
                let ink = iosInk(img, bg: [255, 255, 255, 255])
                try expect(ink > 0.005, "the black button drew nothing: ink \(ink)")
                return "ink \(String(format: "%.3f", ink))"
            }
        })
        c.append(check("_PassKit_SwiftUI", "wallet-pay-buttons", timeout: 20) {
            try await onMain {
                let v = VStack(spacing: 20) {
                    PayWithApplePayButton(.buy) {}.frame(width: 250, height: 50)
                    AddPassToWalletButton {}.frame(width: 250, height: 50)
                }.padding(40).background(Color.white)
                let hc = UIHostingController(rootView: v)
                let (w, done) = try iosShow(hc); defer { done() }
                w.layoutIfNeeded()
                guard let img = iosSnapshot(hc.view) else { throw Fail("no snapshot") }
                let ink = iosInk(img, bg: [255, 255, 255, 255])
                try expect(ink > 0.005, "buttons drew nothing: ink \(ink)")
                // each button's box: inked fraction and mean ink colour (the pay button is black, the wallet one black)
                let ctx = bitmap(img.width, img.height); ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
                func box(_ y0: Int) -> String {
                    var n = 0, k = 0, sum = [0, 0, 0]
                    let midY = img.height / 2, x0 = img.width / 2 - 125
                    for y in stride(from: midY + y0, to: midY + y0 + 50, by: 2) { for x in stride(from: x0, to: x0 + 250, by: 2) where x >= 0 && x < img.width && y >= 0 && y < img.height {
                        n += 1; let p = pixel(ctx, x, y); if (0..<3).contains(where: { p[$0] < 215 }) { k += 1; for i in 0..<3 { sum[i] += Int(p[i]) } } } }
                    return "\(Int(Double(k) * 100 / Double(max(n, 1))))% ink rgb \(k == 0 ? "-" : sum.map { String($0 / k) }.joined(separator: ","))"
                }
                return "ink \(String(format: "%.3f", ink)); pay \(box(-60)); wallet \(box(10)); can make payments \(PKPaymentAuthorizationController.canMakePayments())"
            }
        })

        // MARK: Foundation networking and text
        c.append(check("Foundation", "urlsession-websocket-loopback", timeout: 30) {
            let p = NWParameters.tcp
            let ws = NWProtocolWebSocket.Options(); ws.autoReplyPing = true
            p.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
            let l = try NWListener(using: p, on: .any)
            l.newConnectionHandler = { c in
                c.start(queue: .global())
                func loop() {
                    c.receiveMessage { d, ctx, _, err in
                        guard err == nil, let d else { return }
                        let md = NWProtocolWebSocket.Metadata(opcode: .text)
                        let reply = Data(("echo:" + String(decoding: d, as: UTF8.self)).utf8)
                        c.send(content: reply, contentContext: NWConnection.ContentContext(identifier: "e", metadata: [md]), isComplete: true, completion: .contentProcessed { _ in loop() })
                    }
                }
                loop()
            }
            l.start(queue: .global())
            defer { l.cancel() }
            for _ in 0..<100 where (l.port?.rawValue ?? 0) == 0 { try await Task.sleep(for: .milliseconds(30)) }
            let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(l.port!.rawValue)/sdkcov")!)
            task.resume()
            defer { task.cancel(with: .normalClosure, reason: nil) }
            var got: [String] = []
            for m in ["one", "two", String(repeating: "z", count: 70000)] {
                try await task.send(.string(m))
                switch try await task.receive() { case .string(let s): got.append(s); case .data(let d): got.append("data \(d.count)"); @unknown default: break }
            }
            try expect(got.count == 3 && got[0] == "echo:one" && got[1] == "echo:two" && got[2].count == 70005, "replies \(got.map { String($0.prefix(12)) + " (\($0.count))" })")
            let pong = Mutex<Error??>(nil)
            task.sendPing { e in pong.withLock { $0 = .some(e) } }
            for _ in 0..<100 where pong.withLock({ $0 }) == nil { try await Task.sleep(for: .milliseconds(30)) }
            // the pong is informational: Apple's simulator gets none in 3 s from an NWListener with autoReplyPing
            let pr = pong.withLock { $0 }.map { $0.map { "error \($0)" } ?? "ok" } ?? "none in 3 s"
            return "3 echoes (one of 70000 B), pong \(pr)"
        })
        c.append(check("Foundation", "urlsession-download-upload-cache", timeout: 40) {
            let srv = try IOSHTTPServer(); let port = try await srv.start()
            let base = "http://127.0.0.1:\(port)"
            let cfg = URLSessionConfiguration.default
            let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("sdkcov-urlcache")
            try? FileManager.default.removeItem(at: cacheDir)
            cfg.urlCache = URLCache(memoryCapacity: 4 << 20, diskCapacity: 20 << 20, directory: cacheDir); cfg.requestCachePolicy = .useProtocolCachePolicy
            let s = URLSession(configuration: cfg); defer { s.invalidateAndCancel() }
            // download to a file
            let (file, r1) = try await s.download(from: URL(string: "\(base)/data/300000")!)
            let dl = try Data(contentsOf: file)
            try expect((r1 as? HTTPURLResponse)?.statusCode == 200 && dl.count == 300000 && dl[1000] == UInt8(truncatingIfNeeded: 7000), "download \(dl.count) B")
            // upload
            let body = Data("x86sim upload body".utf8)
            var req = URLRequest(url: URL(string: "\(base)/up")!); req.httpMethod = "POST"
            let (up, _) = try await s.upload(for: req, from: body)
            try expect(up == Data(body.reversed()), "upload echo \(String(decoding: up, as: UTF8.self))")
            // cache: the second GET of a max-age response does not reach the server
            let u = URL(string: "\(base)/data/5000")!
            _ = try await s.data(from: u)
            let before = srv.served.withLock { $0 }
            final class M: NSObject, URLSessionTaskDelegate { var kind: URLSessionTaskMetrics.ResourceFetchType?
                func urlSession(_ s: URLSession, task: URLSessionTask, didFinishCollecting m: URLSessionTaskMetrics) { kind = m.transactionMetrics.last?.resourceFetchType } }
            let md = M()
            let (d2, _) = try await s.data(from: u, delegate: md)
            let after = srv.served.withLock { $0 }
            try expect(d2.count == 5000 && after == before, "cached GET reached the server (\(before) -> \(after)), fetch type \(String(describing: md.kind?.rawValue))")
            try expect(cfg.urlCache!.cachedResponse(for: URLRequest(url: u)) != nil, "no cached response")
            return "download 300000 B, upload echoed, cached GET (\(md.kind == .localCache ? "localCache" : "\(String(describing: md.kind?.rawValue))")), \(after) requests served"
        })
        c.append(check("Foundation", "attributed-markdown-formatters") {
            let a = try AttributedString(markdown: "**Bold** and _it_ [link](https://example.com) `code`")
            let bold = a.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
            let link = a.runs.compactMap(\.link).first
            try expect(String(a.characters) == "Bold and it link code" && bold && link?.host == "example.com", "markdown \(String(a.characters)) bold \(bold) link \(String(describing: link))")
            let en = Locale(identifier: "en_US")
            let lf = ListFormatter(); lf.locale = en
            try expect(lf.string(from: ["a", "b", "c"]) == "a, b, and c", "list \(String(describing: lf.string(from: ["a", "b", "c"])))")
            let rf = RelativeDateTimeFormatter(); rf.locale = en; rf.unitsStyle = .full
            try expect(rf.localizedString(fromTimeInterval: -3 * 86400) == "3 days ago", "relative \(rf.localizedString(fromTimeInterval: -3 * 86400))")
            let bc = ByteCountFormatter(); bc.countStyle = .decimal
            try expect(bc.string(fromByteCount: 1_500_000) == "1.5 MB", "bytes \(bc.string(fromByteCount: 1_500_000))")
            let mf = MeasurementFormatter(); mf.locale = en; mf.unitOptions = .providedUnit
            let km = Measurement(value: 5, unit: UnitLength.kilometers)
            try expect(mf.string(from: km.converted(to: .miles)).hasPrefix("3.107"), "measurement \(mf.string(from: km.converted(to: .miles)))")
            let pn = try PersonNameComponents("Ada Lovelace")
            try expect(pn.givenName == "Ada" && pn.familyName == "Lovelace", "name parse \(pn)")
            let d = Date(timeIntervalSince1970: 1_800_000_000)
            let fs = d.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: en, timeZone: TimeZone(identifier: "UTC")!))
            let fsn = fs.replacingOccurrences(of: "\u{202F}", with: " ")   // ICU puts U+202F before AM
            try expect(fsn == "Jan 15, 2027 at 8:00 AM", "date style \(fs.unicodeScalars.map { String($0.value, radix: 16) })")
            let cur = 1234.5.formatted(.currency(code: "EUR").locale(Locale(identifier: "de_DE")))
            try expect(cur.replacingOccurrences(of: "\u{00A0}", with: " ") == "1.234,50 €", "currency \(cur.unicodeScalars.map { String($0.value, radix: 16) })")
            let re = try NSRegularExpression(pattern: "(\\w+)@(\\w+)\\.com")
            let s = "mail ada@example.com and bob@test.com"
            let ms = re.matches(in: s, range: NSRange(s.startIndex..., in: s))
            try expect(ms.count == 2, "regex matches \(ms.count)")
            return "markdown, list, relative, bytes, measurement, name, date (\(fs)), currency, regex"
        })
        c.append(check("Foundation", "file-coordination-xattr-capacity") {
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("sdkcov-files"); try? fm.removeItem(at: dir)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let f = dir.appendingPathComponent("a.txt")
            var err: NSError?, wrote = false
            NSFileCoordinator().coordinate(writingItemAt: f, options: .forReplacing, error: &err) { u in wrote = (try? Data("one".utf8).write(to: u)) != nil }
            try expect(wrote && err == nil, "coordinated write \(String(describing: err))")
            var read = ""
            NSFileCoordinator().coordinate(readingItemAt: f, options: [], error: &err) { u in read = (try? String(contentsOf: u, encoding: .utf8)) ?? "" }
            try expect(read == "one", "coordinated read \(read)")
            // atomic replace through an item-replacement directory
            let tmp = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: f, create: true).appendingPathComponent("a.txt")
            try Data("two".utf8).write(to: tmp)
            _ = try fm.replaceItemAt(f, withItemAt: tmp)
            try expect(try String(contentsOf: f, encoding: .utf8) == "two", "replaceItemAt")
            // extended attributes
            let rc = f.withUnsafeFileSystemRepresentation { p in setxattr(p!, "com.x86sim.sdkcov", "v1", 2, 0, 0) }
            var buf = [CChar](repeating: 0, count: 8)
            let n = f.withUnsafeFileSystemRepresentation { p in getxattr(p!, "com.x86sim.sdkcov", &buf, 8, 0, 0) }
            try expect(rc == 0 && n == 2 && String(cString: Array(buf.prefix(2)) + [0]) == "v1", "xattr set \(rc) get \(n) errno \(errno)")
            // backup exclusion and volume capacity, as apps check before downloads
            var u = f; var rv = URLResourceValues(); rv.isExcludedFromBackup = true; try u.setResourceValues(rv)
            let vals = try f.resourceValues(forKeys: [.isExcludedFromBackupKey, .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey, .fileSizeKey, .contentModificationDateKey])
            try expect(vals.isExcludedFromBackup == true, "excluded from backup")
            let imp = vals.volumeAvailableCapacityForImportantUsage ?? 0, tot = vals.volumeTotalCapacity ?? 0
            try expect(imp > 100_000_000 && tot > imp.magnitude, "capacity important \(imp) total \(tot)")
            try expect(vals.fileSize == 3 && vals.contentModificationDate != nil, "size \(String(describing: vals.fileSize))")
            let attrs = try fm.attributesOfFileSystem(forPath: dir.path)
            return "coordination, replace, xattr, \(imp / 1_000_000_000) GB free for important use of \(tot / 1_000_000_000) GB, fs free \(((attrs[.systemFreeSize] as? Int64) ?? 0) / 1_000_000_000) GB"
        })

        // MARK: notifications, Live Activities
        c.append(check("UserNotifications", "provisional-deliver-local", timeout: 120) {
            let c = UNUserNotificationCenter.current()
            // a freshly booted simulator's usernotificationsd can take a while to answer the first call
            let pre = try await iosStage("settings", 40) { await c.notificationSettings().authorizationStatus.rawValue }
            let granted = try await iosStage("requestAuthorization(provisional)", 15) { try await c.requestAuthorization(options: [.alert, .sound, .badge, .provisional]) }
            let st = try await iosStage("settings after", 10) { await c.notificationSettings().authorizationStatus.rawValue }
            try expect(granted && (st == UNAuthorizationStatus.provisional.rawValue || st == UNAuthorizationStatus.authorized.rawValue), "provisional authorization: granted \(granted), status \(pre) -> \(st)")
            let d = IOSNotifDelegate(); let old = c.delegate; c.delegate = d
            defer { c.delegate = old }
            let ct = UNMutableNotificationContent(); ct.title = "sdkcov"; ct.body = "iOS local notification"; ct.userInfo = ["n": 1]
            let id = "sdkcov-ios-\(Int(Date().timeIntervalSince1970))"
            // Apple's simulator can refuse the first add right after a provisional grant (2003 "Source is not authorized",
            // status Denied): retried for a few seconds
            var addErr: Error?
            for _ in 0..<6 {
                do { try await iosStage("add", 10) { try await c.add(UNNotificationRequest(identifier: id, content: ct, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))) }; addErr = nil; break }
                catch { addErr = error; if (error as NSError).code != 2003 { break }; try await Task.sleep(for: .seconds(1)) }
            }
            if let addErr {
                let now = await c.notificationSettings().authorizationStatus.rawValue
                if (addErr as NSError).code == 2003 { throw Skip("provisional grant (\(pre) -> \(st)) but add refused 2003 for 6 s, status now \(now): Apple's simulator does this too") }
                throw addErr
            }
            let t0 = Date()
            var deliveredAt: Double?, n: UNNotification?
            while Date().timeIntervalSince(t0) < 15 {
                let ds = try await iosStage("deliveredNotifications", 5) { await c.deliveredNotifications() }
                if let x = ds.first(where: { $0.request.identifier == id }) { n = x; deliveredAt = Date().timeIntervalSince(t0); break }
                try await Task.sleep(for: .milliseconds(250))
            }
            let presented = d.presented.withLock { $0.contains(id) }
            guard let n, let deliveredAt else {
                let pend = try await iosStage("pending", 5) { await c.pendingNotificationRequests().map(\.identifier) }
                throw Fail("not delivered in 15 s (willPresent \(presented), status \(st)); pending \(pend)")
            }
            c.removeDeliveredNotifications(withIdentifiers: [id])
            try expect(n.request.content.title == "sdkcov" && (n.request.content.userInfo["n"] as? Int) == 1, "delivered content \(n.request.content)")
            try await c.setBadgeCount(0)
            return "status \(pre) -> \(st), delivered after \(String(format: "%.1f", deliveredAt)) s, willPresent \(presented)"
        })
        c.append(check("ActivityKit", "live-activity-lifecycle", timeout: 30) {
            let info = ActivityAuthorizationInfo()
            try expect(info.areActivitiesEnabled, "areActivitiesEnabled false (Apple's simulator: true)")
            let supports = Bundle.main.object(forInfoDictionaryKey: "NSSupportsLiveActivities") as? Bool ?? false
            let a: Activity<IOSLiveAttributes>
            do { a = try Activity.request(attributes: IOSLiveAttributes(name: "sdkcov"), content: ActivityContent(state: IOSLiveAttributes.ContentState(step: 1), staleDate: nil)) }
            catch where !supports { throw Skip("enabled; request refused (\(error)) as on Apple's simulator: the app has no NSSupportsLiveActivities") }
            try expect(Activity<IOSLiveAttributes>.activities.contains { $0.id == a.id }, "not listed")
            await a.update(ActivityContent(state: IOSLiveAttributes.ContentState(step: 2), staleDate: nil))
            try expect(a.content.state.step == 2, "state after update \(a.content.state.step)")
            await a.end(nil, dismissalPolicy: .immediate)
            return "activity \(a.id.prefix(8)) state \(a.activityState)"
        })

        // MARK: frameworks so far only loaded
        c.append(check("TouchController", "layout-render-touch", timeout: 30) {
            try await onMain {
                try skipIf(!TCTouchController.isSupported, "TCTouchController.isSupported is false")
                guard let dev = MTLCreateSystemDefaultDevice() else { throw Fail("no Metal device") }
                let desc = TCTouchControllerDescriptor(); desc.device = dev
                desc.size = CGSize(width: 400, height: 200); desc.drawableSize = CGSize(width: 400, height: 200); desc.colorPixelFormat = .bgra8Unorm
                let tc = TCTouchController(descriptor: desc)
                tc.automaticallyLayoutControls(for: [.buttonA, .buttonB, .leftThumbstick])
                try expect(tc.controls.count >= 3, "controls \(tc.controls.count)")
                let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 400, height: 200, mipmapped: false)
                td.usage = [.renderTarget, .shaderRead]; td.storageMode = .shared
                let tex = dev.makeTexture(descriptor: td)!
                let rp = MTLRenderPassDescriptor(); rp.colorAttachments[0].texture = tex; rp.colorAttachments[0].loadAction = .clear
                rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1); rp.colorAttachments[0].storeAction = .store
                let cb = dev.makeCommandQueue()!.makeCommandBuffer()!; let enc = cb.makeRenderCommandEncoder(descriptor: rp)!
                tc.render(using: enc); enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
                try expect(cb.status == .completed, "command buffer \(cb.status.rawValue): \(String(describing: cb.error))")
                var px = [UInt8](repeating: 0, count: 400 * 200 * 4)
                tex.getBytes(&px, bytesPerRow: 1600, from: MTLRegionMake2D(0, 0, 400, 200), mipmapLevel: 0)
                var lit = 0; for i in stride(from: 0, to: px.count, by: 4) where px[i] > 20 || px[i + 1] > 20 || px[i + 2] > 20 { lit += 1 }
                try expect(lit > 200, "rendered controls lit \(lit) pixels")
                // a touch on button A presses it, and the virtual GCController sees it
                var aPoint: CGPoint?
                outer: for y in stride(from: 0.0, to: 200.0, by: 4) { for x in stride(from: 0.0, to: 400.0, by: 4) {
                    if let ctl = tc.control(at: CGPoint(x: x, y: y)), ctl.label == TCControlLabel.buttonA { aPoint = CGPoint(x: x, y: y); break outer } } }
                guard let aPoint else { throw Fail("no point maps to button A") }
                tc.connect()
                _ = tc.handleTouchBegan(at: aPoint, index: 0)
                let pressed = tc.buttons.first { $0.label == TCControlLabel.buttonA }?.isPressed ?? false
                let gc = tc.controller.extendedGamepad?.buttonA.isPressed
                _ = tc.handleTouchEnded(at: aPoint, index: 0)
                tc.disconnect()
                try expect(pressed, "button A not pressed after a touch at \(aPoint)")
                return "\(tc.controls.count) controls, \(lit) lit pixels, A at \(aPoint), GCController A \(String(describing: gc))"
            }
        })
        c.append(check("libMobileGestalt", "answers") {
            typealias Copy = @convention(c) (CFString) -> Unmanaged<CFTypeRef>?
            let copy = try cfunc("libMobileGestalt", "MGCopyAnswer", Copy.self)
            func s(_ k: String) -> String { copy(k as CFString).map { "\($0.takeRetainedValue())" } ?? "nil" }
            let ver = s("ProductVersion"), cls = s("DeviceClass"), name = s("ProductName"), build = s("BuildVersion")
            try expect(ver == UIDevice.current.systemVersion, "ProductVersion \(ver) vs UIDevice \(UIDevice.current.systemVersion)")
            try expect(cls == "iPhone" && name == "iPhone OS", "DeviceClass \(cls), ProductName \(name)")
            try expect(build == ProcessInfo.processInfo.operatingSystemVersionString.components(separatedBy: "Build ").last?.dropLast().description, "BuildVersion \(build)")
            return "ProductType \(s("ProductType")), \(cls) \(name) \(ver) (\(build)), HWModel \(s("HWModelStr")), DeviceName \(s("DeviceName"))"
        })
        c.append(check("AlarmKit", "manager-state") {
            let m = AlarmManager.shared
            let st = m.authorizationState
            let alarms = try m.alarms
            return "authorization \(st), \(alarms.count) alarms"
        })
        c.append(check("FamilyControls", "authorization-status") {
            await onMain { "status \(AuthorizationCenter.shared.authorizationStatus)" }
        })
        c.append(check("DeviceActivity", "center-activities") {
            let c = DeviceActivityCenter()
            return "\(c.activities.count) monitored activities"
        })
        c.append(check("ProximityReader", "reader-support") {
            "PaymentCardReader supported \(PaymentCardReader.isSupported)"
        })
        c.append(check("BackgroundAssets", "asset-pack-manager", timeout: 20) {
            // AssetPackManager traps (fatalError) in an app without BAAppGroupID, on Apple's simulator too
            try skipIf(Bundle.main.object(forInfoDictionaryKey: "BAAppGroupID") == nil, "needs BAAppGroupID in Info.plist (AssetPackManager traps without it, on Apple's simulator too)")
            do {
                let packs = try await AssetPackManager.shared.allAssetPacks
                return "\(packs.count) asset packs"
            } catch { return "no asset packs: \((error as NSError).domain) \((error as NSError).code)" }
        })
        c.append(check("AdServices", "attribution-token", timeout: 20) {
            do { let t = try AAAttribution.attributionToken(); try expect(t.count > 20, "token \(t.count) chars"); return "token \(t.count) chars" }
            catch { let e = error as NSError; throw Skip("attributionToken: \(e.domain) \(e.code)") }
        })
        c.append(check("AddressBookUI", "people-picker-view") {
            try await onMain {
                let p = ABPeoplePickerNavigationController(); p.loadViewIfNeeded()
                let n = ABNewPersonViewController(); n.loadViewIfNeeded()
                return "picker \(type(of: p.topViewController.map { $0 } as Any)), new-person view \(n.isViewLoaded)"
            }
        })
        c.append(check("AssetsLibrary", "authorization-status") {
            // ALAssetsLibrary is unavailable to Swift on iOS 27: through the runtime, as an old Objective-C app calls it
            guard dlopen("/System/Library/Frameworks/AssetsLibrary.framework/AssetsLibrary", RTLD_NOW) != nil,
                  let cls = NSClassFromString("ALAssetsLibrary") as? NSObject.Type else { throw Fail("no ALAssetsLibrary") }
            typealias F = @convention(c) (AnyClass, Selector) -> Int
            let sel = NSSelectorFromString("authorizationStatus")
            let st = unsafeBitCast(class_getMethodImplementation(object_getClass(cls), sel), to: F.self)(cls, sel)
            let lib = cls.init()
            return "ALAssetsLibrary status \(st), library \(type(of: lib))"
        })
        c.append(check("ClassKit", "main-app-context") {
            let ctx = CLSDataStore.shared.mainAppContext
            try expect(!ctx.identifier.isEmpty, "empty identifier")
            return "context \(ctx.identifier) type \(ctx.type.rawValue)"
        })
        c.append(check("NotificationCenter", "widget-controller") {
            NCWidgetController().setHasContent(true, forWidgetWithBundleIdentifier: "com.x86sim.test.sdkcov.widget")
            return "setHasContent accepted"
        })
        c.append(check("SensorKit", "reader-authorization") {
            let r = SRSensorReader(sensor: .ambientLightSensor)
            return "ambient light reader authorization \(r.authorizationStatus.rawValue)"
        })
        c.append(check("ExposureNotification", "authorization-status") {
            let m = ENManager()
            defer { m.invalidate() }
            return "authorization \(ENManager.authorizationStatus.rawValue), status \(m.exposureNotificationStatus.rawValue)"
        })
        c.append(check("AccessorySetupKit", "session-activate", timeout: 20) {
            // ASAccessorySession traps (fatalError) without NSAccessorySetupKitSupports in Info.plist, on Apple's simulator too
            try skipIf(Bundle.main.object(forInfoDictionaryKey: "NSAccessorySetupKitSupports") == nil, "needs NSAccessorySetupKitSupports (Bluetooth / WiFi) in Info.plist: activate traps without it, on Apple's simulator too")
            let s = ASAccessorySession()
            let events = Mutex<[Int]>([])
            s.activate(on: .main) { e in events.withLock { $0.append(e.eventType.rawValue) } }
            defer { s.invalidate() }
            let t0 = Date()
            while !events.withLock({ $0.contains(ASAccessoryEventType.activated.rawValue) }) && Date().timeIntervalSince(t0) < 10 { try await Task.sleep(for: .milliseconds(50)) }
            try expect(events.withLock { $0.contains(ASAccessoryEventType.activated.rawValue) }, "no activated event: \(events.withLock { $0 })")
            return "events \(events.withLock { $0 }), \(s.accessories.count) accessories"
        })
        c.append(check("Twitter", "compose-can-send") {
            // Twitter has no Swift module (Objective-C only, deprecated): through the runtime
            guard dlopen("/System/Library/Frameworks/Twitter.framework/Twitter", RTLD_NOW) != nil,
                  let cls = NSClassFromString("TWTweetComposeViewController") as? NSObject.Type else { throw Fail("no TWTweetComposeViewController") }
            let can = cls.perform(NSSelectorFromString("canSendTweet")) != nil
            let vc = await onMain { (cls.init() as? UIViewController)?.title ?? "vc" }
            return "canSendTweet \(can), compose controller \(vc)"
        })
        c.append(check("DeclaredAgeRange", "eligibility", timeout: 20) {
            // Apple's simulator never answers this (the check hung there too): a SKIP when no answer comes
            let r = Mutex<Result<Bool, Error>?>(nil)
            Task.detached { do { let e = try await AgeRangeService.shared.isEligibleForAgeFeatures; r.withLock { $0 = .success(e) } } catch { r.withLock { $0 = .failure(error) } } }
            let t0 = Date()
            while r.withLock({ $0 }) == nil && Date().timeIntervalSince(t0) < 8 { try await Task.sleep(for: .milliseconds(100)) }
            guard let res = r.withLock({ $0 }) else { throw Skip("isEligibleForAgeFeatures does not answer in 8 s (Apple's simulator: no answer either)") }
            return "eligible for age features \(try res.get())"
        })
        c.append(check("libxo", "json-text-emit") {
            typealias Create = @convention(c) (Int32, Int32) -> OpaquePointer?
            typealias SetWriter = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Int32,
                                                  (@convention(c) (UnsafeMutableRawPointer?) -> Void)?, (@convention(c) (UnsafeMutableRawPointer?) -> Int32)?) -> Void
            typealias Destroy = @convention(c) (OpaquePointer?) -> Void
            typealias Finish = @convention(c) (OpaquePointer?) -> Int32
            let create = try cfunc("libxo", "xo_create", Create.self), setw = try cfunc("libxo", "xo_set_writer", SetWriter.self)
            let destroy = try cfunc("libxo", "xo_destroy", Destroy.self), finish = try cfunc("libxo", "xo_finish_h", Finish.self)
            // xo_emit_h is variadic: reach it through xo_emit_hv with a va_list
            typealias EmitHV = @convention(c) (OpaquePointer?, UnsafePointer<CChar>, UnsafeMutableRawPointer?) -> Int32
            typealias OpenC = @convention(c) (OpaquePointer?, UnsafePointer<CChar>) -> Int32
            let emit = try cfunc("libxo", "xo_emit_hv", EmitHV.self)
            let open = try cfunc("libxo", "xo_open_container_h", OpenC.self), close = try cfunc("libxo", "xo_close_container_h", OpenC.self)
            final class Buf { var s = "" }
            var outs: [String] = []
            for style: Int32 in [2, 0] {   // XO_STYLE_JSON, XO_STYLE_TEXT
                let b = Buf(); let ctx = Unmanaged.passRetained(b)
                guard let h = create(style, 0) else { ctx.release(); throw Fail("xo_create \(style)") }
                setw(h, ctx.toOpaque(), { p, s in Unmanaged<Buf>.fromOpaque(p!).takeUnretainedValue().s += String(cString: s!); return 0 }, nil, nil)
                _ = open(h, "sdkcov")
                let cs = strdup("x86sim")!; defer { free(cs) }
                _ = withVaList([UnsafePointer(cs), CInt(42)]) { emit(h, "{:name/%s} {:count/%d}\n", unsafeBitCast($0, to: UnsafeMutableRawPointer?.self)) }
                _ = close(h, "sdkcov"); _ = finish(h); destroy(h); ctx.release()
                outs.append(b.s)
            }
            let json = outs[0].filter { !$0.isWhitespace }
            try expect(json.contains("\"sdkcov\":{\"name\":\"x86sim\",\"count\":42}"), "JSON \(outs[0])")
            try expect(outs[1].hasPrefix("x86sim 42"), "text \(outs[1])")
            return "JSON \(json)"
        })
        c.append(check("libncurses.5.4", "terminfo-capabilities") {
            typealias Setup = @convention(c) (UnsafePointer<CChar>?, Int32, UnsafeMutablePointer<Int32>?) -> Int32
            typealias Num = @convention(c) (UnsafePointer<CChar>) -> Int32
            typealias Str = @convention(c) (UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
            let setup = try cfunc("libncurses.5.4", "setupterm", Setup.self)
            let num = try cfunc("libncurses.5.4", "tigetnum", Num.self), str = try cfunc("libncurses.5.4", "tigetstr", Str.self)
            var err: Int32 = 0
            let rc = setup("vt100", -1, &err)
            try skipIf(rc != 0 && err == 0, "no terminfo entry for vt100 in the runtime (err \(err))")
            try expect(rc == 0, "setupterm vt100: rc \(rc) err \(err)")
            let cols = num("cols"), clear = str("clear").map { String(cString: $0) } ?? "nil"
            try expect(cols == 80, "cols \(cols)")
            return "vt100: \(cols) cols, \(num("lines")) lines, clear \(clear.debugDescription)"
        })
        // MARK: system view controllers presented (out-of-process content), Metal on screen, video export
        c.append(check("UIKit", "activity-share-sheet-present", timeout: 40) {
            let r = try await iosPresentSystem({ UIActivityViewController(activityItems: ["x86sim", URL(string: "https://example.com")!], applicationActivities: nil) })
            // presented and dismissed is the check; what drawHierarchy captures of the remote sheet is reported
            return "\(Int(r.size.width))x\(Int(r.size.height)), ink \(String(format: "%.2f", r.ink)), map \(r.grid)"
        })
        c.append(check("UIKit", "document-picker-present", timeout: 40) {
            let r = try await iosPresentSystem({ UIDocumentPickerViewController(forOpeningContentTypes: [.plainText, .pdf]) })
            try expect(!r.remote.isEmpty || r.ink > 0.05, "document picker shows nothing: no remote view, ink \(r.ink)")
            return "remote \(r.remote.prefix(2).joined(separator: "; ")), ink \(String(format: "%.2f", r.ink))"
        })
        c.append(check("PhotosUI", "picker-present", timeout: 40) {
            let r = try await iosPresentSystem({ var cfg = PHPickerConfiguration(); cfg.selectionLimit = 3; cfg.filter = .images; return PHPickerViewController(configuration: cfg) }, settle: 6)
            // the simulator's sample photos (CoreSimulator copies the runtime's SampleContent into a new device) fill the
            // grid in the middle of the sheet: dark / coloured cells there; an empty library shows "No Photos" on white
            let rows = r.grid.split(separator: "/").map(String.init)
            let photoCells = rows.count == 12 ? rows[3...8].reduce(0) { $0 + $1.filter { Int(String($0), radix: 16)! < 0xa }.count } : 0
            try expect(photoCells >= 4, "no photo thumbnails in the picker (sample photos missing?): map \(r.grid)")
            return "\(photoCells) photo cells, \(Int(r.size.width))x\(Int(r.size.height)), ink \(String(format: "%.2f", r.ink)), map \(r.grid)"
        })
        c.append(check("SafariServices", "safari-present-load", timeout: 60) {
            // a page from a loopback server: SFSafariViewController loads it in its own (remote) web view
            let srv = try IOSHTTPServer(); let port = try await srv.start()
            final class D: NSObject, SFSafariViewControllerDelegate { let loaded = Mutex<Bool?>(nil)
                func safariViewController(_ c: SFSafariViewController, didCompleteInitialLoad ok: Bool) { loaded.withLock { $0 = ok } } }
            let d = D()
            let r = try await iosPresentSystem({ let s = SFSafariViewController(url: URL(string: "http://127.0.0.1:\(port)/page")!); s.delegate = d; return s }, settle: 12)
            let served = srv.served.withLock { $0 }
            try expect(d.loaded.withLock { $0 } == true, "didCompleteInitialLoad \(String(describing: d.loaded.withLock { $0 })) (\(served) requests served)")
            return "initial load \(d.loaded.withLock { $0 }!), \(served) requests, remote \(r.remote.prefix(1).joined()), ink \(String(format: "%.2f", r.ink))"
        })
        c.append(check("MetalKit", "mtkview-draw-loop-on-screen", timeout: 30) {
            final class R: NSObject, MTKViewDelegate { let q: MTLCommandQueue; var frames = 0
                init(_ d: MTLDevice) { q = d.makeCommandQueue()! }
                func mtkView(_ v: MTKView, drawableSizeWillChange s: CGSize) {}
                func draw(in v: MTKView) {
                    guard let rp = v.currentRenderPassDescriptor, let dr = v.currentDrawable, let cb = q.makeCommandBuffer() else { return }
                    rp.colorAttachments[0].clearColor = MTLClearColor(red: 1, green: 0, blue: 0, alpha: 1); rp.colorAttachments[0].loadAction = .clear
                    cb.makeRenderCommandEncoder(descriptor: rp)?.endEncoding(); cb.present(dr); cb.commit(); frames += 1
                } }
            let (v, r, done) = try await onMain { () -> (MTKView, R, () -> Void) in
                guard let dev = MTLCreateSystemDefaultDevice() else { throw Fail("no MTLDevice") }
                let vc = UIViewController(); vc.view.backgroundColor = .blue
                let v = MTKView(frame: CGRect(x: 0, y: 100, width: 300, height: 300), device: dev)
                v.colorPixelFormat = .bgra8Unorm; v.preferredFramesPerSecond = 60
                let r = R(dev); v.delegate = r; vc.view.addSubview(v)
                let (_, done) = try iosShow(vc); return (v, r, done)
            }
            defer { Task { @MainActor in v.isPaused = true; done() } }
            try await Task.sleep(for: .milliseconds(300))
            let f0 = await onMain { r.frames }; let t0 = Date()
            try await Task.sleep(for: .seconds(1))
            let fps = Double(await onMain { r.frames } - f0) / Date().timeIntervalSince(t0)
            try expect(fps > 20, "MTKView drew \(String(format: "%.1f", fps)) frames/s")
            // the presented drawable is what the screen shows
            let px = try await onMain { () -> [UInt8] in guard let img = iosSnapshot(v.window!) else { throw Fail("no snapshot") }; return iosPixel(img, 150, 250) }
            try expect(near(px, 255, 0, 0, 30), "on-screen pixel \(px) (expected the cleared red)")
            return "\(String(format: "%.0f", fps)) frames/s, drawable \(await onMain { v.drawableSize }), screen pixel red"
        })
        c.append(check("AVFoundation", "composition-export-session", timeout: 90) {
            let src = FileManager.default.temporaryDirectory.appendingPathComponent("sdkcov-exsrc.mov")
            try await writeMovie(src, frames: 30, size: 128)
            let asset = AVURLAsset(url: src)
            guard let vt = try await asset.loadTracks(withMediaType: .video).first else { throw Fail("no video track") }
            let dur = try await asset.load(.duration)
            // two copies back to back, then exported as MP4
            let comp = AVMutableComposition()
            let ct = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
            try ct.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: vt, at: .zero)
            try ct.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: vt, at: dur)
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("sdkcov-export.mp4"); try? FileManager.default.removeItem(at: out)
            guard let ex = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else { throw Fail("no export session") }
            try await ex.export(to: out, as: .mp4)
            let back = AVURLAsset(url: out)
            let d2 = try await back.load(.duration).seconds
            let tracks = try await back.loadTracks(withMediaType: .video)
            let size = try await tracks.first?.load(.naturalSize)
            try expect(abs(d2 - 2 * dur.seconds) < 0.1 && tracks.count == 1, "exported \(d2) s (\(tracks.count) video tracks), source \(dur.seconds) s")
            let bytes = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
            return "exported \(String(format: "%.2f", d2)) s, \(String(describing: size)), \(bytes) B"
        })
        #endif
        return c
    }
}
