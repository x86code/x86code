// sdkcov functional checks added by the visionOS coverage round: frameworks and APIs the shared groups don't reach yet.
// Only built into the visionOS app (#if os(visionOS)); checks shared with other platforms belong in the group files.
import Foundation
#if os(visionOS)
import Synchronization
import SwiftUI
import UIKit
import Metal
import AVFoundation
import ModelIO
import RealityKit
import _RealityKit_SwiftUI
import ARKit
import Spatial
import PHASE
import CompositorServices
import _CompositorServices_SwiftUI
import GroupActivities
import ManagedApp
import StateReporting
import ImmersiveMediaSupport
import AVRouting
import MediaIntents
import SuggestedActions
import RelevanceKit
import CoreVideo
import CryptoTokenKit
import StoreKit
#endif

extension Registry {
    static var more_xros: [Check] {
        var c: [Check] = []
        #if os(visionOS)
        // MARK: Spatial (libSpatial): the 3D geometry types SwiftUI and RealityKit use on visionOS
        c.append(check("libSpatial", "point-rotation-affine-rect") {
            let t = AffineTransform3D(scale: Size3D(width: 2, height: 2, depth: 2), rotation: Rotation3D(angle: .degrees(90), axis: .z),
                                      translation: Vector3D(x: 10, y: 0, z: 0))
            let q = Point3D(x: 1, y: 2, z: 3).applying(t)   // rotate (1,2,3) -> (-2,1,3), x2 -> (-4,2,6), + (10,0,0)
            try expect(abs(q.x - 6) < 1e-6 && abs(q.y - 2) < 1e-6 && abs(q.z - 6) < 1e-6, "transformed point \(q)")
            let inv = t.inverse!; let back = q.applying(inv)
            try expect(abs(back.x - 1) < 1e-6 && abs(back.y - 2) < 1e-6 && abs(back.z - 3) < 1e-6, "inverse \(back)")
            let a = Rect3D(origin: .zero, size: Size3D(width: 2, height: 2, depth: 2))
            let b = Rect3D(origin: Point3D(x: 1, y: 1, z: 1), size: Size3D(width: 2, height: 2, depth: 2))
            let i = a.intersection(b), u = a.union(b)
            try expect(i?.size == Size3D(width: 1, height: 1, depth: 1) && u.size == Size3D(width: 3, height: 3, depth: 3), "rect ops \(String(describing: i)) \(u)")
            let r = Rotation3D(angle: .degrees(90), axis: .y).rotated(by: Rotation3D(angle: .degrees(90), axis: .y))
            return "rotation \(String(format: "%.1f", r.angle.degrees))°, \(Ray3D(origin: .zero, direction: Vector3D(x: 0, y: 0, z: -1)).direction)"
        })

        // MARK: RealityKit: offscreen rendering with RealityRenderer (the engine behind RealityView), pixels read back
        c.append(check("RealityKit", "reality-renderer-offscreen", timeout: 60) {
            guard let dev = MTLCreateSystemDefaultDevice() else { throw Fail("no Metal device") }
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: 64, height: 64, mipmapped: false)
            td.usage = [.renderTarget, .shaderRead, .shaderWrite]; td.storageMode = .shared
            guard let tex = dev.makeTexture(descriptor: td) else { throw Fail("texture") }
            let (renderer, done) = try await onMain {
                let r = try RealityRenderer()
                let box = ModelEntity(mesh: .generateBox(size: 0.5), materials: [UnlitMaterial(color: .red)])
                let cam = PerspectiveCamera(); cam.camera.fieldOfViewInDegrees = 60; cam.position = [0, 0, 2]
                r.entities.append(box); r.entities.append(cam); r.activeCamera = cam
                r.cameraSettings.colorBackground = .color(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
                r.cameraSettings.isToneMappingEnabled = false
                let out = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: tex))
                let done = DispatchSemaphore(value: 0)
                try r.updateAndRender(deltaTime: 1.0 / 60, cameraOutput: out, onComplete: { _ in done.signal() })
                return (r, done)
            }
            try await done.waitAsync(seconds: 20, "the render never completed")
            withExtendedLifetime(renderer) {}   // the renderer lives until its frame is done
            var px = [UInt8](repeating: 0, count: 64 * 64 * 4)
            tex.getBytes(&px, bytesPerRow: 64 * 4, from: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0)
            let mid = Array(px[(32 * 64 + 32) * 4..<(32 * 64 + 32) * 4 + 4]), corner = Array(px[(2 * 64 + 2) * 4..<(2 * 64 + 2) * 4 + 4])
            // BGRA: the box red in the middle, the clear color blue in the corner
            try expect(mid[2] > 180 && mid[0] < 80 && mid[1] < 80, "box pixel BGRA \(mid)")
            try expect(corner[0] > 180 && corner[2] < 80, "background pixel BGRA \(corner)")
            return "middle BGRA \(mid), corner \(corner)"
        })
        c.append(check("RealityKit", "ecs-system-animation-raycast", timeout: 60) {
            // custom Component + System, a transform animation and a scene raycast, driven by RealityRenderer.update
            return try await onMain {
                SDKCovSpin.registerComponent(); SDKCovSpinSystem.registerSystem()
                let r = try RealityRenderer()
                let box = ModelEntity(mesh: .generateBox(size: 0.2), materials: [SimpleMaterial(color: .green, isMetallic: false)])
                box.name = "target"; box.components.set(SDKCovSpin())
                box.collision = CollisionComponent(shapes: [.generateBox(size: [0.2, 0.2, 0.2])])
                let mover = Entity(); mover.name = "mover"
                r.entities.append(box); r.entities.append(mover)
                mover.move(to: Transform(translation: [1, 0, 0]), relativeTo: nil, duration: 0.2, timingFunction: .linear)
                for _ in 0..<12 { try r.update(0.05) }
                let ticks = box.components[SDKCovSpin.self]?.ticks ?? 0
                try expect(ticks >= 1, "the custom System never ran (ticks \(ticks))")
                try expect(abs(mover.position.x - 1) < 0.05, "move(to:) animation ended at \(mover.position)")
                guard let scene = box.scene else { throw Fail("the entity has no scene") }
                let hits = scene.raycast(origin: [0, 0, 2], direction: [0, 0, -1], length: 5, query: .nearest)
                try expect(hits.first?.entity === box, "raycast hit \(hits.map(\.entity.name))")
                try expect(abs((hits.first?.distance ?? 0) - 1.9) < 0.02, "hit distance \(hits.first?.distance ?? -1)")
                return "system ticks \(ticks), mover x \(mover.position.x), hit at \(hits.first!.distance)"
            }
        })
        c.append(check("_RealityKit_SwiftUI", "reality-view-in-window", timeout: 60) {
            // a RealityView in the app's window: its make closure runs and the entities join the view's scene
            let made = SDKCovFlag()
            let host = try await onMain {
                try hostInWindow(RealityView { content in
                    let e = ModelEntity(mesh: .generateSphere(radius: 0.05), materials: [SimpleMaterial(color: .blue, isMetallic: false)])
                    e.name = "sdkcov-sphere"; content.add(e)
                    made.set(e.scene != nil ? "in scene" : "no scene")
                }.frame(width: 300, height: 300))
            }
            defer { Task { @MainActor in host.view.removeFromSuperview(); host.removeFromParent() } }
            guard let how = await made.wait(seconds: 20) else { throw Fail("RealityView's make closure never ran") }
            return "make ran, entity \(how)"
        })

        // MARK: SwiftUI on visionOS: 3D layout (depth, GeometryReader3D) and glass in a real window
        c.append(check("SwiftUI", "depth-geometry3d-glass", timeout: 30) {
            let got = SDKCovFlag()
            let host = try await onMain {
                try hostInWindow(
                    GeometryReader3D { p in
                        Text("sdkcov").padding().glassBackgroundEffect()
                            .onAppear { got.set("\(p.size.width)x\(p.size.height)x\(p.size.depth)") }
                    }
                    .frame(width: 200, height: 120).frame(depth: 80))
                // (no .ornament: its opaque result type needs __isPlatformVersionAtLeast, which the Linux toolchain's
                // compiler-rt for xrOS lacks, so the app would not link)
            }
            defer { Task { @MainActor in host.view.removeFromSuperview(); host.removeFromParent() } }
            guard let s = await got.wait(seconds: 15) else { throw Fail("GeometryReader3D content never appeared") }
            try expect(s.hasPrefix("200.0x120.0x"), "3D size \(s)")
            try expect(s.hasSuffix("x80.0"), "depth not proposed: \(s)")
            return "proxy \(s)"
        })
        // MARK: windows, volumes and immersive spaces: open + dismiss through SwiftUI's environment actions
        c.append(check("SwiftUI", "open-dismiss-window-volume", timeout: 60) {
            try skipIf(!sdkcovMultiScene, "the app declares one scene (shared Harness change: volume + immersive scenes, UIApplicationSupportsMultipleScenes)")
            let a = try await sdkcovSceneActions()
            let before = await onMain { UIApplication.shared.connectedScenes.count }
            await onMain { a.openWindow(id: "sdkcov-volume") }
            let opened = await waitFor(seconds: 15) { await onMain { UIApplication.shared.connectedScenes.count > before } }
            try expect(opened, "openWindow(id:) connected no new scene (\(before) scenes)")
            let made = await SDKCovScenes.volumeMade.wait(seconds: 20)
            let style = await onMain { UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.session.role.rawValue }.joined(separator: ",") }
            await onMain { a.dismissWindow(id: "sdkcov-volume") }
            let closed = await waitFor(seconds: 15) { await onMain { UIApplication.shared.connectedScenes.count == before } }
            let left = await onMain { UIApplication.shared.connectedScenes.count }
            try expect(closed, "dismissWindow(id:) left \(left) scenes")
            try expect(made != nil, "the volume's RealityView never ran its make closure")
            return "roles \(style); volume content \(made!)"
        })
        c.append(check("SwiftUI", "open-dismiss-immersive-space", timeout: 90) {
            try skipIf(!sdkcovMultiScene, "the app declares one scene (shared Harness change: volume + immersive scenes, UIApplicationSupportsMultipleScenes)")
            let a = try await sdkcovSceneActions()
            let r = await a.openImmersiveSpace(id: "sdkcov-immersive")
            guard case .opened = r else { throw Fail("openImmersiveSpace: \(r)") }
            let made = await SDKCovScenes.immersiveMade.wait(seconds: 20)
            let roles = await onMain { UIApplication.shared.connectedScenes.map { $0.session.role.rawValue } }
            try expect(roles.contains { $0.contains("Immersive") }, "no immersive scene session: \(roles)")
            let audio = await SDKCovScenes.immersiveAudio.wait(seconds: 10)
            await a.dismissImmersiveSpace()
            let gone = await waitFor(seconds: 15) { await onMain { !UIApplication.shared.connectedScenes.contains { $0.session.role.rawValue.contains("Immersive") } } }
            try expect(made != nil, "the immersive RealityView never ran its make closure")
            try expect(gone, "dismissImmersiveSpace left the immersive scene connected")
            try expect(audio == "played", "RealityKit spatial audio: \(audio ?? "the tone never finished playing")")
            return "opened + dismissed; content \(made!), spatial audio \(audio!)"
        })

        c.append(check("_CompositorServices_SwiftUI", "immersive-layer-render-frames", timeout: 90) {
            // a full-space Metal renderer: CompositorLayer in an ImmersiveSpace, frames queried, drawables cleared + presented
            try skipIf(!sdkcovMultiScene, "the app declares one scene (shared Harness change: compositor immersive scene, UIApplicationSupportsMultipleScenes)")
            let a = try await sdkcovSceneActions()
            let r = await a.openImmersiveSpace(id: "sdkcov-compositor")
            guard case .opened = r else { throw Fail("openImmersiveSpace: \(r)") }
            let got = await SDKCovScenes.compositorFrames.wait(seconds: 30)
            await a.dismissImmersiveSpace()
            let ended = await SDKCovScenes.compositorEnded.wait(seconds: 15)
            guard let got else { throw Fail("no frames presented (\(SDKCovScenes.compositorState.withLock { $0 }))") }
            try expect(ended != nil, "the layer renderer was not invalidated after the dismiss")
            return "\(got); after dismiss: \(ended!)"
        })

        // MARK: UIKit on visionOS: resizing the window scene (UIWindowScene.GeometryPreferences.Vision)
        c.append(check("UIKit", "window-scene-geometry-resize", timeout: 30) {
            let (ws, size0) = try await onMain { () throws -> (UIWindowScene, CGSize) in
                guard let ws = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { throw Fail("no window scene") }
                return (ws, ws.effectiveGeometry.coordinateSpace.bounds.size)
            }
            let want = CGSize(width: size0.width == 900 ? 1000 : 900, height: size0.height == 700 ? 600 : 700)
            let err = SDKCovFlag()
            await onMain { ws.requestGeometryUpdate(.Vision(size: want)) { e in err.set("\(e)") } }
            let ok = await waitFor(seconds: 10) { await onMain { ws.effectiveGeometry.coordinateSpace.bounds.size == want } }
            let now = await onMain { ws.effectiveGeometry.coordinateSpace.bounds.size }
            await onMain { ws.requestGeometryUpdate(.Vision(size: size0)) }
            if let e = await err.wait(seconds: 0.1) { throw Fail("requestGeometryUpdate: \(e)") }
            try expect(ok, "window \(size0) -> asked \(want), got \(now)")
            let lim = await onMain { (ws.effectiveGeometry.minimumSize, ws.effectiveGeometry.maximumSize) }
            return "\(size0) -> \(now), min \(lim.0) max \(lim.1)"
        })

        // MARK: ARKit: authorization queries and a world-tracking session outside an immersive space
        c.append(check("ARKit", "session-authorization-query") {
            let s = ARKitSession()
            let st = await s.queryAuthorization(for: [.worldSensing, .handTracking])
            try expect(st.count == 2, "statuses \(st)")
            return st.map { "\($0.key) \($0.value)" }.sorted().joined(separator: ", ")
        })
        c.append(check("ARKit", "world-tracking-run-outside-immersive", timeout: 30) {
            try skipIf(!WorldTrackingProvider.isSupported, "world tracking not supported here")
            let s = ARKitSession(), w = WorldTrackingProvider()
            var outcome: String
            do { try await s.run([w]); outcome = "run returned" } catch { outcome = "run threw \(error)" }
            try? await Task.sleep(nanoseconds: 500_000_000)
            let anchor = w.queryDeviceAnchor(atTimestamp: CACurrentMediaTime())
            s.stop()
            return "\(outcome), state \(w.state), device anchor \(anchor == nil ? "nil" : "present")"
        })

        // MARK: CompositorServices: the compositor clock (a LayerRenderer itself needs an immersive CompositorLayer)
        c.append(check("CompositorServices", "layer-renderer-clock") {
            // the clock converts with a mach timebase that CompositorNonUI fills in +[CP_OBJECT_cp_layer_renderer initialize]
            // (no initializers, no +load): until a layer renderer class is touched, Clock.now reads 0, on Apple's side too
            guard let lr = NSClassFromString("CP_OBJECT_cp_layer_renderer") as? NSObject.Type else { throw Fail("no CP_OBJECT_cp_layer_renderer class") }
            var n: UInt32 = 0; let ms = class_copyMethodList(object_getClass(lr), &n)
            let sels = (0..<Int(n)).map { NSStringFromSelector(method_getName(ms![$0])) }; free(ms)
            _ = lr.perform(NSSelectorFromString("self"))   // any message runs +initialize
            let clock = LayerRenderer.Clock()
            let t0 = clock.now
            try await clock.sleep(until: t0.advanced(by: .milliseconds(30)), tolerance: nil)
            let d = t0.duration(to: clock.now)
            let raw = { (i: LayerRenderer.Clock.Instant) in withUnsafeBytes(of: i) { Array($0) } }
            try expect(d >= .milliseconds(29) && d < .seconds(2), "slept \(d) (instants \(raw(t0)) -> \(raw(clock.now)), mach \(mach_absolute_time()))")
            let enc = try JSONEncoder().encode(t0), dec = try JSONDecoder().decode(LayerRenderer.Clock.Instant.self, from: enc)
            try expect(dec == t0, "Instant codable")
            return "slept \(d), resolution \(clock.minimumResolution), layer renderer class methods \(sels)"
        })

        // MARK: spatial audio: AVAudioEnvironmentNode (offline) and PHASE playing a sound event through a spatial mixer
        c.append(check("AVFAudio", "environment-node-spatial-offline") {
            let e = AVAudioEngine(), p = AVAudioPlayerNode(), env = AVAudioEnvironmentNode()
            e.attach(p); e.attach(env)
            let src = sine(440, secs: 0.5)
            e.connect(p, to: env, format: src.format)   // mono into the environment node: spatialized
            e.connect(env, to: e.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
            p.renderingAlgorithm = .equalPowerPanning
            p.position = AVAudio3DPoint(x: -3, y: 0, z: 0)   // to the listener's left
            env.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
            try e.enableManualRenderingMode(.offline, format: AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!, maximumFrameCount: 4096)
            try e.start(); p.scheduleBuffer(src); p.play()
            let out = AVAudioPCMBuffer(pcmFormat: e.manualRenderingFormat, frameCapacity: 4096)!
            var l: Float = 0, r: Float = 0
            for _ in 0..<4 {
                let st = try e.renderOffline(4096, to: out); try expect(st == .success, "render \(st.rawValue)")
                for i in 0..<Int(out.frameLength) { l += abs(out.floatChannelData![0][i]); r += abs(out.floatChannelData![1][i]) }
            }
            e.stop()
            try expect(l > 1, "rendered silence (L \(l), R \(r))")
            try expect(l > r * 2, "source on the left is not louder on the left: L \(l), R \(r)")
            return String(format: "L %.1f R %.1f", l, r)
        })
        c.append(check("PHASE", "spatial-sound-event-playback", timeout: 60) {
            let e = PHASEEngine(updateMode: .automatic)
            let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
            let tone = sine(440, secs: 0.3, rate: 48000)
            let data = Data(bytes: tone.floatChannelData![0], count: Int(tone.frameLength) * 4)
            _ = try e.assetRegistry.registerSoundAsset(data: data, identifier: "sdkcov-tone", format: fmt, normalizationMode: .dynamic)
            guard let pipe = PHASESpatialPipeline(flags: [.directPathTransmission]) else { throw Fail("spatial pipeline") }
            let mixer = PHASESpatialMixerDefinition(spatialPipeline: pipe)
            let sampler = PHASESamplerNodeDefinition(soundAssetIdentifier: "sdkcov-tone", mixerDefinition: mixer)
            sampler.playbackMode = .oneShot; sampler.setCalibrationMode(calibrationMode: .relativeSpl, level: 0)
            _ = try e.assetRegistry.registerSoundEventAsset(rootNode: sampler, identifier: "sdkcov-event")
            let listener = PHASEListener(engine: e); listener.transform = matrix_identity_float4x4
            try e.rootObject.addChild(listener)
            let shape = PHASEShape(engine: e, mesh: MDLMesh.newIcosahedron(withRadius: 0.1, inwardNormals: false, allocator: nil))
            let source = PHASESource(engine: e, shapes: [shape])
            var t = matrix_identity_float4x4; t.columns.3 = [1, 0, -1, 1]; source.transform = t
            try e.rootObject.addChild(source)
            let params = PHASEMixerParameters(); params.addSpatialMixerParameters(identifier: mixer.identifier, source: source, listener: listener)
            let ev = try PHASESoundEvent(engine: e, assetIdentifier: "sdkcov-event", mixerParameters: params)
            do { try e.start() } catch { throw Fail("engine start: \(error)") }
            defer { e.stop(); e.assetRegistry.unregisterAsset(identifier: "sdkcov-event"); e.assetRegistry.unregisterAsset(identifier: "sdkcov-tone") }
            let done = SDKCovFlag()
            ev.start { reason in done.set("\(reason.rawValue)") }
            guard let reason = await done.wait(seconds: 15) else { throw Fail("the sound event never finished (state \(ev.renderingState.rawValue))") }
            try expect(reason == "\(PHASESoundEvent.StartHandlerReason.finishedPlaying.rawValue)", "event ended with reason \(reason)")
            return "finished playing (spatial mixer, source at 1,0,-1)"
        })

        // MARK: system services Apple's simulator answers without an account (checked against Apple's visionOS 27.2 24N120
        // simulator, ref-mac.sh xros: before x86Sim ran ctkd, syncdefaultsd, accountsd and amsaccountsd these came back
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

        // MARK: SharePlay
        c.append(check("GroupActivities", "activity-sessions") {
            // an activity's metadata and its session stream: no FaceTime call, so no session arrives
            let act = SDKCovActivity()
            let md = act.metadata
            try expect(md.title == "sdkcov" && md.type == .generic, "metadata \(String(describing: md.title))")
            let got = SDKCovFlag()
            let t = Task { for await s in SDKCovActivity.sessions() { got.set("\(s.state)"); break } }
            let s = await got.wait(seconds: 2); t.cancel()
            return "metadata ok, \(s.map { "session \($0)" } ?? "no session (no FaceTime call)")"
        })

        // MARK: frameworks only loaded so far
        c.append(check("ManagedApp", "configuration-provider") {
            // an unmanaged app: Apple's simulator (visionOS 27.2 24N120, ref-mac.sh xros) never yields on the configuration
            // stream (managedappsd has nothing to send). A stream that yields nil at once means managedappsd was not
            // reachable (x86Sim before it ran com.apple.devicemanagementclient.managedappsd)
            struct Cfg: Decodable { let x: Int? }
            let got = SDKCovFlag()
            let t = Task { for await c in await ManagedAppConfigurationProvider().configurations(Cfg.self) { got.set(c == nil ? "nil" : "a configuration"); break } }
            let v = await got.wait(seconds: 10); t.cancel()
            if let v { throw Fail("the stream yielded \(v) for an unmanaged app (Apple's yields nothing: managedappsd unreachable?)") }
            return "no configuration in 10 s (unmanaged app, as on Apple's simulator)"
        })
        c.append(check("StateReporting", "metadata-values-reporter") {
            let vals: [ReportableMetadataValue] = [.init("s"), .init(42), .init(true), .init(1.5), .init(Date(timeIntervalSince1970: 0))]
            let d = try JSONEncoder().encode(vals), back = try JSONDecoder().decode([ReportableMetadataValue].self, from: d)
            try expect(back == vals, "codable round trip")
            let rep = StateReporter<Never, Never>.reporter(for: "com.x86sim.test.sdkcov")
            rep.reportTransition(to: "checking")
            return "\(d.count) B"
        })
        c.append(check("ImmersiveMediaSupport", "video-frame-fade-command") {
            var pb: CVPixelBuffer?
            try expect(CVPixelBufferCreate(nil, 128, 64, kCVPixelFormatType_32BGRA, [kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &pb) == kCVReturnSuccess, "pixel buffer")
            let f = ImmersiveVideoFrame(pixelBuffer: pb!, presentationTime: CMTime(value: 1, timescale: 30))
            try expect(f == ImmersiveVideoFrame(pixelBuffer: pb!, presentationTime: CMTime(value: 1, timescale: 30)), "frame equality")
            let fc = FadeCommand(id: 1, time: .zero, duration: CMTime(value: 1, timescale: 1), direction: .out, color: [0, 0, 0])
            let d = try JSONEncoder().encode(FadeCommand.FadeDirection.out)
            try expect(try JSONDecoder().decode(FadeCommand.FadeDirection.self, from: d) == .out, "fade direction codable")
            _ = fc
            return "frame + fade command"
        })
        c.append(check("MediaIntents", "audio-search-codable") {
            let s = AudioSearch(criteria: .searchQuery("sdkcov"))
            let back = try JSONDecoder().decode(AudioSearch.self, from: JSONEncoder().encode(s))
            try expect(back == s, "round trip")
            return "ok"
        })
        c.append(check("SuggestedActions", "message") {
            let me = SuggestedActionsMessage.Participant(name: "sdkcov", handle: "sdkcov@example.com", isUser: true)
            _ = SuggestedActionsMessage(id: 1, date: Date(), subject: nil, body: AttributedString("hello"), sender: me, recipients: [me])
            return "previous messages limit \(SuggestedActionsMessage.previousMessagesLimit)"
        })
        c.append(check("RelevanceKit", "contexts") {
            let now = Date()
            let cs: [RelevantContext] = [.date(now), .date(interval: DateInterval(start: now, duration: 60), kind: .default), .location(inferred: .home), .hardware(headphones: .connected)]
            return "\(cs.count) contexts"
        })
        c.append(check("AVRouting", "custom-routing-controller") {
            let rc = AVCustomRoutingController()
            return "\(rc.authorizedRoutes.count) authorized routes"
        })
        #endif
        return c
    }
}

