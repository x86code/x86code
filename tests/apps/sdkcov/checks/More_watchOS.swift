// sdkcov functional checks added by the watchOS coverage round: frameworks and APIs the shared groups don't reach yet.
// Only built into the watchOS app (#if os(watchOS)); checks shared with other platforms belong in the group files.
import Foundation
#if os(watchOS)
import SwiftUI
import WatchKit
import ClockKit
import HealthKit
import UserNotifications
import WidgetKit
import RelevanceKit
import CoreLocation
import CoreLocationUI
import SafetyKit
import StateReporting
import WorkoutKit
import NowPlaying
import _WatchKit_SwiftUI
import _ClockKit_SwiftUI
import PhotosUI
import _PhotosUI_SwiftUI
import _CoreLocationUI_SwiftUI
import CryptoTokenKit
import StoreKit

// MARK: delegates (WatchKit / HealthKit / UserNotifications report through delegate objects)

/// records WKExtendedRuntimeSession callbacks
final class SDKCovRuntimeSessionDelegate: NSObject, WKExtendedRuntimeSessionDelegate {
    let lock = NSLock()
    var events: [String] = []
    var invalidated: (WKExtendedRuntimeSessionInvalidationReason, NSError?)?
    func extendedRuntimeSessionDidStart(_ s: WKExtendedRuntimeSession) { lock.withLock { events.append("start") } }
    func extendedRuntimeSessionWillExpire(_ s: WKExtendedRuntimeSession) { lock.withLock { events.append("expire") } }
    func extendedRuntimeSession(_ s: WKExtendedRuntimeSession, didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason, error: Error?) {
        lock.withLock { events.append("invalid \(reason.rawValue)"); invalidated = (reason, error as NSError?) }
    }
}

/// counts Digital Crown events that reach SDKCovCrownProbeView
final class SDKCovCrownProbe: @unchecked Sendable {
    let lock = NSLock()
    var events = 0, idle = 0, value = 0.0, focused = false
}

/// a focused view taking the crown (.digitalCrownRotation with onChange / onIdle), shown by the crown-sequencer check
struct SDKCovCrownProbeView: View {
    let p: SDKCovCrownProbe
    @State private var v = 0.0
    @FocusState private var f: Bool
    var body: some View {
        Text("turn the crown").frame(maxWidth: .infinity, maxHeight: .infinity)
            .focusable().focused($f)
            .digitalCrownRotation(detent: $v, from: -1000, through: 1000, by: 0.1, sensitivity: .medium, isContinuous: true,
                                  isHapticFeedbackEnabled: false,
                                  onChange: { e in p.lock.withLock { p.events += 1; p.value = e.offset } },
                                  onIdle: { p.lock.withLock { p.idle += 1 } })
            .onAppear { f = true }
            .onChange(of: f) { _, x in p.lock.withLock { p.focused = x } }
    }
}

/// records Digital Crown rotation delivered to the focused crown sequencer
final class SDKCovCrownDelegate: NSObject, WKCrownDelegate {
    let lock = NSLock()
    var total = 0.0, events = 0, idle = 0
    func crownDidRotate(_ cs: WKCrownSequencer?, rotationalDelta d: Double) { lock.withLock { total += d; events += 1 } }
    func crownDidBecomeIdle(_ cs: WKCrownSequencer?) { lock.withLock { idle += 1 } }
}

/// records HKWorkoutSession state changes / failures and live builder collections
final class SDKCovWorkoutDelegate: NSObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    let lock = NSLock()
    var states: [HKWorkoutSessionState] = []
    var error: NSError?
    var collected: Set<String> = []
    var events = 0
    func workoutSession(_ s: HKWorkoutSession, didChangeTo to: HKWorkoutSessionState, from: HKWorkoutSessionState, date: Date) { lock.withLock { states.append(to) } }
    func workoutSession(_ s: HKWorkoutSession, didFailWithError e: Error) { lock.withLock { error = e as NSError } }
    func workoutBuilder(_ b: HKLiveWorkoutBuilder, didCollectDataOf types: Set<HKSampleType>) { lock.withLock { collected.formUnion(types.map(\.identifier)) } }
    func workoutBuilderDidCollectEvent(_ b: HKLiveWorkoutBuilder) { lock.withLock { events += 1 } }
}

