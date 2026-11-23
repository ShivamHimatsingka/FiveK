// FiveKApp.swift: the one-click launcher (FiveK.app, menu bar only, no Dock icon).
//
// Launch it  -> finds the iMac over Bonjour, then creates FiveK's own virtual display at 2560x1440 HiDPI
//               (5120x2880 pixels) and streams it. No BetterDisplay needed.
// Launch it again (click the app icon) or menu bar > Stop -> stops streaming and removes the virtual display,
//               so windows come back to the Air, then exits.
//
// Settings (optional, defaults shown):
//   defaults write com.fivek.sender Resolution "2560x1440"    # what the iMac "looks like"
//   defaults write com.fivek.sender HiDPI -bool true           # false = 5120x2880 at 1x (tiny text)
//   defaults write com.fivek.sender Mbps -int 100
//   defaults write com.fivek.sender FPS -int 60
//   defaults write com.fivek.sender Host "192.168.1.20"        # skip Bonjour; delete the key to go back
//   defaults write com.fivek.sender LowLatencyRC -bool true    # old encoder mode (slower at 5K on M5)

import Cocoa
import CoreGraphics
import ScreenCaptureKit

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

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "FiveK")
        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Stop", action: #selector(stopClicked), keyEquivalent: "q"))
        item.menu = menu
        Task { await run() }
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

            // 2. Stream. The virtual display is created only once the iMac has connected, so windows never
            //    jump onto a display nobody can see.
            let res = (d.string(forKey: "Resolution") ?? "2560x1440").split(separator: "x").compactMap { Int($0) }
            let (pw, ph) = res.count == 2 ? (res[0], res[1]) : (2560, 1440)
            let hidpi = d.object(forKey: "HiDPI") as? Bool ?? true
            var cfg = SenderConfig()
            if let h = d.string(forKey: "Host"), !h.isEmpty { cfg.host = h }
            if d.integer(forKey: "Mbps") > 0 { cfg.mbps = d.integer(forKey: "Mbps") }
            if d.integer(forKey: "FPS") > 0 { cfg.fps = d.integer(forKey: "FPS") }
            cfg.lowLatencyRC = d.bool(forKey: "LowLatencyRC")
            let s = Sender(cfg)
            s.prepareDisplay = { [weak self] in await self?.makeDisplay(pw, ph, hidpi) }
            s.onStatus = { [weak self] in self?.setStatus($0) }
            s.onStop = { [weak self] err in self?.finish(err) }
            sender = s
            s.start()
        } catch {
            finish(error.localizedDescription)
        }
    }

    @MainActor
    func makeDisplay(_ w: Int, _ h: Int, _ hidpi: Bool) async -> CGDirectDisplayID? {
        setStatus("Creating the 5K display…")
        guard let v = VirtualDisplay(pointsW: w, pointsH: h, hiDPI: hidpi) else {
            print("CGVirtualDisplay creation failed"); return nil
        }
        virtualDisplay = v
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
