import AppKit
import SwiftUI

struct SidebarView: View {
    @Bindable var model: ExplorerModel
    @Binding var selection: URL?

    var body: some View {
        VStack(spacing: 0) {
            folderControls
            Divider()
            List(selection: $selection) {
                if let root = model.root {
                    Section {
                        FolderTreeRow(node: root, includeHidden: model.showHiddenFiles)
                    } header: {
                        Text("Location")
                            .font(AppFont.caption)
                            .foregroundStyle(.supporting)
                            .padding(.top, 12)
                            .padding(.bottom, 6)
                    }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if model.root == nil {
                    Text("No folder open")
                        .font(AppFont.detail)
                        .foregroundStyle(.supporting)
                }
            }
        }
        .background {
            SidebarCollapseLock()
        }
        .toolbar(removing: .sidebarToggle)
    }

    private var folderControls: some View {
        VStack(spacing: 8) {
            Button {
                model.promptForFolder()
            } label: {
                SidebarButtonLabel(title: "Choose a Folder", symbol: "folder.badge.plus")
            }
            .help("Choose a folder to browse (⌘O)")
            Button {
                model.reload()
            } label: {
                SidebarButtonLabel(title: "Reload This Folder", symbol: "arrow.clockwise")
            }
            .disabled(model.currentDirectory == nil)
            .help("Reload this folder (⌘R)")
            Button {
                model.unload()
            } label: {
                SidebarButtonLabel(title: "Unload This Folder", symbol: "folder.badge.minus")
            }
            .disabled(model.currentDirectory == nil)
            .help("Close this folder and leave nothing open")
            Toggle(isOn: $model.showHiddenFiles) {
                SidebarButtonLabel(title: "Show Hidden Files", symbol: model.showHiddenFiles ? "eye" : "eye.slash")
            }
            .toggleStyle(.button)
            .help(model.showHiddenFiles ? "Hide hidden files" : "Show hidden files")
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .padding(10)
    }
}

private struct SidebarButtonLabel: View {
    let title: String
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SidebarCollapseLock: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        CollapseLockView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class CollapseLockView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                self?.pinSidebarOpen()
            }
        }

        private func pinSidebarOpen() {
            var view: NSView? = superview
            while let current = view {
                if let splitView = current as? NSSplitView,
                   let controller = splitView.delegate as? NSSplitViewController,
                   let sidebarItem = controller.splitViewItems.first {
                    sidebarItem.canCollapse = false
                    sidebarItem.isCollapsed = false
                    return
                }
                view = current.superview
            }
        }
    }
}

private struct FolderTreeRow: View {
    @Bindable var node: FolderNode
    let includeHidden: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $node.isExpanded) {
            ForEach(node.children) { child in
                FolderTreeRow(node: child, includeHidden: includeHidden)
            }
        } label: {
            Label(node.name, systemImage: "folder")
                .font(AppFont.body)
                .lineLimit(1)
                .tag(node.url)
        }
        .onChange(of: node.isExpanded, initial: true) { _, expanded in
            if expanded { node.loadChildrenIfNeeded(includeHidden: includeHidden) }
        }
    }
}
