// VirtualDisplay.swift: FiveK's own virtual display (replaces BetterDisplay).
//
// Uses CoreGraphics' private CGVirtualDisplay classes (declared in CGVirtualDisplay.h). The display exists only
// while this object is alive: release it (or quit) and macOS removes the display and moves windows back.
// The vendor/product/serial numbers are fixed so macOS remembers where you put the display in
// System Settings > Displays > Arrange.

import Foundation
import CoreGraphics

final class VirtualDisplay {
    let display: CGVirtualDisplay
    private(set) var pointsW: Int, pointsH: Int, hiDPI: Bool
    let maxPixelW: Int, maxPixelH: Int
    var displayID: CGDirectDisplayID { display.displayID }
    var pixelW: Int { hiDPI ? pointsW * 2 : pointsW }
    var pixelH: Int { hiDPI ? pointsH * 2 : pointsH }

    /// `pointsW` x `pointsH` is the "looks like" size; with `hiDPI` the display has twice the pixels each way.
    /// `maxPixelW` x `maxPixelH` is the largest size `reconfigure` can switch to without recreating the display.
    init?(name: String = "FiveK", pointsW: Int = 2560, pointsH: Int = 1440, hiDPI: Bool = true,
          maxPixelW: Int = 6400, maxPixelH: Int = 3600) {
        self.pointsW = pointsW; self.pointsH = pointsH; self.hiDPI = hiDPI
        let pw = hiDPI ? pointsW * 2 : pointsW, ph = hiDPI ? pointsH * 2 : pointsH
        self.maxPixelW = max(pw, maxPixelW); self.maxPixelH = max(ph, maxPixelH)

        let d = CGVirtualDisplayDescriptor()
        d.setDispatchQueue(DispatchQueue.main)
        d.name = name
        d.maxPixelsWide = UInt32(self.maxPixelW)
        d.maxPixelsHigh = UInt32(self.maxPixelH)
        d.sizeInMillimeters = CGSize(width: 597, height: 336)   // a 27" 16:9 panel
        d.vendorID = 0xF15C; d.productID = 0x5000; d.serialNum = 1
        // sRGB / BT.709 primaries and D65 white, matching how the stream is tagged.
        d.redPrimary = CGPoint(x: 0.640, y: 0.330)
        d.greenPrimary = CGPoint(x: 0.300, y: 0.600)
        d.bluePrimary = CGPoint(x: 0.150, y: 0.060)
        d.whitePoint = CGPoint(x: 0.3127, y: 0.3290)
        d.terminationHandler = { _, _ in print("virtual display terminated") }

        guard let v = CGVirtualDisplay(descriptor: d) else { return nil }
        let s = CGVirtualDisplaySettings()
        s.hiDPI = hiDPI ? 1 : 0
        s.modes = [CGVirtualDisplayMode(width: UInt(pointsW), height: UInt(pointsH), refreshRate: 60)]
        guard v.apply(s) else { return nil }
        display = v
    }

    func fits(pointsW w: Int, pointsH h: Int, hiDPI hd: Bool) -> Bool {
        (hd ? w * 2 : w) <= maxPixelW && (hd ? h * 2 : h) <= maxPixelH
    }

    /// Changes the display's size in place (windows on it stay put). False if it needs more pixels than
    /// the display was created with; then create a new VirtualDisplay instead.
    func reconfigure(pointsW w: Int, pointsH h: Int, hiDPI hd: Bool) -> Bool {
        guard fits(pointsW: w, pointsH: h, hiDPI: hd) else { return false }
        let s = CGVirtualDisplaySettings()
        s.hiDPI = hd ? 1 : 0
        s.modes = [CGVirtualDisplayMode(width: UInt(w), height: UInt(h), refreshRate: 60)]
        guard display.apply(s) else { return false }
        pointsW = w; pointsH = h; hiDPI = hd
        return true
    }

    /// Waits for macOS to bring the display online, then makes sure the wanted mode is active.
    func waitUntilReady(timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if CGDisplayIsOnline(displayID) != 0, let m = CGDisplayCopyDisplayMode(displayID) {
                if m.width == pointsW && m.pixelWidth == pixelW { return true }
                selectMode()
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    private func selectMode() {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(displayID, opts) as? [CGDisplayMode]) ?? []
        guard let m = modes.first(where: { $0.width == pointsW && $0.pixelWidth == pixelW }) else { return }
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success else { return }
        CGConfigureDisplayWithDisplayMode(cfg, displayID, m, nil)
        CGCompleteDisplayConfiguration(cfg, .forSession)
    }
}
