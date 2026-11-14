// sdkcov functional checks added by the tvOS coverage round: frameworks and APIs the shared groups don't reach yet.
// Only built into the tvOS app (#if os(tvOS)); checks shared with other platforms belong in the group files.
// tvOS-specific UI (focus engine, TVUIKit, TVServices, TVMLKit, AVKit's tvOS player, the Siri Remote's micro gamepad)
// runs in a temporary window over the app's own and gives the app's window key back afterwards.
import Foundation
#if os(tvOS)
import SwiftUI
import UIKit
import AVFoundation
import AVKit
import GameController
import TVUIKit
import TVServices
import TVMLKit
import JavaScriptCore
import GroupActivities
import NowPlaying
import MusicUnderstanding
import MediaIntelligence
import MediaIntents
import LinkSecurity
import StateReporting
import RelevanceKit
import DeviceDiscoveryUI
import BackgroundAssets
import NetworkExtension
import AVRouting
import PhotosUI
import ManagedSettings
import SpriteKit
import SceneKit
import MapKit
import RealityKit
import SwiftData
import CoreData
import CloudKit
import Network
import ObjectiveC
import _SpriteKit_SwiftUI
import _SceneKit_SwiftUI
import _MapKit_SwiftUI
import _RealityKit_SwiftUI
import _AVKit_SwiftUI
import _SwiftData_SwiftUI
import _SwiftData_CoreData
import _CoreData_CloudKit
import _DeviceDiscoveryUI_SwiftUI
import _RelevanceKit_MapKit
import Speech
import CoreMIDI
import WeatherKit
import ExtensionFoundation
import DeveloperToolsSupport
import AppIntentsTypeSupport
import AppIntents
import BrowserEngineKit
import Security
import SecurityUI
import AuthenticationServices
import StoreKit
import CoreLocation
import ImageIO
import UniformTypeIdentifiers
import _AuthenticationServices_SwiftUI
import _StoreKit_SwiftUI
import _AppIntents_SwiftUI
import _AppIntents_UIKit

// MARK: helpers

/// poll `cond` on the main actor every 50 ms until it holds or `secs` pass
@MainActor private func tvUntil(_ secs: Double, _ cond: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(secs)
    while !cond() {
        if Date() > end { return false }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return true
}

/// run `f` on the main actor (MainActor.run takes only synchronous closures)
@MainActor private func tvMain<T>(_ f: @MainActor () async throws -> T) async throws -> T { try await f() }

/// the app's window scene (an --only run starts its checks before the scene connects: wait up to 15 s)
@MainActor private func tvScene() async throws -> UIWindowScene {
    var s: UIWindowScene?
    _ = await tvUntil(15) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        s = scenes.first(where: { $0.activationState == .foregroundActive })
        return s != nil
    }
    // an inactive scene means something covers the app: on a fresh install that is a TCC prompt (HomeKit's, from
    // func:HomeKit.manager, as on Apple's simulator) waiting for a press. Focus and snapshots need the app active
    guard let s else {
        let st = UIApplication.shared.connectedScenes.map { "\($0.activationState.rawValue)" }.joined(separator: ",")
        throw Fail("app scene not foreground-active in 15 s (states \(st)): a system alert (TCC prompt?) covers the app")
    }
    return s
}

/// show `vc` full screen in a temporary key window over the app's own; `body` runs with it, then the window goes and
/// the app's own window is key again
@MainActor private func tvWithWindow<T>(_ vc: UIViewController, _ body: (UIWindow) async throws -> T) async throws -> T {
    let scene = try await tvScene()
    let prev = scene.windows.first(where: \.isKeyWindow)
    let w = UIWindow(windowScene: scene)
    w.rootViewController = vc; w.windowLevel = .normal + 1
    w.makeKeyAndVisible()
    defer { w.isHidden = true; w.rootViewController = nil; prev?.makeKeyAndVisible() }
    return try await body(w)
}

/// draw a view hierarchy (as on screen) into an RGBA bitmap; how many sampled pixels match `match`
@MainActor private func tvSample(_ v: UIView, step: Int = 4, _ match: ([UInt8]) -> Bool) -> Int {
    let w = max(1, Int(v.bounds.width)), h = max(1, Int(v.bounds.height))
    let ctx = bitmap(w, h)
    ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
    UIGraphicsPushContext(ctx); v.drawHierarchy(in: v.bounds, afterScreenUpdates: true); UIGraphicsPopContext()
    var n = 0
    for y in stride(from: 0, to: h, by: step) { for x in stride(from: 0, to: w, by: step) where match(pixel(ctx, x, y)) { n += 1 } }
    return n
}

private func tvImp(_ c: AnyClass, _ sel: String) -> String {
    guard let m = class_getInstanceMethod(c, NSSelectorFromString(sel)) else { return "\(sel): none" }
    var i = Dl_info(); let imp = method_getImplementation(m)
    _ = dladdr(unsafeBitCast(imp, to: UnsafeRawPointer.self), &i)
    return "\(sel)=\(imp) \(i.dli_sname.map { String(cString: $0) } ?? "?")"
}

@MainActor private func tvSubviews(_ v: UIView) -> [UIView] { [v] + v.subviews.flatMap { tvSubviews($0) } }

private func tvSolid(_ c: UIColor, _ size: CGSize = CGSize(width: 64, height: 64)) -> UIImage {
    UIGraphicsImageRenderer(size: size).image { ctx in c.setFill(); ctx.fill(CGRect(origin: .zero, size: size)) }
}

/// a mono 44.1 kHz CAF of `secs` seconds: 20 ms 1 kHz clicks every `period` seconds (a 120 BPM click track at 0.5)
private func tvClickTrack(_ secs: Double, period: Double = 0.5) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sdkcov-tv-clicks-\(Int(secs)).caf")
    try? FileManager.default.removeItem(at: url)
    let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    let n = AVAudioFrameCount(secs * 44100)
    guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) else { throw Fail("PCM buffer") }
    buf.frameLength = n
    let p = buf.floatChannelData![0], per = Int(period * 44100), click = 882
    for i in 0..<Int(n) {
        let k = i % per
        p[i] = k < click ? Float(sin(Double(k) * 2 * .pi * 1000 / 44100) * 0.8 * (1 - Double(k) / Double(click))) : 0
    }
    let f = try AVAudioFile(forWriting: url, settings: fmt.settings)
    try f.write(from: buf)
    return url
}

// MARK: focus engine

private class TVFocusVC: UIViewController {
    let a = UIButton(type: .system), b = UIButton(type: .system), off = UIButton(type: .system)
    var preferB = false
    var updates: [String] = []
    override func viewDidLoad() {
        super.viewDidLoad()
        for (btn, t) in [(a, "A"), (b, "B"), (off, "off")] { btn.setTitle(t, for: .normal) }
        off.isEnabled = false
        let s = UIStackView(arrangedSubviews: [a, b, off]); s.axis = .horizontal; s.spacing = 80
        s.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(s)
        NSLayoutConstraint.activate([s.centerXAnchor.constraint(equalTo: view.centerXAnchor), s.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
    }
    override var preferredFocusEnvironments: [UIFocusEnvironment] { preferB ? [b] : [a] }
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let t = { (i: UIFocusItem?) in (i as? UIButton)?.currentTitle ?? (i == nil ? "-" : "\(type(of: i!))") }
        updates.append("\(t(context.previouslyFocusedItem))>\(t(context.nextFocusedItem))")
    }
}

/// focus starts on A; a Siri Remote right-arrow press (simhid: `x86sim key` right arrow) moves it to B
private final class TVPressVC: TVFocusVC {
    var presses: [Int] = []
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        self.presses += presses.map { $0.type.rawValue }
        super.pressesBegan(presses, with: event)
    }
}

// MARK: TVMLKit

private final class TVMLDelegate: NSObject, TVApplicationControllerDelegate {
    var launched = false, failed: Error?, bridged = false
    func appController(_ appController: TVApplicationController, evaluateAppJavaScriptIn jsContext: JSContext) {
        // a native function the JS app calls back
        let f: @convention(block) (String) -> String = { "native:" + $0 }
        jsContext.setObject(f, forKeyedSubscript: "sdkcovNative" as NSString)
        bridged = true
    }
    func appController(_ appController: TVApplicationController, didFinishLaunching options: [String: Any]?) { launched = true }
    func appController(_ appController: TVApplicationController, didFail error: Error) { failed = error }
}

// MARK: GroupActivities, NowPlaying, StateReporting

private struct TVWatchTogether: GroupActivity {
    static let activityIdentifier = "com.x86sim.test.sdkcov.watch-together"
    var metadata: GroupActivityMetadata {
        var m = GroupActivityMetadata(); m.title = "sdkcov"; m.subtitle = "x86sim"; m.type = .watchTogether
        m.fallbackURL = URL(string: "https://example.com/sdkcov"); m.supportsContinuationOnTV = true
        return m
    }
}

@MainActor private final class TVNowPlayingRep: MediaSessionRepresentable {
    let id = "sdkcov-tv-session"
    var played = 0
    var content: (any MediaContentRepresentable)? {
        MovieContent(id: "sdkcov-movie", title: "sdkcov movie", duration: .finite(42), artwork: nil)
    }
    var playbackSnapshot: MediaPlaybackSnapshot? { MediaPlaybackSnapshot(state: .playing(rate: 1), elapsedTime: 3, timestamp: Date()) }
    var commands: [MediaCommand] { [.play { self.played += 1 }, .pause {}, .skipForward(preferredIntervals: [15]) { _ in }] }
}

private struct TVStableMeta: ReportableMetadata {
    var build = "sdkcov"
    var metadataDictionary: [String: ReportableMetadataValue] { ["build": ReportableMetadataValue(build), "n": ReportableMetadataValue(3)] }
}

@objc private protocol TVNoSuchService { func ping(_ reply: @escaping (Bool) -> Void) }

// MARK: SwiftUI hosted views (UIKit- / Metal-backed views ImageRenderer cannot draw)

private final class TVSpriteScene: SKScene {
    var frames = 0
    override func update(_ currentTime: TimeInterval) { frames += 1 }
}

