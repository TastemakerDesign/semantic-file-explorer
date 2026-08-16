import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

nonisolated enum ImageDecoder {
    static let inputSide = 256
    static let processorCount = ProcessInfo.processInfo.activeProcessorCount

    private struct DecodedImage: @unchecked Sendable {
        let index: Int
        let buffer: CVPixelBuffer?
    }

    static func pixelBuffers(for urls: [URL]) async -> [CVPixelBuffer?] {
        guard urls.count > 1 else {
            return urls.map { pixelBuffer(forImageAt: $0) }
        }
        return await withTaskGroup(of: DecodedImage.self) { group in
            var results = [CVPixelBuffer?](repeating: nil, count: urls.count)
            var next = 0
            while next < min(processorCount, urls.count) {
                let index = next
                let url = urls[index]
                group.addTask { DecodedImage(index: index, buffer: pixelBuffer(forImageAt: url)) }
                next += 1
            }
            for await decoded in group {
                results[decoded.index] = decoded.buffer
                guard next < urls.count else {
                    continue
                }
                let index = next
                let url = urls[index]
                group.addTask { DecodedImage(index: index, buffer: pixelBuffer(forImageAt: url)) }
                next += 1
            }
            return results
        }
    }

    static func pixelBuffer(forImageAt url: URL) -> CVPixelBuffer? {
        guard let image = image(at: url, maxPixelSize: inputSide * 2) else {
            return nil
        }
        return scaledPixelBuffer(from: image)
    }

    static func image(at url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func scaledPixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            inputSide,
            inputSide,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &buffer
        ) == kCVReturnSuccess, let buffer else {
            return nil
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: inputSide,
            height: inputSide,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }
        let side = CGFloat(inputSide)
        let scale = max(side / CGFloat(image.width), side / CGFloat(image.height))
        let width = CGFloat(image.width) * scale
        let height = CGFloat(image.height) * scale
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(
            x: (side - width) / 2,
            y: (side - height) / 2,
            width: width,
            height: height
        ))
        return buffer
    }
}
