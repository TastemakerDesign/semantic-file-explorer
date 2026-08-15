import SwiftUI

struct SearchDialog: View {
    @Bindable var model: ExplorerModel
    let dismiss: () -> Void
    @FocusState private var queryFocused: Bool
    @State private var confirmingDelete = false
    private static let missingFileSample = 100

    private var canSearch: Bool {
        !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Search")
                .font(AppFont.title)
            TextField("Describe what you're looking for", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .focused($queryFocused)
                .onSubmit(run)

            Picker("Look in:", selection: $model.searchScope) {
                ForEach(SearchScope.allCases) { scope in
                    Text(scope.label).tag(scope)
                }
            }
            .pickerStyle(.radioGroup)
            Toggle("Also match file names", isOn: $model.includeFileNames)
                .help("Include files whose name contains the query, listed ahead of the visual matches")
            Divider()
            indexSection
                .font(AppFont.detail)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Search", action: run)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSearch)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.separator)
        }
        .shadow(radius: 24, y: 8)
        .confirmationDialog(
            "Delete the index for \(model.root?.name ?? "this folder")?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Index") { model.search.clearIndex() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Searching by description stops working for this folder until the index is built again. Your files aren't touched.")
        }
        .task {
            queryFocused = true
            try? await Task.sleep(for: .milliseconds(50))
            queryFocused = true
        }
    }

    @ViewBuilder
    private var indexSection: some View {
        switch model.search.state {
        case .indexing(let completed, let total):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(total > 0 ? "Indexing this folder..." : "Scanning for images and videos...")
                    Spacer()
                    Button("Stop") { model.search.cancelIndexing() }
                }
                HStack(spacing: 8) {
                    ProgressView(value: model.search.state.fraction ?? 0)
                        .progressViewStyle(.linear)
                    if total > 0 {
                        Text("\(completed)/\(total)")
                            .font(AppFont.detail.monospacedDigit())
                            .foregroundStyle(.primary)
                    }
                }
            }
        case .ready(let count, let total) where count < total:
            VStack(alignment: .leading, spacing: 8) {
                status(
                    total == 1
                        ? "\(count) of 1 file indexed in \(model.root?.name ?? "this folder"). Searching by description covers the indexed ones."
                        : "\(count) of \(total) files indexed in \(model.root?.name ?? "this folder"). Searching by description covers the indexed ones.",
                    symbol: "exclamationmark.circle",
                    tint: .orange
                ) {
                    Button("Finish Indexing") { model.search.startIndexing() }
                        .help("Embed the files the index is still missing")
                }
                missingFiles
            }
            .task(id: model.search.state) {
                model.search.findUnindexedFiles(limit: Self.missingFileSample)
            }
        case .ready(let count, _):
            status(
                count == 1
                    ? "1 file indexed in \(model.root?.name ?? "this folder")."
                    : "\(count) files indexed in \(model.root?.name ?? "this folder").",
                symbol: "checkmark.circle",
                tint: .green
            ) {
                Button("Re-index") { model.search.startIndexing() }
                    .help("Embed anything new or changed since the last build")
            }
        case .notIndexed:
            status(
                "This folder isn't indexed yet.",
                symbol: "exclamationmark.circle",
                tint: .orange
            ) {
                Button("Build Index") { model.search.startIndexing() }
                    .disabled(model.currentDirectory == nil)
                    .help("Index every image and video in this folder and its subfolders")
            }
        case .failed(let message):
            status(
                "Indexing failed: \(message)",
                symbol: "exclamationmark.triangle",
                tint: .red
            ) {
                Button("Try Again") { model.search.startIndexing() }
            }
        }
    }

    @ViewBuilder
    private var missingFiles: some View {
        if let missing = model.search.unindexedFiles, !missing.paths.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Not indexed:")
                    .fontWeight(.semibold)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(missing.paths, id: \.self) { path in
                            Text(path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 110)
                if missing.remainder > 0 {
                    Text(missing.remainder == 1
                        ? "...and 1 more file"
                        : "...and \(missing.remainder) more files")
                        .fontWeight(.semibold)
                }
            }
            .font(AppFont.caption)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func status<Action: View>(
        _ message: LocalizedStringKey,
        symbol: String,
        tint: Color,
        @ViewBuilder action: () -> Action
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            action()
            moreMenu
        }
    }

    private var moreMenu: some View {
        Menu {
            if case .ready = model.search.state {
                Button("Delete Index") { confirmingDelete = true }
            }
            Button("Show Index Location in Finder") { model.search.revealIndexInFinder() }
                .disabled(model.search.indexLocation == nil)
        } label: {
            Label("Index Options", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More index options")
    }

    private func run() {
        guard canSearch else {
            return
        }
        model.submitSearch()
        dismiss()
    }
}
