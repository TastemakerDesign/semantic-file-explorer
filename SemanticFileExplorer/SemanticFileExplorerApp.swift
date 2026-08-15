import SwiftUI

@main
struct SemanticFileExplorerApp: App {
    @FocusedValue(\.explorerModel) private var model

    init() {
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 200])
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder") { model?.promptForFolder() }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(model == nil)
            }
            CommandGroup(after: .toolbar) {
                Button("Bigger Thumbnails") { model?.resizeThumbnails(by: 30) }
                    .keyboardShortcut("+", modifiers: .command)
                    .disabled(model == nil)
                Button("Smaller Thumbnails") { model?.resizeThumbnails(by: -30) }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(model == nil)
                Divider()
                Button("Refresh") { model?.reload() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model?.currentDirectory == nil)
            }
            CommandMenu("Go") {
                Button("Back") { model?.goBack() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                    .disabled(model?.canGoBack != true)
                Button("Forward") { model?.goForward() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                    .disabled(model?.canGoForward != true)
                Button("Enclosing Folder") { model?.goUp() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(model?.canGoUp != true)
                Button("Open Selection") { model?.openSelection() }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                    .disabled(model?.selection == nil)
            }
            CommandGroup(after: .pasteboard) {
                Button("Find") { model?.requestSearchDialog() }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(model == nil)
                Button("Clear Search") { model?.clearSearch() }
                    .disabled(model?.canClearSearch != true)
            }
        }
    }
}

// Lets the menu bar reach the frontmost window's model.
extension FocusedValues {
    @Entry var explorerModel: ExplorerModel?
}
