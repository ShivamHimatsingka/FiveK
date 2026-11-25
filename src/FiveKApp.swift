// FiveKApp.swift: the one-click launcher (FiveK.app, menu bar only, no Dock icon).
//
// Launch it  -> finds the iMac over Bonjour, then creates FiveK's own virtual display (default 2560x1440
//               HiDPI = 5120x2880 pixels) and streams it. No BetterDisplay needed.
// Menu bar > Display Resolution -> pick a size, or Auto (match the receiver's screen). Applies live: the
//               virtual display is resized in place and the stream restarts at the new size.
// Launch it again (click the app icon) or menu bar > Stop -> stops streaming and removes the virtual display,
//               so windows come back to the Air, then exits.
//
// Settings (optional, defaults shown; the resolution is set from the menu and stored as DisplayMode):
//   defaults write com.fivek.sender Mbps -int 100
//   defaults write com.fivek.sender FPS -int 60
//   defaults write com.fivek.sender Host "192.168.1.20"        # skip Bonjour; delete the key to go back
//   defaults write com.fivek.sender LowLatencyRC -bool true    # old encoder mode (slower at 5K on M5)

import Cocoa
import CoreGraphics
import ScreenCaptureKit

/// A virtual display size. `pointsW` x `pointsH` is the "looks like" size; HiDPI doubles the pixels.
struct DisplayChoice {
    let id: String, title: String, pointsW: Int, pointsH: Int, hiDPI: Bool
    var pixelW: Int { hiDPI ? pointsW * 2 : pointsW }
    var pixelH: Int { hiDPI ? pointsH * 2 : pointsH }

    static let auto = "auto", custom = "custom"
    static let defaultID = "5k"
    static func hi(_ id: String, _ label: String, _ w: Int, _ h: Int) -> DisplayChoice {
        DisplayChoice(id: id, title: "\(label)looks like \(w)×\(h) (\(w * 2)×\(h * 2))", pointsW: w, pointsH: h, hiDPI: true)
    }
    /// HiDPI (Retina) sizes, largest workspace first. Above 2560×1440 the iMac scales the picture down.
    static let hiDPIPresets: [DisplayChoice] = [
        hi("3200", "Most space · ", 3200, 1800),
        hi("2880", "More space · ", 2880, 1620),
        hi("5k",   "5K · ", 2560, 1440),
        hi("2304", "", 2304, 1296),
        hi("4096", "Larger text · ", 2048, 1152),
        hi("4k",   "4K · ", 1920, 1080),
        hi("1600", "", 1600, 900),
        hi("1280", "Largest text · ", 1280, 720),
    ]
    /// Low-DPI sizes: far fewer pixels, so faster, but visibly softer on a 5K panel.
    static let standardPresets: [DisplayChoice] = [
        DisplayChoice(id: "1440", title: "2560×1440 (low DPI, faster)", pointsW: 2560, pointsH: 1440, hiDPI: false),
        DisplayChoice(id: "1080", title: "1920×1080 (low DPI, fastest)", pointsW: 1920, pointsH: 1080, hiDPI: false),
    ]
    static var presets: [DisplayChoice] { hiDPIPresets + standardPresets }

    static func customChoice(_ d: UserDefaults = .standard) -> DisplayChoice {
        let w = d.integer(forKey: "CustomWidth"), h = d.integer(forKey: "CustomHeight")
        let hd = d.object(forKey: "CustomHiDPI") as? Bool ?? true
        return DisplayChoice(id: custom, title: "Custom", pointsW: w > 0 ? w : 2560, pointsH: h > 0 ? h : 1440, hiDPI: hd)
    }

    /// Resolves a stored mode id to a size. Auto follows the receiver's screen (5K until it reports one).
    static func resolve(_ id: String, receiver: ReceiverScreen?) -> DisplayChoice {
        if id == auto, let r = receiver {
            return DisplayChoice(id: auto, title: "Auto", pointsW: r.pointsW, pointsH: r.pointsH, hiDPI: r.hiDPI)
        }
        if id == custom { return customChoice() }
        return presets.first { $0.id == id } ?? hiDPIPresets.first { $0.id == defaultID }!
    }
}

struct Failure: Error, LocalizedError {
    let msg: String
    init(_ m: String) { msg = m }
    var errorDescription: String? { msg }
}

