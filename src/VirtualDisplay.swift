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
    let pointsW: Int, pointsH: Int, hiDPI: Bool
    var displayID: CGDirectDisplayID { display.displayID }
    var pixelW: Int { hiDPI ? pointsW * 2 : pointsW }
    var pixelH: Int { hiDPI ? pointsH * 2 : pointsH }

    /// `pointsW` x `pointsH` is the "looks like" size; with `hiDPI` the display has twice the pixels each way.
    init?(name: String = "FiveK", pointsW: Int = 2560, pointsH: Int = 1440, hiDPI: Bool = true) {
        self.pointsW = pointsW; self.pointsH = pointsH; self.hiDPI = hiDPI
        let pw = hiDPI ? pointsW * 2 : pointsW, ph = hiDPI ? pointsH * 2 : pointsH

        let d = CGVirtualDisplayDescriptor()
        d.setDispatchQueue(DispatchQueue.main)
        d.name = name
        d.maxPixelsWide = UInt32(pw)
        d.maxPixelsHigh = UInt32(ph)
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
