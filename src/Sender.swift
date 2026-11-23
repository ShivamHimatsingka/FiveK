// Sender.swift  (MacBook Air side, shared by FiveK.app and the fivek-send debug CLI)
// Captures the 5120x2880 virtual display, hardware-encodes HEVC, streams over TCP to fivek-recv.
//
// Wire format, sender -> receiver: [type u8][len u32 BE][payload]
//   type 1 = parameter sets ([count u8] then [len u16 BE][bytes] each), sent before every keyframe
//   type 2 = frame ([flags u8, 1=key][HEVC NALs, 4-byte length-prefixed])
//   type 3 = cursor position ([x u16][y u16] as fractions of the display * 65535, [visible u8])
//   type 4 = cursor image ([hotX u16][hotY u16][width u16][height u16] in 1/100 points, then PNG bytes)
//   type 5 = display info, sent whenever capture (re)starts ([pointsW u16][pointsH u16][pixelW u16][pixelH u16])
// Receiver -> sender: 0x01 = ack (one per type-2 message), 0x4B ('K') = please send a keyframe,
//   0x52 ('R') + [pointsW u16][pointsH u16][pixelW u16][pixelH u16] = the receiver's screen, sent on connect.
// Flow control: always up to `minInFlight` unacknowledged frames, and up to `maxInFlight` while the unacked
// bytes stay under `byteBudget`, so small frames pipeline freely but big ones can't queue up in socket buffers.
// The cursor is NOT in the video: it's sent separately ~120x/s and drawn by the receiver, so it moves at
// network speed instead of capture+encode+network speed.

import Foundation
import AppKit
@preconcurrency import ScreenCaptureKit
import VideoToolbox
import CoreMedia
import Network

/// The receiver's screen, as it reports it on connect (used by Auto resolution).
struct ReceiverScreen: Equatable {
    var pointsW: Int, pointsH: Int, pixelW: Int, pixelH: Int
    var hiDPI: Bool { pixelW >= pointsW * 2 }
    var description: String { "\(pointsW)×\(pointsH)\(hiDPI ? " HiDPI" : "") (\(pixelW)×\(pixelH) px)" }
}

struct SenderConfig {
    var host: String? = nil          // nil = find the receiver via Bonjour (_fivek._tcp)
    var port: UInt16 = 5959
    var mbps = 100
    var fps = 60
    var displayID: CGDirectDisplayID? = nil   // nil = first display that is 5120 pixels wide
    var findTimeout: TimeInterval = 20
    // Measured on an M5 Air at 5120x2880: low-latency rate control ~27 ms/frame and ~20 fps sustained,
    // normal rate control ~15 ms/frame and ~48 fps. So normal is the default.
    var lowLatencyRC = false
}

