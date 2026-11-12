// sdkcov functional checks: audio and video. Audio renders offline (AVAudioEngine manual rendering) so no output
// device is needed; video is written with AVAssetWriter / VideoToolbox and read back.
import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
#if canImport(AudioToolbox)
import AudioToolbox
#endif
#if canImport(VideoToolbox)
import VideoToolbox
#endif
#if canImport(CoreMIDI)
import CoreMIDI
#endif
#if canImport(MediaPlayer)
import MediaPlayer
#endif
#if canImport(AVKit)
import AVKit
#endif
#if canImport(ShazamKit)
import ShazamKit
#endif
#if canImport(SoundAnalysis)
import SoundAnalysis
#endif
#if canImport(Speech)
import Speech
#endif
#if canImport(PHASE)
import PHASE
#endif
#if canImport(OpenAL)
import OpenAL
#endif
#if canImport(MusicKit)
import MusicKit
#endif
#if canImport(MediaAccessibility)
import MediaAccessibility
#endif

/// a mono float sine buffer
func sine(_ hz: Double, secs: Double, rate: Double = 44100) -> AVAudioPCMBuffer {
    let f = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
    let n = AVAudioFrameCount(secs * rate)
    let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: n)!; b.frameLength = n
    for i in 0..<Int(n) { b.floatChannelData![0][i] = Float(0.5 * sin(2 * .pi * hz * Double(i) / rate)) }
    return b
}
func rms(_ b: AVAudioPCMBuffer) -> Float {
    let p = b.floatChannelData![0]; var s: Float = 0
    for i in 0..<Int(b.frameLength) { s += p[i] * p[i] }
    return (s / Float(max(b.frameLength, 1))).squareRoot()
}
#if !os(watchOS)
/// write `frames` solid-color BGRA frames as an H.264 .mov with AVAssetWriter
func writeMovie(_ url: URL, frames: Int = 30, size: Int = 128) async throws {
    try? FileManager.default.removeItem(at: url)
    let w = try AVAssetWriter(outputURL: url, fileType: .mov)
    let inp = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size, AVVideoHeightKey: size])
    let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: inp, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: size, kCVPixelBufferHeightKey as String: size])
    w.add(inp)
    try expect(w.startWriting(), "startWriting: \(String(describing: w.error))")
    w.startSession(atSourceTime: .zero)
    for i in 0..<frames {
        while !inp.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
        var pb: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil, ad.pixelBufferPool!, &pb)
        CVPixelBufferLockBaseAddress(pb!, []); memset(CVPixelBufferGetBaseAddress(pb!), Int32(i * 8), CVPixelBufferGetDataSize(pb!)); CVPixelBufferUnlockBaseAddress(pb!, [])
        try expect(ad.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30)), "append frame \(i): \(String(describing: w.error))")
    }
    inp.markAsFinished()
    await w.finishWriting()
    try expect(w.status == .completed, "finishWriting: \(String(describing: w.error))")
}
#endif

