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

    static let auto = "auto"
    static let defaultID = "5k"
    static let presets: [DisplayChoice] = [
        DisplayChoice(id: "5k",   title: "5K · looks like 2560×1440 (5120×2880)",        pointsW: 2560, pointsH: 1440, hiDPI: true),
        DisplayChoice(id: "4096", title: "Larger text · looks like 2048×1152 (4096×2304)", pointsW: 2048, pointsH: 1152, hiDPI: true),
        DisplayChoice(id: "4k",   title: "4K · looks like 1920×1080 (3840×2160)",        pointsW: 1920, pointsH: 1080, hiDPI: true),
        DisplayChoice(id: "1440", title: "1440p · 2560×1440, faster, less sharp",        pointsW: 2560, pointsH: 1440, hiDPI: false),
        DisplayChoice(id: "1080", title: "1080p · 1920×1080, fastest",                    pointsW: 1920, pointsH: 1080, hiDPI: false),
    ]

    /// Resolves a stored mode id to a size. Auto follows the receiver's screen (5K until it reports one).
    static func resolve(_ id: String, receiver: ReceiverScreen?) -> DisplayChoice {
        if id == auto, let r = receiver {
            return DisplayChoice(id: auto, title: "Auto", pointsW: r.pointsW, pointsH: r.pointsH, hiDPI: r.hiDPI)
        }
        return presets.first { $0.id == id } ?? presets[0]
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
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Stop", action: #selector(stopClicked), keyEquivalent: "q"))
        item.menu = menu
        rebuildResolutionMenu()
        Task { await run() }
    }

    func rebuildResolutionMenu() {
        resolutionMenu.removeAllItems()
        let autoTitle = receiverScreen.map { "Auto · match the iMac (\($0.pointsW)×\($0.pointsH)\($0.hiDPI ? " HiDPI" : ""))" }
            ?? "Auto · match the iMac's screen"
        let autoItem = NSMenuItem(title: autoTitle, action: #selector(pickResolution(_:)), keyEquivalent: "")
        autoItem.representedObject = DisplayChoice.auto
        autoItem.target = self
        autoItem.state = modeID == DisplayChoice.auto ? .on : .off
        resolutionMenu.addItem(autoItem)
        resolutionMenu.addItem(.separator())
        for c in DisplayChoice.presets {
            let it = NSMenuItem(title: c.title, action: #selector(pickResolution(_:)), keyEquivalent: "")
            it.representedObject = c.id
            it.target = self
            it.state = modeID == c.id ? .on : .off
            resolutionMenu.addItem(it)
        }
    }

    @objc func pickResolution(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, id != modeID else { return }
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
            let s = Sender(cfg)
            s.prepareDisplay = { [weak self] rs in
                guard let self = self else { return nil }
                let id = await MainActor.run { self.modeID }
                let r = await self.makeDisplay(DisplayChoice.resolve(id, receiver: rs))
                await MainActor.run { self.streaming = r != nil }
                return r
            }
            s.onReceiverScreen = { [weak self] rs in self?.receiverScreen = rs; self?.rebuildResolutionMenu() }
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
                                         maxPixelW: max(5120, c.pixelW), maxPixelH: max(2880, c.pixelH)) else {
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
