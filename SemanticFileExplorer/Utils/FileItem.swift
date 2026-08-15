import AppKit
import Foundation
import UniformTypeIdentifiers

struct FileItem: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let isHidden: Bool
    let contentType: UTType?
    let size: Int64
    let modificationDate: Date

    var id: URL { url }
    var isBrowsable: Bool { isDirectory && !isPackage }
    var kind: String {
        if isBrowsable { return "Folder" }
        return contentType?.localizedDescription ?? "Document"
    }
    var icon: NSImage {
        IconCache.icon(for: contentType, isFolder: isBrowsable)
    }
    var formattedSize: String {
        guard size >= 0 else {
            return "--"
        }
        return size.formatted(.byteCount(style: .file))
    }
    var formattedModificationDate: String {
        modificationDate.formatted(date: .abbreviated, time: .shortened)
    }
}

enum IconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for contentType: UTType?, isFolder: Bool) -> NSImage {
        let type = isFolder ? .folder : (contentType ?? .data)
        if let cached = cache[type.identifier] { return cached }
        let icon = NSWorkspace.shared.icon(for: type)
        cache[type.identifier] = icon
        return icon
    }
}

extension FileItem {
    static let resourceKeys: [URLResourceKey] = [
        .nameKey,
        .isDirectoryKey,
        .isPackageKey,
        .isHiddenKey,
        .contentTypeKey,
        .fileSizeKey,
        .contentModificationDateKey,
    ]

    init(url: URL) throws {
        let values = try url.resourceValues(forKeys: Set(Self.resourceKeys))
        let isDirectory = values.isDirectory ?? false
        let isPackage = values.isPackage ?? false
        self.url = url
        self.name = values.name ?? url.lastPathComponent
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isHidden = values.isHidden ?? false
        self.contentType = values.contentType
        self.size = isDirectory ? -1 : Int64(values.fileSize ?? 0)
        self.modificationDate = values.contentModificationDate ?? .distantPast
    }

    static func contents(of directory: URL, includeHidden: Bool) throws -> [FileItem] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: resourceKeys,
            options: includeHidden ? [] : [.skipsHiddenFiles]
        )
        return urls.compactMap { try? FileItem(url: $0) }
    }
}
