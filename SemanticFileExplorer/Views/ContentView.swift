import AppKit
import SwiftUI

struct ContentView: View {
    @State private var model = ExplorerModel()
    @State private var sidebarSelection: URL?
    @State private var showingSearch = false

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            SidebarView(model: model, selection: $sidebarSelection)
                .navigationSplitViewColumnWidth(min: 180, ideal: 240)
        } detail: {
            Group {
                if model.currentDirectory == nil {
                    WelcomeView { model.promptForFolder() }
                } else {
                    VStack(spacing: 0) {
                        if model.isShowingSearchResults {
                            SearchResultsView(model: model)
                        } else {
                            FileGridView(model: model)
                        }
                        Divider()
                        PathBar(model: model)
                    }
                }
            }
            .navigationTitle(model.currentDirectory?.lastPathComponent ?? "Semantic File Explorer")
            .toolbar { toolbarContent }
        }
        .font(AppFont.body)
        .overlay {
            if showingSearch {
                searchOverlay
            }
        }
        .onChange(of: sidebarSelection) { _, newValue in
            if let newValue { model.navigate(to: newValue) }
        }
        .onChange(of: model.currentDirectory) { _, newValue in
            sidebarSelection = newValue
        }
        .onChange(of: model.search.generation) { _, _ in
            model.applySearchResults()
        }
        .onChange(of: model.searchDialogRequests) { _, _ in
            presentSearch()
        }
        .focusedSceneValue(\.explorerModel, model)
        .task {
            model.restoreLastFolder()
        }
    }

    private var searchOverlay: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.2))
                .ignoresSafeArea()
                .contentShape(.rect)
                .onTapGesture { showingSearch = false }
            SearchDialog(model: model) { showingSearch = false }
        }
        .transaction { $0.animation = nil }
        .onExitCommand { showingSearch = false }
    }

    private func presentSearch() {
        showingSearch = true
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                model.goBack()
            } label: {
                Label("Back", systemImage: "chevron.backward")
            }
            .disabled(!model.canGoBack)
            .help("Back (⌘←)")
            Button {
                model.goForward()
            } label: {
                Label("Forward", systemImage: "chevron.forward")
            }
            .disabled(!model.canGoForward)
            .help("Forward (⌘→)")
            Button {
                model.goUp()
            } label: {
                Label("Enclosing Folder", systemImage: "chevron.up")
            }
            .disabled(!model.canGoUp)
            .help("Enclosing folder (⌘↑)")
        }
        ToolbarItem {
            HStack(spacing: 6) {
                Button {
                    presentSearch()
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .labelStyle(.titleAndIcon)
                .disabled(model.currentDirectory == nil)
                .help("Search this folder by description (⌘F)")
                if model.canClearSearch {
                    Button {
                        model.clearSearch()
                    } label: {
                        Label("Clear", systemImage: "xmark.circle")
                    }
                    .labelStyle(.titleAndIcon)
                    .help("Clear the search and go back to this folder")
                }
                ThumbnailCacheButton(model: model)
            }
            .buttonStyle(.glass)
        }
        .sharedBackgroundVisibility(.hidden)
    }
}

struct WelcomeView: View {
    var openFolder: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label {
                Text("No Folder Open")
            } icon: {
                Image(systemName: "folder")
                    .foregroundStyle(.primary)
            }
        } description: {
            Text("Choose a folder on your Mac to browse its contents.")
        } actions: {
            Button("Open Folder", action: openFolder)
                .buttonStyle(.borderedProminent)
                .help("Choose a folder to browse (⌘O)")
        }
    }
}