private final class TVSceneDelegate: NSObject, SCNSceneRendererDelegate {
    var frames = 0
    let lock = NSLock()
    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) { lock.withLock { frames += 1 } }
}

/// host a SwiftUI view in a temporary window for `secs`, then hand the hosting controller to `inspect`
@MainActor private func tvHost<V: View, T>(_ v: V, secs: Double = 1, _ inspect: (UIViewController) throws -> T) async throws -> T {
    let hc = UIHostingController(rootView: v)
    return try await tvWithWindow(hc) { w in
        hc.view.layoutIfNeeded()
        try? await Task.sleep(nanoseconds: UInt64(secs * 1e9))
        return try inspect(hc)
    }
}

private struct TVQueryView: View {
    // what @Query(sort: \.title) expands to (the Linux toolchain has no SwiftDataMacros plugin): the Query property
    var _notes = Query<SDNote, [SDNote]>(FetchDescriptor<SDNote>(sortBy: [SortDescriptor(\.title)]))
    var notes: [SDNote] { _notes.wrappedValue }
    let seen: (Int) -> Void
    var body: some View { Text("\(notes.count) notes").onAppear { seen(notes.count) }.onChange(of: notes.count) { _, n in seen(n) } }
}

// MARK: round 2: focus (SwiftUI, collection views), AVKit tvOS-only API, SecurityUI

@MainActor private final class TVFocusModel: ObservableObject {
    @Published var want: Int?
    var seen: [String] = []
}

private struct TVFocusSUIView: View {
    @ObservedObject var m: TVFocusModel
    @FocusState private var f: Int?
    var body: some View {
        HStack(spacing: 60) {
            ForEach(1...3, id: \.self) { i in Button("item \(i)") {}.focused($f, equals: i).disabled(i == 3) }
        }
        .focusSection()
        .defaultFocus($f, 2)
        .onChange(of: f) { _, n in m.seen.append(n.map(String.init) ?? "nil") }
        .onChange(of: m.want) { _, w in f = w }
    }
}

/// a horizontal shelf of 30 cells: the preferred cell gets focus, and focusing a cell past the edge scrolls it in
private final class TVShelfVC: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate {
    var cv: UICollectionView!
    var target = 0
    var focused: [Int] = []
    override func viewDidLoad() {
        super.viewDidLoad()
        let l = UICollectionViewFlowLayout(); l.scrollDirection = .horizontal; l.itemSize = CGSize(width: 300, height: 700)   // one row: item i at x = 340 i
        l.minimumLineSpacing = 40; l.minimumInteritemSpacing = 40
        cv = UICollectionView(frame: view.bounds, collectionViewLayout: l); cv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cv.dataSource = self; cv.delegate = self; cv.remembersLastFocusedIndexPath = false
        cv.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "c")
        view.addSubview(cv)
    }
    override var preferredFocusEnvironments: [UIFocusEnvironment] { [cv] }
    func collectionView(_ cv: UICollectionView, numberOfItemsInSection s: Int) -> Int { 30 }
    func collectionView(_ cv: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
        let c = cv.dequeueReusableCell(withReuseIdentifier: "c", for: ip); c.backgroundColor = .gray; return c
    }
    func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? { IndexPath(item: target, section: 0) }
    func collectionView(_ cv: UICollectionView, didUpdateFocusIn context: UICollectionViewFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        if let ip = context.nextFocusedIndexPath { focused.append(ip.item) }
    }
}

private final class TVProposalDelegate: NSObject, AVPlayerViewControllerDelegate {
    var offered: [String] = []
    func playerViewController(_ pvc: AVPlayerViewController, shouldPresent proposal: AVContentProposal) -> Bool {
        offered.append(proposal.title); return false
    }
}

private struct TVCertSheetView: View {
    @State var trust: SecTrust?
    let initial: SecTrust
    var body: some View {
        Text("sdkcov certificate").certificateSheet(trust: $trust, title: "sdkcov", message: "x86sim")
            .onAppear { trust = initial }
    }
}

/// a self-signed P-256 certificate, CN=sdkcov.x86sim.test (openssl req -x509 -newkey ec, 100 years)
private let tvTestCertB64 = "MIIBkjCCATegAwIBAgIUbtQ1SHWjekvH559fcAl7evKve4IwCgYIKoZIzj0EAwIwHTEbMBkGA1UEAwwSc2RrY292Lng4NnNpbS50ZXN0MCAXDTI2MTExNDA5MDgxOVoYDzIxMjYxMDIxMDkwODE5WjAdMRswGQYDVQQDDBJzZGtjb3YueDg2c2ltLnRlc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAQOJfkuFPd1F3AV2iKLjzgepMckyeKaC20JwA5V6rVb4EkeI+VoiNM2ornLpK/sP046XLke8x+R1ZNtYhjl1QZVo1MwUTAdBgNVHQ4EFgQUBcbx9mwi8a14lX6VX2j6qFPMVNowHwYDVR0jBBgwFoAUBcbx9mwi8a14lX6VX2j6qFPMVNowDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNJADBGAiEAgnMF6lrC3kpppHOkwEr2DsbrfbE6SRPJRKzEUFNp74QCIQDzKlEPktpfRF/EjqLTpa5/sY92FYMUaoq38ntGwE6iBQ=="

private final class TVIntentsDS: NSObject, UICollectionViewAppIntentsDataSource {
    var asked = 0
    func collectionView(_ collectionView: UICollectionView, appEntityIdentifierForItemAt indexPath: IndexPath) -> EntityIdentifier? { asked += 1; return nil }
}