extension Registry {
    static var media: [Check] {
        var c: [Check] = [
            check("AVFAudio", "engine-offline-render-effects") {
                let e = AVAudioEngine(); let p = AVAudioPlayerNode(); e.attach(p)
                let src = sine(440, secs: 0.5)
                #if os(watchOS)
                e.connect(p, to: e.mainMixerNode, format: src.format)   // no effect units on watchOS
                #else
                let rev = AVAudioUnitReverb(), eq = AVAudioUnitEQ(numberOfBands: 2)
                rev.loadFactoryPreset(.mediumHall); rev.wetDryMix = 30
                e.attach(rev); e.attach(eq)
                e.connect(p, to: eq, format: src.format); e.connect(eq, to: rev, format: src.format); e.connect(rev, to: e.mainMixerNode, format: src.format)
                #endif
                let f = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
                try e.enableManualRenderingMode(.offline, format: f, maximumFrameCount: 4096)
                try e.start(); p.scheduleBuffer(src); p.play()
                let out = AVAudioPCMBuffer(pcmFormat: e.manualRenderingFormat, frameCapacity: 4096)!
                var total: Float = 0
                for _ in 0..<4 { let st = try e.renderOffline(4096, to: out); try expect(st == .success, "render \(st.rawValue)"); total += rms(out) }
                e.stop()
                try expect(total > 0.05, "rendered silence (rms \(total))")
                return "rms \(total)"
            },
            check("AVFAudio", "engine-realtime-output", timeout: 30) {
                // the output device in real time (AURemoteIO), as apps play sound: silence, rendered for half a second
                let e = AVAudioEngine(); let p = AVAudioPlayerNode(); e.attach(p)
                let fmt = e.outputNode.outputFormat(forBus: 0)
                try expect(fmt.sampleRate > 0 && fmt.channelCount > 0, "no output format (\(fmt))")
                let silence = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: fmt.sampleRate, channels: 1)!, frameCapacity: 4800)!
                silence.frameLength = 4800
                e.connect(p, to: e.mainMixerNode, format: silence.format); e.mainMixerNode.outputVolume = 0
                do { try e.start() } catch { throw Fail("engine start: \(error)") }
                let done = DispatchSemaphore(value: 0)
                p.scheduleBuffer(silence, completionCallbackType: .dataPlayedBack) { _ in done.signal() }
                p.play()
                let played = done.wait(timeout: .now() + 5) == .success
                e.stop()
                try expect(played, "the buffer was never played back (no render callbacks)")
                return "\(Int(fmt.sampleRate)) Hz x \(fmt.channelCount)"
            },
            check("AVFAudio", "file-converter-aac") {
                let dir = FileManager.default.temporaryDirectory
                let src = sine(1000, secs: 1)
                // CAF float, then AAC in .m4a
                let caf = dir.appendingPathComponent("sdkcov.caf"), m4a = dir.appendingPathComponent("sdkcov.m4a")
                defer { try? FileManager.default.removeItem(at: caf); try? FileManager.default.removeItem(at: m4a) }
                do { let f = try AVAudioFile(forWriting: caf, settings: src.format.settings); try f.write(from: src) }
                do { let f = try AVAudioFile(forWriting: m4a, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000]); try f.write(from: src) }
                let r = try AVAudioFile(forReading: m4a)
                try expect(abs(Int(r.length) - 44100) < 4096, "AAC length \(r.length)")
                let back = AVAudioPCMBuffer(pcmFormat: r.processingFormat, frameCapacity: AVAudioFrameCount(r.length))!
                try r.read(into: back)
                try expect(rms(back) > 0.2, "AAC decode rms \(rms(back))")
                // sample-rate conversion 44.1k -> 16k
                let to = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
                let conv = AVAudioConverter(from: src.format, to: to)!
                let out = AVAudioPCMBuffer(pcmFormat: to, frameCapacity: 17000)!
                var given = false; var err: NSError?
                conv.convert(to: out, error: &err) { _, st in if given { st.pointee = .endOfStream; return nil }; given = true; st.pointee = .haveData; return src }
                try expect(err == nil && abs(Int(out.frameLength) - 16000) < 200, "converted \(out.frameLength) \(String(describing: err))")
                return "m4a \(try FileManager.default.attributesOfItem(atPath: m4a.path)[.size] ?? 0) B"
            },
            check("AVFAudio", "session-category") {
                #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
                let s = AVAudioSession.sharedInstance()
                try s.setCategory(.playback, mode: .default)
                try expect(s.category == .playback, "category \(s.category)")
                return "rate \(s.sampleRate), outputs \(s.currentRoute.outputs.map(\.portType.rawValue))"
                #else
                throw Skip("no AVAudioSession")
                #endif
            },
            check("AVFAudio", "speech-synthesis-to-buffer", timeout: 60) {
                let syn = AVSpeechSynthesizer()
                let voices = AVSpeechSynthesisVoice.speechVoices()
                try expect(!voices.isEmpty, "no speech voices (Apple's simulator lists them)")
                let u = AVSpeechUtterance(string: "x86 sim"); u.voice = AVSpeechSynthesisVoice(language: "en-US") ?? voices[0]
                let frames: Int = await withCheckedContinuation { c in
                    var n = 0, done = false
                    syn.write(u) { b in
                        guard !done else { return }
                        if let p = b as? AVAudioPCMBuffer, p.frameLength > 0 { n += Int(p.frameLength) } else { done = true; c.resume(returning: n) }
                    }
                }
                try expect(frames > 1000, "synthesized \(frames) frames")
                return "\(voices.count) voices, \(frames) frames"
            },
            check("CoreMedia", "time-formats-samplebuffers") {
                let t = CMTimeAdd(CMTime(value: 1, timescale: 3), CMTime(value: 1, timescale: 6))
                try expect(CMTimeCompare(t, CMTime(value: 1, timescale: 2)) == 0, "CMTime \(t)")
                var pb: CVPixelBuffer?; CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &pb)
                var fd: CMVideoFormatDescription?
                try expect(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb!, formatDescriptionOut: &fd) == noErr, "format")
                var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
                var sb: CMSampleBuffer?
                try expect(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb!, formatDescription: fd!, sampleTiming: &timing, sampleBufferOut: &sb) == noErr, "sample buffer")
                try expect(CMSampleBufferIsValid(sb!), "valid")
                return "ok"
            },
        ]
        #if canImport(AudioToolbox)
        c.append(
            check("AudioToolbox", "components-extaudiofile") {
                var d = AudioComponentDescription(componentType: 0, componentSubType: 0, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
                var n = 0; var comp: AudioComponent? = nil
                repeat { comp = AudioComponentFindNext(comp, &d); if comp != nil { n += 1 } } while comp != nil
                try expect(n > 10, "Apple audio units \(n)")
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("sdkcov-ext.wav") as CFURL
                var asbd = AudioStreamBasicDescription(mSampleRate: 8000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked, mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
                var f: ExtAudioFileRef?
                try expect(ExtAudioFileCreateWithURL(url, kAudioFileWAVEType, &asbd, nil, AudioFileFlags.eraseFile.rawValue, &f) == noErr, "create")
                var samples = [Int16](repeating: 1000, count: 8000)
                let st = samples.withUnsafeMutableBytes { p -> OSStatus in
                    var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 16000, mData: p.baseAddress))
                    return ExtAudioFileWrite(f!, 8000, &abl)
                }
                ExtAudioFileDispose(f!)
                try expect(st == noErr, "write \(st)")
                var af: AudioFileID?; try expect(AudioFileOpenURL(url, .readPermission, 0, &af) == noErr, "open")
                var pk: UInt64 = 0, sz = UInt32(8)
                AudioFileGetProperty(af!, kAudioFilePropertyAudioDataPacketCount, &sz, &pk); AudioFileClose(af!)
                try expect(pk == 8000, "packets \(pk)")
                return "\(n) Apple audio units"
            })
        #endif
        #if !os(watchOS)
        c.append(check("AVFoundation", "assetwriter-asset-imagegen", timeout: 120) {
            let u = FileManager.default.temporaryDirectory.appendingPathComponent("sdkcov.mov")
            defer { try? FileManager.default.removeItem(at: u) }
            try await writeMovie(u)
            let a = AVURLAsset(url: u)
            let (dur, tracks) = try await a.load(.duration, .tracks)
            try expect(abs(dur.seconds - 1.0) < 0.1 && tracks.count == 1, "duration \(dur.seconds), \(tracks.count) tracks")
            let size = try await tracks[0].load(.naturalSize)
            try expect(size == CGSize(width: 128, height: 128), "size \(size)")
            let g = AVAssetImageGenerator(asset: a); g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
            let (img, _) = try await g.image(at: CMTime(value: 15, timescale: 30))
            try expect(img.width == 128, "frame \(img.width)")
            // reader: decode every frame
            let r = try AVAssetReader(asset: a)
            let o = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]); r.add(o)
            try expect(r.startReading(), "reader \(String(describing: r.error))")
            var n = 0; while o.copyNextSampleBuffer() != nil { n += 1 }
            try expect(n == 30, "decoded \(n) frames")
            // player item becomes ready
            let item = AVPlayerItem(asset: a); let p = AVPlayer(playerItem: item); p.isMuted = true
            for _ in 0..<100 where item.status == .unknown { try await Task.sleep(for: .milliseconds(100)) }
            try expect(item.status == .readyToPlay, "player item \(item.status.rawValue) \(String(describing: item.error))")
            return "1 s H.264, 30 frames decoded"
        })
        c.append(check("AVFoundation", "capture-devices") {
            let cams = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified).devices
            try skipIf(cams.isEmpty, "no cameras in the Simulator (Apple's has none either)")
            return "\(cams.count) cameras"
        })
        #endif
        #if canImport(VideoToolbox)
        c.append(check("VideoToolbox", "h264-hevc-encode-decode", timeout: 90) {
            var res: [String] = []
            // SDKCOV_VT_SIZE=<w>x<h>: another frame size (debugging the encoders)
            let sz = (ProcessInfo.processInfo.environment["SDKCOV_VT_SIZE"] ?? "128x128").split(separator: "x").compactMap { Int32($0) }
            let (W, H) = (sz.first ?? 128, sz.last ?? 128)
            for (name, codec) in [("H.264", kCMVideoCodecType_H264), ("HEVC", kCMVideoCodecType_HEVC)] {
                var s: VTCompressionSession?
                let st = VTCompressionSessionCreate(allocator: nil, width: W, height: H, codecType: codec, encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &s)
                if codec == kCMVideoCodecType_HEVC && st != noErr { res.append("HEVC encoder unavailable (\(st))"); continue }
                try expect(st == noErr, "\(name) session \(st)")
                var outs: [CMSampleBuffer] = []
                for i in 0..<10 {
                    var pb: CVPixelBuffer?; CVPixelBufferCreate(nil, Int(W), Int(H), kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
                    VTCompressionSessionEncodeFrame(s!, imageBuffer: pb!, presentationTimeStamp: CMTime(value: CMTimeValue(i), timescale: 30), duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { st, _, sb in
                        if st == noErr, let sb { outs.append(sb) }
                    }
                }
                VTCompressionSessionCompleteFrames(s!, untilPresentationTimeStamp: .invalid)
                let doneAt = outs.count   // frames out when CompleteFrames returned (all of them, by its contract)
                if let w = ProcessInfo.processInfo.environment["SDKCOV_VT_SLEEP"], let t = Double(w) { Thread.sleep(forTimeInterval: t) }
                VTCompressionSessionInvalidate(s!)
                try expect(doneAt == 10, "\(name): CompleteFrames returned with \(doneAt)/10 frames out")
                try expect(outs.count == 10, "\(name) encoded \(outs.count) frames")
                var d: VTDecompressionSession?
                try expect(VTDecompressionSessionCreate(allocator: nil, formatDescription: CMSampleBufferGetFormatDescription(outs[0])!, decoderSpecification: nil, imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &d) == noErr, "\(name) decoder")
                var decoded = 0
                for sb in outs { VTDecompressionSessionDecodeFrame(d!, sampleBuffer: sb, flags: [], infoFlagsOut: nil) { st, _, ib, _, _ in if st == noErr, ib != nil { decoded += 1 } } }
                VTDecompressionSessionWaitForAsynchronousFrames(d!); VTDecompressionSessionInvalidate(d!)
                try expect(decoded == 10, "\(name) decoded \(decoded)")
                res.append("\(name) 10/10 \(outs.reduce(0) { $0 + CMSampleBufferGetTotalSampleSize($1) }) B")
            }
            return res.joined(separator: ", ")
        })
        #endif
        #if canImport(CoreMIDI) && (os(iOS) || os(visionOS))
        c.append(check("CoreMIDI", "virtual-loopback") {
            var client = MIDIClientRef(); let cs = MIDIClientCreateWithBlock("sdkcov" as CFString, &client, nil); try expect(cs == noErr, "MIDIClientCreate \(cs)")
            defer { MIDIClientDispose(client) }
            let got = NSLock(); var notes: [UInt32] = []
            var dst = MIDIEndpointRef()
            // Apple's simulator: the client works, a virtual destination does not (checked on 24B8117)
            try skipIf(MIDIDestinationCreateWithProtocol(client, "sdkcov-in" as CFString, ._1_0, &dst) { list, _ in
                let p = list.pointee.packet   // one packet per send here
                if list.pointee.numPackets > 0 { got.withLock { notes.append(p.words.0) } }
            } != noErr, "client OK; virtual MIDI endpoints are not available in Apple's simulator")
            var port = MIDIPortRef(); try expect(MIDIOutputPortCreate(client, "out" as CFString, &port) == noErr, "port")
            var el = MIDIEventList(); let pkt = MIDIEventListInit(&el, ._1_0)
            var w: UInt32 = 0x2090_3C64   // UMP MIDI 1.0 channel voice: note on, middle C, velocity 100
            _ = MIDIEventListAdd(&el, MemoryLayout<MIDIEventList>.size, pkt, 0, 1, &w)
            try expect(MIDISendEventList(port, dst, &el) == noErr, "send")
            for _ in 0..<50 where got.withLock({ notes.isEmpty }) { try await Task.sleep(for: .milliseconds(20)) }
            try expect(got.withLock { notes } == [0x2090_3C64], "received \(got.withLock { notes.map { String($0, radix: 16) } })")
            return "\(MIDIGetNumberOfDestinations()) destinations"
        })
        #endif
        #if canImport(MediaPlayer)
        c.append(check("MediaPlayer", "nowplaying-remote-commands") {
            let info = MPNowPlayingInfoCenter.default()
            info.nowPlayingInfo = [MPMediaItemPropertyTitle: "sdkcov", MPMediaItemPropertyPlaybackDuration: 42.0]
            try expect(info.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "sdkcov", "nowPlayingInfo")
            let t = MPRemoteCommandCenter.shared().playCommand.addTarget { _ in .success }
            MPRemoteCommandCenter.shared().playCommand.removeTarget(t)
            info.nowPlayingInfo = nil
            return "ok"
        })
        #endif
        #if canImport(AVKit) && !os(watchOS)
        c.append(check("AVKit", "player-view-controller") {
            try await onMain {
                let vc = AVPlayerViewController(); vc.player = AVPlayer()
                vc.loadViewIfNeeded()
                try expect(vc.view != nil, "view")
                return "ok"
            }
        })
        #endif
        #if canImport(ShazamKit)
        c.append(check("ShazamKit", "signature-generation") {
            let g = SHSignatureGenerator()
            let b = sine(523, secs: 4, rate: 48000)
            try g.append(b, at: nil)
            let sig = g.signature()
            try expect(sig.duration > 3 && sig.dataRepresentation.count > 100, "signature \(sig.duration) s \(sig.dataRepresentation.count) B")
            return "\(sig.dataRepresentation.count) B"
        })
        #endif
        #if canImport(SoundAnalysis)
        c.append(check("SoundAnalysis", "classify-sound", timeout: 90) {
            let req = try SNClassifySoundRequest(classifierIdentifier: .version1)
            let b = sine(440, secs: 3, rate: 16000)
            let an = SNAudioStreamAnalyzer(format: b.format)
            final class O: NSObject, SNResultsObserving { var top: String?
                func request(_ r: SNRequest, didProduce res: SNResult) { if top == nil, let c = res as? SNClassificationResult { top = c.classifications.first?.identifier } } }
            let o = O(); try an.add(req, withObserver: o)
            an.analyze(b, atAudioFramePosition: 0); an.completeAnalysis()
            try expect(o.top != nil, "no classification")
            return "\(req.knownClassifications.count) classes, top '\(o.top!)'"
        })
        #endif
        #if canImport(Speech) && !os(tvOS)
        c.append(check("Speech", "recognizer-availability") {
            guard let r = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else { throw Fail("no en-US recognizer") }
            return "available \(r.isAvailable), on-device \(r.supportsOnDeviceRecognition), auth \(SFSpeechRecognizer.authorizationStatus().rawValue)"
        })
        #endif
        #if canImport(PHASE)
        c.append(check("PHASE", "engine") {
            let e = PHASEEngine(updateMode: .manual)
            do { try e.start() } catch { throw Fail("start: \(error)") }
            let l = PHASEListener(engine: e); try e.rootObject.addChild(l)
            e.update(); e.stop()
            return "ok"
        })
        #endif
        #if canImport(OpenAL)
        c.append(check("OpenAL", "device-context-buffer") {
            guard let dev = alcOpenDevice(nil) else { throw Fail("alcOpenDevice") }
            defer { alcCloseDevice(dev) }
            guard let ctx = alcCreateContext(dev, nil) else { throw Fail("alcCreateContext") }
            defer { alcMakeContextCurrent(nil); alcDestroyContext(ctx) }
            alcMakeContextCurrent(ctx)
            var buf: ALuint = 0, src: ALuint = 0; alGenBuffers(1, &buf); alGenSources(1, &src)
            var pcm = [Int16](repeating: 0, count: 4410)
            alBufferData(buf, AL_FORMAT_MONO16, &pcm, ALsizei(pcm.count * 2), 44100)
            alSourcei(src, AL_BUFFER, ALint(buf))
            try expect(alGetError() == AL_NO_ERROR, "AL error")
            alDeleteSources(1, &src); alDeleteBuffers(1, &buf)
            return String(cString: alGetString(AL_VERSION))
        })
        #endif
        #if canImport(MusicKit)
        c.append(check("MusicKit", "authorization-status") {
            "status \(MusicAuthorization.currentStatus)"
        })
        #endif
        #if canImport(MediaAccessibility)
        c.append(check("MediaAccessibility", "caption-appearance") {
            "display type \(MACaptionAppearanceGetDisplayType(.user).rawValue)"
        })
        #endif
        return c
    }
}
