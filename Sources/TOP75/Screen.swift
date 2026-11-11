import CoreGraphics
import Foundation
import ImageIO

struct ScreenArtwork: Sendable {
    static let side = 128
    static let maximumFrames = 25
    let frames: [[UInt8]]
    let delay: UInt8
    let previewPNG: Data?

    init(url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize,
              size <= 20 * 1024 * 1024,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ScreenError.invalidFile
        }
        let count = CGImageSourceGetCount(source)
        guard (1...Self.maximumFrames).contains(count) else { throw ScreenError.frameCount }
        var frames: [[UInt8]] = []
        var milliseconds: Double = 0
        var preview: Data?
        for index in 0..<count {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Self.side
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
                throw ScreenError.invalidFile
            }
            let rendered = try Self.render(image)
            frames.append(rendered.bytes)
            if index == 0 { preview = rendered.preview }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let duration = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
                ?? gif?[kCGImagePropertyGIFDelayTime] as? Double
                ?? 0.1
            milliseconds += max(0.02, duration) * 1000
        }
        self.frames = frames
        delay = count == 1 ? 0 : UInt8(min(255, (milliseconds / Double(count)).rounded()))
        previewPNG = preview
    }

    private static func render(_ image: CGImage) throws -> (bytes: [UInt8], preview: Data?) {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let canvas = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
              ) else { throw ScreenError.invalidFile }
        canvas.setFillColor(gray: 0, alpha: 1)
        canvas.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let scale = min(Double(side) / Double(image.width), Double(side) / Double(image.height))
        let width = Double(image.width) * scale
        let height = Double(image.height) * scale
        canvas.draw(image, in: CGRect(x: (Double(side) - width) / 2, y: (Double(side) - height) / 2, width: width, height: height))
        guard let data = canvas.data else { throw ScreenError.invalidFile }
        let rgba = data.assumingMemoryBound(to: UInt8.self)
        let bytes = rgb565 { x, y in
            let offset = (y * side + x) * 4
            return (rgba[offset], rgba[offset + 1], rgba[offset + 2])
        }
        let preview = NSMutableData()
        if let rendered = canvas.makeImage(),
           let destination = CGImageDestinationCreateWithData(preview, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, rendered, nil)
            if CGImageDestinationFinalize(destination) { return (bytes, preview as Data) }
        }
        return (bytes, nil)
    }

    static func rgb565(pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(side * side * 2)
        for x in 0..<side {
            for y in 0..<side {
                let (r, g, b) = pixel(x, y)
                let value = UInt16(r >> 3) << 11 | UInt16(g >> 2) << 5 | UInt16(b >> 3)
                bytes.append(UInt8(value >> 8))
                bytes.append(UInt8(truncatingIfNeeded: value))
            }
        }
        return bytes
    }
}

enum ScreenError: LocalizedError {
    case invalidFile, frameCount, deviceRejected

    var errorDescription: String? {
        switch self {
        case .invalidFile: "20 MB altında, okunabilir bir görsel seç."
        case .frameCount: "En fazla 25 kare içeren bir görsel veya GIF seç."
        case .deviceRejected: "Ekran aktarımı için klavye hazır yanıtı vermedi."
        }
    }
}

extension Keyboard {
    static func uploadArtwork(
        _ artwork: ScreenArtwork, slot: UInt8, progress: @Sendable (Double) -> Void
    ) throws {
        guard slot < 5, let first = artwork.frames.first,
              artwork.frames.count <= ScreenArtwork.maximumFrames,
              artwork.frames.allSatisfy({ $0.count == ScreenArtwork.side * ScreenArtwork.side * 2 })
        else { throw ScreenError.invalidFile }

        try withDevice { device in
            let count = UInt8(artwork.frames.count)
            let firstIndex: UInt8 = count == 1 ? slot : 0
            let byteCount = UInt16(first.count)
            let side = UInt8(ScreenArtwork.side)
            let parameters: [UInt8] = [
                firstIndex, count, artwork.delay, UInt8(truncatingIfNeeded: byteCount), UInt8(byteCount >> 8),
                0, 0, 0, 0, side, side, 0, 0, 0, 0, 0, 0
            ]
            var ready = false
            for _ in 0..<10 {
                let response = try request(device, opcode: 0xA5, parameters: parameters, delay: 0.1)
                if response[1] == 1 {
                    ready = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            guard ready else { throw ScreenError.deviceRejected }
            Thread.sleep(forTimeInterval: 0.1)

            let pages = (first.count + 55) / 56
            let totalPages = pages * artwork.frames.count
            for (frame, data) in artwork.frames.enumerated() {
                let index = count == 1 ? slot : UInt8(frame)
                for page in 0..<pages {
                    try Task.checkCancellation()
                    let start = page * 56
                    let payload = Array(data[start..<min(start + 56, data.count)])
                    let header: [UInt8] = [
                        0x25, index, count, artwork.delay, UInt8(truncatingIfNeeded: page),
                        UInt8(page >> 8), UInt8(payload.count), 0
                    ]
                    try send(device, report(header + payload, checksumIndex: 7))
                    Thread.sleep(forTimeInterval: 0.003)
                    if page % 32 == 0 {
                        progress(Double(frame * pages + page + 1) / Double(totalPages))
                    }
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
            progress(1)
        }
    }
}
