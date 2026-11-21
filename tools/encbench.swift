// Run: swiftc -O tools/encbench.swift -o /tmp/encbench && /tmp/encbench
// Encoder latency benchmark: feeds IOSurface-backed NV12 frames with a moving block (like a window drag)
// and measures per-frame submit->output latency, encoding strictly one frame at a time.
import Foundation
import VideoToolbox
import CoreVideo

func makePool(_ w: Int, _ h: Int) -> CVPixelBufferPool {
    var pool: CVPixelBufferPool?
    let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                  kCVPixelBufferWidthKey: w, kCVPixelBufferHeightKey: h,
                                  kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
    CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
    return pool!
}

func fill(_ pb: CVPixelBuffer, frame i: Int) {
    CVPixelBufferLockBaseAddress(pb, [])
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
    let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
    let ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
    // static "text-like" background + a 600x400 block moving 40 px/frame
    let bx = (i * 40) % (w - 600), by = h / 3
    for r in stride(from: 0, to: h, by: 1) {
        let row = y + r * ys
        for c in stride(from: 0, to: w, by: 1) {
            let inBlock = c >= bx && c < bx + 600 && r >= by && r < by + 400
            row[c] = inBlock ? 40 : UInt8(((c / 3 + r / 7) * 37 + (c * r) % 11) & 0xFF) / 2 + 100
        }
    }
    let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self)
    memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(pb, 1) * h / 2)
    CVPixelBufferUnlockBaseAddress(pb, [])
}

func bench(_ name: String, w: Int, h: Int, codec: CMVideoCodecType, lowLatency: Bool, realtime: Bool, n: Int = 40) {
    var spec: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
    if lowLatency { spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
    var s: VTCompressionSession?
    let st = VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h), codecType: codec,
                                        encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil,
                                        compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &s)
    guard st == noErr, let sess = s else { print("\(name): create failed \(st)"); return }
    VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_RealTime, value: realtime ? kCFBooleanTrue : kCFBooleanFalse)
    VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
    VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: 100_000_000))
    VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: 60))
    VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: Int32.max))
    VTCompressionSessionPrepareToEncodeFrames(sess)
    let pool = makePool(w, h)
    // pre-render frames so filling doesn't count
    var frames: [CVPixelBuffer] = []
    for i in 0..<8 { var pb: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb); fill(pb!, frame: i); frames.append(pb!) }
    var lat: [Double] = []
    var bytes = 0
    for i in 0..<n {
        let sem = DispatchSemaphore(value: 0)
        let t0 = DispatchTime.now().uptimeNanoseconds
        VTCompressionSessionEncodeFrame(sess, imageBuffer: frames[i % 8], presentationTimeStamp: CMTime(value: CMTimeValue(i), timescale: 60),
                                        duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { _, _, sb in
            if let sb = sb, let bb = CMSampleBufferGetDataBuffer(sb) { bytes += CMBlockBufferGetDataLength(bb) }
            sem.signal()
        }
        sem.wait()
        if i >= 3 { lat.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6) }   // skip warm-up
        Thread.sleep(forTimeInterval: 1.0 / 60)
    }
    VTCompressionSessionInvalidate(sess)
    lat.sort()
    print(String(format: "%-34@ median %5.1f ms  p90 %5.1f  max %5.1f   avg frame %4.0f KB", name as NSString,
                 lat[lat.count / 2], lat[lat.count * 9 / 10], lat.last!, Double(bytes) / Double(n) / 1024))
}


// Pipelined: submit at 60 Hz without waiting (up to `depth` outstanding), measure latency and achieved fps.
func pipe(_ name: String, lowLatency: Bool, delay0: Bool, depth: Int = 3, n: Int = 120) {
    var spec: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
    if lowLatency { spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
    var s: VTCompressionSession?
    VTCompressionSessionCreate(allocator: nil, width: 5120, height: 2880, codecType: kCMVideoCodecType_HEVC,
                               encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil,
                               compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &s)
    let sess = s!
    VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
    VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: 100_000_000))
    VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: 60))
    let d0 = delay0 ? VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: NSNumber(value: 0)) : 0
    VTCompressionSessionPrepareToEncodeFrames(sess)
    let pool = makePool(5120, 2880)
    var frames: [CVPixelBuffer] = []
    for i in 0..<8 { var pb: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb); fill(pb!, frame: i); frames.append(pb!) }
    let lock = NSLock(); var outstanding = 0; var lat: [Double] = []; var done = 0; var skipped = 0
    let start = DispatchTime.now().uptimeNanoseconds
    for i in 0..<n {
        lock.lock(); let o = outstanding; lock.unlock()
        if o >= depth { skipped += 1 } else {
            lock.lock(); outstanding += 1; lock.unlock()
            let t0 = DispatchTime.now().uptimeNanoseconds
            VTCompressionSessionEncodeFrame(sess, imageBuffer: frames[i % 8], presentationTimeStamp: CMTime(value: CMTimeValue(i), timescale: 60),
                                            duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { _, _, _ in
                lock.lock(); outstanding -= 1; done += 1
                lat.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6); lock.unlock()
            }
        }
        Thread.sleep(forTimeInterval: 1.0 / 60)
    }
    VTCompressionSessionCompleteFrames(sess, untilPresentationTimeStamp: .invalid)
    let secs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    lat.sort()
    print(String(format: "%-30@ fps %4.1f  skipped %3d  latency median %5.1f  p90 %5.1f ms  (delay0 status %d)", name as NSString,
                 Double(done) / secs, skipped, lat[lat.count / 2], lat[lat.count * 9 / 10], d0))
    VTCompressionSessionInvalidate(sess)
}
pipe("pipelined low-latency", lowLatency: true, delay0: false)
pipe("pipelined normal", lowLatency: false, delay0: false)
pipe("pipelined normal + delay 0", lowLatency: false, delay0: true)
