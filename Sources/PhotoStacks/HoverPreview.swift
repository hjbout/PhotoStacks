import AppKit
import SwiftUI

/// Floating, click-through window with one or two larger pictures, shown to the right of the thumbnail under the pointer.
@MainActor
final class HoverPreviewPanel {
    static let shared = HoverPreviewPanel()

    private static let maxHeight: CGFloat = 540
    private static let maxWidth: CGFloat = 720
    private static let gap: CGFloat = 12
    private static let spacing: CGFloat = 6
    private let panel: NSPanel
    private let container = NSView()
    private var imageViews: [NSImageView] = []

    private init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true  // never steals the hover from the table
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        container.wantsLayer = true
        panel.contentView = container
    }

    private func makeImageView(label: String?) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleAxesIndependently
        view.wantsLayer = true
        view.layer?.cornerRadius = 6
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = 0.5
        view.layer?.borderColor = NSColor.separatorColor.cgColor
        if let label {
            let text = NSTextField(labelWithString: label)
            text.font = .systemFont(ofSize: 11, weight: .semibold)
            text.textColor = .white
            text.wantsLayer = true
            text.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
            text.layer?.cornerRadius = 4
            text.sizeToFit()
            text.setFrameOrigin(NSPoint(x: 6, y: 6))
            view.addSubview(text)
        }
        return view
    }

    /// Shows `images` side by side to the right of `anchor` (a rect in screen coordinates), vertically centred on
    /// it and kept inside the screen. It never covers the anchor. `labels` are drawn in the corner of each picture.
    func show(_ images: [NSImage], labels: [String], besides anchor: NSRect) {
        guard !images.isEmpty else { return }
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1600, height: 1000)
        let count = CGFloat(images.count)
        let totalSpacing = Self.spacing * (count - 1)
        let availableWidth = max(visible.maxX - anchor.maxX - Self.gap * 2, 120)
        let limitWidth = min(Self.maxWidth * count, availableWidth) - totalSpacing
        let limitHeight = min(Self.maxHeight, visible.height - 16)
        let aspects = images.map { $0.size.width > 0 && $0.size.height > 0 ? $0.size.width / $0.size.height : 4.0 / 3 }
        // One common height: as tall as the limits allow when the pictures stand side by side.
        let height = min(limitHeight, limitWidth / aspects.reduce(0, +)).rounded()
        let widths = aspects.map { ($0 * height).rounded() }
        let size = NSSize(width: widths.reduce(0, +) + totalSpacing, height: height)

        imageViews.forEach { $0.removeFromSuperview() }
        imageViews = images.enumerated().map { index, image in
            let view = makeImageView(label: index < labels.count ? labels[index] : nil)
            view.image = image
            return view
        }
        var x: CGFloat = 0
        for (view, width) in zip(imageViews, widths) {
            view.frame = NSRect(x: x, y: 0, width: width, height: height)
            container.addSubview(view)
            x += width + Self.spacing
        }

        var origin = NSPoint(x: anchor.maxX + Self.gap, y: anchor.midY - size.height / 2)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    /// Screen rect of the thumbnail under the pointer; set by the hover tracker.
    var anchor = NSRect.zero
    private var pending: Task<Void, Never>?

    /// Loads the pictures after `delay` (so moving across the table doesn't flash windows) and shows them.
    func schedule(delay: Duration = .milliseconds(250), labels: [String] = [],
                  images: @escaping () async -> [NSImage]) {
        pending?.cancel()
        let anchor = self.anchor
        pending = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let pictures = await images()
            guard !Task.isCancelled, !pictures.isEmpty else { return }
            show(pictures, labels: labels, besides: anchor)
        }
    }

    func hide() {
        pending?.cancel()
        panel.orderOut(nil)
        imageViews.forEach { $0.removeFromSuperview() }
        imageViews = []
    }
}

/// Reports the pointer entering and leaving its area, with the area's frame in screen coordinates.
struct HoverTracker: NSViewRepresentable {
    let onEnter: (NSRect) -> Void
    let onExit: () -> Void
    /// Called while the pointer is inside whenever Shift is pressed or released.
    var onShiftChange: ((Bool) -> Void)?

    func makeNSView(context: Context) -> TrackerView {
        let view = TrackerView()
        view.onEnter = onEnter
        view.onExit = onExit
        view.onShiftChange = onShiftChange
        return view
    }

    func updateNSView(_ view: TrackerView, context: Context) {
        view.onEnter = onEnter
        view.onExit = onExit
        view.onShiftChange = onShiftChange
    }

    final class TrackerView: NSView {
        var onEnter: ((NSRect) -> Void)?
        var onExit: (() -> Void)?
        var onShiftChange: ((Bool) -> Void)?
        private var monitor: Any?
        private var shiftDown = false
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
            shiftDown = NSEvent.modifierFlags.contains(.shift)
            monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                guard let self else { return event }
                let shift = event.modifierFlags.contains(.shift)
                if shift != self.shiftDown {
                    self.shiftDown = shift
                    self.onShiftChange?(shift)
                }
                return event
            }
            onEnter?(window.convertToScreen(convert(bounds, to: nil)))
        }

        override func mouseExited(with event: NSEvent) { leave() }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { leave() }
        }

        private func leave() {
            guard inside else { return }
            inside = false
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            onExit?()
        }
    }
}
