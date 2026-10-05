import AppKit
import SwiftUI

/// Floating, click-through window with a larger picture, shown to the right of the thumbnail under the pointer.
@MainActor
final class HoverPreviewPanel {
    static let shared = HoverPreviewPanel()

    private static let maxSize = NSSize(width: 720, height: 540)
    private static let gap: CGFloat = 12
    private let panel: NSPanel
    private let imageView = NSImageView()

    private init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true  // never steals the hover from the table
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        imageView.imageScaling = .scaleAxesIndependently
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true
        imageView.layer?.borderWidth = 0.5
        imageView.layer?.borderColor = NSColor.separatorColor.cgColor
        panel.contentView = imageView
    }

    /// Shows `image` to the right of `anchor` (a rect in screen coordinates), vertically centred on it and
    /// kept inside the screen. It never covers the anchor.
    func show(_ image: NSImage, besides anchor: NSRect) {
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1600, height: 1000)
        let available = NSSize(width: max(visible.maxX - anchor.maxX - Self.gap * 2, 120), height: visible.height - 16)
        let limit = NSSize(width: min(Self.maxSize.width, available.width), height: min(Self.maxSize.height, available.height))
        let aspect = image.size.width > 0 && image.size.height > 0 ? image.size.width / image.size.height : 4.0 / 3
        var size = NSSize(width: limit.width, height: limit.width / aspect)
        if size.height > limit.height { size = NSSize(width: limit.height * aspect, height: limit.height) }
        size = NSSize(width: size.width.rounded(), height: size.height.rounded())

        var origin = NSPoint(x: anchor.maxX + Self.gap, y: anchor.midY - size.height / 2)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        imageView.image = image
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    private var pending: Task<Void, Never>?

    /// Loads the picture after a short delay (so moving across the table doesn't flash windows) and shows it.
    func schedule(besides anchor: NSRect, image: @escaping () async -> NSImage?) {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let picture = await image(), !Task.isCancelled else { return }
            show(picture, besides: anchor)
        }
    }

    func hide() {
        pending?.cancel()
        panel.orderOut(nil)
        imageView.image = nil
    }
}

/// Reports the pointer entering and leaving its area, with the area's frame in screen coordinates.
struct HoverTracker: NSViewRepresentable {
    let onEnter: (NSRect) -> Void
    let onExit: () -> Void

    func makeNSView(context: Context) -> TrackerView {
        let view = TrackerView()
        view.onEnter = onEnter
        view.onExit = onExit
        return view
    }

    func updateNSView(_ view: TrackerView, context: Context) {
        view.onEnter = onEnter
        view.onExit = onExit
    }

    final class TrackerView: NSView {
        var onEnter: ((NSRect) -> Void)?
        var onExit: (() -> Void)?
        private var area: NSTrackingArea?
        private var inside = false

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            self.area = area
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }  // clicks go to the thumbnail below

        override func mouseEntered(with event: NSEvent) {
            guard let window else { return }
            inside = true
            onEnter?(window.convertToScreen(convert(bounds, to: nil)))
        }

        override func mouseExited(with event: NSEvent) { leave() }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { leave() }
        }

        private func leave() {
            guard inside else { return }
            inside = false
            onExit?()
        }
    }
}
