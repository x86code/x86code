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
#if canImport(GeoToolbox)
import GeoToolbox
#endif
#if canImport(Matter)
import Matter
#endif
#if canImport(WorkoutKit)
import WorkoutKit
#endif
#if canImport(LiveCommunicationKit)
import LiveCommunicationKit
#endif
#if canImport(SharedWithYouCore)
import SharedWithYouCore
#endif
#if canImport(AddressBook)
import AddressBook
#endif
#if canImport(CarPlay)
import CarPlay
#endif
#if canImport(Messages)
import Messages
#endif
#if canImport(ImageCaptureCore)
import ImageCaptureCore
#endif
#if canImport(FileProvider)
import FileProvider
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
                #if !os(visionOS)   // no region monitoring on visionOS
                let region = CLCircularRegion(center: a.coordinate, radius: 100, identifier: "x")
                try expect(region.contains(CLLocationCoordinate2D(latitude: 37.3350, longitude: -122.0090)), "region")
                #endif
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
        #if canImport(HomeKit)
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
            let dm = step("deviceMotion") { m.isDeviceMotionAvailable }
            #if os(visionOS)   // no pedometer or altimeter API on visionOS
            let steps = false, alt = false
            #else
            let steps = step("pedometer") { CMPedometer.isStepCountingAvailable() }
            let alt = step("altimeter") { CMAltimeter.isRelativeAltitudeAvailable() }
            #endif
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
        #if canImport(ARKit) && os(visionOS)
        c.append(check("ARKit", "data-providers") {
            // visionOS ARKit: data providers run in an ARKitSession, and only inside an immersive space; here which
            // ones the device supports (Apple's simulator: world tracking and planes, no hands / cameras)
            let p: [(String, Bool)] = [("world", WorldTrackingProvider.isSupported), ("planes", PlaneDetectionProvider.isSupported),
                                       ("scene", SceneReconstructionProvider.isSupported), ("hands", HandTrackingProvider.isSupported),
                                       ("images", ImageTrackingProvider.isSupported), ("room", RoomTrackingProvider.isSupported)]
            try skipIf(!p.contains { $0.1 }, "no ARKit data providers in the Simulator")
            let session = ARKitSession(); _ = session
            return p.map { "\($0.0) \($0.1)" }.joined(separator: ", ")
        })
        #endif
        #if canImport(PassKit)
        c.append(check("PassKit", "library-payments") {
            let pay = PKPaymentAuthorizationController.canMakePayments()
            #if os(iOS) || os(visionOS)
            let lib = PKPassLibrary.isPassLibraryAvailable()
            return "pass library \(lib), payments \(pay)"
            #else
            return "payments \(pay)"
            #endif
        })
        #endif
        #if canImport(CallKit) && !os(tvOS)
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
            #if os(iOS) || os(watchOS) || os(visionOS)
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
                let lock = NSLock()
                var cont: CheckedContinuation<WCSessionActivationState?, Never>?
                func finish(_ st: WCSessionActivationState?) { lock.withLock { cont?.resume(returning: st); cont = nil } }
                func session(_ s: WCSession, activationDidCompleteWith st: WCSessionActivationState, error: Error?) { finish(st) }
                #if os(iOS) || os(visionOS)
                func sessionDidBecomeInactive(_ s: WCSession) {}
                func sessionDidDeactivate(_ s: WCSession) {}
                #endif
            }
            let d = D()
            // a wait that ends by itself: a continuation that is never resumed would outlive the check's timeout
            let st: WCSessionActivationState? = await withCheckedContinuation { k in
                d.cont = k; WCSession.default.delegate = d; WCSession.default.activate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 15) { d.finish(nil) }
            }
            #if os(watchOS)
            // A watch-only app (WKWatchOnly, as this one: installd refuses WKCompanionAppBundleIdentifier with it) gets
            // no activation callback from watchOS 27.2's wcd: it looks the client up by companion bundle id
            // (-[WCDClient applicationInfo]: type 1 = companion), which a watch-only app has none of, so ClockFace's
            // privilege check gets a nil id (NanoTimeKit MultiplexierError 1) and wcd never sends a session state
            // (and an unpaired watch's wcd lists no installed apps at all until AppConduit posts its update).
            if st == nil, Bundle.main.object(forInfoDictionaryKey: "WKWatchOnly") as? Bool == true {
                throw Skip("watch-only app: watchOS's wcd sends a watch-only app no session state (no companion id), so activate() never calls back")
            }
            #endif
            guard let st else { throw Fail("no activationDidComplete in 15 s") }
            #if os(iOS) || os(visionOS)
            return "state \(st.rawValue), paired \(WCSession.default.isPaired)"
            #else
            return "state \(st.rawValue), companion installed \(WCSession.default.isCompanionAppInstalled)"
            #endif
        })
        #endif
        #if canImport(MetricKit) && (os(iOS) || os(visionOS))
        c.append(check("MetricKit", "manager") {
            final class S: NSObject, MXMetricManagerSubscriber {}
            let s = S(); MXMetricManager.shared.add(s); MXMetricManager.shared.remove(s)
            return "\(MXMetricManager.shared.pastPayloads.count) past payloads"
        })
        #endif
        #if canImport(ReplayKit) && !os(watchOS)
        c.append(check("ReplayKit", "recorder") { "available \(RPScreenRecorder.shared().isAvailable)" })
        #endif
        #if canImport(SensitiveContentAnalysis) && (os(iOS) || os(visionOS))
        c.append(check("SensitiveContentAnalysis", "policy") { "policy \(SCSensitivityAnalyzer().analysisPolicy.rawValue)" })
        #endif
        #if canImport(SharedWithYou) && !os(watchOS)
        c.append(check("SharedWithYou", "highlight-center") { await onMain { "\(SWHighlightCenter().highlights.count) highlights" } })
        #endif
        #if canImport(LinkPresentation)
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
        #if canImport(CryptoTokenKit)
        c.append(check("CryptoTokenKit", "watcher") { "\(TKTokenWatcher().tokenIDs.count) tokens" })
        #endif
        #if canImport(VideoSubscriberAccount) && !os(watchOS)
        c.append(check("VideoSubscriberAccount", "manager") {
            let m = VSAccountManager(); _ = m
            return "ok"
        })
        #endif
        #if canImport(NetworkExtension) && !os(tvOS)   // tvOS: no hotspot configuration
        c.append(check("NetworkExtension", "hotspot-helper-objects") {
            let cfg = NEHotspotConfiguration(ssid: "sdkcov")
            try expect(cfg.ssid == "sdkcov", "config")
            return "ok (VPN / filters need entitlements and a provider extension)"
        })
        #endif
        #if canImport(GeoToolbox)
        c.append(check("GeoToolbox", "place-descriptor") {
            let ap = CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090)
            let p = PlaceDescriptor(representations: [.coordinate(ap), .address("1 Apple Park Way, Cupertino, CA 95014")], commonName: "Apple Park")
            try expect(p.coordinate?.latitude == ap.latitude && p.address?.hasPrefix("1 Apple Park Way") == true, "accessors \(p)")
            let d = try JSONEncoder().encode(p)
            let back = try JSONDecoder().decode(PlaceDescriptor.self, from: d)
            try expect(back == p && back.commonName == "Apple Park", "Codable round trip \(back)")
            return "\(d.count) B JSON"
        })
        #endif
        #if canImport(Matter)
        c.append(check("Matter", "setup-payload-codes") {
            // Matter's onboarding codes for the spec's test device: passcode 20202021, discriminator 3840
            let p = MTRSetupPayload(setupPasscode: 20202021, discriminator: 3840)
            p.vendorID = 0xFFF1; p.productID = 0x8000; p.discoveryCapabilities = .onNetwork
            let manual = p.manualEntryCode()
            try expect(manual == "34970112332", "manual pairing code \(manual ?? "nil")")
            guard let qr = p.qrCodeString(), qr.hasPrefix("MT:") else { throw Fail("QR code string \(String(describing: p.qrCodeString()))") }
            guard let back = MTRSetupPayload(payload: qr) else { throw Fail("parse \(qr)") }
            try expect(back.setupPasscode == 20202021 && back.discriminator == 3840 && back.vendorID == 0xFFF1 && back.productID == 0x8000 && !back.hasShortDiscriminator, "QR round trip \(back)")
            guard let short = MTRSetupPayload(payload: "34970112332") else { throw Fail("parse the manual code") }
            try expect(short.setupPasscode == 20202021 && short.hasShortDiscriminator && short.discriminator == 15, "manual code parse \(short.setupPasscode) \(short.discriminator)")
            try expect(MTRSetupPayload.isValidSetupPasscode(20202021) && !MTRSetupPayload.isValidSetupPasscode(11111111), "passcode validity")
            let a = try NSKeyedArchiver.archivedData(withRootObject: p, requiringSecureCoding: true)
            try expect(try NSKeyedUnarchiver.unarchivedObject(ofClass: MTRSetupPayload.self, from: a)?.qrCodeString() == qr, "archive round trip")
            return "\(manual!), \(qr)"
        })
        #endif
        #if canImport(WorkoutKit) && (os(iOS) || os(watchOS))
        c.append(check("WorkoutKit", "custom-workout-plan") {
            let work = IntervalStep(.work, goal: .distance(400, .meters), alert: .speed(3.5...4.5, unit: .metersPerSecond))
            let rest = IntervalStep(.recovery, goal: .time(90, .seconds))
            let w = CustomWorkout(activity: .running, location: .outdoor, displayName: "sdkcov 6x400",
                                  warmup: WorkoutStep(goal: .time(10, .minutes)), blocks: [IntervalBlock(steps: [work, rest], iterations: 6)],
                                  cooldown: WorkoutStep(goal: .open))
            try expect(CustomWorkout.supportsActivity(.running), "running supported")
            let plan = WorkoutPlan(.custom(w))
            let d = try plan.dataRepresentation
            let back = try WorkoutPlan(from: d)
            guard case .custom(let cw) = back.workout else { throw Fail("decoded \(back.workout)") }
            try expect(cw.displayName == "sdkcov 6x400" && cw.blocks.first?.iterations == 6 && cw.blocks.first?.steps.count == 2, "round trip \(cw)")
            return "\(d.count) B plan"
        })
        #endif
        #if canImport(LiveCommunicationKit) && !os(tvOS)
        c.append(check("LiveCommunicationKit", "conversation-manager") {
            let cfg = ConversationManager.Configuration(ringtoneName: nil, iconTemplateImageData: nil, maximumConversationGroups: 1, maximumConversationsPerConversationGroup: 1,
                                                        includesConversationInRecents: false, supportsVideo: false, supportedHandleTypes: [.generic])
            let m = ConversationManager(configuration: cfg)
            defer { m.invalidate() }
            try expect(m.conversations.isEmpty && m.configuration.maximumConversationGroups == 1, "\(m.conversations.count) conversations")
            let h = Handle(type: .emailAddress, value: "ada@example.com", displayName: "Ada")
            let back = try JSONDecoder().decode(Handle.self, from: try JSONEncoder().encode(h))
            try expect(back == h, "Handle round trip")
            return "ok"
        })
        #endif
        #if canImport(SharedWithYouCore) && (os(iOS) || os(visionOS))   // tvOS: the collaboration classes are unavailable
        c.append(check("SharedWithYouCore", "collaboration-metadata") {
            let m = SWCollaborationMetadata(localIdentifier: SWLocalCollaborationIdentifier(rawValue: "sdkcov-doc"))
            m.title = "sdkcov"; m.initiatorHandle = "ada@example.com"
            let opt = SWCollaborationOption(title: "Allow edits", identifier: "edit"); opt.isSelected = true
            m.defaultShareOptions = SWCollaborationShareOptions(optionsGroups: [SWCollaborationOptionsGroup(identifier: "perm", options: [opt])])
            let d = try NSKeyedArchiver.archivedData(withRootObject: m, requiringSecureCoding: true)
            let back = try NSKeyedUnarchiver.unarchivedObject(ofClass: SWCollaborationMetadata.self, from: d)
            try expect(back?.title == "sdkcov" && back?.localIdentifier.rawValue == "sdkcov-doc" && back?.defaultShareOptions?.optionsGroups.first?.options.first?.isSelected == true, "archive round trip")
            return "\(d.count) B"
        })
        #endif
        #if canImport(AutomaticAssessmentConfiguration) && os(iOS)   // visionOS ships it, every class unavailable
        c.append(check("AutomaticAssessmentConfiguration", "configuration-session", timeout: 30) {
            let cfg = AEAssessmentConfiguration()
            cfg.allowsDictation = false; cfg.allowsPasswordAutoFill = false; cfg.allowsContinuousPathKeyboard = true
            let copy = cfg.copy() as! AEAssessmentConfiguration
            try expect(!copy.allowsDictation && copy.allowsContinuousPathKeyboard, "configuration copy")
            // begin: needs the com.apple.developer.automatic-assessment-configuration entitlement, so the session
            // reports a failure to its delegate (Apple's simulator too); either answer is an answer
            final class D: NSObject, AEAssessmentSessionDelegate { var k: CheckedContinuation<String, Never>?
                func assessmentSessionDidBegin(_ s: AEAssessmentSession) { k?.resume(returning: "began"); k = nil }
                func assessmentSession(_ s: AEAssessmentSession, failedToBeginWithError e: Error) { k?.resume(returning: "failed to begin: \((e as NSError).domain) \((e as NSError).code)"); k = nil } }
            let d = D()
            let s = await onMain { AEAssessmentSession(configuration: cfg) }
            let r: String = await withCheckedContinuation { k in d.k = k; Task { @MainActor in s.delegate = d; s.begin() } }
            if r == "began" { await onMain { s.end() } }
            return r
        })
        #endif
        #if canImport(IdentityLookup) && (os(iOS) || os(visionOS))
        c.append(check("IdentityLookup", "responses-archive") {
            let r = ILClassificationResponse(action: .reportJunk); r.userInfo = ["reason": "sdkcov"]
            let d = try NSKeyedArchiver.archivedData(withRootObject: r, requiringSecureCoding: true)
            let back = try NSKeyedUnarchiver.unarchivedObject(ofClass: ILClassificationResponse.self, from: d)
            try expect(back?.action == .reportJunk && back?.userInfo?["reason"] as? String == "sdkcov", "classification response round trip")
            let q = ILMessageFilterQueryResponse(); q.action = .junk; q.subAction = .promotionalOffers
            let qd = try NSKeyedArchiver.archivedData(withRootObject: q, requiringSecureCoding: true)
            let qb = try NSKeyedUnarchiver.unarchivedObject(ofClass: ILMessageFilterQueryResponse.self, from: qd)
            try expect(qb?.action == .junk && qb?.subAction == .promotionalOffers, "filter response round trip")
            return "ok"
        })
        #endif
        #if canImport(AddressBook) && os(iOS)
        c.append(check("AddressBook", "person-vcard-roundtrip") {
            // the C address book API: records live without a book (no Contacts access needed)
            let p = ABPersonCreate().takeRetainedValue()
            try expect(ABRecordSetValue(p, kABPersonFirstNameProperty, "Ada" as CFString, nil) && ABRecordSetValue(p, kABPersonLastNameProperty, "Lovelace" as CFString, nil), "set names")
            let phones = ABMultiValueCreateMutable(ABPropertyType(kABMultiStringPropertyType)).takeRetainedValue()
            try expect(ABMultiValueAddValueAndLabel(phones, "+1 555 0100" as CFString, kABPersonPhoneMobileLabel, nil), "add phone")
            try expect(ABRecordSetValue(p, kABPersonPhoneProperty, phones, nil), "set phones")
            let name = ABRecordCopyCompositeName(p)?.takeRetainedValue() as String?
            try expect(name == "Ada Lovelace", "composite name \(String(describing: name))")
            let vcard = ABPersonCreateVCardRepresentationWithPeople([p] as CFArray).takeRetainedValue() as Data
            let text = String(decoding: vcard, as: UTF8.self)
            try expect(text.contains("BEGIN:VCARD") && text.contains("Lovelace") && text.contains("555"), "vCard '\(text.prefix(200))'")
            let back = ABPersonCreatePeopleInSourceWithVCardRepresentation(nil, vcard as CFData).takeRetainedValue() as [ABRecord]
            let bn = back.first.flatMap { ABRecordCopyCompositeName($0)?.takeRetainedValue() as String? }
            try expect(back.count == 1 && bn == "Ada Lovelace", "vCard back: \(back.count) people, \(String(describing: bn))")
            return "\(vcard.count) B vCard, authorization \(ABAddressBookGetAuthorizationStatus().rawValue)"
        })
        #endif
        #if canImport(CarPlay) && os(iOS)
        c.append(check("CarPlay", "templates") {
            // templates are plain objects until a CarPlay scene shows them
            try await onMain {
                let items = (0..<5).map { CPListItem(text: "Item \($0)", detailText: "x86sim") }
                let list = CPListTemplate(title: "sdkcov", sections: [CPListSection(items: Array(items.prefix(3)), header: "A", sectionIndexTitle: "A"),
                                                                      CPListSection(items: Array(items.suffix(2)))])
                try expect(list.sectionCount == 2 && list.itemCount == 5 && list.indexPath(for: items[4]) == IndexPath(item: 1, section: 1), "list \(list.sectionCount)/\(list.itemCount)")
                items[0].setText("changed"); try expect(items[0].text == "changed", "item update")
                let grid = CPGridTemplate(title: "grid", gridButtons: (0..<4).map { i in CPGridButton(titleVariants: ["B\(i)"], image: UIImage(systemName: "star")!) { _ in } })
                let alert = CPAlertTemplate(titleVariants: ["Long title", "Short"], actions: [CPAlertAction(title: "OK", style: .default) { _ in }])
                let tabs = CPTabBarTemplate(templates: [list, grid])
                try expect(tabs.templates.count == 2 && grid.gridButtons.count == 4 && alert.actions.count == 1, "templates")
                let info = CPInformationTemplate(title: "info", layout: .twoColumn, items: [CPInformationItem(title: "k", detail: "v")], actions: [])
                return "\(CPListTemplate.maximumItemCount) max list items, \(info.items.count) info items"
            }
        })
        #endif
        #if canImport(Messages) && os(iOS)
        c.append(check("Messages", "message-sticker-objects") {
            let u = FileManager.default.temporaryDirectory.appendingPathComponent("sdkcov-sticker.png")
            try encode(textImage("x86", 300, 300, size: 96), .png).write(to: u)
            defer { try? FileManager.default.removeItem(at: u) }
            let st = try MSSticker(contentsOfFileURL: u, localizedDescription: "sdkcov sticker")
            try expect(st.localizedDescription == "sdkcov sticker", "sticker")
            let layout = MSMessageTemplateLayout(); layout.caption = "x86sim"; layout.subcaption = "sdkcov"; layout.imageTitle = "t"
            let m = MSMessage(session: MSSession())
            m.layout = layout; m.url = URL(string: "https://example.com/game?move=e4"); m.summaryText = "sdkcov move"
            let live = MSMessageLiveLayout(alternateLayout: layout)
            try expect(m.url?.query == "move=e4" && (m.layout as? MSMessageTemplateLayout)?.caption == "x86sim" && live.alternateLayout.caption == "x86sim", "message")
            return "sticker + message"
        })
        #endif
        #if canImport(ImageCaptureCore) && (os(iOS) || os(visionOS))
        c.append(check("ImageCaptureCore", "device-browser", timeout: 20) {
            final class D: NSObject, ICDeviceBrowserDelegate { var n = 0
                func deviceBrowser(_ b: ICDeviceBrowser, didAdd d: ICDevice, moreComing: Bool) { n += 1 }
                func deviceBrowser(_ b: ICDeviceBrowser, didRemove d: ICDevice, moreGoing: Bool) {} }
            let d = D()
            let b = await onMain { () -> ICDeviceBrowser in let b = ICDeviceBrowser(); b.delegate = d; b.start(); return b }
            try await Task.sleep(for: .seconds(1))
            let r: String = await onMain {
                let s = "browsing \(b.isBrowsing), \(b.devices?.count ?? 0) devices (none attached to a simulator)"
                b.stop(); return s
            }
            return r
        })
        #endif
        #if canImport(FileProvider) && (os(iOS) || os(visionOS))
        c.append(check("FileProvider", "domains-identifiers", timeout: 30) {
            try expect(NSFileProviderItemIdentifier.rootContainer.rawValue == "NSFileProviderRootContainerItemIdentifier", "root identifier \(NSFileProviderItemIdentifier.rootContainer.rawValue)")
            let dom = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier("sdkcov"), displayName: "sdkcov")
            try expect(dom.identifier.rawValue == "sdkcov" && dom.displayName == "sdkcov", "domain")
            // an app without a File Provider extension has no domains (or is told it has no provider)
            let r: String = await withCheckedContinuation { k in
                NSFileProviderManager.getDomainsWithCompletionHandler { ds, e in k.resume(returning: e.map { "error \(($0 as NSError).domain) \(($0 as NSError).code)" } ?? "\(ds.count) domains") }
            }
            return r
        })
        #endif
        return c
    }
}

#if canImport(ActivityKit) && os(iOS)
struct SDKCovAttributes: ActivityAttributes { struct ContentState: Codable, Hashable { var n: Int } }
#endif
