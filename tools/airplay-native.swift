// airplay-native.swift
// Force a display (e.g. an AirPlay "Extend" display on a 5K iMac / Studio Display Mac)
// into its native 5120x2880 pixel (2560x1440 HiDPI) mode.
//
// Build:  swiftc -O airplay-native.swift -o airplay-native
// Usage:
//   airplay-native list                      list displays and every mode they expose
//   airplay-native set [--id N] [--size WxH] [--lodpi] [--best]
//   airplay-native watch [--id N] [--size WxH]   re-apply whenever displays change / AirPlay connects
//
// Defaults: size 5120x2880, HiDPI (pixel > point size). If --id is omitted the single
// non-built-in display is used (pass --id when you have several).

import Foundation
import CoreGraphics

// MARK: - Options

struct Opts {
    var id: CGDirectDisplayID? = nil
    var w = 5120
    var h = 2880
    var hidpi = true
    var best = false      // fall back to the largest available mode if exact size is missing
}
var opts = Opts()

// MARK: - Helpers

func onlineDisplays() -> [CGDirectDisplayID] {
    var n: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &n)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
    CGGetOnlineDisplayList(n, &ids, &n)
    return Array(ids.prefix(Int(n)))
}

func allModes(_ id: CGDirectDisplayID) -> [CGDisplayMode] {
    // Without this option macOS hides the low-res / duplicate entries that
    // often include the HiDPI variants.
    let o = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
    return (CGDisplayCopyAllDisplayModes(id, o) as? [CGDisplayMode]) ?? []
}

func describe(_ m: CGDisplayMode) -> String {
    let hidpi = m.pixelWidth > m.width ? "HiDPI" : "1x   "
    return "\(m.pixelWidth)x\(m.pixelHeight) px  (\(m.width)x\(m.height) pt) \(hidpi) @\(Int(m.refreshRate))Hz  id=\(m.ioDisplayModeID)"
}

func describe(display id: CGDirectDisplayID) -> String {
    let b = CGDisplayBounds(id)
    let kind = CGDisplayIsBuiltin(id) != 0 ? "built-in" : "external/virtual"
    let main = CGDisplayIsMain(id) != 0 ? " main" : ""
    return String(format: "id=%u  vendor=0x%X model=0x%X  %@%@  bounds=%.0fx%.0f @ (%.0f,%.0f)",
                  id, CGDisplayVendorNumber(id), CGDisplayModelNumber(id), kind, main,
                  b.width, b.height, b.origin.x, b.origin.y)
}

func resolveTarget() -> CGDirectDisplayID? {
    if let id = opts.id { return id }
    let ext = onlineDisplays().filter { CGDisplayIsBuiltin($0) == 0 }
    if ext.count == 1 { return ext[0] }
    if ext.isEmpty { fputs("No non-built-in display is online.\n", stderr) }
    else { fputs("Several non-built-in displays; pick one with --id (see `list`).\n", stderr) }
    return nil
}

func pickMode(_ id: CGDirectDisplayID) -> CGDisplayMode? {
    let modes = allModes(id).filter { $0.isUsableForDesktopGUI() }
    var exact = modes.filter { $0.pixelWidth == opts.w && $0.pixelHeight == opts.h }
    if opts.hidpi { exact = exact.filter { $0.pixelWidth > $0.width } }
    if let m = exact.max(by: { $0.refreshRate < $1.refreshRate }) { return m }
    if opts.best {
        return modes.max(by: {
            ($0.pixelWidth * $0.pixelHeight, $0.pixelWidth > $0.width ? 1 : 0, $0.refreshRate) <
            ($1.pixelWidth * $1.pixelHeight, $1.pixelWidth > $1.width ? 1 : 0, $1.refreshRate)
        })
    }
    return nil
}

@discardableResult
func apply(to id: CGDirectDisplayID, quiet: Bool = false) -> Bool {
    guard let mode = pickMode(id) else {
        if !quiet {
            fputs("No \(opts.w)x\(opts.h)\(opts.hidpi ? " HiDPI" : "") mode is exposed by display \(id).\n", stderr)
            fputs("Modes it does expose:\n", stderr)
            for m in allModes(id) { fputs("  " + describe(m) + "\n", stderr) }
            fputs("\nmacOS only lets you choose from modes the AirPlay receiver advertises. " +
                  "If 5120x2880 is missing, the stream itself is capped (see README).\n", stderr)
        }
        return false
    }
    if let cur = CGDisplayCopyDisplayMode(id), cur.ioDisplayModeID == mode.ioDisplayModeID,
       cur.pixelWidth == mode.pixelWidth {
        if !quiet { print("Already in: " + describe(mode)) }
        return true
    }
    var cfg: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&cfg) == .success else { fputs("BeginDisplayConfiguration failed\n", stderr); return false }
    let e1 = CGConfigureDisplayWithDisplayMode(cfg, id, mode, nil)
    guard e1 == .success else {
        CGCancelDisplayConfiguration(cfg)
        fputs("ConfigureDisplayWithDisplayMode failed (\(e1.rawValue))\n", stderr)
        return false
    }
    let e2 = CGCompleteDisplayConfiguration(cfg, .forSession)
    guard e2 == .success else { fputs("CompleteDisplayConfiguration failed (\(e2.rawValue))\n", stderr); return false }
    print("Set display \(id) to: " + describe(mode))
    return true
}

// MARK: - Watch

var pending = false
let reconfigCallback: CGDisplayReconfigurationCallBack = { _, flags, _ in
    if flags.contains(.beginConfigurationFlag) { return }
    if flags.contains(.addFlag) || flags.contains(.setModeFlag) || flags.contains(.enabledFlag) {
        if pending { return }
        pending = true
        // Let the AirPlay session finish negotiating before touching it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            pending = false
            if let id = resolveTarget() { apply(to: id, quiet: true) }
        }
    }
}

// MARK: - CLI

func usage() -> Never {
    print("""
    usage: airplay-native list
           airplay-native set   [--id N] [--size WxH] [--lodpi] [--best]
           airplay-native watch [--id N] [--size WxH] [--lodpi] [--best]
    """)
    exit(64)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { usage() }
args.removeFirst()
var i = 0
while i < args.count {
    switch args[i] {
    case "--id":   i += 1; guard i < args.count, let v = UInt32(args[i]) else { usage() }; opts.id = v
    case "--size":
        i += 1
        guard i < args.count else { usage() }
        let p = args[i].lowercased().split(separator: "x").compactMap { Int($0) }
        guard p.count == 2 else { usage() }
        opts.w = p[0]; opts.h = p[1]
    case "--lodpi": opts.hidpi = false
    case "--best":  opts.best = true
    default: usage()
    }
    i += 1
}

switch cmd {
case "list":
    for id in onlineDisplays() {
        print(describe(display: id))
        let cur = CGDisplayCopyDisplayMode(id)?.ioDisplayModeID
        for m in allModes(id).sorted(by: { ($0.pixelWidth, $0.refreshRate) > ($1.pixelWidth, $1.refreshRate) }) {
            print("   " + (m.ioDisplayModeID == cur ? "* " : "  ") + describe(m))
        }
        print("")
    }
case "set":
    guard let id = resolveTarget() else { exit(1) }
    exit(apply(to: id) ? 0 : 2)
case "watch":
    if let id = resolveTarget() { apply(to: id, quiet: true) }
    CGDisplayRegisterReconfigurationCallback(reconfigCallback, nil)
    print("Watching for display changes (Ctrl-C to stop)...")
    RunLoop.main.run()
default:
    usage()
}
