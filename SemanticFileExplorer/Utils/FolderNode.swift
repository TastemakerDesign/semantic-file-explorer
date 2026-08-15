import Foundation

@Observable
final class FolderNode: Identifiable {
    let url: URL
    let name: String

    var isExpanded = false
    private(set) var children: [FolderNode] = []
    private var hasLoaded = false

    var id: URL { url }

    init(url: URL, name: String? = nil) {
        self.url = url
        self.name = name ?? (try? url.resourceValues(forKeys: [.nameKey]).name) ?? url.lastPathComponent
    }

    func loadChildrenIfNeeded(includeHidden: Bool) {
        guard !hasLoaded else {
            return
        }
        reloadChildren(includeHidden: includeHidden)
    }

    func reloadChildren(includeHidden: Bool) {
        let folders = (try? FileItem.contents(of: url, includeHidden: includeHidden)) ?? []
        children = folders
            .filter(\.isBrowsable)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { FolderNode(url: $0.url, name: $0.name) }
        hasLoaded = true
    }

    func reveal(_ target: URL, includeHidden: Bool) {
        guard target != url, target.isDescendant(of: url) else {
            return
        }
        loadChildrenIfNeeded(includeHidden: includeHidden)
        isExpanded = true
        for child in children where target == child.url || target.isDescendant(of: child.url) {
            child.reveal(target, includeHidden: includeHidden)
        }
    }
}

extension URL {
    nonisolated func isDescendant(of ancestor: URL) -> Bool {
        let ancestorComponents = ancestor.standardizedFileURL.pathComponents
        let components = standardizedFileURL.pathComponents
        guard components.count > ancestorComponents.count else {
            return false
        }
        return Array(components.prefix(ancestorComponents.count)) == ancestorComponents
    }
}
