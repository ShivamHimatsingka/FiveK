// make-icon.swift: draws the FiveK app icon and writes an .icns.
// Usage (build.sh does this):  swift src/make-icon.swift build/AppIcon.icns
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let u = s / 1024   // design on a 1024 grid

    // macOS icon grid: 824x824 rounded square centred in 1024, radius ~185.
    let tile = NSRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185 * u, yRadius: 185 * u)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * u)
    shadow.shadowBlurRadius = 24 * u
    shadow.set()
    NSColor.black.setFill(); tilePath.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.30, alpha: 1),
               ending: NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.11, alpha: 1))!.draw(in: tilePath, angle: -90)

    // Monitor: bezel, screen, stand.
    let bezel = NSRect(x: 196 * u, y: 352 * u, width: 632 * u, height: 400 * u)
    NSColor(calibratedWhite: 0.86, alpha: 1).setFill()
    NSBezierPath(roundedRect: bezel, xRadius: 34 * u, yRadius: 34 * u).fill()
    let screen = bezel.insetBy(dx: 22 * u, dy: 22 * u)
    let screenPath = NSBezierPath(roundedRect: screen, xRadius: 14 * u, yRadius: 14 * u)
    NSGradient(colors: [NSColor(calibratedRed: 0.30, green: 0.62, blue: 1.00, alpha: 1),
                        NSColor(calibratedRed: 0.52, green: 0.36, blue: 0.98, alpha: 1),
                        NSColor(calibratedRed: 0.95, green: 0.40, blue: 0.62, alpha: 1)])!
        .draw(in: screenPath, angle: -35)
    let stand = NSBezierPath()
    stand.move(to: NSPoint(x: 452 * u, y: 352 * u)); stand.line(to: NSPoint(x: 572 * u, y: 352 * u))
    stand.line(to: NSPoint(x: 596 * u, y: 268 * u)); stand.line(to: NSPoint(x: 428 * u, y: 268 * u)); stand.close()
    NSColor(calibratedWhite: 0.72, alpha: 1).setFill(); stand.fill()
    NSColor(calibratedWhite: 0.86, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 380 * u, y: 244 * u, width: 264 * u, height: 30 * u),
                 xRadius: 15 * u, yRadius: 15 * u).fill()

    // "5K" on the screen.
    let font = NSFont.systemFont(ofSize: 210 * u, weight: .heavy)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white, .kern: -6 * u]
    let text = NSAttributedString(string: "5K", attributes: attrs)
    let ts = text.size()
    text.draw(at: NSPoint(x: screen.midX - ts.width / 2, y: screen.midY - ts.height / 2 + font.descender / 2 * -0.2))

    // Wi-Fi arcs above the monitor.
    NSColor(calibratedWhite: 0.92, alpha: 1).setStroke()
    for r in [44.0, 92.0, 140.0] {
        let arc = NSBezierPath()
        arc.appendArc(withCenter: NSPoint(x: 512 * u, y: 758 * u), radius: CGFloat(r) * u,
                      startAngle: 50, endAngle: 130)
        arc.lineWidth = 26 * u; arc.lineCapStyle = .round
        arc.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fivek-\(getpid()).iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! draw(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! draw(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out]
try! p.run(); p.waitUntilExit()
try? fm.removeItem(at: iconset)
if p.terminationStatus != 0 { exit(1) }
// Also leave a PNG preview next to the .icns.
try! draw(512).write(to: URL(fileURLWithPath: out).deletingPathExtension().appendingPathExtension("png"))
print("wrote \(out)")
