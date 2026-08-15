import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

nonisolated enum MediaDecoder {
    static let inputSide = 256
    static let processorCount = ProcessInfo.processInfo.activeProcessorCount

    private struct DecodedImage: @unchecked Sendable {
        let index: Int
        let buffer: CVPixelBuffer?
    }

    static func pixelBuffers(for urls: [URL]) async -> [CVPixelBuffer?] {
        guard urls.count > 1 else {
            return urls.map { pixelBuffer(for: $0) }
        }
        return await withTaskGroup(of: DecodedImage.self) { group in
            var results = [CVPixelBuffer?](repeating: nil, count: urls.count)
            var next = 0
            while next < min(processorCount, urls.count) {
                let index = next
                let url = urls[index]
                group.addTask { DecodedImage(index: index, buffer: pixelBuffer(for: url)) }
                next += 1
            }
            for await decoded in group {
                results[decoded.index] = decoded.buffer
                guard next < urls.count else {
                    continue
                }
                let index = next
                let url = urls[index]
                group.addTask { DecodedImage(index: index, buffer: pixelBuffer(for: url)) }
                next += 1
            }
            return results
        }
    }

    static func pixelBuffer(for url: URL) -> CVPixelBuffer? {
        guard let image = image(at: url, maxPixelSize: inputSide * 2) else {
            return nil
        }
        return pixelBuffer(from: image)
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

    static func frame(of url: URL, after seconds: Double, maxSize: CGSize) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0 else {
            return nil
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maxSize
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let target = duration > seconds ? seconds : 0
        return try? await generator.image(at: CMTime(seconds: target, preferredTimescale: 600)).image
    }

    static func pixelBuffer(from image: CGImage) -> CVPixelBuffer? {
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

    static func frames(of url: URL, targetInterval: Double, maxFrames: Int) async throws -> [DecodedVideoFrame] {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            return []
        }
        let interval = max(targetInterval, duration / Double(maxFrames))
        let times = stride(from: 0, to: duration, by: interval).map {
            CMTime(seconds: $0, preferredTimescale: 600)
        }
        guard !times.isEmpty else {
            return []
        }
        let lanes = min(processorCount, times.count)
        let perLane = (times.count + lanes - 1) / lanes
        var decoded: [DecodedVideoFrame] = []
        await withTaskGroup(of: [DecodedVideoFrame].self) { group in
            for lane in 0..<lanes {
                let start = lane * perLane
                let end = min(start + perLane, times.count)
                guard start < end else {
                    continue
                }
                let slice = Array(times[start..<end])
                group.addTask { await frames(at: slice, of: url) }
            }
            for await lane in group {
                decoded.append(contentsOf: lane)
            }
        }
        decoded.sort { $0.time < $1.time }
        var unique: [DecodedVideoFrame] = []
        var lastTime = -Double.infinity
        for frame in decoded {
            guard frame.time > lastTime + 0.001 else {
                continue
            }
            lastTime = frame.time
            unique.append(frame)
        }
        return unique
    }

    private static func frames(at times: [CMTime], of url: URL) async -> [DecodedVideoFrame] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(
            width: inputSide * 2,
            height: inputSide * 2
        )
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        var frames: [DecodedVideoFrame] = []
        for await result in generator.images(for: times) {
            guard let image = try? result.image, let snapped = try? result.actualTime else {
                continue
            }
            guard let buffer = pixelBuffer(from: image) else {
                continue
            }
            frames.append(DecodedVideoFrame(time: snapped.seconds, buffer: buffer))
        }
        return frames
    }
}

nonisolated struct DecodedVideoFrame: @unchecked Sendable {
    let time: Double
    let buffer: CVPixelBuffer
}
