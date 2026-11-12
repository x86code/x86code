// sdkcov functional checks: system services. Hardware Apple's simulator does not have (cameras, NFC, UWB,
// Bluetooth radios, motion sensors, haptics, ARKit tracking) is reported SKIP when the framework itself says it is
// unavailable, as it does in Apple's simulator; the check fails only when the framework misbehaves.
import Foundation
import CoreLocation
#if canImport(MapKit)
import MapKit
#endif
#if canImport(HealthKit)
import HealthKit
#endif
#if canImport(HomeKit)
import HomeKit
#endif
import StoreKit
#if canImport(GameKit)
import GameKit
#endif
#if canImport(GameController)
import GameController
#endif
#if canImport(GameplayKit)
import GameplayKit
#endif
import AuthenticationServices
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
import DeviceCheck
#if canImport(AppTrackingTransparency)
import AppTrackingTransparency
#endif
#if canImport(AdSupport)
import AdSupport
#endif
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif
#if canImport(CoreBluetooth)
import CoreBluetooth
#endif
#if canImport(CoreMotion)
import CoreMotion
#endif
#if canImport(CoreHaptics)
import CoreHaptics
#endif
#if canImport(CoreNFC)
import CoreNFC
#endif
#if canImport(NearbyInteraction)
import NearbyInteraction
#endif
#if canImport(ARKit)
import ARKit
#endif
#if canImport(PassKit)
import PassKit
#endif
#if canImport(CallKit)
import CallKit
#endif
#if canImport(PushKit)
import PushKit
#endif
#if canImport(CoreTelephony)
import CoreTelephony
#endif
#if canImport(Intents)
import Intents
#endif
#if canImport(AppIntents)
import AppIntents
#endif
#if canImport(WidgetKit)
import WidgetKit
#endif
#if canImport(ActivityKit)
import ActivityKit
#endif
#if canImport(GroupActivities)
import GroupActivities
#endif
#if canImport(TipKit)
import TipKit
#endif
#if canImport(MultipeerConnectivity)
import MultipeerConnectivity
#endif
#if canImport(ExternalAccessory)
import ExternalAccessory
#endif
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif
#if canImport(MetricKit)
import MetricKit
#endif
#if canImport(ReplayKit)
import ReplayKit
#endif
#if canImport(SensitiveContentAnalysis)
import SensitiveContentAnalysis
#endif
#if canImport(SharedWithYou)
import SharedWithYou
#endif
#if canImport(LinkPresentation)
import LinkPresentation
#endif
#if canImport(IdentityLookup)
import IdentityLookup
#endif
#if canImport(Accounts)
import Accounts
#endif
#if canImport(CryptoTokenKit)
import CryptoTokenKit
#endif
#if canImport(AutomaticAssessmentConfiguration)
import AutomaticAssessmentConfiguration
#endif
#if canImport(VideoSubscriberAccount)
import VideoSubscriberAccount
#endif
#if canImport(NetworkExtension)
import NetworkExtension
#endif

#if canImport(AppIntents)
struct SDKCovIntent: AppIntent {
    static var title: LocalizedStringResource { "sdkcov probe" }
    var value = 0   // a plain property: @Parameter would clash with TipKit's @Parameter macro in this module
    init() {}
    init(value: Int) { self.value = value }
    func perform() async throws -> some IntentResult & ReturnsValue<Int> { .result(value: value * 2) }
}
#endif
#if canImport(TipKit)
struct SDKCovTip: Tip { var title: Text { Text("sdkcov") } }
import SwiftUI
#endif