#if os(visionOS)
/// a one-shot value set from any thread, awaited with a timeout
final class SDKCovFlag: @unchecked Sendable {
    private let lock = NSLock(); private var v: String?
    func set(_ s: String) { lock.withLock { if v == nil { v = s } } }
    func wait(seconds: Double) async -> String? {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if let v = lock.withLock({ v }) { return v }; try? await Task.sleep(nanoseconds: 20_000_000) }
        return lock.withLock { v }
    }
}
func waitFor(seconds: Double, _ cond: () async -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { if await cond() { return true }; try? await Task.sleep(nanoseconds: 50_000_000) }
    return await cond()
}
extension DispatchSemaphore {
    func waitAsync(seconds: Double, _ msg: String) async throws {
        let ok = await withCheckedContinuation { k in DispatchQueue.global().async { k.resume(returning: self.wait(timeout: .now() + seconds) == .success) } }
        if !ok { throw Fail(msg) }
    }
}
/// put a SwiftUI view into the app's key window (on top of the results view), laid out
@MainActor func hostInWindow<V: View>(_ v: V) throws -> UIHostingController<V> {
    guard let ws = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
          let w = ws.windows.first(where: { $0.isKeyWindow }) ?? ws.windows.first, let root = w.rootViewController else { throw Fail("no window") }
    let h = UIHostingController(rootView: v)
    root.addChild(h); h.view.frame = CGRect(x: 0, y: 0, width: 400, height: 400); root.view.addSubview(h.view); h.didMove(toParent: root)
    h.view.layoutIfNeeded()
    return h
}
struct SDKCovSpin: Component { var ticks = 0 }
final class SDKCovSpinSystem: System {
    static let query = EntityQuery(where: .has(SDKCovSpin.self))
    required init(scene: RealityKit.Scene) {}
    func update(context: SceneUpdateContext) {
        for e in context.entities(matching: Self.query, updatingSystemWhen: .rendering) { e.components[SDKCovSpin.self]?.ticks += 1 }
    }
}
struct SDKCovActivity: GroupActivity {
    static let activityIdentifier = "com.x86sim.test.sdkcov.activity"
    var metadata: GroupActivityMetadata { var m = GroupActivityMetadata(); m.title = "sdkcov"; m.type = .generic; return m }
}

