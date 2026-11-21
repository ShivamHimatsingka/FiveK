// Sender.swift  (MacBook Air side, shared by FiveK.app and the fivek-send debug CLI)
// Captures the 5120x2880 virtual display, hardware-encodes HEVC, streams over TCP to fivek-recv.
//
// Wire format, sender -> receiver: [type u8][len u32 BE][payload]
//   type 1 = parameter sets ([count u8] then [len u16 BE][bytes] each), sent before every keyframe
//   type 2 = frame ([flags u8, 1=key][HEVC NALs, 4-byte length-prefixed])
// Receiver -> sender: one byte per type-2 message received (0x01 = ack), 0x4B ('K') = please send a keyframe.
// The sender keeps at most `maxInFlight` unacknowledged frames, so latency cannot build up in socket buffers.

import Foundation
@preconcurrency import ScreenCaptureKit
import VideoToolbox
import CoreMedia
import Network

struct SenderConfig {
    var host: String? = nil          // nil = find the receiver via Bonjour (_fivek._tcp)
    var port: UInt16 = 5959
    var mbps = 60
    var fps = 60
    var displayID: CGDirectDisplayID? = nil   // nil = first display that is 5120 pixels wide
    var findTimeout: TimeInterval = 20
}

final class Sender: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    // Callbacks are delivered on the main queue.
    var onStatus: ((String) -> Void)?
    var onStop: ((_ error: String?) -> Void)?   // nil = normal stop

    let cfg: SenderConfig
    // All mutable state is touched only on `q`: capture callbacks, network callbacks and
    // encoder output (which hops back onto `q`) all run there, so no locks are needed.
    let q = DispatchQueue(label: "fivek.capture", qos: .userInteractive)
    var conn: NWConnection?
    var browser: NWBrowser?
    var session: VTCompressionSession?
    var stream: SCStream?
    var statsTimer: DispatchSourceTimer?
    let maxInFlight = 2
    var inFlight = 0
    var held: (pb: CVPixelBuffer, pts: CMTime)? = nil   // newest frame skipped while the pipe was full
    var needKey = true
    var bytesOut = 0, framesOut = 0, framesSkipped = 0
    var pixelW = 5120, pixelH = 2880
    var activity: NSObjectProtocol?
    var stopped = false
    var connected = false

    init(_ cfg: SenderConfig) { self.cfg = cfg }

    func status(_ s: String) {
        print(s)
        DispatchQueue.main.async { self.onStatus?(s) }
    }

    // MARK: lifecycle
    func start() {
        // Keep timers precise and the process out of App Nap while streaming.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                         reason: "fivek streaming")
        q.async { self.connect() }
        q.asyncAfter(deadline: .now() + cfg.findTimeout) {
            if !self.connected && !self.stopped {
                self.fail(self.cfg.host == nil
                    ? "Couldn't find the iMac. Is it on, logged in, on the same network, with the receiver installed?"
                    : "Couldn't connect to \(self.cfg.host!):\(self.cfg.port).")
            }
        }
    }

    /// Stops everything. Safe to call from any thread, more than once.
    func stop(_ error: String? = nil) {
        q.async {
            guard !self.stopped else { return }
            self.stopped = true
            self.statsTimer?.cancel()
            self.browser?.cancel()
            self.conn?.cancel()
            if let s = self.session { VTCompressionSessionInvalidate(s); self.session = nil }
            self.held = nil
            let st = self.stream; self.stream = nil
            if let a = self.activity { ProcessInfo.processInfo.endActivity(a) }
            Task {
                try? await st?.stopCapture()
                DispatchQueue.main.async { self.onStop?(error) }
            }
        }
    }

    func fail(_ msg: String) { print("error: \(msg)"); stop(msg) }

    // MARK: network (on q)
    func connect() {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.serviceClass = .interactiveVideo
        if let h = cfg.host {
            status("Connecting to \(h)…")
            open(NWConnection(host: NWEndpoint.Host(h), port: NWEndpoint.Port(rawValue: cfg.port)!, using: params))
        } else {
            status("Looking for the iMac…")
            let b = NWBrowser(for: .bonjour(type: "_fivek._tcp", domain: nil), using: params)
            b.browseResultsChangedHandler = { [weak self] results, _ in
                guard let self = self, self.conn == nil, !self.stopped, let r = results.first else { return }
                b.cancel()
                self.open(NWConnection(to: r.endpoint, using: params))
            }
            b.stateUpdateHandler = { [weak self] st in
                if case .failed(let e) = st { self?.fail("Bonjour browse failed: \(e)") }
            }
            browser = b
            b.start(queue: q)
        }
    }

    func open(_ c: NWConnection) {
        conn = c
        c.stateUpdateHandler = { [weak self] st in
            guard let self = self, !self.stopped else { return }
            switch st {
            case .ready:
                self.connected = true
                self.status("Connected, starting capture…")
                self.readAcks(c)
                Task { await self.startCapture() }
            case .failed(let e): self.fail("Connection failed: \(e)")
            case .waiting(let e): print("waiting: \(e)")   // retried by Network.framework until findTimeout
            default: break
            }
        }
        c.start(queue: q)
    }

    func readAcks(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 256) { [weak self] data, _, done, err in
            guard let self = self, !self.stopped else { return }
            if let d = data {
                for b in d {
                    if b == 0x4B { self.needKey = true } else { self.frameDone() }
                }
            }
            if done || err != nil { self.stop("The iMac closed the display.") ; return }
            self.readAcks(c)
        }
    }

    static func header(_ type: UInt8, _ n: Int, into p: UnsafeMutablePointer<UInt8>) {
        p[0] = type
        p[1] = UInt8(n >> 24 & 255); p[2] = UInt8(n >> 16 & 255); p[3] = UInt8(n >> 8 & 255); p[4] = UInt8(n & 255)
    }

    // MARK: capture
    func startCapture() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            var chosen: SCDisplay? = nil
            for d in content.displays {
                if let w = cfg.displayID { if d.displayID == w { chosen = d } }
                else if let m = CGDisplayCopyDisplayMode(d.displayID), m.pixelWidth == 5120 { chosen = d }
            }
            guard let disp = chosen else {
                let list = content.displays.map { "id=\($0.displayID) \($0.width)x\($0.height)pt" }.joined(separator: ", ")
                fail("No 5120-pixel-wide display found (\(list)).")
                return
            }
            var w = 5120, h = 2880
            if let m = CGDisplayCopyDisplayMode(disp.displayID) { w = m.pixelWidth; h = m.pixelHeight }
            print("Capturing display \(disp.displayID) at \(w)x\(h)")

            let sc = SCStreamConfiguration()
            sc.width = w; sc.height = h
            // NV12 straight from the capture GPU path: the encoder takes it with no conversion or copy.
            sc.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            sc.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
            sc.colorSpaceName = CGColorSpace.sRGB
            sc.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(cfg.fps))
            sc.queueDepth = 4   // 3 is the minimum; one extra because we may hold the newest skipped frame
            sc.showsCursor = true

            let filter = SCContentFilter(display: disp, excludingWindows: [])
            let s = SCStream(filter: filter, configuration: sc, delegate: self)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: q)

            var ok = false
            q.sync {
                guard !stopped else { return }
                pixelW = w; pixelH = h; stream = s
                ok = makeEncoder()
            }
            guard ok else { if !stopped { fail("Could not create the HEVC hardware encoder at \(w)x\(h).") }; return }
            try await s.startCapture()
            q.async { self.startStats() }
            status("Streaming \(w)x\(h)")
        } catch {
            fail("Screen capture failed: \(error.localizedDescription)")
        }
    }

    func startStats() {
        guard !stopped else { return }
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.status(String(format: "%d fps · %.1f Mbps · skipped %d", self.framesOut,
                               Double(self.bytesOut) * 8 / 1e6, self.framesSkipped))
            self.framesOut = 0; self.bytesOut = 0; self.framesSkipped = 0
        }
        t.resume()
        statsTimer = t
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fail("Screen capture stopped: \(error.localizedDescription)")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !stopped, type == .screen, sb.isValid else { return }
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = arr.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        if inFlight >= maxInFlight {
            // Skip BEFORE encoding (keeps the P-frame chain intact), but remember the newest frame so the
            // final state of the screen is always sent once the pipe drains, even if nothing changes after it.
            if held != nil { framesSkipped += 1 }
            held = (pb, pts)
            return
        }
        encode(pb, pts)
    }

    /// Called on `q` when the receiver acknowledges a frame (or a frame never made it out of the encoder).
    func frameDone() {
        inFlight = max(0, inFlight - 1)
        if inFlight < maxInFlight, let h = held { held = nil; encode(h.pb, h.pts) }
    }

    func encode(_ pb: CVPixelBuffer, _ pts: CMTime) {
        guard let sess = session else { return }
        let key = needKey
        let props: CFDictionary? = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        needKey = false
        inFlight += 1
        let st = VTCompressionSessionEncodeFrame(sess, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid,
                                                 frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, out in
            guard let self = self else { return }
            self.q.async {
                if status == noErr, let out = out, self.handleEncoded(out) { return }
                if key { self.needKey = true }   // a frame that never went out can't be acked
                self.frameDone()
            }
        }
        if st != noErr { print("encode failed: \(st)"); inFlight -= 1; if key { needKey = true } }
    }

    // MARK: encoder
    func makeEncoder() -> Bool {
        func create(lowLatency: Bool) -> VTCompressionSession? {
            var spec: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
            if lowLatency { spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
            var s: VTCompressionSession?
            let st = VTCompressionSessionCreate(allocator: nil, width: Int32(pixelW), height: Int32(pixelH),
                                                codecType: kCMVideoCodecType_HEVC, encoderSpecification: spec as CFDictionary,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &s)
            if st != noErr { print("VTCompressionSessionCreate(lowLatency=\(lowLatency)) -> \(st)") }
            else { print("HEVC hardware encoder ready (low-latency rate control: \(lowLatency))") }
            return st == noErr ? s : nil
        }
        guard let s = create(lowLatency: true) ?? create(lowLatency: false) else { return false }
        func set(_ k: CFString, _ v: CFTypeRef) {
            let st = VTSessionSetProperty(s, key: k, value: v)
            if st != noErr { print("  (property \(k) not accepted: \(st))") }
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_MaxFrameDelayCount, NSNumber(value: 0))
        set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel)
        set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: cfg.mbps * 1_000_000))
        // Cap bursts to ~2x average over 1 s so one big frame (e.g. a full-screen change) can't flood Wi-Fi.
        set(kVTCompressionPropertyKey_DataRateLimits, [NSNumber(value: cfg.mbps * 1_000_000 / 8 * 2), NSNumber(value: 1)] as CFArray)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: cfg.fps))
        // TCP is lossless, so periodic keyframes (multi-MB at 5K) only add latency spikes. The receiver asks for one if needed.
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: Int32.max))
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 0))
        set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_sRGB)
        set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        VTCompressionSessionPrepareToEncodeFrames(s)
        session = s
        return true
    }

    /// Runs on `q`. Returns false if nothing was sent (so the caller releases the in-flight slot).
    func handleEncoded(_ sb: CMSampleBuffer) -> Bool {
        guard !stopped, let c = conn, let bb = CMSampleBufferGetDataBuffer(sb) else { return false }
        let attach = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]]
        let isKey = !((attach?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)

        if isKey, let fd = CMSampleBufferGetFormatDescription(sb) {
            var count = 0
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                               nalUnitHeaderLengthOut: nil)
            var payload = Data([UInt8(count)])
            for i in 0..<count {
                var p: UnsafePointer<UInt8>? = nil; var sz = 0
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &p,
                                                                   parameterSetSizeOut: &sz, parameterSetCountOut: nil,
                                                                   nalUnitHeaderLengthOut: nil)
                guard let p = p else { continue }
                payload.append(contentsOf: [UInt8(sz >> 8 & 255), UInt8(sz & 255)])
                payload.append(p, count: sz)
            }
            var msg = Data(count: 5)
            msg.withUnsafeMutableBytes { Sender.header(1, payload.count, into: $0.baseAddress!.assumingMemoryBound(to: UInt8.self)) }
            msg.append(payload)
            c.send(content: msg, completion: .idempotent)
        }

        // One allocation, one copy: header + flag + NALs. CMBlockBufferCopyDataBytes also handles
        // non-contiguous block buffers correctly.
        let len = CMBlockBufferGetDataLength(bb)
        var msg = Data(count: 6 + len)
        let st = msg.withUnsafeMutableBytes { raw -> OSStatus in
            let p = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            Sender.header(2, len + 1, into: p)
            p[5] = isKey ? 1 : 0
            return CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: p + 6)
        }
        guard st == noErr else { return false }
        c.send(content: msg, completion: .idempotent)
        bytesOut += msg.count; framesOut += 1
        return true
    }
}
