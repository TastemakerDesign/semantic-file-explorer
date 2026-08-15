import AppKit
import Foundation
import SwiftUI

@Observable
final class ExplorerModel {
    private(set) var root: FolderNode?
    private(set) var currentDirectory: URL?
    private(set) var items: [FileItem] = []
    private(set) var errorMessage: String?
    let search = SearchEngine()
    let thumbnails = ThumbnailStore()
    var thumbnailSize: Double = 160
    private(set) var isShowingSearchResults = false
    private(set) var scores: [URL: Float] = [:]
    private(set) var moments: [URL: [MatchMoment]] = [:]
    var selection: FileItem.ID?
    private(set) var scrollTarget: FileItem.ID?
    private(set) var scrollResetRequests = 0
    private(set) var searchDialogRequests = 0
    var searchScope: SearchScope = .currentFolderAndSubfolders
    var includeFileNames = false
    var searchText = ""
    var canClearSearch: Bool {
        isShowingSearchResults || search.needsIndex || !searchText.isEmpty
    }
    func submitSearch() {
        search.search(
            searchText,
            scope: searchScope,
            directory: currentDirectory,
            includeFileNames: includeFileNames
        )
    }
    func clearSearch() {
        searchText = ""
        search.clearSearch()
        applySearch()
    }
    func applySearchResults() {
        applySearch()
        scrollResetRequests += 1
    }
    var showHiddenFiles = false {
        didSet {
            root?.reloadChildren(includeHidden: showHiddenFiles)
            reload()
        }
    }
    private var allItems: [FileItem] = []
    private var backStack: [URL] = []
    private var forwardStack: [URL] = []
    private var scopedRoot: URL?
    private static let bookmarkKey = "lastOpenedFolderBookmark"
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool {
        guard let currentDirectory else {
            return false
        }
        guard let root else {
            return false
        }
        return currentDirectory != root.url && currentDirectory.isDescendant(of: root.url)
    }
    var breadcrumb: [URL] {
        guard let root else {
            return []
        }
        guard let currentDirectory else {
            return []
        }
        var trail: [URL] = []
        var url = currentDirectory
        while url != root.url, url.isDescendant(of: root.url) {
            trail.insert(url, at: 0)
            url = url.deletingLastPathComponent()
        }
        trail.insert(root.url, at: 0)
        return trail
    }
    func location(of item: FileItem) -> String {
        let folder = item.url.deletingLastPathComponent()
        guard let root, folder.isDescendant(of: root.url) else {
            return folder.lastPathComponent
        }
        let depth = root.url.standardizedFileURL.pathComponents.count
        return folder.standardizedFileURL.pathComponents.dropFirst(depth).joined(separator: "/")
    }
    func restoreLastFolder() {
        guard currentDirectory == nil, let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else {
            return
        }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
            return
        }
        open(url)
        if isStale {
            saveBookmark(for: url)
        }
    }
    func promptForFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a folder to browse."
        panel.directoryURL = currentDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK else {
            return
        }
        guard let url = panel.url else {
            return
        }
        open(url)
    }
    func open(_ url: URL) {
        scopedRoot?.stopAccessingSecurityScopedResource()
        scopedRoot = url.startAccessingSecurityScopedResource() ? url : nil
        root = FolderNode(url: url)
        backStack.removeAll()
        forwardStack.removeAll()
        setCurrentDirectory(url)
        saveBookmark(for: url)
        search.use(root: url)
    }
    func unload() {
        guard root != nil else {
            return
        }
        scopedRoot?.stopAccessingSecurityScopedResource()
        scopedRoot = nil
        root = nil
        currentDirectory = nil
        backStack.removeAll()
        forwardStack.removeAll()
        allItems = []
        errorMessage = nil
        selection = nil
        scrollTarget = nil
        searchText = ""
        search.close()
        thumbnails.clearMemoryCache()
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        applySearch()
    }
    private func saveBookmark(for url: URL) {
        guard let data = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            return
        }
        UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
    }
    func navigate(to url: URL) {
        guard url != currentDirectory else {
            return
        }
        if let currentDirectory {
            backStack.append(currentDirectory)
            forwardStack.removeAll()
        }
        setCurrentDirectory(url)
    }
    func goBack() {
        guard let previous = backStack.popLast() else {
            return
        }
        guard let currentDirectory else {
            return
        }
        forwardStack.append(currentDirectory)
        setCurrentDirectory(previous)
    }
    func goForward() {
        guard let next = forwardStack.popLast() else {
            return
        }
        guard let currentDirectory else {
            return
        }
        backStack.append(currentDirectory)
        setCurrentDirectory(next)
    }
    func goUp() {
        guard canGoUp else {
            return
        }
        guard let currentDirectory else {
            return
        }
        navigate(to: currentDirectory.deletingLastPathComponent())
    }
    func activate(_ item: FileItem) {
        if item.isBrowsable {
            navigate(to: item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }
    func resizeThumbnails(by delta: Double) {
        thumbnailSize = min(max(thumbnailSize + delta, 90), 320)
    }
    func openSelection() {
        guard let item = selectedItem else {
            return
        }
        activate(item)
    }
    var selectedItem: FileItem? {
        guard let selection else {
            return nil
        }
        return items.first { $0.id == selection }
    }
    func select(_ item: FileItem) {
        selection = item.id
    }
    func clearSelection() {
        selection = nil
    }
    func moveSelection(by delta: Int) {
        guard !items.isEmpty else {
            return
        }
        let currentIndex = selection.flatMap { current in items.firstIndex { $0.id == current } }
        let newIndex: Int
        if let currentIndex {
            newIndex = min(max(currentIndex + delta, 0), items.count - 1)
        } else {
            newIndex = delta > 0 ? 0 : items.count - 1
        }
        selection = items[newIndex].id
        scrollTarget = items[newIndex].id
    }
    func requestSearchDialog() {
        searchDialogRequests += 1
    }
    func revealInFinder(_ item: FileItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }
    func reload() {
        guard let currentDirectory else {
            return
        }
        do {
            allItems = try FileItem.contents(of: currentDirectory, includeHidden: showHiddenFiles)
            errorMessage = nil
        } catch {
            allItems = []
            errorMessage = error.localizedDescription
        }
        applySearch()
    }
    private func setCurrentDirectory(_ url: URL) {
        currentDirectory = url
        selection = nil
        scrollTarget = nil
        if canClearSearch {
            searchText = ""
            search.clearSearch()
        }
        reload()
        root?.reveal(url, includeHidden: showHiddenFiles)
    }
    func applySearch() {
        if let hits = search.hits {
            let results = hits.compactMap { hit in try? FileItem(url: hit.url) }
            scores = Dictionary(
                hits.compactMap { hit in hit.score.map { (hit.url, $0) } },
                uniquingKeysWith: { first, _ in first }
            )
            moments = Dictionary(
                hits.compactMap { hit in hit.moments.isEmpty ? nil : (hit.url, hit.moments) },
                uniquingKeysWith: { first, _ in first }
            )
            items = results
            isShowingSearchResults = true
            return
        }
        scores = [:]
        moments = [:]
        isShowingSearchResults = false
        items = listingOrder(allItems)
    }
    private func listingOrder(_ items: [FileItem]) -> [FileItem] {
        let sorted = items.sorted(using: KeyPathComparator(\FileItem.name))
        return sorted.filter(\.isBrowsable) + sorted.filter { !$0.isBrowsable }
    }
}

enum SearchScope: String, CaseIterable, Identifiable {
    case currentFolderAndSubfolders
    case currentFolderOnly
    var id: String { rawValue }
    var label: String {
        switch self {
        case .currentFolderAndSubfolders: "This folder and subfolders"
        case .currentFolderOnly: "This folder only"
        }
    }
    var isRecursive: Bool { self == .currentFolderAndSubfolders }
}
