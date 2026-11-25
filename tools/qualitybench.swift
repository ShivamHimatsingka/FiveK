// qualitybench.swift: how close does a streamed 5K frame get to the original?
// Renders a text-heavy 5120x2880 test image (black/grey/coloured text at Retina scale + a photo-like gradient),
// encodes it with each encoder setting, decodes it back, and reports PSNR against the original for the first
// frame and after each "refinement" re-encode of the same still image (what FiveK does when the screen stops
// changing), plus bytes and encode time. Also writes a crop of each result as PNG for eyeballing.
// Run: swiftc -O tools/qualitybench.swift -o /tmp/qb && /tmp/qb [outdir]
import Foundation
import AppKit
import VideoToolbox
import CoreMedia

let W = 5120, H = 2880
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory()

// MARK: test image
func makeSource() -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, W, H, kCVPixelFormatType_32BGRA,
                        [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &pb)
    CVPixelBufferLockBaseAddress(pb!, [])
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb!), width: W, height: H, bitsPerComponent: 8,
                        bytesPerRow: CVPixelBufferGetBytesPerRow(pb!), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.setFillColor(NSColor.white.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    // photo-like area: smooth gradient with detail
    for y in stride(from: 0, to: 900, by: 4) { for x in stride(from: 3600, to: W, by: 4) {
        ctx.setFillColor(CGColor(srgbRed: CGFloat(x - 3600) / 1520, green: CGFloat(y) / 900,
                                 blue: 0.5 + 0.5 * sin(CGFloat(x * y) / 9000), alpha: 1))
        ctx.fill(CGRect(x: x, y: H - 900 + y, width: 4, height: 4))
    } }
    let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns
    let text = "The quick brown fox jumps over the lazy dog. 0123456789 — FiveK sharpness test, iOS/macOS UI text. "
    let colors: [NSColor] = [.black, .darkGray, .systemBlue, .systemRed, .systemGreen, .secondaryLabelColor]
    var y = H - 60
    var i = 0
    while y > 40 {
        let size: CGFloat = [22, 26, 28, 32, 40][i % 5]   // 11-20 pt at 2x
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size), .foregroundColor: colors[i % colors.count]]
        NSAttributedString(string: String(repeating: text, count: 3), attributes: attrs).draw(at: NSPoint(x: 20, y: y))
        y -= Int(size * 1.5); i += 1
    }
    NSGraphicsContext.restoreGraphicsState()
    CVPixelBufferUnlockBaseAddress(pb!, [])
    return pb!
}