extension Registry {
    static var services: [Check] {
        var c: [Check] = [
            check("CoreLocation", "manager-geometry-simulated-location", timeout: 30) {
                let m = await onMain { CLLocationManager() }
                let st = m.authorizationStatus
                let a = CLLocation(latitude: 37.3349, longitude: -122.0090), b = CLLocation(latitude: 37.7749, longitude: -122.4194)
                let d = a.distance(from: b)
                try expect(abs(d - 60_000) < 5_000, "distance \(d)")
                let region = CLCircularRegion(center: a.coordinate, radius: 100, identifier: "x")
                try expect(region.contains(CLLocationCoordinate2D(latitude: 37.3350, longitude: -122.0090)), "region")
                return "authorization \(st.rawValue), services \(CLLocationManager.locationServicesEnabled())"
            },
            check("StoreKit", "products-storefront", timeout: 40) {
                // no StoreKit configuration and no App Store account in the simulator: an empty answer, not an error
                let p = try await Product.products(for: ["com.x86sim.test.sdkcov.none"])
                try expect(p.isEmpty, "unexpected products")
                return "canMakePayments \(AppStore.canMakePayments), storefront \(await Storefront.current?.countryCode ?? "none")"
            },
            check("AuthenticationServices", "apple-id-request") {
                let r = ASAuthorizationAppleIDProvider().createRequest(); r.requestedScopes = [.fullName, .email]
                let pw = ASAuthorizationPasswordProvider().createRequest()
                let ctrl = ASAuthorizationController(authorizationRequests: [r, pw])
                try expect(ctrl.authorizationRequests.count == 2, "requests")
                return "ok"
            },
            check("DeviceCheck", "support") {
                // Apple's simulator: DCDevice and App Attest are not supported
                let dc = DCDevice.current.isSupported
                #if os(watchOS)
                return "DCDevice supported \(dc)"
                #else
                return "DCDevice supported \(dc), App Attest \(DCAppAttestService.shared.isSupported)"
                #endif
            },
        ]
        #if canImport(GameplayKit)
        c.append(
            check("GameplayKit", "random-pathfinding-statemachine") {
                let r = GKMersenneTwisterRandomSource(seed: 42); let v = r.nextInt(upperBound: 1000)
                try expect(GKMersenneTwisterRandomSource(seed: 42).nextInt(upperBound: 1000) == v, "deterministic")
                let g = GKGridGraph(fromGridStartingAt: [0, 0], width: 10, height: 10, diagonalsAllowed: false)
                g.remove([g.node(atGridPosition: [5, 5])!])
                let p = g.findPath(from: g.node(atGridPosition: [0, 0])!, to: g.node(atGridPosition: [9, 9])!)
                try expect(p.count == 19, "path length \(p.count)")
                final class A: GKState {}; final class B: GKState {}
                let sm = GKStateMachine(states: [A(), B()]); try expect(sm.enter(A.self) && sm.enter(B.self), "state machine")
                let n = GKNoise(GKPerlinNoiseSource()); let map = GKNoiseMap(n); _ = map.value(at: [10, 10])
                return "path \(p.count)"
            })
        #endif
        #if canImport(MapKit)
        c.append(check("MapKit", "geometry-local-objects") {
            let r = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 37.33, longitude: -122.03), latitudinalMeters: 1000, longitudinalMeters: 1000)
            try expect(r.span.latitudeDelta > 0.008 && r.span.latitudeDelta < 0.01, "span \(r.span.latitudeDelta)")
            var pts = [CLLocationCoordinate2D(latitude: 0, longitude: 0), CLLocationCoordinate2D(latitude: 0, longitude: 1)]
            let line = MKPolyline(coordinates: &pts, count: 2)
            try expect(abs(line.boundingMapRect.size.width - MKMapPointsPerMeterAtLatitude(0) * 111_319) / line.boundingMapRect.size.width < 0.01, "polyline")
            let item = MKMapItem(location: CLLocation(latitude: 37.33, longitude: -122.03), address: nil); item.name = "sdkcov"
            try expect(item.name == "sdkcov", "map item")
            return "ok"
        })
        #if !os(watchOS)
        c.append(check("MapKit", "snapshotter", timeout: 90) {
            let o = MKMapSnapshotter.Options()
            o.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 37.33, longitude: -122.03), latitudinalMeters: 2000, longitudinalMeters: 2000)
            o.size = CGSize(width: 128, height: 128)
            let s = try await MKMapSnapshotter(options: o).start()
            try expect(s.image.size.width == 128, "image \(s.image.size)")
            return "snapshot \(s.image.size)"
        })
        #endif
        #endif
        #if canImport(HealthKit)
        c.append(check("HealthKit", "store-units-samples") {
            try skipIf(!HKHealthStore.isHealthDataAvailable(), "health data not available on this device")
            let st = HKHealthStore().authorizationStatus(for: HKQuantityType(.stepCount))
            let q = HKQuantity(unit: .mile(), doubleValue: 1)
            try expect(abs(q.doubleValue(for: .meter()) - 1609.344) < 1e-6, "units")
            let s = HKQuantitySample(type: HKQuantityType(.heartRate), quantity: HKQuantity(unit: HKUnit.count().unitDivided(by: .minute()), doubleValue: 60), start: .now, end: .now)
            try expect(s.quantity.doubleValue(for: HKUnit(from: "count/min")) == 60, "sample")
            return "authorization \(st.rawValue)"
        })
        #endif
        #if canImport(HomeKit) && !os(watchOS)
        c.append(check("HomeKit", "manager", timeout: 30) {
            let st = await onMain { HMHomeManager().authorizationStatus }
            return "authorization \(st.rawValue)"
        })
        #endif
        #if canImport(GameKit)
        c.append(check("GameKit", "local-player-leaderboard-objects") {
            let p = GKLocalPlayer.local
            let s = GKLeaderboardScore(); s.leaderboardID = "sdkcov"; s.value = 1
            return "authenticated \(p.isAuthenticated)"
        })
        #endif
        #if canImport(GameController)
        c.append(check("GameController", "controllers-keyboard-mouse") {
            let n = GCController.controllers().count
            let ext: String
            #if os(watchOS)
            ext = ""
            #else
            ext = ", keyboard \(GCKeyboard.coalesced != nil), mice \(GCMouse.mice().count)"
            #endif
            return "\(n) controllers\(ext)"
        })
        #endif
        #if canImport(LocalAuthentication) && !os(tvOS)
        c.append(check("LocalAuthentication", "policies") {
            let ctx = LAContext(); var e: NSError?
            #if os(watchOS)
            let bio = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithWristDetection, error: &e)
            #else
            let bio = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &e)
            #endif
            // a fresh simulator: no biometry enrolled / no passcode: an LAError code, not a crash
            let code = e?.code ?? 0
            try expect(bio || e?.domain == LAErrorDomain, "biometrics error \(String(describing: e))")
            return "biometrics \(bio) (\(code)), biometryType \(ctx.biometryType.rawValue)"
        })
        #endif
        #if canImport(AppTrackingTransparency)
        c.append(check("AppTrackingTransparency", "status") { "status \(ATTrackingManager.trackingAuthorizationStatus.rawValue)" })
        #endif
        #if canImport(AdSupport)
        c.append(check("AdSupport", "identifier") {
            let id = ASIdentifierManager.shared().advertisingIdentifier
            return id.uuidString == "00000000-0000-0000-0000-000000000000" ? "zeroed (tracking not authorized)" : "set"
        })
        #endif
        #if canImport(BackgroundTasks) && !os(watchOS)
        c.append(check("BackgroundTasks", "register-submit") {
            // Apple: "background tasks are not supported in Simulator": submit fails with .unavailable there
            let ok = await onMain { BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.x86sim.test.sdkcov.refresh", using: nil) { $0.setTaskCompleted(success: true) } }
            try expect(ok, "register (BGTaskSchedulerPermittedIdentifiers)")
            do { try BGTaskScheduler.shared.submit(BGAppRefreshTaskRequest(identifier: "com.x86sim.test.sdkcov.refresh")) }
            catch let e as BGTaskScheduler.Error where e.code == .unavailable { return "submit: unavailable (as in Apple's simulator)" }
            BGTaskScheduler.shared.cancelAllTaskRequests()
            return "submitted"
        })
        #endif
        #if canImport(CoreBluetooth)
        c.append(check("CoreBluetooth", "central-state", timeout: 20) {
            final class D: NSObject, CBCentralManagerDelegate { var cont: CheckedContinuation<CBManagerState, Never>?
                func centralManagerDidUpdateState(_ c: CBCentralManager) { cont?.resume(returning: c.state); cont = nil } }
            let d = D(); var m: CBCentralManager?
            let st: CBManagerState = await withCheckedContinuation { k in d.cont = k; m = CBCentralManager(delegate: d, queue: .global()) }
            _ = m
            try skipIf(st == .unsupported, "no Bluetooth radio in the Simulator (Apple's reports .unsupported too)")
            return "state \(st.rawValue)"
        })
        #endif
        #if canImport(CoreMotion)
        c.append(check("CoreMotion", "availability") {
            // one call at a time, each logged on stderr: a call that never returns shows as the last "coremotion:" line
            func step<T>(_ n: String, _ f: () -> T) -> T { FileHandle.standardError.write("coremotion: \(n)\n".data(using: .utf8)!); return f() }
            let m = step("CMMotionManager()") { CMMotionManager() }
            let acc = step("accelerometer") { m.isAccelerometerAvailable }, gyro = step("gyro") { m.isGyroAvailable }
            let dm = step("deviceMotion") { m.isDeviceMotionAvailable }, steps = step("pedometer") { CMPedometer.isStepCountingAvailable() }
            let alt = step("altimeter") { CMAltimeter.isRelativeAltitudeAvailable() }
            let any = acc || gyro || dm || steps || alt
            try skipIf(!any, "no motion sensors in the Simulator (Apple's has none either)")
            return "accelerometer \(m.isAccelerometerAvailable)"
        })
        #endif
        #if canImport(CoreHaptics)
        c.append(check("CoreHaptics", "pattern-engine") {
            let ev = CHHapticEvent(eventType: .hapticTransient, parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1)], relativeTime: 0)
            let p = try CHHapticPattern(events: [ev], parameters: [])
            try expect(p.duration >= 0, "pattern")
            try skipIf(!CHHapticEngine.capabilitiesForHardware().supportsHaptics, "no haptics hardware in the Simulator (pattern API checked)")
            let e = try CHHapticEngine(); try e.start(); try e.makePlayer(with: p).start(atTime: 0); e.stop()
            return "played"
        })
        #endif
        #if canImport(CoreNFC)
        c.append(check("CoreNFC", "reading-available") {
            try skipIf(!NFCNDEFReaderSession.readingAvailable, "no NFC in the Simulator")
            return "available"
        })
        #endif
        #if canImport(NearbyInteraction)
        c.append(check("NearbyInteraction", "capabilities") {
            try skipIf(!NISession.deviceCapabilities.supportsPreciseDistanceMeasurement, "no UWB in the Simulator")
            return "UWB"
        })
        #endif
        #if canImport(ARKit) && os(iOS)
        c.append(check("ARKit", "configurations") {
            try skipIf(!ARWorldTrackingConfiguration.isSupported, "ARKit tracking is not supported in the Simulator")
            return "world tracking"
        })
        #endif
        #if canImport(PassKit)
        c.append(check("PassKit", "library-payments") {
            let pay = PKPaymentAuthorizationController.canMakePayments()
            #if os(iOS)
            let lib = PKPassLibrary.isPassLibraryAvailable()
            return "pass library \(lib), payments \(pay)"
            #else
            return "payments \(pay)"
            #endif
        })
        #endif
        #if canImport(CallKit) && os(iOS)
        c.append(check("CallKit", "provider-observer") {
            let p = CXProvider(configuration: CXProviderConfiguration()); p.invalidate()
            return "\(CXCallObserver().calls.count) calls"
        })
        #endif
        #if canImport(PushKit) && !os(tvOS)
        c.append(check("PushKit", "registry") {
            await onMain { let r = PKPushRegistry(queue: .main); r.desiredPushTypes = []; return "ok" }
        })
        #endif
        #if canImport(CoreTelephony) && os(iOS)
        c.append(check("CoreTelephony", "network-info") {
            "\(CTTelephonyNetworkInfo().serviceCurrentRadioAccessTechnology?.count ?? 0) radios (none in the Simulator)"
        })
        #endif
        #if canImport(Intents)
        c.append(check("Intents", "preferences-interaction") {
            #if os(iOS) || os(watchOS)
            let st = INPreferences.siriAuthorizationStatus()
            let i = INSendMessageIntent(recipients: nil, outgoingMessageType: .outgoingMessageText, content: "x", speakableGroupName: nil, conversationIdentifier: nil, serviceName: nil, sender: nil, attachments: nil)
            try expect(i.content == "x", "intent")
            return "siri authorization \(st.rawValue)"
            #else
            return "INPreferences \(INPreferences.siriAuthorizationStatus().rawValue)"
            #endif
        })
        #endif
        #if canImport(AppIntents)
        c.append(check("AppIntents", "perform") {
            let r = try await SDKCovIntent(value: 21).perform()
            try expect(r.value == 42, "result \(String(describing: r.value))")
            return "42"
        })
        #endif
        #if canImport(WidgetKit) && !os(tvOS)
        c.append(check("WidgetKit", "center") {
            WidgetCenter.shared.reloadAllTimelines()
            let cfg = try await WidgetCenter.shared.currentConfigurations()
            return "\(cfg.count) widgets configured"
        })
        #endif
        #if canImport(ActivityKit) && os(iOS)
        c.append(check("ActivityKit", "authorization") {
            "activities enabled \(ActivityAuthorizationInfo().areActivitiesEnabled), \(Activity<SDKCovAttributes>.activities.count) running"
        })
        #endif
        #if canImport(GroupActivities) && !os(watchOS)
        c.append(check("GroupActivities", "observer") {
            await onMain { "eligible \(GroupStateObserver().isEligibleForGroupSession)" }
        })
        #endif
        #if canImport(TipKit)
        c.append(check("TipKit", "configure") {
            try Tips.configure([.datastoreLocation(.applicationDefault)])
            let t = SDKCovTip()
            return "tip \(t.id)"
        })
        #endif
        #if canImport(MultipeerConnectivity) && !os(watchOS)
        c.append(check("MultipeerConnectivity", "session") {
            let p = MCPeerID(displayName: "sdkcov"); let s = MCSession(peer: p, securityIdentity: nil, encryptionPreference: .required)
            try expect(s.connectedPeers.isEmpty, "peers")
            let adv = MCNearbyServiceAdvertiser(peer: p, discoveryInfo: nil, serviceType: "sdkcov")
            adv.startAdvertisingPeer(); adv.stopAdvertisingPeer()
            return "ok"
        })
        #endif
        #if canImport(ExternalAccessory) && !os(watchOS)
        c.append(check("ExternalAccessory", "manager") { "\(EAAccessoryManager.shared().connectedAccessories.count) accessories" })
        #endif
        #if canImport(WatchConnectivity)
        c.append(check("WatchConnectivity", "session-activate", timeout: 20) {
            try skipIf(!WCSession.isSupported(), "WCSession not supported here")
            final class D: NSObject, WCSessionDelegate {
                var cont: CheckedContinuation<WCSessionActivationState, Never>?
                func session(_ s: WCSession, activationDidCompleteWith st: WCSessionActivationState, error: Error?) { cont?.resume(returning: st); cont = nil }
                #if os(iOS)
                func sessionDidBecomeInactive(_ s: WCSession) {}
                func sessionDidDeactivate(_ s: WCSession) {}
                #endif
            }
            let d = D()
            let st: WCSessionActivationState = await withCheckedContinuation { k in d.cont = k; WCSession.default.delegate = d; WCSession.default.activate() }
            #if os(iOS)
            return "state \(st.rawValue), paired \(WCSession.default.isPaired)"
            #else
            return "state \(st.rawValue), companion installed \(WCSession.default.isCompanionAppInstalled)"
            #endif
        })
        #endif
        #if canImport(MetricKit) && os(iOS)
        c.append(check("MetricKit", "manager") {
            final class S: NSObject, MXMetricManagerSubscriber {}
            let s = S(); MXMetricManager.shared.add(s); MXMetricManager.shared.remove(s)
            return "\(MXMetricManager.shared.pastPayloads.count) past payloads"
        })
        #endif
        #if canImport(ReplayKit) && !os(watchOS)
        c.append(check("ReplayKit", "recorder") { "available \(RPScreenRecorder.shared().isAvailable)" })
        #endif
        #if canImport(SensitiveContentAnalysis) && os(iOS)
        c.append(check("SensitiveContentAnalysis", "policy") { "policy \(SCSensitivityAnalyzer().analysisPolicy.rawValue)" })
        #endif
        #if canImport(SharedWithYou) && os(iOS)
        c.append(check("SharedWithYou", "highlight-center") { await onMain { "\(SWHighlightCenter().highlights.count) highlights" } })
        #endif
        #if canImport(LinkPresentation) && !os(watchOS)
        c.append(check("LinkPresentation", "metadata") {
            let m = LPLinkMetadata(); m.originalURL = URL(string: "https://example.com"); m.title = "sdkcov"
            let d = try NSKeyedArchiver.archivedData(withRootObject: m, requiringSecureCoding: true)
            let back = try NSKeyedUnarchiver.unarchivedObject(ofClass: LPLinkMetadata.self, from: d)
            try expect(back?.title == "sdkcov", "archive round trip")
            return "\(d.count) B"
        })
        #endif
        #if canImport(Accounts) && os(iOS)
        c.append(check("Accounts", "store") { "\(ACAccountStore().accounts?.count ?? 0) accounts visible" })
        #endif
        #if canImport(CryptoTokenKit) && os(iOS)
        c.append(check("CryptoTokenKit", "watcher") { "\(TKTokenWatcher().tokenIDs.count) tokens" })
        #endif
        #if canImport(VideoSubscriberAccount) && !os(watchOS)
        c.append(check("VideoSubscriberAccount", "manager") {
            let m = VSAccountManager(); _ = m
            return "ok"
        })
        #endif
        #if canImport(NetworkExtension) && os(iOS)
        c.append(check("NetworkExtension", "hotspot-helper-objects") {
            let cfg = NEHotspotConfiguration(ssid: "sdkcov")
            try expect(cfg.ssid == "sdkcov", "config")
            return "ok (VPN / filters need entitlements and a provider extension)"
        })
        #endif
        return c
    }
}

#if canImport(ActivityKit) && os(iOS)
struct SDKCovAttributes: ActivityAttributes { struct ContentState: Codable, Hashable { var n: Int } }
#endif
