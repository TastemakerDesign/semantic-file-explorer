import AppKit
import SwiftUI

struct ThumbnailCacheButton: View {
    let model: ExplorerModel
    @State private var anchor = MenuAnchor()

    var body: some View {
        Button {
            anchor.present(menu: cacheMenu())
        } label: {
            HStack(spacing: 4) {
                Label("Thumbnails", systemImage: "photo.stack")
                Image(systemName: "chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(.supporting)
            }
        }
        .labelStyle(.titleAndIcon)
        .background {
            MenuAnchorView(anchor: anchor)
        }
        .help("Where rendered image and video thumbnails are cached on disk")
    }

    private func cacheMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(MenuActionItem(title: "Show Thumbnail Cache in Finder") {
            ThumbnailStore.revealCacheInFinder()
        })
        menu.addItem(.separator())
        menu.addItem(MenuActionItem(title: "Clear Thumbnail Cache") {
            model.thumbnails.clearAllCaches()
        })
        return menu
    }
}

private final class MenuAnchor {
    weak var view: NSView?

    func present(menu: NSMenu) {
        guard let view else { return }
        let below = view.isFlipped ? view.bounds.maxY + 4 : view.bounds.minY - 4
        menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.minX, y: below), in: view)
    }
}

private struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}

private final class MenuActionItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func fire() {
        handler()
    }
}