/// presents notifications while the app is frontmost and records which ones arrived
final class SDKCovNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    let lock = NSLock()
    var presented: [String] = []
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions {
        lock.withLock { presented.append(n.request.identifier) }
        return [.list, .banner, .sound]
    }
}

/// poll `cond` every 50 ms for up to `secs`
func watchWaitFor(_ secs: Double, _ cond: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(secs)
    while Date() < end { if cond() { return true }; try? await Task.sleep(for: .milliseconds(50)) }
    return cond()
}

/// fraction of sampled pixels (every 2nd) with alpha > 0 in an image
func watchInked(_ img: CGImage) -> Double {
    let ctx = bitmap(img.width, img.height); ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    var ink = 0, n = 0
    for y in stride(from: 0, to: img.height, by: 2) { for x in stride(from: 0, to: img.width, by: 2) { n += 1; if pixel(ctx, x, y)[3] > 0 { ink += 1 } } }
    return n == 0 ? 0 : Double(ink) / Double(n)
}

struct SDKCovNoMeta: ReportableMetadata {
    var metadataDictionary: [String: ReportableMetadataValue] { ["check": ReportableMetadataValue("sdkcov"), "n": ReportableMetadataValue(1)] }
}
#endif

extension Registry {
    static var more_watchos: [Check] {
        var c: [Check] = []
        #if os(watchOS)
        // MARK: WatchKit
        c.append(check("WatchKit", "device-traits-haptics") {
            try await onMain {
                let d = WKInterfaceDevice.current()
                // every haptic type plays (the simulator has no Taptic Engine: a no-op there, but must not throw or crash)
                let all: [WKHapticType] = [.notification, .directionUp, .directionDown, .success, .failure, .retry, .start, .stop, .click,
                                           .underwaterDepthPrompt, .underwaterDepthCriticalPrompt]
                for h in all { d.play(h) }
                try expect(!d.preferredContentSizeCategory.isEmpty, "content size category")
                let v1 = d.identifierForVendor, v2 = WKInterfaceDevice.current().identifierForVendor
                try expect(v1 != nil && v1 == v2, "identifierForVendor \(String(describing: v1)) vs \(String(describing: v2))")
                let rtl = WKInterfaceDevice.interfaceLayoutDirection(for: .forceRightToLeft)
                try expect(rtl == .rightToLeft && WKInterfaceDevice.interfaceLayoutDirection(for: .forceLeftToRight) == .leftToRight, "semantic layout \(rtl.rawValue)")
                d.isBatteryMonitoringEnabled = true
                let batt = "battery \(d.batteryState.rawValue) \(d.batteryLevel)"
                d.isBatteryMonitoringEnabled = false
                try expect(d.screenBounds.width * d.screenScale > 300 && d.screenScale == 2, "screen \(d.screenBounds) @\(d.screenScale)")
                return "\(all.count) haptics, layout \(d.layoutDirection.rawValue), crown \(d.crownOrientation.rawValue), water \(d.waterResistanceRating.rawValue), audio streaming \(d.supportsAudioStreaming), \(batt), \(d.preferredContentSizeCategory)"
            }
        })
        c.append(check("WatchKit", "application-state-controllers") {
            try await onMain {
                let a = WKApplication.shared()
                let st = a.applicationState
                let root = a.rootInterfaceController.map { String(describing: type(of: $0)) } ?? "nil"
                let tint = a.globalTintColor
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, al: CGFloat = 0
                tint.getRed(&r, green: &g, blue: &b, alpha: &al)
                // active, or inactive while a system alert covers it (an earlier check's permission prompt): never background
                try expect(st != .background, "applicationState \(st.rawValue) (0 active, 1 inactive, 2 background) for the frontmost app")
                return "state \(st.rawValue), root \(root), dock \(a.isApplicationRunningInDock), autorotated \(a.isAutorotated), tint alpha \(al)"
            }
        })
        c.append(check("WatchKit", "background-refresh-schedule", timeout: 20) {
            // the app-refresh budget lives in Carousel / dasd; the scheduled-completion fires once it accepted the request
            let e1: Error? = await withCheckedContinuation { k in
                DispatchQueue.main.async {
                    WKApplication.shared().scheduleBackgroundRefresh(withPreferredDate: Date().addingTimeInterval(3600), userInfo: ["sdkcov": 1] as NSDictionary) { k.resume(returning: $0) }
                }
            }
            try expect(e1 == nil, "background refresh: \(String(describing: e1))")
            let e2: Error? = await withCheckedContinuation { k in
                DispatchQueue.main.async {
                    WKApplication.shared().scheduleSnapshotRefresh(withPreferredDate: Date().addingTimeInterval(3600), userInfo: nil) { k.resume(returning: $0) }
                }
            }
            try expect(e2 == nil, "snapshot refresh: \(String(describing: e2))")
            return "background + snapshot refresh scheduled"
        })
        c.append(check("WatchKit", "extended-runtime-session", timeout: 30) {
            // a session needs WKBackgroundModes (self-care, mindfulness, physical-therapy, smart-alarm) in Info.plist and a
            // frontmost app; without the key watchOS refuses it (WKExtendedRuntimeSessionErrorNotApprovedToStartSession 7)
            let modes = Bundle.main.object(forInfoDictionaryKey: "WKBackgroundModes") as? [String] ?? []
            let d = SDKCovRuntimeSessionDelegate()
            let s = await onMain { () -> WKExtendedRuntimeSession in let s = WKExtendedRuntimeSession(); s.delegate = d; s.start(); return s }
            _ = await watchWaitFor(10) { d.lock.withLock { !d.events.isEmpty } }
            let ev = d.lock.withLock { d.events }, inv = d.lock.withLock { d.invalidated }
            let auto: String = await withCheckedContinuation { k in
                WKExtendedRuntimeSession.requestAutoLaunchAuthorizationStatus { st, e in k.resume(returning: "auto-launch \(st.rawValue)\(e.map { " (\(($0 as NSError).code))" } ?? "")") }
            }
            if modes.isEmpty {
                guard let inv else { throw Fail("no WKBackgroundModes: expected an invalidation, got \(ev) state \(s.state.rawValue)") }
                try expect(inv.0 == .error && inv.1?.domain == WKExtendedRuntimeSessionErrorDomain, "invalidated \(inv.0.rawValue) \(String(describing: inv.1))")
                return "no WKBackgroundModes: refused, error \(inv.1!.code) (7 = not approved), \(auto)"
            }
            try expect(ev.first == "start" && s.state == .running, "\(modes): events \(ev), state \(s.state.rawValue), error \(String(describing: inv?.1))")
            let exp = s.expirationDate.map { Int($0.timeIntervalSinceNow) } ?? -1
            await onMain { s.invalidate() }
            _ = await watchWaitFor(5) { d.lock.withLock { d.invalidated != nil } }
            try expect(d.lock.withLock { d.invalidated?.0 } == WKExtendedRuntimeSessionInvalidationReason.none, "invalidate: \(d.lock.withLock { d.events })")
            return "\(modes.joined(separator: ",")): ran, expires in \(exp) s, invalidated; \(auto)"
        })
        c.append(check("WatchKit", "crown-sequencer", timeout: 60) {
            // SDKCOV_CROWN_WAIT=<s> (launch --env): wait that long for Digital Crown input (`x86sim crown 120 5` meanwhile)
            // and require it to arrive in the app; without it only the sequencer's state is checked.
            // In a SwiftUI app the crown goes to SwiftUI's crown focus (the focused .digitalCrownRotation view, else the
            // scroll view), never to rootInterfaceController's WKCrownSequencer: on Apple's watchOS 27.2 simulator that
            // delegate gets nothing while backboardd routes the scroll events to the app and its scroll view turns. So the
            // input part puts a focused .digitalCrownRotation view on screen (Runner.overlay) and counts its events.
            let wait = Double(ProcessInfo.processInfo.environment["SDKCOV_CROWN_WAIT"] ?? "") ?? 0
            let d = SDKCovCrownDelegate()
            let cs = try await onMain { () -> WKCrownSequencer in
                // a SwiftUI app's root is a hosting interface controller once its scene connected
                guard let root = WKApplication.shared().rootInterfaceController else { throw Fail("no root interface controller") }
                let cs = root.crownSequencer; cs.delegate = d; cs.focus(); return cs
            }
            let st = await onMain { "idle \(cs.isIdle), haptics \(cs.isHapticFeedbackEnabled), rps \(cs.rotationsPerSecond)" }
            await onMain { cs.resignFocus(); cs.delegate = nil }
            guard wait > 0 else { return st }
            let probe = SDKCovCrownProbe()
            await onMain { Runner.shared.overlay = AnyView(SDKCovCrownProbeView(p: probe)) }
            defer { Task { @MainActor in Runner.shared.overlay = nil } }
            let ok = await watchWaitFor(wait) { probe.lock.withLock { probe.events > 0 && probe.idle > 0 } }
            let (n, v, idle, focused) = probe.lock.withLock { (probe.events, probe.value, probe.idle, probe.focused) }
            try expect(ok, "no crown input in \(Int(wait)) s: \(n) rotation events, \(idle) idle, view focused \(focused)")
            return st + ", crown: \(n) rotation events in SwiftUI, value \(String(format: "%.3f", v)), idle \(idle)"
        })
        c.append(check("_WatchKit_SwiftUI", "now-playing-view") {
            try await onMain {
                let r = ImageRenderer(content: NowPlayingView().frame(width: 200, height: 240)); r.scale = 1
                // the view hosts the system Now Playing remote UI: no pixels offscreen, but it builds
                return r.cgImage.map { "renders \($0.width)x\($0.height)" } ?? "built (remote view: no offscreen image)"
            }
        })

        // MARK: SwiftUI on watch: the watch-specific controls and modifiers render offscreen
        c.append(check("SwiftUI", "watch-gauges-crown-modifier") {
            try await onMain {
                struct V: View {
                    @State var crown = 0.4
                    var body: some View {
                        HStack(spacing: 0) {
                            Gauge(value: 0.75) { Text("x") }.gaugeStyle(.accessoryCircularCapacity).tint(Color(red: 0, green: 1, blue: 0)).frame(width: 60, height: 60)
                            ProgressView(value: 0.5).progressViewStyle(.circular).frame(width: 60, height: 60)
                        }
                        .focusable()
                        .digitalCrownRotation($crown, from: 0, through: 1, by: 0.1, sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true)
                    }
                }
                let r = ImageRenderer(content: V().frame(width: 120, height: 60).background(Color.black)); r.scale = 2
                guard let img = r.cgImage else { throw Fail("no image") }
                let ctx = bitmap(img.width, img.height); ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
                var green = 0
                for y in stride(from: 0, to: img.height, by: 2) { for x in stride(from: 0, to: img.width / 2, by: 2) { let p = pixel(ctx, x, y); if p[1] > 150 && p[0] < 100 { green += 1 } } }
                try expect(green > 20, "capacity gauge drew \(green) green samples")
                return "\(img.width)x\(img.height), \(green) gauge samples"
            }
        })

        // MARK: HealthKit: healthd round trips without authorization, and a workout session
        c.append(check("HealthKit", "healthd-queries-save", timeout: 30) {
            try skipIf(!HKHealthStore.isHealthDataAvailable(), "health data not available")
            let st = HKHealthStore()
            let hr = HKQuantityType(.heartRate), steps = HKQuantityType(.stepCount)
            let req = try await st.statusForAuthorizationRequest(toShare: [steps], read: [hr, steps])
            let q = HKSampleQueryDescriptor(predicates: [.quantitySample(type: hr)], sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)], limit: 5)
            // a query of a type never asked for fails "Authorization not determined" (HKError 5), as on Apple's; asked: no samples
            func hkCode(_ e: Error) -> Int? { let n = e as NSError; return n.domain == HKErrorDomain ? n.code : nil }
            var got = "?"
            do { got = "\(try await q.result(for: st).count) samples" } catch {
                try expect([4, 5].contains(hkCode(error) ?? 0), "heart-rate query: \(error)"); got = "query error \(hkCode(error)!)"
            }
            var stats = "?"
            do { stats = "\(try await HKStatisticsQueryDescriptor(predicate: .quantitySample(type: steps), options: .cumulativeSum).result(for: st)?.sumQuantity()?.doubleValue(for: .count()) ?? 0)" } catch {
                try expect([4, 5].contains(hkCode(error) ?? 0), "statistics query: \(error)"); stats = "error \(hkCode(error)!)"
            }
            // a write without share authorization is refused by healthd
            let s = HKQuantitySample(type: steps, quantity: HKQuantity(unit: .count(), doubleValue: 10), start: Date().addingTimeInterval(-60), end: .now)
            var saveErr = "saved"
            do { try await st.save(s) } catch let e as NSError { saveErr = "\(e.domain) \(e.code)" }
            let shareSt = st.authorizationStatus(for: steps)
            if shareSt != .sharingAuthorized {
                try expect(saveErr.hasPrefix(HKErrorDomain), "save without authorization: \(saveErr)")
            }
            return "request status \(req.rawValue), heart rate \(got), steps sum \(stats), save \(saveErr), share \(shareSt.rawValue)"
        })
        c.append(check("HealthKit", "workout-session-live-builder", timeout: 40) {
            // The simulator runs workout sessions and their live builders. Saving needs the user's Health authorization
            // (workouts + the collected types): to get the whole path, answer sdkcov's Health sheet once on the device
            // (requestAuthorization: Review, both "All Requested Data", Next / Continue, a data range, Done). Without it the
            // session still runs, but healthd fails the builder (it cannot save): beginCollection then fails with HKError 3
            // ("already started", the builder's failed state) or 4 ("Not authorized").
            try skipIf(!HKHealthStore.isHealthDataAvailable(), "health data not available")
            let st = HKHealthStore()
            // a session a previous (killed) run left active: recover and end it, as an app does at launch
            var recovered = ""
            if let old = try? await st.recoverActiveWorkoutSession() { recovered = ", ended a recovered session"; old.end() }
            let cfg = HKWorkoutConfiguration(); cfg.activityType = .running; cfg.locationType = .outdoor
            let s = try HKWorkoutSession(healthStore: st, configuration: cfg)
            let b = s.associatedWorkoutBuilder()
            let d = SDKCovWorkoutDelegate(); s.delegate = d; b.delegate = d
            b.dataSource = HKLiveWorkoutDataSource(healthStore: st, workoutConfiguration: cfg)
            try expect(b.dataSource?.typesToCollect.contains(HKQuantityType(.heartRate)) == true, "data source types \(String(describing: b.dataSource?.typesToCollect))")
            let shared = st.authorizationStatus(for: .workoutType())
            // Apple's sequence (WWDC "Build a workout app"): start the session, then begin the builder's collection at the same date
            let start = Date()
            s.prepare()
            s.startActivity(with: start)
            var beginErr: NSError?
            do { try await b.beginCollection(at: start) } catch { beginErr = error as NSError }
            _ = await watchWaitFor(15) { d.lock.withLock { d.states.contains(.running) || d.error != nil } }
            let (states, err) = d.lock.withLock { (d.states, d.error) }
            try expect(err == nil && states.contains(.running) && s.state == .running, "session: states \(states.map(\.rawValue)), state \(s.state.rawValue), error \(String(describing: err))")
            guard shared == .sharingAuthorized else {
                s.end()
                try expect(beginErr?.domain == HKErrorDomain && [3, 4].contains(beginErr!.code), "unauthorized builder: \(String(describing: beginErr))")
                return "session ran; workouts not authorized (answer the Health sheet once for the builder path): builder refused \(beginErr!.code)\(recovered)"
            }
            if let beginErr { throw Fail("beginCollection: \(beginErr)") }
            try expect(b.startDate != nil, "builder start date")
            _ = await watchWaitFor(10) { d.lock.withLock { !d.collected.isEmpty } }
            s.stopActivity(with: .now)
            s.end()
            try await b.endCollection(at: .now)
            guard let w = try await b.finishWorkout() else { throw Fail("finishWorkout returned no workout") }
            let col = d.lock.withLock { d.collected }
            try expect(!col.isEmpty, "the live data source collected nothing")
            // the saved workout reads back
            let q = HKSampleQueryDescriptor(predicates: [.workout(HKQuery.predicateForObject(with: w.uuid))], sortDescriptors: [], limit: 1)
            let back = try await q.result(for: st)
            try expect(back.first?.workoutActivityType == .running, "saved workout read back: \(back)")
            return "collected \(col.sorted().map { $0.replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "") }), workout \(String(format: "%.1f", w.duration)) s saved\(recovered)"
        })

        // MARK: ClockKit (deprecated, still shipped): templates, providers, descriptors; and its SwiftUI overlay
        c.append(check("ClockKit", "templates-providers-descriptors") {
            let now = Date()
            let line1 = CLKSimpleTextProvider(text: "x86sim", shortText: "x86")
            let t1 = CLKComplicationTemplateGraphicCircularStackText(line1TextProvider: line1, line2TextProvider: CLKTimeTextProvider(date: now))
            let t2 = CLKComplicationTemplateModularLargeStandardBody(headerTextProvider: CLKDateTextProvider(date: now, units: [.weekday, .day]),
                                                                    body1TextProvider: CLKRelativeDateTextProvider(date: now.addingTimeInterval(600), style: .timer, units: [.minute, .second]),
                                                                    body2TextProvider: CLKTimeIntervalTextProvider(start: now, end: now.addingTimeInterval(3600)))
            let gauge = CLKSimpleGaugeProvider(style: .fill, gaugeColor: .green, fillFraction: 0.5)
            let t3 = CLKComplicationTemplateGraphicCornerGaugeText(gaugeProvider: gauge, outerTextProvider: line1)
            let e = CLKComplicationTimelineEntry(date: now, complicationTemplate: t1)
            try expect(e.complicationTemplate.isKind(of: CLKComplicationTemplateGraphicCircularStackText.self), "entry template \(e.complicationTemplate)")
            try expect(t2.headerTextProvider is CLKDateTextProvider, "header provider \(t2.headerTextProvider)")
            try expect(t3.gaugeProvider.style == .fill && (t3.gaugeProvider as? CLKSimpleGaugeProvider)?.fillFraction == 0.5, "gauge \(t3.gaugeProvider)")
            let fams = CLKComplicationFamily.allCases
            let desc = CLKComplicationDescriptor(identifier: "sdkcov", displayName: "sdkcov", supportedFamilies: fams)
            try expect(desc.supportedFamilies.count == fams.count && desc.identifier == "sdkcov", "descriptor")
            // archived like ClockKit sends templates to the face
            let a = try NSKeyedArchiver.archivedData(withRootObject: t2, requiringSecureCoding: true)
            let back = try NSKeyedUnarchiver.unarchivedObject(ofClasses: [CLKComplicationTemplateModularLargeStandardBody.self], from: a) as? CLKComplicationTemplateModularLargeStandardBody
            try expect(back?.body1TextProvider is CLKRelativeDateTextProvider, "template archive round trip")
            CLKComplicationServer.sharedInstance().reloadComplicationDescriptors()
            return "\(fams.count) families, template archive \(a.count) B"
        })
        c.append(check("_ClockKit_SwiftUI", "graphic-view-templates") {
            try await onMain {
                let v = Gauge(value: 0.5) { Text("x") }.gaugeStyle(.accessoryCircular)
                let t = CLKComplicationTemplateGraphicCircularView(v)
                let r = CLKComplicationTemplateGraphicRectangularFullView(Text("x86sim"))
                try expect(t.isKind(of: CLKComplicationTemplate.self) && r.isKind(of: CLKComplicationTemplate.self), "templates")
                return "\(type(of: t)), \(type(of: r))"
            }
        })

        // MARK: WidgetKit + RelevanceKit: watch Smart Stack relevance and accessory rendering
        c.append(check("RelevanceKit", "contexts-widget-relevance") {
            let now = Date()
            let ctxs: [RelevantContext] = [.date(now), .date(interval: DateInterval(start: now, duration: 3600), kind: .scheduled),
                                           .date(range: now...now.addingTimeInterval(60), kind: .informational),
                                           .location(CLCircularRegion(center: CLLocationCoordinate2D(latitude: 37.33, longitude: -122.0), radius: 100, identifier: "sdkcov")),
                                           .location(inferred: .home), .sleep(.bedtime), .fitness(.workoutActive), .hardware(headphones: .connected)]
            let rel = WidgetRelevance<Void>(ctxs.map { WidgetRelevanceAttribute(context: $0) } + [WidgetRelevanceAttribute(group: .named("sdkcov"))])
            _ = rel
            WidgetCenter.shared.invalidateRelevance(ofKind: "sdkcov")
            let cur = try await WidgetCenter.shared.currentConfigurations()
            return "\(ctxs.count) contexts, \(cur.count) configured widgets"
        })
        c.append(check("WidgetKit", "accessory-background-render") {
            try await onMain {
                let v = ZStack { AccessoryWidgetBackground(); Text("42").font(.title) }.frame(width: 80, height: 80).clipShape(Circle())
                let r = ImageRenderer(content: v); r.scale = 2
                guard let img = r.cgImage else { throw Fail("no image") }
                let f = watchInked(img)
                try expect(f > 0.3, "accessory background inked \(f)")
                return "\(img.width)x\(img.height), \(Int(f * 100))% inked"
            }
        })

        // MARK: UserNotifications: provisional authorization (no prompt) and a local notification delivered to the app
        c.append(check("UserNotifications", "provisional-deliver-local", timeout: 40) {
            let c = UNUserNotificationCenter.current()
            let granted = try await c.requestAuthorization(options: [.alert, .sound, .badge, .provisional])
            let st = await c.notificationSettings()
            try expect(granted && (st.authorizationStatus == .provisional || st.authorizationStatus == .authorized),
                       "provisional authorization: granted \(granted), status \(st.authorizationStatus.rawValue)")
            let d = SDKCovNotificationDelegate()
            let old = c.delegate; c.delegate = d
            defer { c.delegate = old }
            let ct = UNMutableNotificationContent(); ct.title = "sdkcov"; ct.body = "watch local notification"; ct.threadIdentifier = "sdkcov"
            ct.userInfo = ["n": 1]
            let id = "sdkcov-deliver-\(Int(Date().timeIntervalSince1970))"
            try await c.add(UNNotificationRequest(identifier: id, content: ct, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)))
            let came = await watchWaitFor(20) { d.lock.withLock { d.presented.contains(id) } }
            let pending = await c.pendingNotificationRequests().map(\.identifier)
            try expect(came, "willPresent never called for \(id) (status \(st.authorizationStatus.rawValue)); pending \(pending)")
            var delivered: [UNNotification] = []
            for _ in 0..<20 { delivered = await c.deliveredNotifications(); if delivered.contains(where: { $0.request.identifier == id }) { break }; try await Task.sleep(for: .milliseconds(250)) }
            let n = delivered.first { $0.request.identifier == id }
            c.removeDeliveredNotifications(withIdentifiers: [id])
            try expect(n?.request.content.title == "sdkcov" && (n?.request.content.userInfo["n"] as? Int) == 1, "delivered list \(delivered.map(\.request.identifier))")
            return "status \(st.authorizationStatus.rawValue), presented and delivered"
        })

        // MARK: other watch frameworks
        c.append(check("WorkoutKit", "scheduler") {
            try skipIf(!WorkoutScheduler.isSupported, "WorkoutScheduler not supported")
            let s = WorkoutScheduler.shared
            let auth = await s.authorizationState
            let n = await s.scheduledWorkouts.count
            return "authorization \(auth), \(n) scheduled, max \(WorkoutScheduler.maxAllowedScheduledWorkoutCount)"
        })
        c.append(check("SafetyKit", "crash-detection") {
            // every SACrashDetectionManager call (even +isAvailable) raises without Apple's Crash Detection entitlement, which
            // only Apple grants (a team-signed app): not something an ad-hoc simulator build can have
            throw Skip("SafetyKit needs Apple's com.apple.developer.safety-kit entitlement (+isAvailable raises without it, as on Apple's)")
        })
        c.append(check("StateReporting", "reporter-transitions") {
            let r = StateReporter<SDKCovNoMeta, SDKCovNoMeta>.reporter(for: "com.x86sim.test.sdkcov", stableMetadata: SDKCovNoMeta.self, volatileMetadata: SDKCovNoMeta.self)
            try expect(r.domain == "com.x86sim.test.sdkcov", "domain \(r.domain)")
            r.reportTransition(to: "running", stableMetadata: SDKCovNoMeta(), volatileMetadata: SDKCovNoMeta())
            r.reportVolatileMetadataUpdate(SDKCovNoMeta())
            r.reportTransition(to: nil)
            let v = ReportableMetadataValue(42)
            let back = try JSONDecoder().decode(ReportableMetadataValue.self, from: JSONEncoder().encode(v))
            try expect(back == v, "metadata value codable")
            return "ok"
        })
        c.append(check("CoreLocationUI", "location-button-render") {
            try await onMain {
                let v = LocationButton(.currentLocation) {}.labelStyle(.titleAndIcon).tint(.blue)
                let r = ImageRenderer(content: v.frame(width: 180, height: 50)); r.scale = 2
                guard let img = r.cgImage else { throw Fail("no image") }
                return "\(img.width)x\(img.height), \(Int(watchInked(img) * 100))% inked"
            }
        })
        c.append(check("PhotosUI", "photos-picker-view") {
            try await onMain {
                struct V: View {
                    @State var sel: [PhotosPickerItem] = []
                    var body: some View { PhotosPicker(selection: $sel, maxSelectionCount: 2, matching: .images) { Text("Pick").foregroundColor(.white) }.background(Color.blue) }
                }
                let r = ImageRenderer(content: V().frame(width: 120, height: 40)); r.scale = 1
                guard let img = r.cgImage else { throw Fail("no image") }
                return "\(img.width)x\(img.height), \(Int(watchInked(img) * 100))% inked"
            }
        })
        // MARK: system services Apple's simulator answers without an account (checked against Apple's watchOS 27.2 24S118
        // simulator, ref-mac.sh watchos: before x86Sim ran ctkd, syncdefaultsd, accountsd and amsaccountsd these came back
        // empty / false / nil while the shared checks still passed)
        c.append(check("CryptoTokenKit", "secure-element-tokens") {
            // ctkd's secelemtoken extension publishes the Secure Enclave tokens
            let ids = TKTokenWatcher().tokenIDs
            try expect(ids.contains("com.apple.setoken"), "token ids \(ids) (Apple's: com.apple.setoken, com.apple.setoken:aks)")
            return ids.joined(separator: ", ")
        })
        c.append(check("Foundation", "kvstore-synchronize") {
            // syncdefaultsd (com.apple.kvsd) accepts the store even with no iCloud account
            let kv = NSUbiquitousKeyValueStore.default; kv.set("x", forKey: "sdkcov-sync")
            let ok = kv.synchronize()
            try expect(ok, "synchronize() false (no com.apple.kvsd?)")
            return "synchronize true, \(kv.dictionaryRepresentation.count) keys"
        })
        c.append(check("StoreKit", "storefront-sandbox", timeout: 40) {
            // storekitd answers from the simulator's local App Store sandbox account (accountsd / amsaccountsd): USA
            let sf = await Storefront.current
            try expect(sf != nil && !(sf!.countryCode.isEmpty), "Storefront.current \(String(describing: sf)) (Apple's: USA 143441)")
            return "\(sf!.countryCode) \(sf!.id)"
        })
        c.append(check("libMobileGestalt", "answers-match-device") {
            typealias Copy = @convention(c) (CFString) -> Unmanaged<CFTypeRef>?
            let mg = try cfunc("libMobileGestalt", "MGCopyAnswer", Copy.self)
            func ans(_ k: String) -> Any? { mg(k as CFString)?.takeRetainedValue() }
            let env = ProcessInfo.processInfo.environment
            let cls = ans("DeviceClass") as? String, prod = ans("ProductType") as? String, ver = ans("ProductVersion") as? String
            try expect(cls == "Watch", "DeviceClass \(String(describing: cls))")
            if let want = env["SIMULATOR_MODEL_IDENTIFIER"] { try expect(prod == want, "ProductType \(String(describing: prod)) vs \(want)") }
            try expect(ver == WKInterfaceDevice.current().systemVersion, "ProductVersion \(String(describing: ver))")
            return "\(cls!) \(prod ?? "?") \(ver ?? "?") build \(ans("BuildVersion") as? String ?? "?")"
        })
        #endif
        return c
    }
}
