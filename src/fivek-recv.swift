// fivek-recv.swift  (runs on the 27" 5K iMac, macOS 12+)
// Receives the HEVC stream from FiveK on the Air, decodes it in hardware and shows it borderless fullscreen.
// Esc quits (which also stops the Air side).
//
// Normal use: installed by install-receiver.sh as a launchd agent with socket activation. launchd owns
// port 5959 and advertises _fivek._tcp over Bonjour, so NOTHING runs on the iMac until the Air connects.
// launchd then starts this program, it shows the picture, and exits when the Air disconnects.
//
// Debug use: run it by hand (./fivek-recv); it listens on 5959 itself and keeps running between sessions.

import Cocoa
import AVFoundation
import CoreMedia
import dnssd
import IOKit.pwr_mgt

final class KeyWindow: NSWindow { override var canBecomeKey: Bool { true } }

final class Receiver: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let layer = AVSampleBufferDisplayLayer()
    var launchdMode = false
    var listenSources: [DispatchSourceRead] = []
    var bonjour: DNSServiceRef?
    var activity: NSObjectProtocol?
    var busy = false   // one sender at a time; touched only on main

    func applicationDidFinishLaunching(_ n: Notification) {
        // Get the listening socket(s): from launchd if it started us, otherwise make our own.
        var fds = launchdSockets()
        launchdMode = !fds.isEmpty
        if !launchdMode {
            guard let fd = makeListener(port: 5959) else { print("Can't listen on port 5959"); exit(1) }
            fds = [fd]
            DNSServiceRegister(&bonjour, 0, 0, nil, "_fivek._tcp", nil, nil, UInt16(5959).bigEndian, 0, nil, nil, nil)
            print("Listening on 5959 (manual mode).")
        }
        for fd in fds {
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            src.setEventHandler { [weak self] in self?.acceptOn(fd) }
            src.resume()
            listenSources.append(src)
        }
        if launchdMode { showWindow() }   // a connection is already waiting
    }

    // MARK: window

    func showWindow() {
        // Wake the display if it was asleep, and keep it (and the system) awake while we run:
        // nobody touches the iMac's keyboard/mouse, so the idle timers would otherwise fire.
        var aid: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("fivek" as CFString, kIOPMUserActiveLocal, &aid)
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleDisplaySleepDisabled, .latencyCritical], reason: "fivek display")
        }
        if window == nil {
            let screen = NSScreen.main!
            window = KeyWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
            window.backgroundColor = .black
            window.isReleasedWhenClosed = false
            let v = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            v.wantsLayer = true
            layer.frame = v.bounds
            layer.contentsScale = screen.backingScaleFactor
            layer.videoGravity = .resize
            layer.backgroundColor = NSColor.black.cgColor
            v.layer?.addSublayer(layer)
            window.contentView = v
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                if e.keyCode == 53 { NSApp.terminate(nil); return nil }   // Esc
                return e
            }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        NSCursor.hide()
    }

    func hideWindow() {
        flushLayer()
        window?.orderOut(nil)
        NSApp.presentationOptions = []
        NSCursor.unhide()
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
    }

    func flushLayer() {
        if #available(macOS 15.0, *) { layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil) }
        else { layer.flushAndRemoveImage() }
    }

    // MARK: sockets

    func launchdSockets() -> [Int32] {
        typealias LAS = @convention(c) (UnsafePointer<CChar>, UnsafeMutablePointer<UnsafeMutablePointer<Int32>?>,
                                        UnsafeMutablePointer<Int>) -> Int32
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "launch_activate_socket") else { return [] }
        var fds: UnsafeMutablePointer<Int32>? = nil; var cnt = 0
        guard unsafeBitCast(sym, to: LAS.self)("Listener", &fds, &cnt) == 0, let f = fds else { return [] }
        defer { free(f) }
        return Array(UnsafeBufferPointer(start: f, count: cnt))
    }

    func makeListener(port: UInt16) -> Int32? {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1, off: Int32 = 0
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, 4)
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &off, 4)   // accept IPv4 too
        var a = sockaddr_in6()
        a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        a.sin6_family = sa_family_t(AF_INET6)
        a.sin6_port = port.bigEndian
        a.sin6_addr = in6addr_any
        let ok = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
        guard ok == 0, Darwin.listen(fd, 4) == 0 else { close(fd); return nil }
        return fd
    }

    func acceptOn(_ lfd: Int32) {
        let c = Darwin.accept(lfd, nil, nil)
        guard c >= 0 else { return }
        if busy { close(c); return }   // already showing a sender
        busy = true
        var on: Int32 = 1
        setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &on, 4)
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &on, 4)
        var vi = Int32(NET_SERVICE_TYPE_VI)
        setsockopt(c, SOL_SOCKET, SO_NET_SERVICE_TYPE, &vi, 4)
        print("Sender connected.")
        showWindow()
        let t = Thread { [weak self] in
            self?.serve(c)
            close(c)
            DispatchQueue.main.async { self?.sessionEnded() }
        }
        t.qualityOfService = .userInteractive
        t.name = "fivek.net"
        t.start()
    }

    func sessionEnded() {
        print("Sender disconnected.")
        busy = false
        if launchdMode { NSApp.terminate(nil) }   // launchd starts us again on the next connection
        else { hideWindow() }
    }

    // MARK: stream (runs on the network thread; all decode state is local to it)

    func serve(_ fd: Int32) {
        var fmt: CMVideoFormatDescription?
        var waitingForKey = true   // drop P-frames until a keyframe (after connect or a decoder reset)
        var frames = 0, bytes = 0
        var lastStats = Date()
        var header = [UInt8](repeating: 0, count: 5)
        flushLayer()

        while true {
            guard readFully(fd, &header, 5) else { return }
            let type = header[0]
            let len = Int(header[1]) << 24 | Int(header[2]) << 16 | Int(header[3]) << 8 | Int(header[4])
            guard len <= 64 << 20 else { print("bad message length \(len)"); return }
            var p = [UInt8](repeating: 0, count: len)
            guard len == 0 || readFully(fd, &p, len) else { return }

            if type == 1 {
                if let f = makeFormat(p) { fmt = f }
            } else if type == 2 {
                // Ack every frame message, decoded or not, so the sender's in-flight window keeps moving.
                var ack: UInt8 = 0x01
                _ = write(fd, &ack, 1)
                guard let f = fmt, p.count > 1 else { continue }
                let isKey = p[0] == 1
                if waitingForKey { if isKey { waitingForKey = false } else { continue } }
                if !enqueue(p, isKey: isKey, fmt: f) {
                    // P-frames can't decode after a flush: wait for a keyframe and ask the sender for one.
                    print("decoder reset, requesting keyframe")
                    waitingForKey = true
                    var k: UInt8 = 0x4B
                    _ = write(fd, &k, 1)
                    continue
                }
                frames += 1; bytes += p.count
            }
            if lastStats.timeIntervalSinceNow < -1 {
                print(String(format: "recv %d fps, %.1f Mbps", frames, Double(bytes) * 8 / 1e6))
                frames = 0; bytes = 0; lastStats = Date()
            }
        }
    }

    func readFully(_ fd: Int32, _ buf: inout [UInt8], _ n: Int) -> Bool {
        var got = 0
        return buf.withUnsafeMutableBytes { raw in
            while got < n {
                let r = read(fd, raw.baseAddress! + got, n - got)
                if r > 0 { got += r } else if r < 0 && errno == EINTR { continue } else { return false }
            }
            return true
        }
    }

    func makeFormat(_ p: [UInt8]) -> CMVideoFormatDescription? {
        guard !p.isEmpty else { return nil }
        let count = Int(p[0]); var o = 1
        var sets: [[UInt8]] = []
        for _ in 0..<count {
            guard o + 2 <= p.count else { return nil }
            let n = Int(p[o]) << 8 | Int(p[o + 1]); o += 2
            guard o + n <= p.count else { return nil }
            sets.append(Array(p[o..<o + n])); o += n
        }
        let ptrs: [UnsafePointer<UInt8>] = sets.map { s in
            let m = UnsafeMutablePointer<UInt8>.allocate(capacity: s.count)
            m.initialize(from: s, count: s.count)
            return UnsafePointer(m)
        }
        defer { for p in ptrs { UnsafeMutablePointer(mutating: p).deallocate() } }
        // Match the sender's colour tags (BT.709 primaries/matrix, sRGB transfer) so colours aren't shifted.
        let ext: [CFString: Any] = [
            kCMFormatDescriptionExtension_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kCMFormatDescriptionExtension_TransferFunction: kCVImageBufferTransferFunction_sRGB,
            kCMFormatDescriptionExtension_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ]
        var f: CMFormatDescription?
        let st = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
            allocator: nil, parameterSetCount: sets.count, parameterSetPointers: ptrs,
            parameterSetSizes: sets.map { $0.count }, nalUnitHeaderLength: 4,
            extensions: ext as CFDictionary, formatDescriptionOut: &f)
        if st != noErr { print("format description failed: \(st)"); return nil }
        return f
    }

    /// Returns false if the decoder needed a reset (frame not shown; a keyframe is required).
    func enqueue(_ p: [UInt8], isKey: Bool, fmt: CMVideoFormatDescription) -> Bool {
        let n = p.count - 1
        var bb: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: n,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: n,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &bb) == noErr,
              let block = bb else { return true }
        let ok = p.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress! + 1, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: n)
        }
        guard ok == noErr else { return true }

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var size = n
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: fmt,
                                        sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb) == noErr,
              let sample = sb else { return true }

        if let arr = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(arr) > 0 {
            let d = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(d, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            if !isKey {
                CFDictionarySetValue(d, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }
        if #available(macOS 15.0, *) {
            let r = layer.sampleBufferRenderer
            if r.status == .failed || r.requiresFlushToResumeDecoding { r.flush(); return false }
            r.enqueue(sample)
        } else {
            if layer.status == .failed || layer.requiresFlushToResumeDecoding { layer.flush(); return false }
            layer.enqueue(sample)
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = Receiver()
app.delegate = delegate
app.run()