// MARK: App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let d = UserDefaults.standard
    var item: NSStatusItem!
    var statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    var sender: Sender?
    var virtualDisplay: VirtualDisplay?   // the display exists exactly as long as this is set
    var quitting = false
    var streaming = false                 // capture has started at least once (menu changes apply live)
    var receiverScreen: ReceiverScreen?
    let resolutionMenu = NSMenu()
    let sharpnessMenu = NSMenu()
    var using444: Bool?
    var chromaNote: String?
    var currentStream: (w: Int, h: Int)?

    var chromaID: String {
        get { d.string(forKey: "Chroma") ?? ChromaMode.auto.rawValue }
        set { d.set(newValue, forKey: "Chroma") }
    }

    var modeID: String {
        get { d.string(forKey: "DisplayMode") ?? DisplayChoice.defaultID }
        set { d.set(newValue, forKey: "DisplayMode") }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "FiveK")
        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        let res = NSMenuItem(title: "Display Resolution", action: nil, keyEquivalent: "")
        res.submenu = resolutionMenu
        menu.addItem(res)
        let sharp = NSMenuItem(title: "Text Sharpness", action: nil, keyEquivalent: "")
        sharp.submenu = sharpnessMenu
        menu.addItem(sharp)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Stop", action: #selector(stopClicked), keyEquivalent: "q"))
        item.menu = menu
        rebuildResolutionMenu()
        rebuildSharpnessMenu()
        Task { await run() }
    }

    func rebuildResolutionMenu() {
        resolutionMenu.removeAllItems()
        func add(_ title: String, _ id: String) {
            let it = NSMenuItem(title: title, action: #selector(pickResolution(_:)), keyEquivalent: "")
            it.representedObject = id
            it.target = self
            it.state = modeID == id ? .on : .off
            resolutionMenu.addItem(it)
        }
        func header(_ t: String) { let h = NSMenuItem(title: t, action: nil, keyEquivalent: ""); h.isEnabled = false; resolutionMenu.addItem(h) }

        // The sharpest picture is when the stream's pixels match the iMac's exactly (no resampling there).
        if let r = receiverScreen, let cur = currentStream, (cur.w != r.pixelW || cur.h != r.pixelH) {
            header("⚠︎ The iMac's screen is \(r.pixelW)×\(r.pixelH) px; this stream is \(cur.w)×\(cur.h)")
            header("   so it's resampled. Auto matches it exactly.")
            resolutionMenu.addItem(.separator())
        }
        add(receiverScreen.map { "Auto · match the iMac (\($0.pointsW)×\($0.pointsH)\($0.hiDPI ? " HiDPI" : ""))" }
            ?? "Auto · match the iMac's screen", DisplayChoice.auto)
        resolutionMenu.addItem(.separator())
        header("HiDPI (sharp)")
        for c in DisplayChoice.hiDPIPresets { add(c.title, c.id) }
        resolutionMenu.addItem(.separator())
        header("Low DPI")
        for c in DisplayChoice.standardPresets { add(c.title, c.id) }
        resolutionMenu.addItem(.separator())
        let cc = DisplayChoice.customChoice(d)
        let customItem = NSMenuItem(title: modeID == DisplayChoice.custom
                                        ? "Custom: \(cc.pointsW)×\(cc.pointsH)\(cc.hiDPI ? " HiDPI" : "")…" : "Custom…",
                                    action: #selector(pickCustom), keyEquivalent: "")
        customItem.target = self
        customItem.state = modeID == DisplayChoice.custom ? .on : .off
        resolutionMenu.addItem(customItem)
    }

    func rebuildSharpnessMenu() {
        sharpnessMenu.removeAllItems()
        func add(_ title: String, _ id: String) {
            let it = NSMenuItem(title: title, action: #selector(pickChroma(_:)), keyEquivalent: "")
            it.representedObject = id
            it.target = self
            it.state = chromaID == id ? .on : .off
            sharpnessMenu.addItem(it)
        }
        add("Auto · full colour if the iMac can decode it", ChromaMode.auto.rawValue)
        add("Full colour (4:4:4) · sharpest text", ChromaMode.full444.rawValue)
        add("Standard (4:2:0) · lightest for the iMac", ChromaMode.standard420.rawValue)
        if let u = using444 {
            sharpnessMenu.addItem(.separator())
            let now = NSMenuItem(title: "Now: \(u ? "full colour 4:4:4" : "standard 4:2:0")\(chromaNote.map { " (\($0))" } ?? "")",
                                 action: nil, keyEquivalent: "")
            now.isEnabled = false
            sharpnessMenu.addItem(now)
        }
    }

    @objc func pickChroma(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let m = ChromaMode(rawValue: id) else { return }
        chromaID = id
        chromaNote = nil
        rebuildSharpnessMenu()
        self.sender?.setChroma(m)
    }

    @objc func pickCustom() {
        let cc = DisplayChoice.customChoice(d)
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Custom display size"
        a.informativeText = "The size the iMac's screen will look like, in points. With HiDPI on, FiveK draws it with twice as many pixels each way (like the iMac's own 5K screen). Width 640–4096, height 360–2304."
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 58))
        let wf = NSTextField(frame: NSRect(x: 0, y: 30, width: 110, height: 24)); wf.stringValue = "\(cc.pointsW)"
        let x = NSTextField(labelWithString: "×"); x.frame = NSRect(x: 118, y: 33, width: 20, height: 20)
        let hf = NSTextField(frame: NSRect(x: 140, y: 30, width: 110, height: 24)); hf.stringValue = "\(cc.pointsH)"
        let hd = NSButton(checkboxWithTitle: "HiDPI (Retina)", target: nil, action: nil); hd.frame = NSRect(x: 0, y: 0, width: 200, height: 22)
        hd.state = cc.hiDPI ? .on : .off
        [wf, x, hf, hd].forEach { v.addSubview($0) }
        a.accessoryView = v
        a.addButton(withTitle: "Use This Size"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = wf
        guard a.runModal() == .alertFirstButtonReturn else { return }
        // Even sizes only (video needs them), within what the virtual display and HEVC encoder handle.
        let w = min(4096, max(640, (Int(wf.stringValue.trimmingCharacters(in: .whitespaces)) ?? cc.pointsW) / 2 * 2))
        let h = min(2304, max(360, (Int(hf.stringValue.trimmingCharacters(in: .whitespaces)) ?? cc.pointsH) / 2 * 2))
        d.set(w, forKey: "CustomWidth"); d.set(h, forKey: "CustomHeight"); d.set(hd.state == .on, forKey: "CustomHiDPI")
        let item = NSMenuItem(); item.representedObject = DisplayChoice.custom
        modeID = ""   // force a re-apply even if Custom was already selected
        pickResolution(item)
    }

    @objc func pickResolution(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, id != modeID || id == DisplayChoice.custom else { return }
        modeID = id
        rebuildResolutionMenu()
        let c = DisplayChoice.resolve(id, receiver: receiverScreen)
        print("Resolution set to \(id): \(c.pointsW)x\(c.pointsH)\(c.hiDPI ? " HiDPI" : "")")
        // Not streaming yet: it's used when the iMac connects. Streaming: switch now, on the same connection.
        if streaming, let s = self.sender {
            s.reconfigure { [weak self] rs in await self?.makeDisplay(DisplayChoice.resolve(id, receiver: rs)) }
        }
    }

    // Clicking FiveK.app again while it runs = stop.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        stopClicked(); return false
    }

    func setStatus(_ s: String) { statusLine.title = s }

    @MainActor
    func run() async {
        do {
            // 1. Screen Recording permission (ask before touching any displays).
            // CGPreflightScreenCaptureAccess can report false for ad-hoc-signed apps that do have access,
            // so the real test is whether ScreenCaptureKit will list displays.
            let preflight = CGPreflightScreenCaptureAccess()
            var canCapture = preflight
            if !preflight {
                do { _ = try await SCShareableContent.current; canCapture = true }
                catch { print("SCShareableContent: \(error)") }
            }
            print("Screen Recording: preflight=\(preflight) usable=\(canCapture)")
            if !canCapture {
                CGRequestScreenCaptureAccess()
                throw Failure("FiveK needs Screen Recording permission. Turn it on in System Settings > Privacy & Security > Screen & System Audio Recording, then open FiveK again.")
            }

            // 2. Stream. The virtual display is created only once the iMac has connected (and has reported
            //    its screen, for Auto), so windows never jump onto a display nobody can see.
            var cfg = SenderConfig()
            if let h = d.string(forKey: "Host"), !h.isEmpty { cfg.host = h }
            if d.integer(forKey: "Mbps") > 0 { cfg.mbps = d.integer(forKey: "Mbps") }
            if d.integer(forKey: "FPS") > 0 { cfg.fps = d.integer(forKey: "FPS") }
            cfg.lowLatencyRC = d.bool(forKey: "LowLatencyRC")
            cfg.chroma = ChromaMode(rawValue: chromaID) ?? .auto
            if d.object(forKey: "MaxQP") != nil { cfg.maxQP = d.integer(forKey: "MaxQP") }
            let s = Sender(cfg)
            s.prepareDisplay = { [weak self] rs in
                guard let self = self else { return nil }
                let id = await MainActor.run { self.modeID }
                let r = await self.makeDisplay(DisplayChoice.resolve(id, receiver: rs))
                await MainActor.run { self.streaming = r != nil }
                return r
            }
            s.onReceiverScreen = { [weak self] rs in self?.receiverScreen = rs; self?.rebuildResolutionMenu() }
            s.onChromaChange = { [weak self] full, note in
                self?.using444 = full; self?.chromaNote = note; self?.rebuildSharpnessMenu()
            }
            s.onStreamSize = { [weak self] w, h in self?.currentStream = (w, h); self?.rebuildResolutionMenu() }
            s.onStatus = { [weak self] in self?.setStatus($0) }
            s.onStop = { [weak self] err in self?.finish(err) }
            sender = s
            s.start()
        } catch {
            finish(error.localizedDescription)
        }
    }

    /// Creates the virtual display, or resizes the existing one in place (windows on it stay put).
    @MainActor
    func makeDisplay(_ c: DisplayChoice) async -> CGDirectDisplayID? {
        setStatus("Setting up the \(c.pixelW)×\(c.pixelH) display…")
        if let v = virtualDisplay, v.reconfigure(pointsW: c.pointsW, pointsH: c.pointsH, hiDPI: c.hiDPI) {
            // resized in place
        } else {
            virtualDisplay = nil   // too small for the new size (or none yet): make a new one
            // Room for every preset, so later switches happen in place.
            guard let v = VirtualDisplay(pointsW: c.pointsW, pointsH: c.pointsH, hiDPI: c.hiDPI,
                                         maxPixelW: max(6400, c.pixelW), maxPixelH: max(3600, c.pixelH)) else {
                print("CGVirtualDisplay creation failed"); return nil
            }
            virtualDisplay = v
        }
        guard let v = virtualDisplay else { return nil }
        let ok = await v.waitUntilReady()
        let m = CGDisplayCopyDisplayMode(v.displayID)
        print("Virtual display \(v.displayID): \(m?.width ?? 0)x\(m?.height ?? 0) pt, \(m?.pixelWidth ?? 0)x\(m?.pixelHeight ?? 0) px, ready=\(ok)")
        return ok ? v.displayID : nil
    }

    @objc func stopClicked() {
        setStatus("Stopping…")
        if let s = sender { s.stop() } else { finish(nil) }
    }

    /// Restores everything we changed, shows an error if there was one, then quits.
    func finish(_ error: String?) {
        guard !quitting else { return }
        quitting = true
        virtualDisplay = nil   // removes the display; windows move back to the Air
        if let e = error {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "FiveK stopped"
            a.informativeText = e
            a.runModal()
        }
        NSApp.terminate(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Quit from elsewhere (logout, Activity Monitor): still put the displays back.
        if !quitting { quitting = true; self.sender?.stop(); virtualDisplay = nil }
        return .terminateNow
    }
}

@main
enum FiveKMain {
    static func main() {
        // Log to ~/Library/Logs/FiveK.log (viewable in Console.app) unless run from a terminal.
        if isatty(STDOUT_FILENO) == 0 {
            let path = NSHomeDirectory() + "/Library/Logs/FiveK.log"
            freopen(path, "w", stdout); freopen(path, "a", stderr)
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        print("FiveK started \(Date())")
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
