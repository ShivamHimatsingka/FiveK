// send-cli.swift: debug command-line front end for Sender (FiveK.app is the normal way to run it).
// Usage:  fivek-send [--host IP[:PORT]] [--mbps 60] [--fps 60] [--display ID]
// Does NOT touch BetterDisplay: the 5120x2880 virtual screen must already be connected.

import Foundation
import CoreGraphics

@main
enum SendCLI {
    static func main() {
        var cfg = SenderConfig()
        var argv = Array(CommandLine.arguments.dropFirst())
        while !argv.isEmpty {
            let a = argv.removeFirst()
            guard !argv.isEmpty else { print("missing value for \(a)"); exit(64) }
            switch a {
            case "--host":
                let s = argv.removeFirst().split(separator: ":")
                cfg.host = String(s[0]); if s.count > 1, let p = UInt16(s[1]) { cfg.port = p }
            case "--mbps": cfg.mbps = Int(argv.removeFirst()) ?? cfg.mbps
            case "--fps": cfg.fps = Int(argv.removeFirst()) ?? cfg.fps
            case "--display": cfg.displayID = CGDirectDisplayID(argv.removeFirst())
            default: print("unknown arg \(a)"); exit(64)
            }
        }
        let s = Sender(cfg)
        s.onStop = { err in exit(err == nil ? 0 : 1) }
        signal(SIGINT, SIG_IGN)
        let sig = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sig.setEventHandler { s.stop() }
        sig.resume()
        s.start()
        withExtendedLifetime(sig) { dispatchMain() }
    }
}
