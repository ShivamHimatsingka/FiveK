// fivek-recv.swift  (runs on the 27" 5K iMac, macOS 12+)
// Receives the HEVC stream from FiveK on the Air, decodes it in hardware and shows it borderless fullscreen.
// Esc quits (which also stops the Air side).
//
// Packaged as "FiveK Receiver.app". Three ways it can start:
//  1. Opened by the user (double-click): installer. Copies itself to ~/Applications and registers a launchd
//     agent with socket activation: launchd owns port 5959 and advertises _fivek._tcp over Bonjour, so
//     NOTHING runs on the iMac until the Air connects. Opening it again offers Uninstall.
//  2. Started by launchd when the Air connects: shows the stream, exits when the Air disconnects.
//  3. `.../fivek-recv --listen` (debug): listens on 5959 itself and keeps running between sessions.

import Cocoa
import AVFoundation
import CoreMedia
import dnssd
import IOKit.pwr_mgt

final class KeyWindow: NSWindow { override var canBecomeKey: Bool { true } }
/// Works on the first click even when the receiver isn't the active app.
final class FirstClickButton: NSButton { override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true } }

final class Receiver: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let layer = AVSampleBufferDisplayLayer()
    let cursorLayer = CALayer()   // the Air's cursor, drawn here so it moves at network speed (type 3/4)
    var cursorSize = CGSize(width: 17, height: 23)
    var senderPointsW: CGFloat = 0   // the sender display's width in points (type 5); scales the cursor
    var launchdMode = false
    var listenSources: [DispatchSourceRead] = []
    var bonjour: DNSServiceRef?
    var activity: NSObjectProtocol?
    var busy = false   // one sender at a time; touched only on main
    var clientFD: Int32 = -1
    var controls: NSView?
    var controlsHideTimer: Timer?
    var cursorShown = true
    var monitorsInstalled = false

    func applicationDidFinishLaunching(_ n: Notification) {
        installMenu()
        // Get the listening socket(s): from launchd if it started us, otherwise make our own.
        var fds = launchdSockets()
        launchdMode = !fds.isEmpty
        if !launchdMode && !CommandLine.arguments.contains("--listen") {
            Installer.run()
            return
        }
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
            cursorLayer.contentsScale = screen.backingScaleFactor
            cursorLayer.contentsGravity = .resize
            cursorLayer.isHidden = true
            cursorLayer.zPosition = 10
            cursorLayer.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(),
                                   "hidden": NSNull(), "anchorPoint": NSNull()]
            v.layer?.addSublayer(cursorLayer)
            window.contentView = v
            window.acceptsMouseMovedEvents = true
            v.addSubview(makeControls(in: v.bounds))
        }
        installMonitors()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        setControlsVisible(false)
    }

    // MARK: ending a session
    // Ways out: Esc or Cmd-Q (menu key equivalents, work with the menu bar hidden), moving the iMac's own mouse
    // (shows its pointer and a Disconnect button), or Stop on the MacBook (closes the connection).

    func installMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let m = NSMenu()
        let end = NSMenuItem(title: "Disconnect", action: #selector(endSession), keyEquivalent: "\u{1b}")
        end.keyEquivalentModifierMask = []
        end.target = self
        m.addItem(end)
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "Quit FiveK Receiver", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = m
        NSApp.mainMenu = main
    }

    @objc func endSession() {
        if launchdMode || clientFD < 0 { NSApp.terminate(nil); return }
        shutdown(clientFD, SHUT_RDWR)   // manual mode: the reader thread ends and the window hides
    }

    func installMonitors() {
        guard !monitorsInstalled else { return }
        monitorsInstalled = true
        let mouse: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel, .leftMouseDragged]
        // Global: the iMac's mouse moved while another app has focus (no special permission needed for mouse events).
        NSEvent.addGlobalMonitorForEvents(matching: mouse) { [weak self] _ in self?.localMouseActivity() }
        NSEvent.addLocalMonitorForEvents(matching: mouse) { [weak self] e in self?.localMouseActivity(); return e }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.endSession(); return nil }   // Esc (backup for the menu item)
            return e
        }
    }

    func localMouseActivity() {
        guard busy || launchdMode, window?.isVisible == true else { return }
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
        setControlsVisible(true)
        controlsHideTimer?.invalidate()
        controlsHideTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            self?.setControlsVisible(false)
        }
    }

    func setControlsVisible(_ on: Bool) {
        controls?.isHidden = !on
        if on != cursorShown {
            cursorShown = on
            if on { NSCursor.unhide() } else { NSCursor.hide() }
        }
    }

    func makeControls(in bounds: NSRect) -> NSView {
        let w: CGFloat = 420, h: CGFloat = 56
        let hud = NSVisualEffectView(frame: NSRect(x: (bounds.width - w) / 2, y: bounds.height - h - 24, width: w, height: h))
        hud.material = .hudWindow
        hud.blendingMode = .withinWindow
        hud.state = .active
        hud.wantsLayer = true
        hud.layer?.cornerRadius = 14
        hud.layer?.zPosition = 20
        hud.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        let label = NSTextField(labelWithString: "Showing your MacBook · Esc to disconnect")
        label.textColor = .white
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.frame = NSRect(x: 18, y: (h - 20) / 2, width: 280, height: 20)
        hud.addSubview(label)
        let b = FirstClickButton(title: "Disconnect", target: self, action: #selector(endSession))
        b.bezelStyle = .rounded
        b.controlSize = .large
        b.frame = NSRect(x: w - 124, y: (h - 32) / 2, width: 110, height: 32)
        hud.addSubview(b)
        hud.isHidden = true
        controls = hud
        return hud
    }

    func hideWindow() {
        flushLayer()
        cursorLayer.isHidden = true
        controlsHideTimer?.invalidate()
        setControlsVisible(true)   // restores the pointer
        controls?.isHidden = true
        window?.orderOut(nil)
        NSApp.presentationOptions = []
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
        clientFD = c
        showWindow()
        // Tell the sender our screen size so its Auto resolution can match it: 'R' + points W/H + pixels W/H.
        if let sc = window?.screen ?? NSScreen.main {
            let pw = Int(sc.frame.width), ph = Int(sc.frame.height), sf = sc.backingScaleFactor
            func u16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 255), UInt8(v & 255)] }
            var msg: [UInt8] = [0x52] + u16(pw) + u16(ph) + u16(Int(CGFloat(pw) * sf)) + u16(Int(CGFloat(ph) * sf))
            _ = write(c, &msg, msg.count)
        }
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
        clientFD = -1
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

            if type == 5, p.count >= 8 {
                let ptW = CGFloat(Int(p[0]) << 8 | Int(p[1]))
                print("Sender display: \(Int(ptW))x\(Int(p[2]) << 8 | Int(p[3])) pt, \(Int(p[4]) << 8 | Int(p[5]))x\(Int(p[6]) << 8 | Int(p[7])) px")
                DispatchQueue.main.async { self.senderPointsW = ptW; self.applyCursorSize() }
            } else if type == 3, p.count >= 5 {
                let x = CGFloat(Int(p[0]) << 8 | Int(p[1])) / 65535, y = CGFloat(Int(p[2]) << 8 | Int(p[3])) / 65535
                let visible = p[4] != 0
                DispatchQueue.main.async { self.moveCursor(x, y, visible) }
            } else if type == 4, p.count > 8 {
                func u16(_ i: Int) -> CGFloat { CGFloat(Int(p[i]) << 8 | Int(p[i + 1])) / 100 }
                let hot = CGPoint(x: u16(0), y: u16(2)), size = CGSize(width: u16(4), height: u16(6))
                if let src = CGImageSourceCreateWithData(Data(p[8...]) as CFData, nil),
                   let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                    DispatchQueue.main.async { self.setCursor(img, size: size, hot: hot) }
                }
            } else if type == 1 {
                if let f = makeFormat(p) {
                    // Resolution switch on the sender: drop whatever is queued for the old size.
                    if let old = fmt, CMVideoFormatDescriptionGetDimensions(old).width != CMVideoFormatDescriptionGetDimensions(f).width
                        || CMVideoFormatDescriptionGetDimensions(old).height != CMVideoFormatDescriptionGetDimensions(f).height {
                        let d = CMVideoFormatDescriptionGetDimensions(f)
                        print("Stream resolution changed to \(d.width)x\(d.height)")
                        if #available(macOS 15.0, *) { layer.sampleBufferRenderer.flush() } else { layer.flush() }
                    }
                    fmt = f
                }
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

    // MARK: cursor (main thread)

    func moveCursor(_ x: CGFloat, _ y: CGFloat, _ visible: Bool) {
        let b = layer.bounds
        cursorLayer.position = CGPoint(x: x * b.width, y: (1 - y) * b.height)   // layer origin is bottom-left
        cursorLayer.isHidden = !visible
    }

    func setCursor(_ img: CGImage, size: CGSize, hot: CGPoint) {
        guard size.width > 0, size.height > 0 else { return }
        cursorSize = size
        cursorLayer.contents = img
        cursorLayer.anchorPoint = CGPoint(x: hot.x / size.width, y: 1 - hot.y / size.height)   // hotspot is top-left based
        applyCursorSize()
    }

    /// The cursor's size is in the sender display's points; ours may differ (e.g. sender at "looks like"
    /// 1920x1080 shown on a 2560x1440-point iMac), so scale it to look the same size as on the MacBook.
    func applyCursorSize() {
        let scale = senderPointsW > 0 ? layer.bounds.width / senderPointsW : 1
        cursorLayer.bounds = CGRect(origin: .zero, size: CGSize(width: cursorSize.width * scale, height: cursorSize.height * scale))
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

// MARK: installer

enum Installer {
    static let label = "com.fivek.receiver"
    static let fm = FileManager.default
    static var home: URL { fm.homeDirectoryForCurrentUser }
    static var dest: URL { home.appendingPathComponent("Applications/FiveK Receiver.app") }
    static var plist: URL { home.appendingPathComponent("Library/LaunchAgents/\(label).plist") }
    static var domain: String { "gui/\(getuid())" }

    static var isInstalled: Bool { fm.fileExists(atPath: plist.path) && fm.fileExists(atPath: dest.path) }
    static var runningFromInstalledCopy: Bool {
        Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path == dest.resolvingSymlinksInPath().standardizedFileURL.path
    }

    @discardableResult
    static func sh(_ path: String, _ args: [String]) -> Int32 {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit(); return p.terminationStatus
    }

    static func install() throws {
        // 1. Put the app at a fixed path (a copy opened from Downloads/AirDrop may be translocated by Gatekeeper).
        if !runningFromInstalledCopy {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: Bundle.main.bundleURL, to: dest)
            sh("/usr/bin/xattr", ["-dr", "com.apple.quarantine", dest.path])
        }
        // 2. launchd agent: socket-activated, Bonjour-advertised, only in the logged-in GUI session.
        let exe = dest.appendingPathComponent("Contents/MacOS/fivek-recv").path
        let job: [String: Any] = [
            "Label": label,
            "ProgramArguments": [exe],
            "Sockets": ["Listener": ["SockServiceName": "5959", "SockType": "stream", "Bonjour": "fivek"]],
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
            "StandardOutPath": "/tmp/fivek-recv.log",
            "StandardErrorPath": "/tmp/fivek-recv.log",
        ]
        try fm.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
        try data.write(to: plist)
        sh("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        guard sh("/bin/launchctl", ["bootstrap", domain, plist.path]) == 0 else {
            throw NSError(domain: "fivek", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "launchctl couldn't load the agent. Try logging out and back in, then open FiveK Receiver again."])
        }
    }

    static func uninstall() {
        sh("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        try? fm.removeItem(at: plist)
        try? fm.removeItem(at: dest)
    }

    static func alert(_ title: String, _ text: String, _ buttons: [String] = ["OK"]) -> NSApplication.ModalResponse {
        let a = NSAlert()
        a.messageText = title; a.informativeText = text
        for b in buttons { a.addButton(withTitle: b) }
        return a.runModal()
    }

    static func run() {
        NSApp.activate(ignoringOtherApps: true)
        if isInstalled && runningFromInstalledCopy {
            let r = alert("FiveK Receiver is ready",
                          "It starts by itself when FiveK on your MacBook connects, and nothing runs until then.\n\nPress Esc on this Mac to end a session.",
                          ["OK", "Uninstall"])
            if r == .alertSecondButtonReturn {
                uninstall()
                _ = alert("FiveK Receiver uninstalled", "This Mac no longer accepts FiveK connections.")
            }
        } else {
            do {
                try install()
                _ = alert("FiveK Receiver is installed",
                          "This iMac now shows your MacBook's screen whenever you open FiveK on the MacBook. Nothing runs in the background until then.\n\nInstalled to ~/Applications. You can delete the copy you just opened.\n\nKeep this Mac logged in and set it not to sleep (System Preferences > Battery/Energy Saver: Prevent computer from sleeping automatically when the display is off).")
            } catch {
                _ = alert("Couldn't install FiveK Receiver", error.localizedDescription)
            }
        }
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = Receiver()
app.delegate = delegate
app.run()
