import AppKit
import SwiftUI

struct FileGridView: View {
    @Bindable var model: ExplorerModel
    @FocusState private var gridFocused: Bool

    private let spacing: CGFloat = 16

    var body: some View {
        GeometryReader { geometry in
            let columnCount = columnCount(for: geometry.size.width)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columnCount),
                        spacing: spacing
                    ) {
                        ForEach(model.items) { item in
                            FileGridCell(
                                item: item,
                                size: model.thumbnailSize,
                                model: model,
                                store: model.thumbnails
                            )
                            .id(item.id)
                        }
                    }
                    .padding(spacing)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .top)
                    .background {
                        Color.clear
                            .contentShape(.rect)
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onEnded { _ in model.clearSelection() }
                            )
                    }
                }
                .onChange(of: model.scrollTarget) { _, target in
                    guard let target else {
                        return
                    }
                    proxy.scrollTo(target)
                }
                .onChange(of: model.scrollResetRequests) { _, _ in
                    guard let first = model.items.first?.id else {
                        return
                    }
                    proxy.scrollTo(first, anchor: .top)
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($gridFocused)
            .onAppear { gridFocused = true }
            .task(id: model.currentDirectory) {
                model.thumbnails.prefetch(Array(model.items.prefix(200)), concurrency: 6)
            }
            .onChange(of: model.currentDirectory) { _, _ in gridFocused = true }
            .onKeyPress(.leftArrow) { move(by: -1) }
            .onKeyPress(.rightArrow) { move(by: 1) }
            .onKeyPress(.upArrow) { move(by: -columnCount) }
            .onKeyPress(.downArrow) { move(by: columnCount) }
            .onKeyPress(.return) { model.openSelection(); return .handled }
        }
        .overlay {
            if let errorMessage = model.errorMessage {
                ContentUnavailableView("Can't Read Folder", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else if model.items.isEmpty {
                ContentUnavailableView("Empty Folder", systemImage: "folder")
            }
        }
    }

    private func columnCount(for width: CGFloat) -> Int {
        let usable = width - spacing * 2
        return max(1, Int(usable / (model.thumbnailSize + spacing)))
    }

    private func move(by delta: Int) -> KeyPress.Result {
        model.moveSelection(by: delta)
        return .handled
    }
}