final class Sender: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    // Callbacks are delivered on the main queue.
    var onStatus: ((String) -> Void)?
    var onStop: ((_ error: String?) -> Void)?   // nil = normal stop
    /// Called once connected, before capture starts: creates the display to stream and returns its ID
    /// (nil = failed). Gets the receiver's screen if it reported one within `screenWait`.
    /// Without it, `cfg.displayID` or the first 5120-pixel-wide display is used.
    var prepareDisplay: ((ReceiverScreen?) async -> CGDirectDisplayID?)?
    var targetDisplay: CGDirectDisplayID?
    var onReceiverScreen: ((ReceiverScreen) -> Void)?   // main queue
    var receiverScreen: ReceiverScreen?                 // on q
    var screenWait: TimeInterval = 0.8                  // how long to wait for it before creating the display
    var ackBuf: [UInt8] = []
    var generation = 0                                  // bumped on every capture restart
    var timersStarted = false

    let cfg: SenderConfig
    // All mutable state is touched only on `q`: capture callbacks, network callbacks and
    // encoder output (which hops back onto `q`) all run there, so no locks are needed.
    let q = DispatchQueue(label: "fivek.capture", qos: .userInteractive)
    var conn: NWConnection?
    var browser: NWBrowser?
    var session: VTCompressionSession?
    var stream: SCStream?
    var statsTimer: DispatchSourceTimer?
    let minInFlight = 2, maxInFlight = 5, byteBudget = 600_000
    var inFlight = 0                                   // submitted to the encoder, not yet acked
    var sentFrames: [(t: UInt64, bytes: Int)] = []     // sent, waiting for an ack (in order)
    var unackedBytes = 0
    var netMs = 0.0, encMs = 0.0, latN = 0, encN = 0
    var lastFrame: (pb: CVPixelBuffer, pts: CMTime)?   // kept while the screen is still, for refinement
    var lastNewFrame: UInt64 = 0
    var refinesLeft = 0
    var displayID: CGDirectDisplayID = 0
    var cursorTimer: DispatchSourceTimer?
    var cursorImageTimer: DispatchSourceTimer?
    var lastCursor: (UInt16, UInt16, Bool)? = nil
    var lastCursorPNG = Data()
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
            self.cursorTimer?.cancel(); self.cursorImageTimer?.cancel()
            self.lastFrame = nil
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
                Task {
                    if let prep = self.prepareDisplay {
                        // Give the receiver a moment to report its screen (an older receiver never does).
                        let deadline = Date().addingTimeInterval(self.screenWait)
                        while Date() < deadline, self.q.sync(execute: { self.receiverScreen }) == nil {
                            try? await Task.sleep(nanoseconds: 50_000_000)
                        }
                        guard let id = await prep(self.q.sync { self.receiverScreen }) else {
                            self.fail("Couldn't create the virtual 5K display (CGVirtualDisplay). This macOS version may not support it.")
                            return
                        }
                        self.targetDisplay = id
                    }
                    await self.startCapture()
                }
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
            if let d = data { self.ackBuf += d; self.parseBackChannel() }
            if done || err != nil { self.stop("The iMac closed the display.") ; return }
            self.readAcks(c)
        }
    }

    /// Back-channel bytes from the receiver (on q). 'R' messages are 9 bytes and may arrive split.
    func parseBackChannel() {
        var i = 0
        while i < ackBuf.count {
            let b = ackBuf[i]
            if b == 0x52 {
                guard i + 9 <= ackBuf.count else { break }   // wait for the rest
                func u16(_ k: Int) -> Int { Int(ackBuf[i + k]) << 8 | Int(ackBuf[i + k + 1]) }
                let rs = ReceiverScreen(pointsW: u16(1), pointsH: u16(3), pixelW: u16(5), pixelH: u16(7))
                receiverScreen = rs
                print("Receiver screen: \(rs.description)")
                DispatchQueue.main.async { self.onReceiverScreen?(rs) }
                i += 9; continue
            }
            i += 1
            if b == 0x4B { needKey = true; continue }
            if b != 0x01 { continue }
            if !sentFrames.isEmpty {
                let f = sentFrames.removeFirst()
                unackedBytes -= f.bytes
                netMs += Double(DispatchTime.now().uptimeNanoseconds - f.t) / 1e6; latN += 1
            }
            frameDone()
        }
        ackBuf.removeFirst(i)
    }

    /// Switches to a different display mode while connected: stops capture and the encoder, lets `prepare`
    /// resize (or recreate) the display, then restarts capture with a fresh keyframe. The connection stays up.
    func reconfigure(_ prepare: @escaping (ReceiverScreen?) async -> CGDirectDisplayID?) {
        Task {
            var old: SCStream?
            let rs: ReceiverScreen? = q.sync {
                old = stream; stream = nil
                generation += 1
                if let s = session { VTCompressionSessionInvalidate(s); session = nil }
                held = nil; lastFrame = nil; refinesLeft = 0
                inFlight = sentFrames.count   // frames still inside the old encoder are gone
                needKey = true
                return receiverScreen
            }
            try? await old?.stopCapture()
            status("Switching resolution…")
            guard let id = await prepare(rs) else { fail("Couldn't change the virtual display."); return }
            targetDisplay = id
            await startCapture()
        }
    }

    /// Small control message (on q).
    func sendMsg(_ type: UInt8, _ payload: Data) {
        guard let c = conn, !stopped else { return }
        var msg = Data(count: 5)
        msg.withUnsafeMutableBytes { Sender.header(type, payload.count, into: $0.baseAddress!.assumingMemoryBound(to: UInt8.self)) }
        msg.append(payload)
        c.send(content: msg, completion: .idempotent)
    }

    static func header(_ type: UInt8, _ n: Int, into p: UnsafeMutablePointer<UInt8>) {
        p[0] = type
        p[1] = UInt8(n >> 24 & 255); p[2] = UInt8(n >> 16 & 255); p[3] = UInt8(n >> 8 & 255); p[4] = UInt8(n & 255)
    }

    // MARK: capture
    func startCapture() async {
        do {
            // A just-created display can take a moment to show up in ScreenCaptureKit, so retry briefly.
            var content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            var chosen: SCDisplay? = nil
            let want = targetDisplay ?? cfg.displayID
            for attempt in 0..<20 {
                for d in content.displays {
                    if let w = want { if d.displayID == w { chosen = d } }
                    else if let m = CGDisplayCopyDisplayMode(d.displayID), m.pixelWidth == 5120 { chosen = d }
                }
                if chosen != nil || attempt == 19 { break }
                try await Task.sleep(nanoseconds: 150_000_000)
                content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
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
            sc.queueDepth = 5   // 3 minimum + the held newest skipped frame + the last frame kept for refinement
            sc.showsCursor = false   // the receiver draws the cursor itself (see type 3/4 messages)
            sc.captureResolution = .best

            let filter = SCContentFilter(display: disp, excludingWindows: [])
            let s = SCStream(filter: filter, configuration: sc, delegate: self)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: q)

            let ptW = CGDisplayCopyDisplayMode(disp.displayID)?.width ?? w / 2
            let ptH = CGDisplayCopyDisplayMode(disp.displayID)?.height ?? h / 2
            var ok = false
            q.sync {
                guard !stopped else { return }
                pixelW = w; pixelH = h; stream = s; displayID = disp.displayID
                ok = makeEncoder()
                func u16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 255), UInt8(v & 255)] }
                sendMsg(5, Data(u16(ptW) + u16(ptH) + u16(w) + u16(h)))   // lets the receiver size the cursor
                lastCursor = nil; lastCursorPNG = Data()                   // resend cursor for the new size
            }
            guard ok else { if !stopped { fail("Could not create the HEVC hardware encoder at \(w)x\(h).") }; return }
            try await s.startCapture()
            q.async {
                guard !self.timersStarted else { return }
                self.timersStarted = true
                self.startStats(); self.startRefiner(); self.startCursor()
            }
            status("Streaming \(w)×\(h)")
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
            let net = self.latN > 0 ? self.netMs / Double(self.latN) : 0
            let enc = self.encN > 0 ? self.encMs / Double(self.encN) : 0
            self.status(String(format: "%d fps · %.1f Mbps · enc %.0f ms · net %.0f ms · skipped %d", self.framesOut,
                               Double(self.bytesOut) * 8 / 1e6, enc, net, self.framesSkipped))
            self.framesOut = 0; self.bytesOut = 0; self.framesSkipped = 0
            self.netMs = 0; self.latN = 0; self.encMs = 0; self.encN = 0
        }
        t.resume()
        statsTimer = t
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard stream === self.stream else { return }   // an old stream from before a resolution switch
        fail("Screen capture stopped: \(error.localizedDescription)")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !stopped, type == .screen, sb.isValid, stream === self.stream else { return }
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = arr.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        lastFrame = (pb, pts); lastNewFrame = DispatchTime.now().uptimeNanoseconds; refinesLeft = 3
        if !canSend {
            // Skip BEFORE encoding (keeps the P-frame chain intact), but remember the newest frame so the
            // final state of the screen is always sent once the pipe drains, even if nothing changes after it.
            if held != nil { framesSkipped += 1 }
            held = (pb, pts)
            return
        }
        encode(pb, pts)
    }

    var canSend: Bool { inFlight < minInFlight || (inFlight < maxInFlight && unackedBytes < byteBudget) }

    /// Called on `q` when the receiver acknowledges a frame (or a frame never made it out of the encoder).
    func frameDone() {
        inFlight = max(0, inFlight - 1)
        if canSend, let h = held { held = nil; encode(h.pb, h.pts) }
    }

    // MARK: refinement
    // The low-latency rate control gives every frame about the same bit budget, and nothing is captured while the
    // screen is still, so the last change would stay at "moving" quality. Once the screen has been still for
    // 120 ms, re-encode the last frame a few times: each pass codes the remaining error and the image sharpens.
    func startRefiner() {
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 0.1, repeating: .milliseconds(60), leeway: .milliseconds(10))
        t.setEventHandler { [weak self] in
            guard let self = self, !self.stopped, self.refinesLeft > 0, let f = self.lastFrame,
                  self.held == nil, self.inFlight == 0,
                  DispatchTime.now().uptimeNanoseconds - self.lastNewFrame > 120_000_000 else { return }
            self.refinesLeft -= 1
            self.encode(f.pb, CMClockGetTime(CMClockGetHostTimeClock()))
            if self.refinesLeft == 0 { self.lastFrame = nil }   // give the buffer back to ScreenCaptureKit
        }
        t.resume()
        let old = refineTimerBox; refineTimerBox = t; old?.cancel()
    }
    var refineTimerBox: DispatchSourceTimer?

    // MARK: cursor
    func startCursor() {
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: .microseconds(8333), leeway: .milliseconds(1))   // ~120 Hz
        t.setEventHandler { [weak self] in self?.sendCursorPosition() }
        t.resume(); cursorTimer = t
        // Cursor shape: AppKit, so poll on the main queue (cheap: the image is tiny).
        let it = DispatchSource.makeTimerSource(queue: .main)
        it.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(10))
        it.setEventHandler { [weak self] in self?.checkCursorImage() }
        it.resume(); cursorImageTimer = it
    }

    func sendCursorPosition() {
        guard !stopped, let loc = CGEvent(source: nil)?.location else { return }
        let b = CGDisplayBounds(displayID)
        guard b.width > 0, b.height > 0 else { return }
        let inside = b.contains(loc)
        func frac(_ v: CGFloat) -> UInt16 { UInt16(max(0, min(65535, (v * 65535).rounded()))) }
        let cur = (frac((loc.x - b.minX) / b.width), frac((loc.y - b.minY) / b.height), inside)
        if let l = lastCursor, l.0 == cur.0, l.1 == cur.1, l.2 == cur.2 { return }
        lastCursor = cur
        sendMsg(3, Data([UInt8(cur.0 >> 8), UInt8(cur.0 & 255), UInt8(cur.1 >> 8), UInt8(cur.1 & 255), inside ? 1 : 0]))
    }

    func checkCursorImage() {   // main queue
        // `currentSystemCursor` is the system-wide cursor (not just ours); called via selector because it's
        // marked to-be-deprecated, which would otherwise warn.
        guard !stopped,
              let c = NSCursor.perform(NSSelectorFromString("currentSystemCursor"))?.takeUnretainedValue() as? NSCursor
        else { return }
        let img = c.image, size = img.size
        guard size.width > 0, size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]), png != lastCursorPNG else { return }
        lastCursorPNG = png
        func u16(_ v: CGFloat) -> [UInt8] { let n = UInt16(max(0, min(65535, (v * 100).rounded()))); return [UInt8(n >> 8), UInt8(n & 255)] }
        var payload = Data(u16(c.hotSpot.x) + u16(c.hotSpot.y) + u16(size.width) + u16(size.height))
        payload.append(png)
        q.async { self.lastCursor = nil; self.sendMsg(4, payload) }   // resend position too
    }

    func encode(_ pb: CVPixelBuffer, _ pts: CMTime) {
        guard let sess = session else { return }
        let key = needKey
        let props: CFDictionary? = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        needKey = false
        inFlight += 1
        let t0 = DispatchTime.now().uptimeNanoseconds
        let gen = generation
        let st = VTCompressionSessionEncodeFrame(sess, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid,
                                                 frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, out in
            guard let self = self else { return }
            let t1 = DispatchTime.now().uptimeNanoseconds
            self.q.async {
                guard gen == self.generation else { return }   // from an encoder replaced by a resolution switch
                self.encMs += Double(t1 - t0) / 1e6; self.encN += 1
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
            else { print("HEVC hardware encoder ready (\(lowLatency ? "low-latency" : "normal") rate control)") }
            return st == noErr ? s : nil
        }
        guard let s = create(lowLatency: cfg.lowLatencyRC) ?? create(lowLatency: !cfg.lowLatencyRC) else { return false }
        func set(_ k: CFString, _ v: CFTypeRef) {
            let st = VTSessionSetProperty(s, key: k, value: v)
            if st != noErr { print("  (property \(k) not accepted: \(st))") }
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
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
        sentFrames.append((DispatchTime.now().uptimeNanoseconds, msg.count))
        unackedBytes += msg.count
        bytesOut += msg.count; framesOut += 1
        return true
    }
}
