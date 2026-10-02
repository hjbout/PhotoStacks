import AppKit
import SwiftUI

/// A small handle that drags several files at once (SwiftUI rows can only drag a single item, and
/// Helicon Focus accepts dropped image files but not a dropped folder). Only offers "copy", so a drop
/// in Finder can never move the originals.
struct FileDragHandle: NSViewRepresentable {
    let urls: () -> [URL]

    func makeNSView(context: Context) -> DragHandleView {
        let view = DragHandleView()
        view.urls = urls
        return view
    }

    func updateNSView(_ view: DragHandleView, context: Context) {
        view.urls = urls
    }
}

final class DragHandleView: NSView, NSDraggingSource {
    var urls: () -> [URL] = { [] }
    private var isDragging = false
    private let symbol = NSImage(systemSymbolName: "photo.stack", accessibilityDescription: "Sleep foto's")

    override var intrinsicContentSize: NSSize { NSSize(width: 18, height: 16) }

    override func draw(_ dirtyRect: NSRect) {
        guard let symbol else { return }
        let configured = symbol.withSymbolConfiguration(.init(paletteColors: [.secondaryLabelColor])) ?? symbol
        let size = configured.size
        configured.draw(in: NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                                   width: size.width, height: size.height))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isDragging else { return }
        let files = urls()
        guard !files.isEmpty else { return }
        isDragging = true
        let image = NSWorkspace.shared.icon(for: .image)
        let items = files.enumerated().map { index, url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let offset = CGFloat(min(index, 4)) * 3
            item.setDraggingFrame(NSRect(x: offset, y: -offset, width: 32, height: 32), contents: image)
            return item
        }
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.draggingFormation = .pile
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}
