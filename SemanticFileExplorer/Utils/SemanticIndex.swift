import CryptoKit
import Foundation
import UniformTypeIdentifiers

actor SemanticIndex {
    private let root: URL
    nonisolated let fileURL: URL
    private var entries: [String: IndexEntry] = [:]
    private var database: IndexDatabase?

    var count: Int { entries.count }

    init(root: URL) {
        self.root = root
        self.fileURL = Self.storageURL(for: root)
    }

    private func openedDatabase() throws -> IndexDatabase {
        if let database {
            return database
        }
        let database = try IndexDatabase(url: fileURL, dimension: CLIPEncoder.embeddingDimension)
        self.database = database
        return database
    }

    func build(
        using encoder: CLIPEncoder,
        batchSize: Int,
        progress: @Sendable @escaping (Int, Int) -> Void
    ) async throws {
        let database = try openedDatabase()
        let root = root
        let files = await Task.detached(priority: .userInitiated) {
            Self.mediaFiles(under: root).sorted { $0.size < $1.size }
        }.value
        progress(0, files.count)
        let scanned = Set(files.map(\.relativePath))
        try database.removeFiles(notIn: scanned)
        entries = entries.filter { scanned.contains($0.key) }
        var pending: [ScannedFile] = []
        var completed = 0
        func commit(_ indexed: [IndexEntry], dropping dropped: [String]) throws {
            try database.save(indexed)
            try database.remove(dropped)
            for entry in indexed { entries[entry.relativePath] = entry }
            for path in dropped { entries[path] = nil }
        }

        func drainImages() async throws {
            guard !pending.isEmpty else {
                return
            }
            let embeddings = try await encoder.encodeImages(at: pending.map(\.url))
            var indexed: [IndexEntry] = []
            var dropped: [String] = []
            for (file, embedding) in zip(pending, embeddings) {
                guard let embedding else {
                    dropped.append(file.relativePath)
                    continue
                }
                indexed.append(IndexEntry(
                    relativePath: file.relativePath,
                    modificationDate: file.modificationDate,
                    size: file.size,
                    isVideo: false,
                    embeddings: [embedding],
                    timestamps: [0]
                ))
            }
            try commit(indexed, dropping: dropped)
            completed += pending.count
            progress(completed, files.count)
            pending.removeAll(keepingCapacity: true)
        }
        for file in files {
            try Task.checkCancellation()
            if let existing = entries[file.relativePath],
               existing.size == file.size,
               existing.modificationDate == file.modificationDate {
                completed += 1
                progress(completed, files.count)
                continue
            }
            guard file.isVideo else {
                pending.append(file)
                if pending.count >= batchSize {
                    try await drainImages()
                }
                continue
            }
            try await drainImages()
            let keyframes = (try? await encoder.encodeVideo(at: file.url, targetInterval: 2, maxFrames: 240)) ?? []
            guard !keyframes.isEmpty else {
                try commit([], dropping: [file.relativePath])
                completed += 1
                progress(completed, files.count)
                continue
            }
            let entry = IndexEntry(
                relativePath: file.relativePath,
                modificationDate: file.modificationDate,
                size: file.size,
                isVideo: true,
                embeddings: keyframes.map(\.embedding),
                timestamps: keyframes.map(\.time)
            )
            try commit([entry], dropping: [])
            completed += 1
            progress(completed, files.count)
        }
        try await drainImages()
    }

    private static let momentLimit = 5
    private static let momentTolerance: Float = 0.05

    func search(
        _ query: [Float],
        filter: SearchFilter = SearchFilter(),
        limit: Int,
        minimumScore: Float
    ) -> [SearchHit] {
        guard !query.isEmpty else {
            return []
        }
        var visual: [SearchHit] = []
        for entry in entries.values {
            guard let first = entry.embeddings.first, first.count == query.count else {
                continue
            }
            let url = root.appending(path: entry.relativePath)
            guard filter.admits(url) else {
                continue
            }
            let score: Float
            let moments: [MatchMoment]
            if entry.isVideo {
                moments = Self.matchingSegments(of: entry, for: query, minimumScore: minimumScore)
                guard let best = moments.first else {
                    continue
                }
                score = best.score
            } else {
                score = Self.similarity(query, first)
                moments = []
            }
            guard score >= minimumScore else {
                continue
            }
            visual.append(SearchHit(url: url, score: score, moments: moments, matchedName: false))
        }
        let ranked = visual.sorted { ($0.score ?? 0) > ($1.score ?? 0) }
        return Array(ranked.prefix(limit))
    }

    private static func matchingSegments(of entry: IndexEntry, for query: [Float], minimumScore: Float) -> [MatchMoment] {
        let similarities = entry.embeddings.map { similarity(query, $0) }
        guard !similarities.isEmpty else {
            return []
        }
        guard similarities.count > 1 else {
            let time = entry.timestamps.first ?? 0
            return [MatchMoment(range: time...time, score: similarities[0])]
        }
        let smoothed = movingAverage(similarities, window: smoothingWindow(for: similarities.count))
        guard var scores = zScores(smoothed) else {
            return [segment(of: entry, over: 0...(smoothed.count - 1), for: query)]
        }
        var found: [MatchMoment] = []
        while found.count < momentLimit {
            guard let window = maximumSubarray(scores), scores[window].reduce(0, +) > 0 else {
                break
            }
            found.append(segment(of: entry, over: window, for: query))
            let low = max(0, window.lowerBound - 1)
            let high = min(scores.count - 1, window.upperBound + 1)
            for index in low...high {
                scores[index] = -.greatestFiniteMagnitude
            }
        }
        guard let best = found.map(\.score).max(), best >= minimumScore else {
            return []
        }
        return found
            .filter { $0.score >= minimumScore && $0.score >= best - momentTolerance }
            .sorted { $0.score > $1.score }
    }

    private static func segment(of entry: IndexEntry, over window: ClosedRange<Int>, for query: [Float]) -> MatchMoment {
        let mean = normalized(meanVector(entry.embeddings[window]))
        let start = entry.timestamps[window.lowerBound]
        let end = entry.timestamps[window.upperBound]
        return MatchMoment(range: start...max(start, end), score: similarity(query, mean))
    }

    static func movingAverage(_ values: [Float], window: Int) -> [Float] {
        guard window > 1, values.count > window else {
            return values
        }
        let radius = window / 2
        return values.indices.map { i in
            let low = max(0, i - radius)
            let high = min(values.count - 1, i + radius)
            var sum: Float = 0
            for j in low...high { sum += values[j] }
            return sum / Float(high - low + 1)
        }
    }

    private static func smoothingWindow(for count: Int) -> Int {
        switch count {
        case ..<5: 1
        case ..<12: 3
        default: 5
        }
    }

    static func zScores(_ values: [Float]) -> [Float]? {
        guard values.count > 1 else {
            return nil
        }
        let mean = values.reduce(0, +) / Float(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(values.count)
        let deviation = variance.squareRoot()
        guard deviation > 1e-6 else {
            return nil
        }
        return values.map { ($0 - mean) / deviation }
    }

    static func maximumSubarray(_ values: [Float]) -> ClosedRange<Int>? {
        guard !values.isEmpty else {
            return nil
        }
        var bestSum = -Float.greatestFiniteMagnitude
        var best = 0...0
        var runningSum: Float = 0
        var runStart = 0
        for (index, value) in values.enumerated() {
            if runningSum <= 0 {
                runningSum = value
                runStart = index
            } else {
                runningSum += value
            }
            if runningSum > bestSum {
                bestSum = runningSum
                best = runStart...index
            }
        }
        return best
    }

    private static func meanVector(_ vectors: ArraySlice<[Float]>) -> [Float] {
        guard let width = vectors.first?.count, !vectors.isEmpty else {
            return []
        }
        var sum = [Float](repeating: 0, count: width)
        for vector in vectors where vector.count == width {
            for i in 0..<width { sum[i] += vector[i] }
        }
        let count = Float(vectors.count)
        return sum.map { $0 / count }
    }

    private static func normalized(_ vector: [Float]) -> [Float] {
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else {
            return vector
        }
        return vector.map { $0 / norm }
    }

    private static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else {
            return 0
        }
        var total: Float = 0
        for i in 0..<a.count {
            total += a[i] * b[i]
        }
        return total
    }

    nonisolated static func mediaFileCount(under root: URL) -> Int {
        mediaFiles(under: root).count
    }

    func unindexedFiles(limit: Int) async -> UnindexedFiles {
        let known = Set(entries.keys)
        let root = root
        return await Task.detached(priority: .userInitiated) {
            let missing = Self.mediaFiles(under: root)
                .map(\.relativePath)
                .filter { !known.contains($0) }
            return UnindexedFiles(paths: Array(missing.prefix(limit)), total: missing.count)
        }.value
    }

    private struct ScannedFile: Sendable {
        let url: URL
        let relativePath: String
        let modificationDate: Date
        let size: Int64
        let isVideo: Bool
    }

    private static func mediaFiles(under root: URL) -> [ScannedFile] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .contentTypeKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }
        let prefixCount = root.standardizedFileURL.pathComponents.count
        var files: [ScannedFile] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isDirectory != true, let type = values.contentType else {
                continue
            }
            let isVideo = type.conforms(to: .movie)
            guard isVideo || type.conforms(to: .image) else {
                continue
            }
            let relative = url.standardizedFileURL.pathComponents.dropFirst(prefixCount).joined(separator: "/")
            files.append(ScannedFile(
                url: url,
                relativePath: relative,
                modificationDate: values.contentModificationDate ?? .distantPast,
                size: Int64(values.fileSize ?? 0),
                isVideo: isVideo
            ))
        }
        return files
    }

    func load() {
        guard let database = try? openedDatabase() else {
            return
        }
        let stored = (try? database.entries()) ?? []
        entries = Dictionary(stored.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func deleteStoredIndex() {
        entries = [:]
        try? openedDatabase().removeAll()
    }

    private static func storageURL(for root: URL) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let digest = SHA256.hash(data: Data(root.path(percentEncoded: false).utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return support
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "SemanticFileExplorer", isDirectory: true)
            .appendingPathComponent("Indexes", isDirectory: true)
            .appendingPathComponent(name)
            .appendingPathExtension("sqlite")
    }
}

struct IndexEntry: Sendable {
    let relativePath: String
    let modificationDate: Date
    let size: Int64
    let isVideo: Bool
    let embeddings: [[Float]]
    let timestamps: [Double]
}

nonisolated struct MatchMoment: Sendable, Hashable {
    let range: ClosedRange<Double>
    let score: Float
}

struct SearchHit: Sendable {
    let url: URL
    let score: Float?
    let moments: [MatchMoment]
    let matchedName: Bool
}

nonisolated struct UnindexedFiles: Sendable {
    let paths: [String]
    let total: Int

    var remainder: Int { max(0, total - paths.count) }
}

nonisolated struct SearchFilter: Sendable {
    var directory: URL?
    var includesSubfolders = true
    var excluding: Set<URL> = []

    func admits(_ url: URL) -> Bool {
        guard !excluding.contains(url) else {
            return false
        }
        guard let directory else {
            return true
        }
        if includesSubfolders {
            return url.isDescendant(of: directory)
        }
        return url.deletingLastPathComponent().standardizedFileURL.pathComponents
            == directory.standardizedFileURL.pathComponents
    }
}
