// FiveKApp.swift: the one-click launcher (FiveK.app, menu bar only, no Dock icon).
//
// Launch it  -> starts BetterDisplay if needed, connects the virtual screen at 2560x1440 HiDPI
//               (5120x2880 pixels), finds the iMac over Bonjour and streams.
// Launch it again (click the app icon) or menu bar > Stop -> stops streaming, disconnects the virtual
//               screen so windows come back to the Air, quits BetterDisplay if FiveK started it, exits.
//
// Settings (optional, defaults shown):
//   defaults write com.fivek.sender VirtualScreenName "Virtual 16:9"
//   defaults write com.fivek.sender Resolution "2560x1440"    # what the iMac "looks like"
//   defaults write com.fivek.sender HiDPI -bool true           # false = 5120x2880 at 1x (tiny text)
//   defaults write com.fivek.sender Mbps -int 100
//   defaults write com.fivek.sender FPS -int 60
//   defaults write com.fivek.sender Host "192.168.1.20"        # skip Bonjour; delete the key to go back
//   defaults write com.fivek.sender LowLatencyRC -bool true    # old encoder mode (slower at 5K on M5)

import Cocoa
import CoreGraphics
import ScreenCaptureKit

// MARK: BetterDisplay control (via its built-in CLI; the app must be running)

enum BetterDisplay {
    static let bundleID = "pro.betterdisplay.BetterDisplay"

    static var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
    static var running: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    /// Runs `BetterDisplay <args>` and returns (success, output). Only call while the app is running:
    /// the binary forwards the command to the running instance.
    @discardableResult
    static func cli(_ args: [String]) -> (Bool, String) {
        guard let url = appURL?.appendingPathComponent("Contents/MacOS/BetterDisplay") else { return (false, "") }
        let p = Process()
        p.executableURL = url
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (false, "\(error)") }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        let text = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return (p.terminationStatus == 0 && text != "Failed.", text)
    }

    /// Launches BetterDisplay in the background if needed. Returns true if we launched it.
    static func ensureRunning() async throws -> Bool {
        if running != nil { return false }
        guard let url = appURL else { throw Failure("BetterDisplay isn't installed.") }
        let c = NSWorkspace.OpenConfiguration()
        c.activates = false
        c.addsToRecentItems = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: c)
        // Wait until it answers CLI requests.
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 250_000_000)
            if cli(["get", "-identifiers"]).0 { return true }
        }
        throw Failure("BetterDisplay started but isn't answering. Check Settings > Application > Integration > CLI access.")
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
    var launchedBetterDisplay = false
    var connectedScreen = false
    var quitting = false

    var screenName: String { d.string(forKey: "VirtualScreenName") ?? "Virtual 16:9" }

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

            // 2. BetterDisplay running + virtual screen connected in the right mode.
            setStatus("Starting BetterDisplay…")
            launchedBetterDisplay = try await BetterDisplay.ensureRunning()
            let name = screenName
            setStatus("Connecting \(name)…")
            // BetterDisplay answers "Failed." to a `set` that changes nothing (e.g. connecting an already
            // connected screen), so read the current state first and only set what differs.
            let (exists, state) = BetterDisplay.cli(["get", "-name=\(name)", "-connected"])
            guard exists else {
                throw Failure("BetterDisplay has no virtual screen named \"\(name)\". Create a 16:9 virtual screen in BetterDisplay, or set its name with: defaults write com.fivek.sender VirtualScreenName \"<name>\"")
            }
            if state != "on" {
                guard BetterDisplay.cli(["set", "-name=\(name)", "-connected=on"]).0 else {
                    throw Failure("BetterDisplay couldn't connect \"\(name)\".")
                }
            }
            connectedScreen = true   // disconnect on stop either way, so windows come back to the Air
            let res = d.string(forKey: "Resolution") ?? "2560x1440"
            let hidpi = d.object(forKey: "HiDPI") as? Bool ?? true
            let curRes = BetterDisplay.cli(["get", "-name=\(name)", "-resolution"]).1
            let curHiDPI = BetterDisplay.cli(["get", "-name=\(name)", "-hiDPI"]).1 == "on"
            if curRes != res || curHiDPI != hidpi {
                // Retry briefly: right after connecting, the mode list may not be ready yet.
                var done = false
                for _ in 0..<8 where !done {
                    done = BetterDisplay.cli(["set", "-name=\(name)", "-resolution=\(res)", "-hiDPI=\(hidpi ? "on" : "off")"]).0
                    if !done { try await Task.sleep(nanoseconds: 250_000_000) }
                }
                // "Failed." can also mean BetterDisplay already restored that mode by itself, so check.
                let nowRes = BetterDisplay.cli(["get", "-name=\(name)", "-resolution"]).1
                let nowHiDPI = BetterDisplay.cli(["get", "-name=\(name)", "-hiDPI"]).1 == "on"
                print("BetterDisplay mode: wanted \(res) HiDPI \(hidpi), now \(nowRes) HiDPI \(nowHiDPI)\(done ? "" : " (set reported Failed.)")")
            }

            // 3. Wait for macOS to show it as a 5120-pixel-wide display.
            guard let displayID = try await waitForDisplay(pixelWidth: 5120) else {
                throw Failure("\(name) didn't come up at 5120 pixels wide. Check its resolution in BetterDisplay (\(res), HiDPI \(hidpi ? "on" : "off")).")
            }

            // 4. Stream.
            var cfg = SenderConfig()
            cfg.displayID = displayID
            if let h = d.string(forKey: "Host"), !h.isEmpty { cfg.host = h }
            if d.integer(forKey: "Mbps") > 0 { cfg.mbps = d.integer(forKey: "Mbps") }
            if d.integer(forKey: "FPS") > 0 { cfg.fps = d.integer(forKey: "FPS") }
            cfg.lowLatencyRC = d.bool(forKey: "LowLatencyRC")
            let s = Sender(cfg)
            s.onStatus = { [weak self] in self?.setStatus($0) }
            s.onStop = { [weak self] err in self?.finish(err) }
            sender = s
            s.start()
        } catch {
            finish(error.localizedDescription)
        }
    }

    func waitForDisplay(pixelWidth: Int) async throws -> CGDirectDisplayID? {
        for _ in 0..<40 {
            var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
            CGGetOnlineDisplayList(16, &ids, &n)
            for id in ids.prefix(Int(n)) where CGDisplayIsBuiltin(id) == 0 {
                if let m = CGDisplayCopyDisplayMode(id), m.pixelWidth == pixelWidth { return id }
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        return nil
    }

    @objc func stopClicked() {
        setStatus("Stopping…")
        if let s = sender { s.stop() } else { finish(nil) }
    }

    /// Restores everything we changed, shows an error if there was one, then quits.
    func finish(_ error: String?) {
        guard !quitting else { return }
        quitting = true
        if connectedScreen { BetterDisplay.cli(["set", "-name=\(screenName)", "-connected=off"]) }
        if launchedBetterDisplay { BetterDisplay.running?.terminate() }
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
        if !quitting { quitting = true; self.sender?.stop()
            if connectedScreen { BetterDisplay.cli(["set", "-name=\(screenName)", "-connected=off"]) }
            if launchedBetterDisplay { BetterDisplay.running?.terminate() }
        }
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