func convert(_ src: CVPixelBuffer, to fmt: OSType) -> CVPixelBuffer {
    var dst: CVPixelBuffer?
    CVPixelBufferCreate(nil, W, H, fmt, [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &dst)
    CVBufferSetAttachment(dst!, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(dst!, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(dst!, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
    var t: VTPixelTransferSession?
    VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &t)
    let st = VTPixelTransferSessionTransferImage(t!, from: src, to: dst!)
    precondition(st == noErr, "transfer \(st)")
    return dst!
}

// MARK: metrics
func psnr(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Double {
    CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
    let pa = CVPixelBufferGetBaseAddress(a)!.assumingMemoryBound(to: UInt8.self), ra = CVPixelBufferGetBytesPerRow(a)
    let pb = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self), rb = CVPixelBufferGetBytesPerRow(b)
    var se: Double = 0
    for y in 0..<H { for x in 0..<W { for c in 0..<3 {
        let d = Double(Int(pa[y * ra + x * 4 + c]) - Int(pb[y * rb + x * 4 + c])); se += d * d
    } } }
    let mse = se / Double(W * H * 3)
    return mse == 0 ? 99 : 10 * log10(255 * 255 / mse)
}

func savePNGCrop(_ pb: CVPixelBuffer, _ name: String) {
    let ci = CIImage(cvPixelBuffer: pb).cropped(to: CGRect(x: 0, y: H - 700, width: 1400, height: 700))
    let rep = NSBitmapImageRep(ciImage: ci)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name + ".png"))
}

// MARK: encode + decode
struct Config {
    let name: String
    var fmt: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    var profile: CFString = kVTProfileLevel_HEVC_Main_AutoLevel
    var props: [CFString: CFTypeRef] = [:]
}

func run(_ c: Config, source: CVPixelBuffer) {
    let input = convert(source, to: c.fmt)
    var enc: VTCompressionSession?
    let spec: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
    var st = VTCompressionSessionCreate(allocator: nil, width: Int32(W), height: Int32(H), codecType: kCMVideoCodecType_HEVC,
                                        encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil,
                                        compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &enc)
    guard st == noErr, let e = enc else { print("\(c.name): encoder create failed \(st)"); return }
    var base: [CFString: CFTypeRef] = [kVTCompressionPropertyKey_RealTime: kCFBooleanTrue,
                                       kVTCompressionPropertyKey_AllowFrameReordering: kCFBooleanFalse,
                                       kVTCompressionPropertyKey_ProfileLevel: c.profile,
                                       kVTCompressionPropertyKey_ExpectedFrameRate: NSNumber(value: 60),
                                       kVTCompressionPropertyKey_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                                       kVTCompressionPropertyKey_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
                                       kVTCompressionPropertyKey_TransferFunction: kCVImageBufferTransferFunction_sRGB]
    for (k, v) in c.props { base[k] = v }
    for (k, v) in base {
        let r = VTSessionSetProperty(e, key: k, value: v)
        if r != noErr { print("  \(c.name): \(k) rejected \(r)") }
    }
    VTCompressionSessionPrepareToEncodeFrames(e)
    var dec: VTDecompressionSession?
    var results: [String] = []
    var last: CVPixelBuffer?
    for pass in 0..<4 {
        var out: CMSampleBuffer?
        let sem = DispatchSemaphore(value: 0)
        let t0 = Date()
        VTCompressionSessionEncodeFrame(e, imageBuffer: input, presentationTimeStamp: CMTime(value: CMTimeValue(pass), timescale: 60),
                                        duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { s, _, sb in out = sb; sem.signal() }
        sem.wait()
        let ms = Date().timeIntervalSince(t0) * 1000
        guard let sb = out, let fd = CMSampleBufferGetFormatDescription(sb) else { results.append("pass \(pass): no output"); continue }
        let bytes = CMBlockBufferGetDataLength(CMSampleBufferGetDataBuffer(sb)!)
        if dec == nil {
            st = VTDecompressionSessionCreate(allocator: nil, formatDescription: fd, decoderSpecification: nil,
                                              imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary,
                                              outputCallback: nil, decompressionSessionOut: &dec)
            guard st == noErr else { print("\(c.name): decoder create failed \(st)"); return }
        }
        let dsem = DispatchSemaphore(value: 0)
        VTDecompressionSessionDecodeFrame(dec!, sampleBuffer: sb, flags: [], infoFlagsOut: nil) { _, _, img, _, _ in last = img; dsem.signal() }
        dsem.wait()
        let p = last.map { psnr(source, $0) } ?? 0
        results.append(String(format: "%@ %6.2f dB %5.0f KB %3.0f ms", pass == 0 ? "key " : "ref\(pass)", p, Double(bytes) / 1024, ms))
    }
    if let l = last { savePNGCrop(l, c.name.replacingOccurrences(of: " ", with: "_")) }
    print("\(c.name.padding(toLength: 30, withPad: " ", startingAt: 0)) " + results.joined(separator: " | "))
    VTCompressionSessionInvalidate(e)
}

let src = makeSource()
savePNGCrop(src, "original")
let n = { (v: Int) in NSNumber(value: v) }
let abr: [CFString: CFTypeRef] = [kVTCompressionPropertyKey_AverageBitRate: n(100_000_000)]
var configs = [
    Config(name: "420 ABR100 (current)", props: abr),
    Config(name: "420 ABR100 maxQP 24", props: abr.merging([kVTCompressionPropertyKey_MaxAllowedFrameQP: n(24)]) { $1 }),
    Config(name: "420 ABR100 maxQP 18", props: abr.merging([kVTCompressionPropertyKey_MaxAllowedFrameQP: n(18)]) { $1 }),
    Config(name: "420 quality 0.95", props: [kVTCompressionPropertyKey_Quality: NSNumber(value: 0.95)]),
    Config(name: "444 ABR100", fmt: kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange, profile: ("HEVC_Main444_AutoLevel" as CFString), props: abr),
    Config(name: "444 ABR100 maxQP 24", fmt: kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange, profile: ("HEVC_Main444_AutoLevel" as CFString),
           props: abr.merging([kVTCompressionPropertyKey_MaxAllowedFrameQP: n(24)]) { $1 }),
    Config(name: "444 quality 0.95", fmt: kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange, profile: ("HEVC_Main444_AutoLevel" as CFString),
           props: [kVTCompressionPropertyKey_Quality: NSNumber(value: 0.95)]),
]
for c in configs { run(c, source: src) }
print("crops written to \(outDir)")
