import AppKit
import Foundation

@Observable
final class SearchEngine {
    enum State: Equatable {
        case notIndexed
        case indexing(completed: Int, total: Int)
        case ready(count: Int, total: Int)
        case failed(String)

        var isIndexing: Bool {
            if case .indexing = self { return true }
            return false
        }

        var indexedCount: Int {
            if case .ready(let count, _) = self { return count }
            return 0
        }

        var fraction: Double? {
            guard case .indexing(let completed, let total) = self, total > 0 else {
                return nil
            }
            return Double(completed) / Double(total)
        }
    }

    private(set) var state: State = .notIndexed
    private(set) var hits: [SearchHit]?
    private(set) var generation = 0
    private(set) var needsIndex = false
    private(set) var activeQuery: String?
    private(set) var unindexedFiles: UnindexedFiles?

    var indexLocation: URL? { index?.fileURL }

    private func publish(_ results: [SearchHit]?, query: String? = nil) {
        hits = results
        activeQuery = query
        generation &+= 1
    }

    private var root: URL?
    private var mediaTotal = 0
    private var index: SemanticIndex?
    private var encoder: CLIPEncoder?
    private var indexTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var unindexedTask: Task<Void, Never>?

    var isAvailable: Bool {
        if case .failed = state { return false }
        return true
    }

    func use(root url: URL) {
        guard url != root else {
            return
        }
        indexTask?.cancel()
        searchTask?.cancel()
        root = url
        publish(nil)
        forgetUnindexedFiles()
        state = .notIndexed
        let index = SemanticIndex(root: url)
        self.index = index

        Task {
            await index.load()
            let count = await index.count
            guard url == root else {
                return
            }
            guard count > 0 else {
                state = .notIndexed
                return
            }

            state = .ready(count: count, total: count)

            let scanned = await Task.detached(priority: .userInitiated) {
                SemanticIndex.mediaFileCount(under: url)
            }.value

            guard url == root, state == .ready(count: count, total: count) else {
                return
            }
            mediaTotal = max(scanned, count)
            state = .ready(count: count, total: mediaTotal)
        }
    }

    func close() {
        indexTask?.cancel()
        indexTask = nil
        searchTask?.cancel()
        searchTask = nil
        forgetUnindexedFiles()
        root = nil
        index = nil
        mediaTotal = 0
        needsIndex = false
        state = .notIndexed
        publish(nil)
    }

    func startIndexing() {
        guard let root, let index, !state.isIndexing else {
            return
        }
        forgetUnindexedFiles()
        state = .indexing(completed: 0, total: 0)
        indexTask = Task {
            do {
                let encoder = try await loadedEncoder()
                try await index.build(using: encoder, batchSize: 16) { completed, total in
                    Task { @MainActor in
                        self.mediaTotal = total
                        guard self.state.isIndexing else {
                            return
                        }
                        self.state = .indexing(completed: completed, total: total)
                    }
                }
                let count = await index.count
                guard !Task.isCancelled, root == self.root else {
                    return
                }
                state = .ready(count: count, total: max(mediaTotal, count))
            } catch is CancellationError {
                let count = await index.count
                state = count > 0 ? .ready(count: count, total: max(mediaTotal, count)) : .notIndexed
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancelIndexing() {
        indexTask?.cancel()
        indexTask = nil
    }

    func findUnindexedFiles(limit: Int) {
        guard case .ready(let count, let total) = state, count < total else {
            return
        }
        guard unindexedFiles == nil, unindexedTask == nil, let index else {
            return
        }
        unindexedTask = Task {
            let found = await index.unindexedFiles(limit: limit)
            guard !Task.isCancelled else {
                return
            }
            unindexedTask = nil
            guard case .ready(let now, let all) = state, now < all else {
                return
            }
            unindexedFiles = found
        }
    }

    private func forgetUnindexedFiles() {
        unindexedTask?.cancel()
        unindexedTask = nil
        unindexedFiles = nil
    }

    func clearIndex() {
        cancelIndexing()
        forgetUnindexedFiles()
        guard let index else {
            return
        }
        Task {
            await index.deleteStoredIndex()
            state = .notIndexed
        }
    }

    func search(
        _ query: String,
        scope: SearchScope = .currentFolderAndSubfolders,
        directory: URL? = nil,
        includeFileNames: Bool = false
    ) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            needsIndex = false
            publish(nil)
            return
        }
        let scanRoot = directory ?? root
        let recursive = scope.isRecursive
        let index = index
        searchTask = Task {
            let indexed = await index?.count ?? 0
            guard indexed > 0 || includeFileNames else {
                needsIndex = true
                return
            }
            needsIndex = false
            var named: [SearchHit] = []
            if includeFileNames, let scanRoot {
                let urls = await Task.detached(priority: .userInitiated) {
                    FilenameSearch.matches(for: trimmed, in: scanRoot, includesSubfolders: recursive, limit: 300)
                }.value
                named = urls.map { SearchHit(url: $0, score: nil, moments: [], matchedName: true) }
            }
            guard !Task.isCancelled else {
                return
            }
            guard indexed > 0, let index else {
                publish(named, query: trimmed)
                return
            }
            let filter = SearchFilter(
                directory: directory,
                includesSubfolders: recursive,
                excluding: Set(named.map(\.url))
            )
            do {
                let encoder = try await loadedEncoder()
                let embedding = try await encoder.encodeText(trimmed)
                let visual = await index.search(embedding, filter: filter, limit: 300, minimumScore: 0.05)
                guard !Task.isCancelled else {
                    return
                }
                publish(named + visual, query: trimmed)
            } catch {
                state = .failed(error.localizedDescription)
                publish(named, query: trimmed)
            }
        }
    }

    func clearSearch() {
        searchTask?.cancel()
        needsIndex = false
        publish(nil)
    }

    func revealIndexInFinder() {
        guard let location = indexLocation else {
            return
        }
        if FileManager.default.fileExists(atPath: location.path(percentEncoded: false)) {
            NSWorkspace.shared.activateFileViewerSelecting([location])
            return
        }
        let directory = location.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    private func loadedEncoder() async throws -> CLIPEncoder {
        if let encoder {
            return encoder
        }
        let encoder = try await Task.detached(priority: .userInitiated) { try CLIPEncoder() }.value
        self.encoder = encoder
        return encoder
    }
}
