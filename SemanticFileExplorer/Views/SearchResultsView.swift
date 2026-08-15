import SwiftUI

struct SearchResultsView: View {
    @Bindable var model: ExplorerModel
    @FocusState private var listFocused: Bool

    private static let listPadding: CGFloat = 12

    var body: some View {
        GeometryReader { geometry in
            let rowWidth = max(0, geometry.size.width - Self.listPadding * 2 - SearchResultRow.rowPadding * 2)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.items) { item in
                            SearchResultRow(item: item, model: model, store: model.thumbnails, availableWidth: rowWidth)
                                .id(item.id)
                        }
                    }
                    .padding(Self.listPadding)
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
            .focused($listFocused)
            .onAppear { listFocused = true }
            .onKeyPress(.upArrow) { move(by: -1) }
            .onKeyPress(.downArrow) { move(by: 1) }
            .onKeyPress(.return) { model.openSelection(); return .handled }
        }
        .overlay {
            if model.items.isEmpty {
                ContentUnavailableView(
                    "No Matches",
                    systemImage: "magnifyingglass",
                    description: Text("Nothing in the index looks like \u{201C}\(model.search.activeQuery ?? model.searchText)\u{201D}.")
                )
            }
        }
    }

    private func move(by delta: Int) -> KeyPress.Result {
        model.moveSelection(by: delta)
        return .handled
    }
}
