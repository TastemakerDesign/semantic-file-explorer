import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import UniformTypeIdentifiers

@Observable
final class ThumbnailStore {
    private nonisolated static let renderPixelSize = 512
    private nonisolated static let jpegQuality = 0.85
    private nonisolated static let videoFrameTime = 15.0
    private nonisolated static let keyframeLead = 0.25

    private let memory = NSCache<NSString, NSImage>()
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    private var prefetchTask: Task<Void, Never>?

    init() {
        memory.countLimit = 600
    }

    func cachedThumbnail(for item: FileItem, at time: Double?) -> NSImage? {
        memory.object(forKey: Self.cacheKey(for: item, at: time) as NSString)
    }

    func thumbnail(for item: FileItem, at time: Double?) async -> NSImage? {
        let key = Self.cacheKey(for: item, at: time)
        if let cached = memory.object(forKey: key as NSString) { return cached }
        if let existing = inFlight[key] { return await existing.value }
        let url = item.url
        let contentType = item.contentType
        let task = Task { () -> NSImage? in
            let cached = await Task.detached(priority: .userInitiated) { Self.readCache(key) }.value
            if let cached { return NSImage(data: cached) }
            guard let data = await Task.detached(priority: .userInitiated, operation: {
                await Self.renderJPEG(for: url, contentType: contentType, at: time)
            }).value else {
                return nil
            }
            Task.detached(priority: .background) { Self.writeCache(data, key: key) }
            return NSImage(data: data)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { memory.setObject(image, forKey: key as NSString) }
        return image
    }

    func prefetch(_ items: [FileItem], concurrency: Int) {
        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                var pending = items.makeIterator()
                var running = 0
                while running < concurrency, let item = pending.next() {
                    group.addTask { _ = await self?.thumbnail(for: item, at: nil) }
                    running += 1
                }
                while await group.next() != nil {
                    if Task.isCancelled {
                        break
                    }
                    guard let item = pending.next() else {
                        continue
                    }
                    group.addTask { _ = await self?.thumbnail(for: item, at: nil) }
                }
            }
        }
    }

    func clearMemoryCache() {
        prefetchTask?.cancel()
        memory.removeAllObjects()
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
    }

    func clearAllCaches() {
        clearMemoryCache()
        try? FileManager.default.removeItem(at: Self.cacheDirectory)
    }

    nonisolated static func revealCacheInFinder() {
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(cacheDirectory)
    }

    private nonisolated static func cacheKey(for item: FileItem, at time: Double?) -> String {
        var seed = "2|\(item.url.path(percentEncoded: false))|\(item.size)|\(item.modificationDate.timeIntervalSince1970)"
        if let time {
            seed += "|@\(Int(time.rounded()))"
        }
        let digest = SHA256.hash(data: Data(seed.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static let cacheDirectory: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "SemanticFileExplorer", isDirectory: true)
            .appendingPathComponent("Thumbnails", isDirectory: true)
    }()

    private nonisolated static func cacheFile(for key: String) -> URL {
        cacheDirectory.appendingPathComponent(key).appendingPathExtension("jpg")
    }

    private nonisolated static func readCache(_ key: String) -> Data? {
        try? Data(contentsOf: cacheFile(for: key), options: .mappedIfSafe)
    }

    private nonisolated static func writeCache(_ data: Data, key: String) {
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? data.write(to: cacheFile(for: key), options: .atomic)
    }

    private nonisolated static func renderJPEG(for url: URL, contentType: UTType?, at time: Double?) async -> Data? {
        guard let contentType else {
            return nil
        }
        let image: CGImage?
        if contentType.conforms(to: .movie) {
            let seconds = time.map { max(0, $0 - keyframeLead) } ?? videoFrameTime
            image = await VideoDecoder.thumbnailFrame(
                of: url,
                after: seconds,
                maxSize: CGSize(width: renderPixelSize, height: renderPixelSize)
            )
        } else if contentType.conforms(to: .image) {
            image = ImageDecoder.image(at: url, maxPixelSize: renderPixelSize)
        } else {
            return nil
        }
        guard let image else {
            return nil
        }
        let bitmap = NSBitmapImageRep(cgImage: image)
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality])
    }
}
