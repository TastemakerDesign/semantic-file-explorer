import SwiftUI

struct PathBar: View {
    let model: ExplorerModel

    var body: some View {
        HStack(spacing: 4) {
            if model.search.needsIndex {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                Text("This folder isn't indexed yet.")
                    .lineLimit(1)
                clearButton
            } else if model.isShowingSearchResults {
                Image(systemName: "sparkle.magnifyingglass")
                    .foregroundStyle(.supporting)
                Text("Results for “\(model.search.activeQuery ?? model.searchText)” in \(scopeName)")
                    .lineLimit(1)
                clearButton
            } else {
                breadcrumb
            }
            Spacer()
            if case .indexing(let completed, let total) = model.search.state {
                indexingProgress(completed: completed, total: total)
            }
            Text(statusText)
                .foregroundStyle(.supporting)
        }
        .font(AppFont.detail)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(height: 34)
        .background(.bar)
    }

    private func indexingProgress(completed: Int, total: Int) -> some View {
        HStack(spacing: 6) {
            ProgressView(value: model.search.state.fraction ?? 0)
                .progressViewStyle(.linear)
                .frame(width: 70)
            // Use monospaced font to prevent the text from shifting too much.
            Text(total > 0 ? "\(completed)/\(total)" : "Scanning...")
                .font(AppFont.detail.monospacedDigit())
                .foregroundStyle(.supporting)
            Button {
                model.search.cancelIndexing()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .help("Stop indexing")
        }
        .padding(.trailing, 6)
        .fixedSize()
        .help(total > 0 ? "Indexing \(completed) of \(total)" : "Scanning for images and videos")
    }

    private var clearButton: some View {
        Button("Clear") { model.clearSearch() }
            .buttonStyle(.link)
            .help("Stop showing results and go back to this folder")
    }

    @ViewBuilder
    private var breadcrumb: some View {
        Group {
            ForEach(Array(model.breadcrumb.enumerated()), id: \.element) { index, url in
                if index > 0 {
                    Image(systemName: "chevron.compact.right")
                        .foregroundStyle(.tertiary)
                }
                Button {
                    model.navigate(to: url)
                } label: {
                    Label(url.lastPathComponent, systemImage: "folder")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .foregroundStyle(url == model.currentDirectory ? Color.primary : .supporting)
                .help("Go to \(url.path(percentEncoded: false))")
            }
        }
    }

    private var scopeName: String {
        model.currentDirectory?.lastPathComponent ?? "this folder"
    }

    private var statusText: String {
        let count = model.items.count
        if model.isShowingSearchResults {
            return "\(count) match\(count == 1 ? "" : "es")"
        }
        return "\(count) item\(count == 1 ? "" : "s")"
    }
}
