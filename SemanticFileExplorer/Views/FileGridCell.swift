import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FileGridCell: View {
    let item: FileItem
    let size: Double
    let model: ExplorerModel
    let store: ThumbnailStore

    @State private var thumbnail: NSImage?

    init(item: FileItem, size: Double, model: ExplorerModel, store: ThumbnailStore) {
        self.item = item
        self.size = size
        self.model = model
        self.store = store
        _thumbnail = State(initialValue: store.cachedThumbnail(for: item, at: nil))
    }

    private var isSelected: Bool {
        model.selection == item.id
    }

    private var isVideo: Bool {
        item.contentType?.conforms(to: .movie) ?? false
    }

    private var side: CGFloat { size.rounded() }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Rectangle()
                    .fill(.quaternary)
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(nsImage: item.icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: side * 0.5, height: side * 0.5)
                        .opacity(0.7)
                }
                if isVideo {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: side * 0.22))
                        .foregroundStyle(.white, .black.opacity(0.45))
                        .shadow(radius: 2)
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(item.name)
                .font(AppFont.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isSelected ? Color.accentColor : .clear)
                }
                .foregroundStyle(isSelected ? .white : .primary)
        }
        .padding(6)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : .clear)
        }
        .contentShape(.rect)
        .frame(width: side, height: side + 58, alignment: .top)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onEnded { _ in handleClick() }
        )
        .contextMenu {
            Button("Open") { open() }
            Button("Show in Finder") { model.revealInFinder(item) }
        }
        .help(tooltip)
        .task(id: item) {
            if let cached = store.cachedThumbnail(for: item, at: nil) {
                thumbnail = cached
            } else {
                thumbnail = await store.thumbnail(for: item, at: nil)
            }
        }
    }

    private func handleClick() {
        if let event = NSApp.currentEvent, event.clickCount >= 2 {
            model.activate(item)
        } else {
            model.select(item)
        }
    }

    private func open() {
        model.select(item)
        model.openSelection()
    }

    private var tooltip: String {
        var lines = [item.name, item.kind]
        if item.size >= 0 { lines.append(item.formattedSize) }
        lines.append("Modified \(item.formattedModificationDate)")
        return lines.joined(separator: "\n")
    }
}