/// run `body`, giving up after `secs` (nil: it did not answer)
private func tvWithin<T: Sendable>(_ secs: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T? {
    try await withThrowingTaskGroup(of: T?.self) { g in
        g.addTask { try await body() }
        g.addTask { try await Task.sleep(nanoseconds: UInt64(secs * 1e9)); return nil }
        let r = try await g.next()!
        g.cancelAll()
        return r
    }
}

extension Registry {
    static var more_tvos: [Check] {
        var c: [Check] = []
        #if os(tvOS)
        // MARK: UIKit on tvOS
        c.append(check("UIKit", "tv-focus-engine", timeout: 40) {
            // the focus engine: the preferred item gets focus when the window shows, a focus update moves it, a
            // disabled button can't take it, didUpdateFocus reports each move
            try await tvMain { () async throws -> String in
                let vc = TVFocusVC()
                return try await tvWithWindow(vc) { w in
                    guard await tvUntil(10, { vc.a.isFocused }) else {
                        throw Fail("initial focus: \(String(describing: UIFocusSystem.focusSystem(for: w)?.focusedItem)), updates \(vc.updates)")
                    }
                    try expect(UIFocusSystem.focusSystem(for: w)?.focusedItem === vc.a, "focus system's item")
                    vc.preferB = true; vc.setNeedsFocusUpdate(); vc.updateFocusIfNeeded()
                    guard await tvUntil(5, { vc.b.isFocused }) else { throw Fail("focus update to B: updates \(vc.updates)") }
                    try expect(!vc.off.canBecomeFocused && vc.a.canBecomeFocused, "disabled button focusable")
                    // requestFocusUpdate(to:) on the focus system moves it back
                    vc.preferB = false; vc.setNeedsFocusUpdate(); vc.updateFocusIfNeeded()
                    let back = await tvUntil(5, { vc.a.isFocused })
                    try expect(back, "focus update back to A: updates \(vc.updates)")
                    // the focus system's own request: to B
                    UIFocusSystem.focusSystem(for: w)?.requestFocusUpdate(to: vc.b); UIFocusSystem.focusSystem(for: w)?.updateFocusIfNeeded()
                    let req = await tvUntil(3, { vc.b.isFocused })
                    let dbg = UIFocusDebugger.checkFocusability(for: vc.off).description
                    try expect(!dbg.isEmpty, "focus debugger")
                    return "moves \(vc.updates.joined(separator: " ")), requestFocusUpdate(to: B) \(req); debugger \(dbg.split(separator: "\n").count) lines"
                }
            }
        })
        c.append(check("UIKit", "tv-tabbar-search-alert", timeout: 40) {
            // tvOS's own containers: the top tab bar, a search container with its keyboard, segmented controls, an
            // alert presented over them; all lay out in a window and draw
            try await tvMain { () async throws -> String in
                let tabs = UITabBarController()
                let red = UIViewController(); red.view.backgroundColor = .red; red.tabBarItem = UITabBarItem(title: "Red", image: nil, tag: 0)
                let results = UIViewController(); results.view.backgroundColor = .blue
                let sc = UISearchController(searchResultsController: results); sc.searchBar.placeholder = "sdkcov"
                let search = UISearchContainerViewController(searchController: sc); search.tabBarItem = UITabBarItem(title: "Search", image: nil, tag: 1)
                let seg = UIViewController(); seg.tabBarItem = UITabBarItem(title: "Segments", image: nil, tag: 2)
                let s = UISegmentedControl(items: ["one", "two", "three"]); s.selectedSegmentIndex = 1; s.frame = CGRect(x: 100, y: 300, width: 600, height: 70); seg.view.addSubview(s)
                tabs.viewControllers = [red, search, seg]
                return try await tvWithWindow(tabs) { w in
                    w.layoutIfNeeded(); try? await Task.sleep(nanoseconds: 300_000_000)
                    let redPx = tvSample(w, step: 16) { $0[0] > 200 && $0[1] < 60 && $0[2] < 60 }
                    try expect(redPx > 100, "red tab drew \(redPx) red samples")
                    try expect(tabs.tabBar.items?.count == 3, "tab items")
                    tabs.selectedIndex = 1; w.layoutIfNeeded()
                    let inSearch = await tvUntil(5) { search.view.window != nil }
                    try expect(inSearch, "search container in the window (selected \(tabs.selectedIndex), search bar window \(sc.searchBar.window != nil))")
                    tabs.selectedIndex = 2; w.layoutIfNeeded()
                    let inSeg = await tvUntil(5) { s.window != nil }
                    try expect(s.numberOfSegments == 3 && inSeg, "segments")
                    let alert = UIAlertController(title: "sdkcov", message: "x86sim", preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .default))
                    var shown = false
                    tabs.present(alert, animated: false) { shown = true }
                    let up = await tvUntil(5) { shown && alert.view.window != nil }
                    alert.dismiss(animated: false)
                    _ = await tvUntil(3) { tabs.presentedViewController == nil }
                    try expect(up, "alert presented")
                    return "\(redPx) red samples, tab bar \(tabs.tabBar.frame.size), alert shown"
                }
            }
        })
        c.append(check("UIKit", "tv-press-gestures") {
            // the Siri Remote's buttons are presses: gesture recognizers filter them by press type
            try await onMain {
                let tap = UITapGestureRecognizer(); tap.allowedPressTypes = [NSNumber(value: UIPress.PressType.playPause.rawValue), NSNumber(value: UIPress.PressType.select.rawValue)]
                tap.allowedTouchTypes = []
                let lp = UILongPressGestureRecognizer(); lp.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
                let v = UIView(); v.addGestureRecognizer(tap); v.addGestureRecognizer(lp)
                try expect(v.gestureRecognizers?.count == 2 && tap.allowedPressTypes.count == 2, "recognizers")
                let types: [UIPress.PressType] = [.upArrow, .downArrow, .leftArrow, .rightArrow, .select, .menu, .playPause, .pageUp, .pageDown, .tvRemoteOneTwoThree, .tvRemoteFourColors]
                return "\(types.count) press types: \(types.map { String($0.rawValue) }.joined(separator: ","))"
            }
        })
        // MARK: TVUIKit
        c.append(check("UIKit", "tv-draw-hierarchy-repeat", timeout: 60) {
            // drawHierarchy(afterScreenUpdates: true) snapshots what the window shows after the pending changes are
            // rendered: a view switched between red and blue 30 times must come back in the new color every time
            try await tvMain { () async throws -> String in
                let vc = UIViewController(); vc.view.backgroundColor = .black
                let ref = UIView(frame: CGRect(x: 1600, y: 650, width: 200, height: 200)); ref.backgroundColor = .red
                vc.view.addSubview(ref)
                return try await tvWithWindow(vc) { w in
                    var bad: [String] = []
                    for i in 0..<30 {
                        let red = i % 2 == 0
                        ref.backgroundColor = red ? .red : .blue
                        let wv = Int(ref.bounds.width), hv = Int(ref.bounds.height)
                        let ctx = bitmap(wv, hv)
                        ctx.translateBy(x: 0, y: CGFloat(hv)); ctx.scaleBy(x: 1, y: -1)
                        UIGraphicsPushContext(ctx); let ok = ref.drawHierarchy(in: ref.bounds, afterScreenUpdates: true); UIGraphicsPopContext()
                        var want = 0, other = 0, rows: [Int] = []
                        for y in stride(from: 0, to: hv, by: 4) {
                            var r = 0
                            for x in stride(from: 0, to: wv, by: 4) {
                                let p = pixel(ctx, x, y)
                                let m = red ? (p[0] > 180 && p[2] < 80) : (p[2] > 180 && p[0] < 80)
                                if m { want += 1; r += 1 } else { other += 1 }
                            }
                            rows.append(r)
                        }
                        if want < 2400 {
                            let firstRow = rows.firstIndex(where: { $0 > 0 }).map { $0 * 4 } ?? -1, lastRow = rows.lastIndex(where: { $0 > 0 }).map { $0 * 4 } ?? -1
                            let p = pixel(ctx, wv / 2, hv / 2)
                            bad.append("#\(i) \(red ? "red" : "blue") ok \(ok): \(want) match rows \(firstRow)-\(lastRow), centre \(p)")
                        }
                    }
                    try expect(bad.isEmpty, "\(tvImp(UIView.self, "drawViewHierarchyInRect:afterScreenUpdates:")) \(bad.count) of 30 snapshots wrong: \(bad.prefix(4).joined(separator: "; "))")
                    return "30 snapshots, each in the new color"
                }
            }
        })
        c.append(check("TVUIKit", "lockups-cards-render", timeout: 40) {
            try await tvMain { () async throws -> String in
                let vc = UIViewController(); vc.view.backgroundColor = .black
                let poster = TVPosterView(image: tvSolid(.red, CGSize(width: 300, height: 400)))
                poster.title = "sdkcov"; poster.subtitle = "x86sim"; poster.frame = CGRect(x: 80, y: 80, width: 300, height: 500)
                let mono = TVMonogramView(); var pn = PersonNameComponents(); pn.givenName = "Sim"; pn.familyName = "Runner"
                mono.personNameComponents = pn; mono.title = "Sim Runner"; mono.frame = CGRect(x: 500, y: 80, width: 250, height: 330)
                let cap = TVCaptionButtonView(); cap.contentImage = UIImage(systemName: "play.fill"); cap.title = "Play"; cap.subtitle = "sdkcov"
                cap.frame = CGRect(x: 850, y: 80, width: 250, height: 250)
                let card = TVCardView(); card.cardBackgroundColor = .green; card.frame = CGRect(x: 1200, y: 80, width: 300, height: 200)
                let lbl = UILabel(); lbl.text = "card"; lbl.frame = CGRect(x: 10, y: 10, width: 200, height: 50); card.contentView.addSubview(lbl)
                let lock = TVLockupView(); lock.contentSize = CGSize(width: 200, height: 120); lock.frame = CGRect(x: 80, y: 650, width: 220, height: 220)
                let hdr = TVLockupHeaderFooterView(); hdr.titleLabel?.text = "header"; lock.headerView = hdr
                let ftr = TVLockupHeaderFooterView(); ftr.titleLabel?.text = "footer"; ftr.subtitleLabel?.text = "sub"; lock.footerView = ftr
                let ref = UIView(frame: CGRect(x: 1600, y: 650, width: 200, height: 200)); ref.backgroundColor = .red
                for v in [poster, mono, cap, card, lock, ref] as [UIView] { vc.view.addSubview(v) }
                return try await tvWithWindow(vc) { w in
                    w.layoutIfNeeded(); try? await Task.sleep(nanoseconds: 300_000_000)
                    let refRed = tvSample(ref) { $0[0] > 180 && $0[1] < 80 && $0[2] < 80 }
                    try expect(refRed > 1000, "a plain red view drew \(refRed) red samples (drawHierarchy)")
                    let red = tvSample(poster) { $0[0] > 180 && $0[1] < 80 && $0[2] < 80 }
                    let green = tvSample(card) { $0[1] > 150 && $0[0] < 120 && $0[2] < 120 }
                    try expect(red > 50, "poster image drew \(red) red samples")
                    try expect(green > 20, "card background drew \(green) green samples")
                    try expect(poster.title == "sdkcov", "poster title \(String(describing: poster.title))")
                    // -[TVCaptionButtonView setTitle:] only forwards to its footer view (the title getter reads an ivar
                    // nothing sets: nil on Apple's too), so the footer's label carries it
                    let capTitle = (cap.footerView as? TVLockupHeaderFooterView)?.titleLabel?.text
                    try expect(capTitle == "Play", "caption button footer title \(String(describing: capTitle))")
                    try expect(lock.footerView === ftr, "lockup footer \(String(describing: lock.footerView))")
                    try expect(mono.personNameComponents?.givenName == "Sim", "monogram name")
                    return "poster \(red) red, card \(green) green, lockup \(lock.bounds.size)"
                }
            }
        })
        c.append(check("TVUIKit", "digit-entry-fullscreen-layout", timeout: 40) {
            try await tvMain { () async throws -> String in
                let d = TVDigitEntryViewController(); d.numberOfDigits = 6; d.titleText = "sdkcov"; d.promptText = "enter a code"; d.isSecureDigitEntry = true
                var entered: String?
                d.entryCompletionHandler = { entered = $0 }
                d.loadViewIfNeeded()
                try expect(d.numberOfDigits == 6 && d.isSecureDigitEntry && entered == nil, "digit entry")
                let shown = try await tvWithWindow(d) { w in w.layoutIfNeeded(); return d.view.window != nil && d.view.subviews.count > 0 }
                try expect(shown, "digit entry shown")
                d.clearEntry(animated: false)
                // a full-screen collection view (TVCollectionViewFullScreenLayout + cells)
                final class DS: NSObject, UICollectionViewDataSource {
                    func collectionView(_ cv: UICollectionView, numberOfItemsInSection s: Int) -> Int { 5 }
                    func collectionView(_ cv: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
                        let c = cv.dequeueReusableCell(withReuseIdentifier: "c", for: ip) as! TVCollectionViewFullScreenCell
                        c.maskedBackgroundView.backgroundColor = [.red, .green, .blue, .yellow, .purple][ip.item]
                        return c
                    }
                }
                let lay = TVCollectionViewFullScreenLayout(); lay.interitemSpacing = 40; lay.maskAmount = 0.5
                let vc = UIViewController(); let ds = DS()
                let cv = UICollectionView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), collectionViewLayout: lay)
                cv.register(TVCollectionViewFullScreenCell.self, forCellWithReuseIdentifier: "c"); cv.dataSource = ds
                vc.view.addSubview(cv)
                let cells = try await tvWithWindow(vc) { w in
                    cv.frame = w.bounds; w.layoutIfNeeded(); cv.layoutIfNeeded()
                    _ = await tvUntil(3) { cv.visibleCells.count > 0 }
                    return cv.visibleCells.count
                }
                try expect(cells > 0 && lay.maskAmount == 0.5, "\(cells) visible full-screen cells")
                return "6-digit entry, \(cells) full-screen cells visible"
            }
        })
        c.append(check("TVUIKit", "content-configurations") {
            try await onMain {
                // TVMediaItemContentConfiguration / TVMonogramContentConfiguration (refined for Swift: __-prefixed in ObjC)
                let m = __TVMediaItemContentConfiguration.wideCell()
                m.text = "sdkcov"; m.secondaryText = "x86sim"; m.image = tvSolid(.blue); m.playbackProgress = 0.4
                let mv = m.makeContentView(); mv.frame = CGRect(x: 0, y: 0, width: 400, height: 300); mv.layoutIfNeeded()
                let mo = __TVMonogramContentConfiguration.cell()
                var pn = PersonNameComponents(); pn.givenName = "Apple"; pn.familyName = "TV"
                mo.personNameComponents = pn; mo.text = "Apple TV"
                let ov = mo.makeContentView(); ov.frame = CGRect(x: 0, y: 0, width: 250, height: 330); ov.layoutIfNeeded()
                let copy = m.copy() as? __TVMediaItemContentConfiguration
                try expect(copy?.text == "sdkcov" && abs((copy?.playbackProgress ?? 0) - 0.4) < 0.001, "copy")
                return "media item view \(type(of: mv)) \(mv.subviews.count) subviews; monogram \(type(of: ov))"
            }
        })
        // MARK: TVServices
        c.append(check("TVServices", "carousel-inset-actions-coding") {
            let it = TVTopShelfCarouselItem(identifier: "sdkcov-1")
            it.title = "sdkcov"; it.contextTitle = "Featured"; it.summary = "x86sim runs the tvOS simulator"; it.genre = "Test"
            it.duration = 5400; it.creationDate = Date(timeIntervalSince1970: 1_700_000_000)
            it.mediaOptions = [.videoResolution4K, .videoColorSpaceHDR, .audioDolbyAtmos]
            it.namedAttributes = [TVTopShelfNamedAttribute(name: "Cast", values: ["A", "B"])]
            it.setImageURL(URL(string: "https://example.com/a.jpg"), for: .screenScale1x)
            it.previewVideoURL = URL(string: "https://example.com/p.m3u8")
            it.playAction = TVTopShelfAction(url: URL(string: "sdkcov://play/1")!)
            it.displayAction = TVTopShelfAction(url: URL(string: "sdkcov://show/1")!)
            let car = TVTopShelfCarouselContent(style: .details, items: [it])
            try expect(car.items.first?.mediaOptions.contains(.audioDolbyAtmos) == true && car.style == .details, "carousel")
            try expect(it.imageURL(for: .screenScale1x)?.lastPathComponent == "a.jpg", "image url")
            let inset = TVTopShelfInsetContent(items: [TVTopShelfItem(identifier: "i1")])
            try expect(inset.items.count == 1 && TVTopShelfInsetContent.imageSize.width > 0, "inset \(TVTopShelfInsetContent.imageSize)")
            let sec = TVTopShelfSectionedItem(identifier: "s1"); sec.imageShape = .poster; sec.playbackProgress = 0.25
            try expect(sec.imageShape == .poster && abs(sec.playbackProgress - 0.25) < 0.001, "sectioned item")
            // the content provider API the top shelf extension uses
            TVTopShelfContentProvider.topShelfContentDidChange()
            return "carousel 1 item, inset image \(TVTopShelfInsetContent.imageSize)"
        })
        // MARK: TVMLKit
        c.append(check("TVMLKit", "js-app-launch-push-document", timeout: 60) {
            // a TVML app: its JavaScript launches, calls a native function, parses and pushes an alertTemplate document;
            // the navigation controller gets its view controller
            let js = """
            App.onLaunch = function(options) {
              var xml = '<?xml version="1.0" encoding="UTF-8" ?><document><alertTemplate><title>sdkcov</title><description>' + sdkcovNative('tvml') + '</description></alertTemplate></document>';
              var doc = new DOMParser().parseFromString(xml, "application/xml");
              navigationDocument.pushDocument(doc);
            }
            """
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("sdkcov-tvml.js")
            try js.write(to: url, atomically: true, encoding: .utf8)
            return try await tvMain { () async throws -> String in
                let ctx = TVApplicationControllerContext(); ctx.javaScriptApplicationURL = url; ctx.launchOptions = ["sdkcov": 1]
                let d = TVMLDelegate()
                let app = TVApplicationController(context: ctx, window: nil, delegate: d)
                return try await tvWithWindow(app.navigationController) { w in
                    guard await tvUntil(30, { d.launched || d.failed != nil }) else { throw Fail("no launch callback (bridged \(d.bridged))") }
                    if let e = d.failed { throw Fail("didFail: \(e)") }
                    try expect(d.bridged, "evaluateAppJavaScriptIn not called")
                    let pushed = await tvUntil(15) { app.navigationController.viewControllers.count >= 1 }
                    try expect(pushed, "pushDocument: no view controller")
                    var sum: String?
                    app.evaluate(inJavaScriptContext: { jc in sum = jc.evaluateScript("[1+2, sdkcovNative('x'), navigationDocument.documents.length].join(',')")?.toString() }, completion: nil)
                    _ = await tvUntil(10) { sum != nil }
                    try expect(sum == "3,native:x,1", "evaluate \(String(describing: sum))")
                    let top = app.navigationController.viewControllers.last
                    app.stop()
                    return "\(app.navigationController.viewControllers.count) document(s), top \(top.map { "\(type(of: $0))" } ?? "-"), js \(sum!)"
                }
            }
        })
        // MARK: AVKit (tvOS player UI)
        c.append(check("AVKit", "tv-player-transport-bar-playback", timeout: 60) {
            let url = try tvClickTrack(3)
            return try await tvMain { () async throws -> String in
                let item = AVPlayerItem(url: url)
                let title = AVMutableMetadataItem(); title.identifier = .commonIdentifierTitle; title.value = "sdkcov" as NSString; title.extendedLanguageTag = "und"
                item.externalMetadata = [title]
                let marker = AVTimedMetadataGroup(items: [title], timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1)))
                item.navigationMarkerGroups = [AVNavigationMarkersGroup(title: "Chapters", timedNavigationMarkers: [marker])]
                item.interstitialTimeRanges = [AVInterstitialTimeRange(timeRange: CMTimeRange(start: CMTime(value: 2, timescale: 1), duration: CMTime(value: 1, timescale: 2)))]
                let player = AVPlayer(playerItem: item)
                let vc = AVPlayerViewController(); vc.player = player
                vc.transportBarCustomMenuItems = [UIAction(title: "Speed", image: UIImage(systemName: "speedometer")) { _ in }]
                vc.contextualActions = [UIAction(title: "Skip") { _ in }]
                vc.infoViewActions = [UIAction(title: "Info") { _ in }]
                let info = UIViewController(); info.title = "Info"; vc.customInfoViewControllers = [info]
                vc.playbackControlsIncludeTransportBar = true; vc.requiresLinearPlayback = false
                return try await tvWithWindow(vc) { w in
                    guard await tvUntil(15, { item.status != .unknown }) else { throw Fail("item status stayed unknown") }
                    if item.status == .failed { throw Fail("item failed: \(String(describing: item.error))") }
                    let dur = item.duration.seconds
                    try expect(abs(dur - 3) < 0.1, "duration \(dur)")
                    try expect(vc.view.window != nil && vc.transportBarCustomMenuItems.count == 1 && vc.customInfoViewControllers.count == 1, "player UI")
                    player.play()
                    let moved = await tvUntil(10) { player.currentTime().seconds > 0.3 }
                    let t = player.currentTime().seconds
                    player.pause()
                    try expect(moved, "playback did not advance (at \(t) s, rate \(player.rate), \(String(describing: item.error)))")
                    var sought = false
                    player.seek(to: CMTime(value: 2, timescale: 1), toleranceBefore: .zero, toleranceAfter: .zero) { sought = $0 }
                    _ = await tvUntil(5) { sought }
                    try expect(sought && abs(player.currentTime().seconds - 2) < 0.05, "seek to 2 s: \(player.currentTime().seconds)")
                    return "\(dur) s CAF played to \(String(format: "%.2f", t)) s, seek ok, \(item.navigationMarkerGroups.count) marker group"
                }
            }
        })
        c.append(check("_AVKit_SwiftUI", "video-player-hosted") {
            let url = try tvClickTrack(1)
            return try await tvMain { () async throws -> String in
                let p = AVPlayer(url: url)
                return try await tvHost(VideoPlayer(player: p) { Text("sdkcov overlay") }) { hc in
                    let names = tvSubviews(hc.view).map { "\(type(of: $0))" }
                    try expect(names.contains(where: { $0.contains("AVPlayer") }) || hc.children.contains(where: { $0 is AVPlayerViewController }), "no AVPlayer view in \(names.count) views")
                    return "\(names.count) views, \(hc.children.count) child controllers"
                }
            }
        })
        // MARK: GameController (Siri Remote)
        c.append(check("GameController", "tv-micro-gamepad-event-vc", timeout: 30) {
            try await tvMain { () async throws -> String in
                // the Siri Remote is a micro gamepad: a snapshot one takes values and reports them to its handlers
                let ctl = GCController.withMicroGamepad()
                guard let mg = ctl.microGamepad else { throw Fail("no micro gamepad profile") }
                mg.reportsAbsoluteDpadValues = true; mg.allowsRotation = true
                var changes = 0
                mg.valueChangedHandler = { _, _ in changes += 1 }
                mg.dpad.setValueForXAxis(0.5, yAxis: -0.25)
                mg.buttonA.setValue(1)
                try expect(abs(mg.dpad.xAxis.value - 0.5) < 0.01 && abs(mg.dpad.yAxis.value + 0.25) < 0.01, "dpad \(mg.dpad.xAxis.value),\(mg.dpad.yAxis.value)")
                try expect(mg.buttonA.isPressed && !mg.buttonX.isPressed, "buttons")
                try expect(mg.reportsAbsoluteDpadValues && mg.allowsRotation, "remote options")
                let prof = ctl.physicalInputProfile
                let ext = GCController.withExtendedGamepad()
                ext.extendedGamepad?.leftThumbstick.setValueForXAxis(-1, yAxis: 1)
                try expect(ext.extendedGamepad?.leftThumbstick.left.isPressed == true, "extended thumbstick")
                // GCEventViewController routes controller input to the app or to UIKit
                let evc = GCEventViewController(); evc.controllerUserInteractionEnabled = false
                let (up, n) = try await tvWithWindow(evc) { w in
                    w.layoutIfNeeded()
                    // Apple's tvOS simulator lists its Siri Remote (Simulator's virtual remote) as a controller
                    _ = await tvUntil(5) { !GCController.controllers().isEmpty }
                    return (evc.view.window != nil, GCController.controllers().count)
                }
                try expect(up && !evc.controllerUserInteractionEnabled, "event view controller")
                try expect(n >= 1, "\(n) controllers connected with the event view controller up (Apple: the Siri Remote, 1)")
                return "micro gamepad: \(prof.buttons.count) buttons, \(prof.dpads.count) dpads, \(changes) change callbacks; \(GCController.controllers().count) connected"
            }
        })
        // MARK: GroupActivities (SharePlay)
        c.append(check("GroupActivities", "activity-metadata-prepare", timeout: 40) {
            let a = TVWatchTogether()
            try expect(a.metadata.type == .watchTogether && a.metadata.title == "sdkcov", "metadata")
            let st = GroupStateObserver()
            // no FaceTime call: activation is disabled (or cancelled), never a hang
            let r = await a.prepareForActivation()
            let rs: String
            switch r {
            case .activationDisabled: rs = "activationDisabled"
            case .activationPreferred: rs = "activationPreferred"
            case .cancelled: rs = "cancelled"
            @unknown default: rs = "unknown"
            }
            return "prepareForActivation \(rs), eligible \(await onMain { st.isEligibleForGroupSession })"
        })
        // MARK: new 27 frameworks
        c.append(check("NowPlaying", "media-session-primary", timeout: 30) {
            try await tvMain { () async throws -> String in
                let rep = TVNowPlayingRep()
                let s = MediaSession(rep)
                try expect(s.id.isEmpty == false, "session id")
                var err = ""
                do { try await s.requestToBecomeApplicationPrimary() } catch { err = " (request: \(error))" }
                _ = await tvUntil(3) { s.isApplicationPrimary }
                try expect(rep.content?.id == "sdkcov-movie" && rep.commands.count == 3, "representable")
                return "primary \(s.isApplicationPrimary), canBecome \(s.canBecomeApplicationPrimary)\(err)"
            }
        })
        c.append(check("MusicUnderstanding", "click-track-loudness-rhythm", timeout: 240) {
            // a 120 BPM click track: loudness is measured (integrated LUFS), then the rhythm network finds beats
            // (Espresso on the CPU: slow under translation, so the track is 4 s)
            let url = try tvClickTrack(4)
            let t0 = Date()
            let s = try await MusicUnderstandingSession(asset: AVURLAsset(url: url))
            let r = try await s.analyze(for: [.loudness])
            guard let lo = r.loudness else { throw Fail("no loudness result") }
            try expect(lo.integrated.value.isFinite && lo.integrated.value < 0 && lo.integrated.value > -60, "integrated loudness \(lo.integrated.value)")
            let t1 = Date()
            let s2 = try await MusicUnderstandingSession(asset: AVURLAsset(url: url))
            let rr = try await s2.analyze(for: [.rhythm])
            let beats = rr.rhythm?.beats ?? []
            let t2 = Date()
            let gaps = zip(beats.dropFirst(), beats).map { ($0.0 - $0.1).seconds }
            return "loudness \(String(format: "%.1f", lo.integrated.value)) LUFS (\(Int(t1.timeIntervalSince(t0) * 1000)) ms); \(beats.count) beats, gaps \(gaps.map { String(format: "%.2f", $0) }.joined(separator: ",")), bpm \(rr.rhythm?.beatsPerMinute.map { String(format: "%.1f", $0) } ?? "nil") (\(Int(t2.timeIntervalSince(t1) * 1000)) ms)"
        })
        c.append(check("MediaIntelligence", "face-group-analyzer", timeout: 90) {
            // the analyzer's store: created empty, ready, purged. Ingesting images runs Vision's face networks
            // (espresso), which fail in Apple's simulator too ("Could not create inference context"), and the
            // framework then resumes a continuation twice (abort), so no assets go in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sdkcov-mi", isDirectory: true)
            try? FileManager.default.removeItem(at: dir); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let work = dir.appendingPathComponent("work", isDirectory: true)
            let fa = try FaceGroupAnalyzer(workingDirectory: work)
            var faces = 0, ids = 0
            for try await _ in fa.allFaces { faces += 1 }
            for try await _ in fa.allAssetIDs { ids += 1 }
            try expect(faces == 0 && ids == 0, "\(faces) faces, \(ids) assets in a new analyzer")
            try await fa.deleteAllAssets()
            let st = await fa.state
            try await FaceGroupAnalyzer.purge(workingDirectory: work)
            return "empty analyzer, state \(st)"
        })
        c.append(check("MediaIntents", "audio-search-codable") {
            let s = AudioSearch(criteria: .searchQuery("x86sim"))
            let d = try JSONEncoder().encode(s), back = try JSONDecoder().decode(AudioSearch.self, from: d)
            try expect(back == s, "round trip")
            let u = AudioSearch(criteria: .url([URL(string: "https://example.com/a.m4a")!]))
            try expect(u != s, "criteria")
            return "\(d.count) B JSON"
        })
        c.append(check("Foundation", "xpc-missing-service-errors", timeout: 30) {
            // an NSXPCConnection to a Mach service nobody publishes fails at once: the proxy's error handler and
            // the invalidation handler run (NSCocoaErrorDomain 4099, as on Apple's simulator)
            // init(machServiceName:) is unavailable to tvOS apps in Swift; frameworks (LinkSecurity, ...) use it
            typealias Init = @convention(c) (AnyObject, Selector, NSString, UInt) -> NSXPCConnection
            let sel = NSSelectorFromString("initWithMachServiceName:options:")
            guard let imp = class_getMethodImplementation(NSXPCConnection.self, sel) else { throw Fail("no initWithMachServiceName:options:") }
            let raw = (NSXPCConnection.self as NSObject.Type).perform(NSSelectorFromString("alloc")).takeUnretainedValue()
            let conn = unsafeBitCast(imp, to: Init.self)(raw, sel, "com.x86sim.test.sdkcov.no-such-service", 0)
            conn.remoteObjectInterface = NSXPCInterface(with: TVNoSuchService.self)
            let lock = NSLock(); var err: NSError?, invalidated = false
            conn.invalidationHandler = { lock.withLock { invalidated = true } }
            conn.resume()
            let proxy = conn.remoteObjectProxyWithErrorHandler { e in lock.withLock { err = e as NSError } } as? TVNoSuchService
            proxy?.ping { _ in }
            let t0 = Date()
            while lock.withLock({ err == nil || !invalidated }) && Date().timeIntervalSince(t0) < 10 { try await Task.sleep(nanoseconds: 50_000_000) }
            let (e, inv) = lock.withLock { (err, invalidated) }
            conn.invalidate()
            guard let e else { throw Fail("no error handler call in 10 s (invalidated \(inv))") }
            try expect(e.domain == NSCocoaErrorDomain && (e.code == 4099 || e.code == 4097), "error \(e)")
            return "error \(e.domain) \(e.code) after \(Int(Date().timeIntervalSince(t0) * 1000)) ms, invalidated \(inv)"
        })
        c.append(check("LinkSecurity", "flag-urls", timeout: 30) {
            // the flagged-URL store lives in imagent (com.apple.imagent.EnhancedLinkSecurityStore), which the
            // tvOS simulator runtime doesn't ship (nor does iOS's): answers come only where Messages runs
            let u = URL(string: "https://example.com/sdkcov-\(UUID().uuidString)")!
            let lock = NSLock(); var r: Bool?, stage = "shared"
            Thread.detachNewThread {
                let m = LSLinkSecurityManager.shared
                lock.withLock { stage = "isFlaggedURL" }
                m.checkIsFlaggedURL(u) { f in lock.withLock { r = f; stage = "answered" } }
                lock.withLock { if stage == "isFlaggedURL" { stage = "isFlaggedURL returned" } }
            }
            let t0 = Date()
            while lock.withLock({ r == nil }) && Date().timeIntervalSince(t0) < 10 { try await Task.sleep(nanoseconds: 50_000_000) }
            guard let before = lock.withLock({ r }) else { throw Skip("no answer from imagent's EnhancedLinkSecurityStore in 10 s, at \(lock.withLock { stage }) (the simulator runtime has no imagent)") }
            try expect(!before, "flagged before adding")
            return "flagged before add \(before)"
        })
        c.append(check("StateReporting", "reporter-transitions") {
            let r = StateReporter.reporter(for: "com.x86sim.test.sdkcov", stableMetadata: TVStableMeta.self)
            r.reportTransition(to: "running", stableMetadata: TVStableMeta())
            r.reportTransition(to: "idle")
            r.reportTransition(to: nil)
            try expect(r.domain == "com.x86sim.test.sdkcov", "domain")
            let v = ReportableMetadataValue(Int64(42))
            let d = try JSONEncoder().encode(v)
            try expect(try JSONDecoder().decode(ReportableMetadataValue.self, from: d) == v, "value coding")
            return "3 transitions"
        })
        c.append(check("RelevanceKit", "contexts") {
            let now = Date()
            let cs: [RelevantContext] = [.date(now), .date(from: now, to: now.addingTimeInterval(3600)),
                                         .location(CLCircularRegion(center: CLLocationCoordinate2D(latitude: 37.33, longitude: -122.0), radius: 100, identifier: "sdkcov"))]
            return "\(cs.count) contexts"
        })
        c.append(check("_RelevanceKit_MapKit", "poi-category-context") {
            let c = RelevantContext.location(category: .cafe)
            return "cafe context \(c != nil)"
        })
        // MARK: tvOS services
        c.append(check("DeviceDiscoveryUI", "device-picker", timeout: 30) {
            // the picker's view needs the app's NSApplicationServices Info.plist entry (DeviceDiscoveryUI aborts the
            // app without it, "Missing TCC info for browse", on Apple's too); sdkcov has none, so the view isn't loaded
            try await tvMain { () async throws -> String in
                let desc = NWBrowser.Descriptor.applicationService(name: "sdkcov")
                let ok = DDDevicePickerViewController.isSupported(desc, using: .applicationService)
                let p = DDDevicePickerViewController(browseDescriptor: desc, parameters: .applicationService)
                return "supported \(ok), picker \(p != nil)"
            }
        })
        c.append(check("_DeviceDiscoveryUI_SwiftUI", "device-picker-supports") {
            try await tvMain { () async throws -> String in
                let env = EnvironmentValues()
                let ok = env.devicePickerSupports(.applicationService(name: "sdkcov"), parameters: { .applicationService })
                let uikit = DDDevicePickerViewController.isSupported(.applicationService(name: "sdkcov"), using: .applicationService)
                try expect(ok == uikit, "SwiftUI \(ok) vs UIKit \(uikit)")
                return "supported \(ok)"
            }
        })
        c.append(check("BackgroundAssets", "asset-pack-manager-downloads", timeout: 30) {
            // AssetPackManager needs BAAppGroupID in Info.plist (a fatal error without it, as on Apple's)
            var packs = "no BAAppGroupID: AssetPackManager not used"
            if Bundle.main.object(forInfoDictionaryKey: "BAAppGroupID") is String {
                let local = AssetPackManager.shared.assetPackIsAvailableLocally(withID: "sdkcov-pack")
                try expect(!local, "unknown asset pack available locally")
                packs = "asset pack not local"
            }
            // BADownloadManager traps ("BUG IN CLIENT") without BAInitialDownloadRestrictions / BAManifestURL in Info.plist
            var cur = "no BAInitialDownloadRestrictions: BADownloadManager not used"
            if Bundle.main.object(forInfoDictionaryKey: "BAInitialDownloadRestrictions") is [String: Any] {
                do { cur = "\(try await BADownloadManager.shared.fetchCurrentDownloads().count) downloads" } catch { cur = "fetchCurrentDownloads: \((error as NSError).domain) \((error as NSError).code)" }
            }
            let dl = BAURLDownload(identifier: "sdkcov", request: URLRequest(url: URL(string: "https://example.com/a.bin")!), essential: false, fileSize: 1024, applicationGroupIdentifier: "group.com.x86sim.test.sdkcov", priority: .default)
            try expect(dl.identifier == "sdkcov" && dl.state == .created, "download object state \(dl.state.rawValue)")
            return "\(packs); \(cur)"
        })
        c.append(check("NetworkExtension", "vpn-relay-managers-settings", timeout: 40) {
            // without the Network Extension entitlement the managers answer with an error, not a hang
            func load(_ f: (@escaping (Error?) -> Void) -> Void) async -> String {
                await withCheckedContinuation { k in f { e in k.resume(returning: e.map { "\(($0 as NSError).domain) \(($0 as NSError).code)" } ?? "ok") } }
            }
            let vpn = await load { NEVPNManager.shared().loadFromPreferences(completionHandler: $0) }
            let relay = await load { NERelayManager.shared().loadFromPreferences(completionHandler: $0) }
            let all: String = await withCheckedContinuation { k in
                NETunnelProviderManager.loadAllFromPreferences { ms, e in k.resume(returning: e.map { "\(($0 as NSError).domain) \(($0 as NSError).code)" } ?? "\(ms?.count ?? 0) managers") }
            }
            let s = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "192.0.2.1")
            s.ipv4Settings = NEIPv4Settings(addresses: ["10.0.0.2"], subnetMasks: ["255.255.255.0"])
            s.ipv4Settings?.includedRoutes = [NEIPv4Route.default()]
            s.dnsSettings = NEDNSSettings(servers: ["192.0.2.53"])
            let rule = NEOnDemandRuleConnect(); rule.interfaceTypeMatch = .ethernet
            try expect(s.ipv4Settings?.addresses == ["10.0.0.2"] && s.dnsSettings?.servers.first == "192.0.2.53", "settings")
            // Apple's tvOS 27.2 simulator: "vpn ok, relay ok, tunnels 0 managers" (its NEConfigurationManager reaches
            // com.apple.nehelper, which the simulator runtime does not ship: the Mac's own, through CoreSimulator)
            try expect(vpn == "ok" && relay == "ok" && all == "0 managers", "vpn \(vpn), relay \(relay), tunnels \(all) (Apple: ok, ok, 0 managers)")
            return "vpn \(vpn), relay \(relay), tunnels \(all)"
        })
        c.append(check("AVRouting", "playback-arbiter") {
            let a = AVRoutingPlaybackArbiter.shared()
            let p = AVPlayer()
            a.preferredParticipantForExternalPlayback = p
            a.preferredParticipantForNonMixableAudioRoutes = p
            try expect(a.preferredParticipantForExternalPlayback === p, "preferred participant")
            a.preferredParticipantForExternalPlayback = nil; a.preferredParticipantForNonMixableAudioRoutes = nil
            return "ok"
        })
        c.append(check("PhotosUI", "live-photo-view") {
            try await onMain {
                let v = PHLivePhotoView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
                v.contentMode = .scaleAspectFit; v.isMuted = true; v.layoutIfNeeded()
                try expect(v.livePhoto == nil && v.isMuted, "view")
                return "badge \(PHLivePhotoView.livePhotoBadgeImage(options: .overContent).size)"
            }
        })
        c.append(check("ManagedSettings", "store-read-write") {
            // tvOS has only the default store's effective (read-only) values
            let st = ManagedSettingsStore()
            return "effectiveDenyExplicitContent \(st.effectiveDenyExplicitContent)"
        })
        // MARK: SwiftUI cross-import overlays
        c.append(check("_SpriteKit_SwiftUI", "sprite-view-runs-scene", timeout: 30) {
            try await tvMain { () async throws -> String in
                let sc = TVSpriteScene(size: CGSize(width: 400, height: 300)); sc.backgroundColor = .red
                let n = SKShapeNode(circleOfRadius: 30); n.fillColor = .yellow; n.position = CGPoint(x: 200, y: 150); sc.addChild(n)
                n.run(.repeatForever(.rotate(byAngle: .pi, duration: 1)), withKey: "spin")
                return try await tvHost(SpriteView(scene: sc).frame(width: 400, height: 300), secs: 1.5) { _ in
                    try expect(sc.frames > 10, "scene updated \(sc.frames) times in 1.5 s")
                    return "\(sc.frames) frames"
                }
            }
        })
        c.append(check("SceneKit", "scnview-onscreen-continuous", timeout: 30) {
            // an on-screen SCNView (Metal layer + display link) that renders continuously: about 60 frames a second
            try await tvMain { () async throws -> String in
                let s = SCNScene(); s.rootNode.addChildNode(SCNNode(geometry: SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0.1)))
                let cam = SCNNode(); cam.camera = SCNCamera(); cam.position = SCNVector3(0, 0, 4); s.rootNode.addChildNode(cam)
                let d = TVSceneDelegate()
                let vc = UIViewController()
                let v = SCNView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), options: nil)
                v.scene = s; v.pointOfView = cam; v.delegate = d; v.rendersContinuously = true; v.backgroundColor = .blue
                vc.view.addSubview(v)
                return try await tvWithWindow(vc) { w in
                    // the first frame waits for SceneKit's shaders to compile (seconds on a cold start)
                    let t0 = Date()
                    let first = await tvUntil(15) { d.lock.withLock { d.frames } > 0 }
                    let t1 = Date(), f0 = d.lock.withLock { d.frames }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    let f = d.lock.withLock { d.frames } - f0
                    try expect(first && f > 20, "renderer updated \(f) times in 1 s after the first frame (first \(first), api \(v.renderingAPI.rawValue), playing \(v.isPlaying))")
                    return "first frame after \(Int(t1.timeIntervalSince(t0) * 1000)) ms, then \(f) frames/s"
                }
            }
        })
        c.append(check("_SceneKit_SwiftUI", "scene-view-renders", timeout: 30) {
            try await tvMain { () async throws -> String in
                let s = SCNScene(); s.rootNode.addChildNode(SCNNode(geometry: SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0.1)))
                let cam = SCNNode(); cam.camera = SCNCamera(); cam.position = SCNVector3(0, 0, 4); s.rootNode.addChildNode(cam)
                let d = TVSceneDelegate()
                let hc = UIHostingController(rootView: SceneView(scene: s, pointOfView: cam, options: [.rendersContinuously], delegate: d).frame(width: 400, height: 300))
                return try await tvWithWindow(hc) { _ in
                    let first = await tvUntil(15) { d.lock.withLock { d.frames } > 0 }
                    let f0 = d.lock.withLock { d.frames }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    let f = d.lock.withLock { d.frames } - f0
                    try expect(first && f > 20, "renderer updated \(f) times in 1 s after the first frame (first \(first))")
                    return "\(f) frames/s"
                }
            }
        })
        c.append(check("_MapKit_SwiftUI", "map-view-hosted", timeout: 30) {
            try await tvMain { () async throws -> String in
                let center = CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.009)
                let v = Map(initialPosition: .region(MKCoordinateRegion(center: center, latitudinalMeters: 1000, longitudinalMeters: 1000))) {
                    Marker("sdkcov", coordinate: center)
                }.mapStyle(.standard(pointsOfInterest: .excludingAll))
                return try await tvHost(v.frame(width: 600, height: 400), secs: 1) { hc in
                    let names = tvSubviews(hc.view).map { "\(type(of: $0))" }
                    try expect(names.contains(where: { $0.contains("MKMapView") || $0.contains("Map") }), "no map view in \(names.count) views")
                    return "\(names.count) views"
                }
            }
        })
        c.append(check("_RealityKit_SwiftUI", "reality-view-make", timeout: 30) {
            try await tvMain { () async throws -> String in
                var made = 0
                let v = RealityView { content in
                    content.add(ModelEntity(mesh: .generateBox(size: 0.2), materials: [SimpleMaterial(color: .red, isMetallic: false)]))
                    made += 1
                }
                return try await tvHost(v.frame(width: 400, height: 300), secs: 2) { _ in
                    try expect(made == 1, "make closure ran \(made) times")
                    return "make ran once"
                }
            }
        })
        c.append(check("_SwiftData_SwiftUI", "query-in-hosted-view", timeout: 30) {
            try await tvMain { () async throws -> String in
                let mc = try ModelContainer(for: SDNote.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
                for i in 0..<7 { mc.mainContext.insert(SDNote(title: "tv\(i)")) }
                try mc.mainContext.save()
                var seen = -1
                return try await tvHost(TVQueryView(seen: { seen = $0 }).modelContainer(mc), secs: 0.5) { _ in
                    try expect(seen == 7, "@Query saw \(seen) notes")
                    return "@Query: \(seen) notes"
                }
            }
        })
        c.append(check("_SwiftData_CoreData", "managed-object-model") {
            guard let m = NSManagedObjectModel.makeManagedObjectModel(for: [SDNote.self]) else { throw Fail("no model") }
            let e = m.entitiesByName["SDNote"]
            try expect(e != nil && Set(e!.attributesByName.keys).isSuperset(of: ["title", "stamp"]), "entities \(m.entitiesByName.keys.sorted())")
            return "attributes \(e!.attributesByName.keys.sorted())"
        })
        c.append(check("_CoreData_CloudKit", "container-options-scope") {
            let o = NSPersistentCloudKitContainerOptions(containerIdentifier: "iCloud.com.x86sim.test.sdkcov")
            o.databaseScope = .public
            try expect(o.databaseScope == .public && o.containerIdentifier == "iCloud.com.x86sim.test.sdkcov", "scope \(o.databaseScope.rawValue)")
            return "scope public"
        })

        // MARK: round 2
        c.append(check("UIKit", "tv-screen-display-traits") {
            // the 1080p Apple TV: 1920x1080 points at scale 1 (Apple's profile), the TV idiom, 60 Hz
            try await tvMain { () async throws -> String in
                let sc = try await tvScene(); let s = sc.screen
                let tc = sc.traitCollection
                try expect(s.bounds.size == CGSize(width: 1920, height: 1080), "bounds \(s.bounds.size)")
                try expect(s.scale == 1 && s.nativeScale == 1, "scale \(s.scale) native \(s.nativeScale)")
                try expect(tc.userInterfaceIdiom == .tv && tc.displayScale == 1, "idiom \(tc.userInterfaceIdiom.rawValue) displayScale \(tc.displayScale)")
                // Apple's tvOS 27.2 simulator (1080p Apple TV 4K): sRGB, though the device type's capabilities say P3
                try expect(s.traitCollection.displayGamut == .SRGB, "displayGamut \(s.traitCollection.displayGamut.rawValue) (Apple: 0, sRGB)")
                try expect(s.maximumFramesPerSecond == 60, "maximumFramesPerSecond \(s.maximumFramesPerSecond)")
                let mode = s.currentMode?.size ?? .zero
                try expect(mode == CGSize(width: 1920, height: 1080), "current mode \(mode)")
                return "\(s.bounds.size) @\(s.scale)x, mode \(mode), \(s.maximumFramesPerSecond) Hz, gamut \(s.traitCollection.displayGamut.rawValue), overscan \(s.overscanCompensation.rawValue)"
            }
        })
        c.append(check("UIKit", "tv-remote-press-focus-move", timeout: 40) {
            // the real input path: a remote press from the host (SimulatorHID keyboard stand-in) reaches the app as a
            // UIPress and the focus engine moves focus right. Needs someone to press: run.sh sends no input, so
            // without a press in 20 s this SKIPs (manual: `x86sim key 0x4f` = right arrow while it waits)
            try await tvMain { () async throws -> String in
                let vc = TVPressVC()
                return try await tvWithWindow(vc) { w in
                    guard await tvUntil(10, { vc.a.isFocused }) else { throw Fail("initial focus not on A: \(vc.updates)") }
                    FileHandle.standardError.write("sdkcov: tv-remote-press-focus-move waits for a right press\n".data(using: .utf8)!)
                    let moved = await tvUntil(20) { vc.b.isFocused }
                    if !moved && vc.presses.isEmpty { throw Skip("no remote press arrived in 20 s (run.sh sends none)") }
                    try expect(moved, "presses \(vc.presses) but focus \(vc.updates)")
                    return "presses \(vc.presses), focus \(vc.updates.joined(separator: " "))"
                }
            }
        })
        c.append(check("UIKit", "tv-focus-collection-scroll", timeout: 40) {
            // a collection view's preferred index path takes focus when the window shows; the focused cell past the
            // right edge is scrolled into view, and the delegate hears of it
            try await tvMain { () async throws -> String in
                let vc = TVShelfVC(); vc.target = 20
                return try await tvWithWindow(vc) { w in
                    w.layoutIfNeeded()
                    guard await tvUntil(10, { vc.focused.contains(20) }) else {
                        throw Fail("cell 20 not focused: focus \(String(describing: UIFocusSystem.focusSystem(for: w)?.focusedItem)), updates \(vc.focused)")
                    }
                    let cell = vc.cv.cellForItem(at: IndexPath(item: 20, section: 0))
                    try expect(cell?.isFocused == true, "cell 20 isFocused \(String(describing: cell?.isFocused))")
                    _ = await tvUntil(5) { vc.cv.contentOffset.x > 1000 && !vc.cv.isDecelerating }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    let vis = vc.cv.bounds, f = cell.map { vc.cv.convert($0.bounds, from: $0) } ?? .zero
                    try expect(vc.cv.contentOffset.x > 1000 && vis.intersects(f), "focused cell not scrolled in: offset \(vc.cv.contentOffset), cell \(f), visible \(vis)")
                    // move focus programmatically to item 2: back to the start
                    vc.target = 2; vc.setNeedsFocusUpdate(); vc.updateFocusIfNeeded()
                    let back = await tvUntil(5) { vc.focused.last == 2 }
                    _ = await tvUntil(5) { vc.cv.contentOffset.x < 400 }
                    try expect(back, "focus update to item 2: updates \(vc.focused)")
                    return "focus \(vc.focused.map(String.init).joined(separator: ">")), offset \(Int(vc.cv.contentOffset.x))"
                }
            }
        })
        c.append(check("SwiftUI", "tv-focus-state-default-focus", timeout: 40) {
            // SwiftUI's focus on tvOS: .defaultFocus picks the second button, a @FocusState change moves focus, a
            // disabled button never takes it
            try await tvMain { () async throws -> String in
                let m = TVFocusModel()
                let hc = UIHostingController(rootView: TVFocusSUIView(m: m))
                return try await tvWithWindow(hc) { w in
                    @MainActor func focused() -> String { (UIFocusSystem.focusSystem(for: w)?.focusedItem as? UIView).map { tvSubviews($0).compactMap { ($0 as? UILabel)?.text }.joined() } ?? "-" }
                    let initial = await tvUntil(10) { m.seen.last == "2" }
                    try expect(initial, "default focus: FocusState updates \(m.seen), focused \(String(describing: UIFocusSystem.focusSystem(for: w)?.focusedItem))")
                    m.want = 1
                    let moved = await tvUntil(5) { m.seen.last == "1" }
                    try expect(moved, "FocusState = 1: updates \(m.seen)")
                    m.want = 3
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    try expect(m.seen.last != "3", "disabled button took focus: \(m.seen)")
                    return "FocusState \(m.seen.joined(separator: ">")); focused view '\(focused())'"
                }
            }
        })
        c.append(check("AVKit", "tv-content-proposal-display-criteria", timeout: 60) {
            // tvOS-only AVKit: the item's next-content proposal reaches the player's delegate at its transition
            // time; the window's display manager takes preferred display criteria (frame rate + format)
            let url = try tvClickTrack(3)
            return try await tvMain { () async throws -> String in
                let item = AVPlayerItem(url: url)
                let prop = AVContentProposal(contentTimeForTransition: CMTime(value: 1, timescale: 1), title: "sdkcov next", previewImage: tvSolid(.red))
                prop.automaticAcceptanceInterval = 10; prop.metadata = []
                item.nextContentProposal = prop
                let player = AVPlayer(playerItem: item)
                let vc = AVPlayerViewController(); vc.player = player
                let d = TVProposalDelegate(); vc.delegate = d
                vc.appliesPreferredDisplayCriteriaAutomatically = false
                return try await tvWithWindow(vc) { w in
                    let dm = w.avDisplayManager
                    var fd: CMVideoFormatDescription?
                    try expect(CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_H264, width: 1920, height: 1080, extensions: nil, formatDescriptionOut: &fd) == noErr, "format description")
                    let crit = AVDisplayCriteria(refreshRate: 24, formatDescription: fd!)
                    dm.preferredDisplayCriteria = crit
                    let set = dm.preferredDisplayCriteria != nil
                    dm.preferredDisplayCriteria = nil
                    guard await tvUntil(15, { item.status != .unknown }) else { throw Fail("item status stayed unknown") }
                    player.play()
                    let offered = await tvUntil(8) { !d.offered.isEmpty }
                    let t = player.currentTime().seconds
                    player.pause()
                    try expect(set, "preferredDisplayCriteria not kept")
                    try expect(offered, "no shouldPresent content proposal callback (played to \(String(format: "%.2f", t)) s, item \(item.status.rawValue) \(String(describing: item.error)), rate \(player.rate), control \(player.timeControlStatus.rawValue) \(String(describing: player.reasonForWaitingToPlay?.rawValue)), duration \(item.duration.seconds))")
                    return "proposal '\(d.offered[0])' at \(String(format: "%.2f", t)) s; matching enabled \(dm.isDisplayCriteriaMatchingEnabled), switching \(dm.isDisplayModeSwitchInProgress)"
                }
            }
        })
        c.append(check("TVServices", "user-manager") {
            let m = TVUserManager()
            return "shouldStorePreferencesForCurrentUser \(m.shouldStorePreferencesForCurrentUser)"
        })
        c.append(check("Speech", "speech-transcriber-assets", timeout: 60) {
            // the SpeechAnalyzer modules tvOS has (SFSpeechRecognizer is iOS-only): availability, locales, asset status
            let ok = SpeechTranscriber.isAvailable
            let locs = await SpeechTranscriber.supportedLocales
            let inst = await SpeechTranscriber.installedLocales
            let t = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .transcription)
            let st = await AssetInventory.status(forModules: [t])
            let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t])
            let det = SpeechDetector()
            let dfmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [det])
            return "available \(ok), \(locs.count) supported / \(inst.count) installed locales, en-US assets \(st), format \(fmt.map { "\($0.sampleRate) Hz" } ?? "nil"), detector \(dfmt.map { "\($0.sampleRate) Hz" } ?? "nil")"
        })
        c.append(check("CoreMIDI", "event-list-ump") {
            // tvOS has CoreMIDI's message API (no MIDI client or endpoints): build a UMP event list, parse it back
            var el = MIDIEventList()
            var pkt = MIDIEventListInit(&el, ._2_0)
            var on1 = MIDI1UPNoteOn(0, 3, 60, 100)
            pkt = MIDIEventListAdd(&el, MemoryLayout<MIDIEventList>.size, pkt, 10, 1, &on1)
            var on2 = MIDI2NoteOn(1, 5, 64, 0, 0, 0x8000)
            let w2 = withUnsafeBytes(of: &on2) { Array($0.bindMemory(to: UInt32.self)) }
            var words = [w2[0], w2[1]]
            pkt = MIDIEventListAdd(&el, MemoryLayout<MIDIEventList>.size, pkt, 20, 2, &words)
            try expect(el.numPackets >= 1, "packets \(el.numPackets)")
            final class Box { var got: [String] = [] }
            let box = Box()
            MIDIEventListForEachEvent(&el, { ctx, ts, msg in
                let b = Unmanaged<Box>.fromOpaque(ctx!).takeUnretainedValue()
                switch msg.type.rawValue {
                case 2: b.got.append("t\(ts) cv1 g\(msg.group) ch\(msg.channelVoice1.channel) st \(msg.channelVoice1.status.rawValue) n\(msg.channelVoice1.note.number)")
                case 4: b.got.append("t\(ts) cv2 g\(msg.group) ch\(msg.channelVoice2.channel) st \(msg.channelVoice2.status.rawValue) n\(msg.channelVoice2.note.number)")
                default: b.got.append("type \(msg.type.rawValue)")
                }
            }, Unmanaged.passUnretained(box).toOpaque())
            try expect(box.got.count == 2, "parsed \(box.got)")
            try expect(box.got[0].contains("g0 ch3") && box.got[0].hasSuffix("n60") && box.got[1].contains("g1 ch5") && box.got[1].hasSuffix("n64"), "parsed \(box.got)")
            return box.got.joined(separator: "; ")
        })
        c.append(check("WeatherKit", "service-answers", timeout: 40) {
            // WeatherKit needs a team-signed WeatherKit entitlement and its auth service: the tvOS simulator runtime
            // ships WeatherDaemon.framework but no launchd job for com.apple.weatherkit.authservice, so on Apple's
            // simulator too the request ends in xpcConnectionFailed. The service must answer, data or error, not hang
            let r: String? = try await tvWithin(30) {
                do {
                    let cur = try await WeatherService.shared.weather(for: CLLocation(latitude: 37.33, longitude: -122.01), including: .current)
                    return "current \(cur.temperature)"
                } catch { return "error \(type(of: error)): \(String(describing: error).prefix(120))" }
            }
            guard let r else { throw Fail("no answer from WeatherService in 30 s") }
            if r.contains("xpcConnectionFailed") && r.contains("weatherkit.auth") {
                throw Skip("WeatherKit's auth service (com.apple.weatherkit.authservice) has no launchd job in the tvOS simulator runtime: \(r.prefix(60))")
            }
            return r
        })
        c.append(check("ExtensionFoundation", "extension-point-monitor", timeout: 30) {
            let mon = AppExtensionPoint.Monitor()
            try expect(mon.identities.isEmpty, "a new monitor has \(mon.identities.count) identities")
            var e = "no error"
            do { _ = try AppExtensionPoint(identifier: "com.x86sim.test.sdkcov.no-such-point") } catch { e = "\(type(of: error)) \(error)" }
            return "monitor empty; unknown point: \(e.prefix(100))"
        })
        c.append(check("DeveloperToolsSupport", "design-time-values-library") {
            let i: Int = DeveloperToolsSupport.__designTimeInteger("#sdkcov.1", fallback: 42)
            let bo: Bool = DeveloperToolsSupport.__designTimeBoolean("#sdkcov.2", fallback: true)
            try expect(i == 42 && bo, "design-time fallbacks \(i) \(bo)")
            let items = [LibraryItem(Text("sdkcov"), title: "sdkcov text", category: .control)]
            return "fallbacks ok, \(items.count) library item"
        })
        c.append(check("AppIntentsTypeSupport", "value-containers") {
            let ex = [3, 4].makeExpression(), _ = "x86sim".makeExpression(), _ = Date(timeIntervalSince1970: 0).makeExpression()
            _ = ex
            let a = AttributedTypeIdentifier(persistentIdentifier: "SDKCovEntity", bundleIdentifier: "com.x86sim.test.sdkcov")
            let e1 = AttributedEntityIdentifier(entityType: a, instanceIdentifier: "1"), e2 = AttributedEntityIdentifier(entityType: a, instanceIdentifier: "2")
            try expect(e1 != e2 && e1 == AttributedEntityIdentifier(entityType: a, instanceIdentifier: "1"), "identifiers")
            return "expressions made"
        })
        c.append(check("libAppleEXR", "imageio-openexr-roundtrip") {
            // ImageIO's OpenEXR codec is libAppleEXR: a 64x64 half-float image written and read back
            let ctx = bitmap(64, 64)
            ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 64))
            ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1); ctx.fill(CGRect(x: 32, y: 0, width: 32, height: 64))
            let img = ctx.makeImage()!
            let d = NSMutableData()
            guard let dst = CGImageDestinationCreateWithData(d, UTType.exr.identifier as CFString, 1, nil) else { throw Fail("no OpenEXR encoder") }
            CGImageDestinationAddImage(dst, img, nil)
            try expect(CGImageDestinationFinalize(dst), "finalize")
            guard let src = CGImageSourceCreateWithData(d, nil), let back = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw Fail("decode") }
            try expect(CGImageSourceGetType(src) as String? == UTType.exr.identifier, "type \(String(describing: CGImageSourceGetType(src)))")
            let rd = bitmap(64, 64); rd.draw(back, in: CGRect(x: 0, y: 0, width: 64, height: 64))
            let l = pixel(rd, 8, 32), r = pixel(rd, 56, 32)
            try expect(back.width == 64 && l[0] > 200 && l[2] < 40 && r[2] > 200 && r[0] < 40, "\(back.width)x\(back.height) \(back.bitsPerComponent) bpc, left \(l) right \(r)")
            return "\(d.length) B EXR, \(back.bitsPerComponent) bpc"
        })
        c.append(check("SecurityUI", "certificate-sheet", timeout: 30) {
            // .certificateSheet shows a sheet with the trust's certificate when the binding gets a SecTrust
            guard let der = Data(base64Encoded: tvTestCertB64), let cert = SecCertificateCreateWithData(nil, der as CFData) else { throw Fail("certificate") }
            var tr: SecTrust?
            try expect(SecTrustCreateWithCertificates(cert, SecPolicyCreateBasicX509(), &tr) == errSecSuccess, "trust")
            let summary = SecCertificateCopySubjectSummary(cert) as String?
            return try await tvMain { () async throws -> String in
                let hc = UIHostingController(rootView: TVCertSheetView(initial: tr!))
                return try await tvWithWindow(hc) { w in
                    let up = await tvUntil(10) { hc.presentedViewController != nil }
                    let p = hc.presentedViewController
                    p?.dismiss(animated: false)
                    _ = await tvUntil(3) { hc.presentedViewController == nil }
                    try expect(up, "no sheet presented")
                    return "sheet \(p.map { "\(type(of: $0))" } ?? "-") for '\(summary ?? "?")'"
                }
            }
        })
        c.append(check("_AuthenticationServices_SwiftUI", "sign-in-with-apple-button", timeout: 30) {
            try await tvMain { () async throws -> String in
                let v = SignInWithAppleButton(.continue, onRequest: { $0.requestedScopes = [.email] }, onCompletion: { _ in })
                    .signInWithAppleButtonStyle(.white).frame(width: 400, height: 80)
                return try await tvHost(v, secs: 1) { hc in
                    let names = tvSubviews(hc.view).map { "\(type(of: $0))" }
                    try expect(names.contains(where: { $0.contains("ASAuthorizationAppleIDButton") }), "no ASAuthorizationAppleIDButton in \(names.count) views")
                    return "\(names.count) views"
                }
            }
        })
        c.append(check("_StoreKit_SwiftUI", "product-store-views", timeout: 40) {
            // no StoreKit configuration or App Store account: the views show their unavailable state, no crash
            try await tvMain { () async throws -> String in
                let v = VStack { ProductView(id: "com.x86sim.test.sdkcov.none"); StoreView(ids: ["com.x86sim.test.sdkcov.none"]) }
                return try await tvHost(v, secs: 3) { hc in
                    let n = tvSubviews(hc.view).count
                    try expect(n > 1, "\(n) views")
                    return "\(n) views"
                }
            }
        })
        #if canImport(AppIntents)
        c.append(check("_AppIntents_SwiftUI", "siri-tip-view", timeout: 30) {
            try await tvMain { () async throws -> String in
                var visible = true
                let v = SiriTipView(intent: SDKCovIntent(), isVisible: Binding(get: { visible }, set: { visible = $0 })).siriTipViewStyle(.dark)
                return try await tvHost(v.frame(width: 800, height: 200), secs: 1) { hc in
                    "\(tvSubviews(hc.view).count) views, visible \(visible)"
                }
            }
        })
        #endif
        c.append(check("_AppIntents_UIKit", "collection-view-data-source") {
            try await onMain {
                let cv = UICollectionView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), collectionViewLayout: UICollectionViewFlowLayout())
                let ds = TVIntentsDS()
                cv.appIntentsDataSource = ds
                try expect(cv.appIntentsDataSource === ds, "data source not kept")
                let tv = UITableView(); tv.appIntentsDataSource = nil
                return "kept"
            }
        })
        #endif
        return c
    }
}
#else
extension Registry {
    static var more_tvos: [Check] { [] }
}
#endif
