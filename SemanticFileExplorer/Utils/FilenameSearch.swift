import Foundation

nonisolated enum FilenameSearch {
    static func matches(
        for query: String,
        in directory: URL,
        includesSubfolders: Bool,
        limit: Int
    ) -> [URL] {
        guard !query.isEmpty else {
            return []
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        var matched: [URL] = []
        func consider(_ url: URL) {
            guard url.lastPathComponent.localizedCaseInsensitiveContains(query) else {
                return
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isDirectory != true || values?.isPackage == true else {
                return
            }
            matched.append(url)
        }
        if includesSubfolders {
            guard let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                return []
            }
            for case let url as URL in enumerator {
                consider(url)
            }
        } else {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )) ?? []
            for url in contents {
                consider(url)
            }
        }
        let sorted = matched.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        return Array(sorted.prefix(limit))
    }
}