// MARK: scenes for the window / volume / immersive-space checks
/// whether the app can show more than one scene (Info.plist UIApplicationSupportsMultipleScenes)
var sdkcovMultiScene: Bool {
    ((Bundle.main.object(forInfoDictionaryKey: "UIApplicationSceneManifest") as? [String: Any])?["UIApplicationSupportsMultipleScenes"] as? Bool) ?? false
}
/// what the scenes' content reports when SwiftUI builds it
enum SDKCovScenes {
    static let volumeMade = SDKCovFlag(), immersiveMade = SDKCovFlag(), immersiveAudio = SDKCovFlag()
    /// the content of SDKCovApp's WindowGroup(id: "sdkcov-volume") (.windowStyle(.volumetric)) and ImmersiveSpace(id: "sdkcov-immersive")
    @MainActor static func volume() -> some View {
        RealityView { content in
            content.add(ModelEntity(mesh: .generateBox(size: 0.1), materials: [SimpleMaterial(color: .orange, isMetallic: false)]))
            volumeMade.set("\(content.entities.count) entities")
        }
    }
    static let compositorFrames = SDKCovFlag(), compositorEnded = SDKCovFlag()
    static let compositorState = Mutex("not started")
    /// the content of SDKCovApp's ImmersiveSpace(id: "sdkcov-compositor")
    @MainActor static func compositor() -> some ImmersiveSpaceContent {
        CompositorLayer { lr in
            let t = Thread { renderLoop(lr) }; t.name = "sdkcov compositor"; t.start()
        }
    }
    static func renderLoop(_ lr: LayerRenderer) {
        compositorState.withLock { $0 = "waiting until running" }
        lr.waitUntilRunning()
        guard let q = lr.device.makeCommandQueue() else { compositorState.withLock { $0 = "no command queue" }; return }
        var n = 0, nodraw = 0, info = ""
        while true {
            switch lr.state {
            case .invalidated: compositorEnded.set("invalidated after \(n) frames"); return
            case .paused: compositorState.withLock { $0 = "paused after \(n) frames" }; lr.waitUntilRunning(); continue
            default: break
            }
            guard let f = lr.queryNextFrame() else { compositorState.withLock { $0 = "no frame after \(n)" }; continue }
            f.startUpdate(); f.endUpdate()
            if let t = f.predictTiming() { LayerRenderer.Clock().wait(until: t.optimalInputTime) }
            f.startSubmission()
            guard let d = f.queryDrawable() else {   // a frame without a drawable is dropped as is (no endSubmission)
                nodraw += 1; compositorState.withLock { $0 = "no drawable after \(n) frames (\(nodraw) times)" }; continue
            }
            let cb = q.makeCommandBuffer()!
            let rp = MTLRenderPassDescriptor(), ct = d.colorTextures[0]
            rp.colorAttachments[0].texture = ct; rp.colorAttachments[0].loadAction = .clear; rp.colorAttachments[0].storeAction = .store
            rp.colorAttachments[0].clearColor = MTLClearColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
            if let dt = d.depthTextures.first { rp.depthAttachment.texture = dt; rp.depthAttachment.loadAction = .clear; rp.depthAttachment.clearDepth = 0; rp.depthAttachment.storeAction = .store }
            if ct.textureType == .type2DArray { rp.renderTargetArrayLength = ct.arrayLength }
            rp.rasterizationRateMap = d.rasterizationRateMaps.first
            cb.makeRenderCommandEncoder(descriptor: rp)?.endEncoding()
            d.encodePresent(commandBuffer: cb); cb.commit(); f.endSubmission()
            n += 1
            if n == 1 { info = "\(ct.width)x\(ct.height) \(ct.pixelFormat.rawValue) type \(ct.textureType.rawValue) x\(ct.arrayLength), \(d.views.count) views, layout \(lr.configuration.layout)" }
            if n == 30 { cb.waitUntilCompleted(); compositorFrames.set("30 frames (\(nodraw) without drawable), \(info), last command buffer status \(cb.status.rawValue)") }
            compositorState.withLock { $0 = "\(n) frames" }
        }
    }
    @MainActor static func immersive() -> some View {
        RealityView { content in
            let e = ModelEntity(mesh: .generateSphere(radius: 0.2), materials: [SimpleMaterial(color: .cyan, isMetallic: false)])
            e.position = [0, 1.5, -1.5]; content.add(e)
            immersiveMade.set("\(content.entities.count) entities")
            // RealityKit spatial audio: a short tone from the sphere (SpatialAudioComponent, PHASE underneath)
            e.spatialAudio = SpatialAudioComponent(gain: -6)
            do {
                let res = try AudioBufferResource(buffer: sine(440, secs: 0.3, rate: 48000), configuration: .init(shouldLoop: false))
                let ctl = e.playAudio(res)
                ctl.completionHandler = { immersiveAudio.set("played") }
            } catch { immersiveAudio.set("AudioBufferResource: \(error)") }
        }
    }
}
/// SwiftUI's scene actions, captured from a view hosted in the main window
struct SDKCovSceneActions {
    let openWindow: OpenWindowAction, dismissWindow: DismissWindowAction
    let openImmersiveSpace: OpenImmersiveSpaceAction, dismissImmersiveSpace: DismissImmersiveSpaceAction
}
private struct SDKCovActionGrabber: View {
    @Environment(\.openWindow) var ow; @Environment(\.dismissWindow) var dw
    @Environment(\.openImmersiveSpace) var oi; @Environment(\.dismissImmersiveSpace) var di
    let got: (SDKCovSceneActions) -> Void
    var body: some View { Color.clear.frame(width: 1, height: 1).onAppear { got(SDKCovSceneActions(openWindow: ow, dismissWindow: dw, openImmersiveSpace: oi, dismissImmersiveSpace: di)) } }
}
@MainActor private var sdkcovActions: SDKCovSceneActions?
func sdkcovSceneActions() async throws -> SDKCovSceneActions {
    if let a = await onMain({ sdkcovActions }) { return a }
    _ = try await onMain { try hostInWindow(SDKCovActionGrabber { sdkcovActions = $0 }) }
    guard await waitFor(seconds: 10, { await onMain { sdkcovActions != nil } }) else { throw Fail("no SwiftUI environment in a hosted view") }
    return await onMain { sdkcovActions! }
}
#endif
