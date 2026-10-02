import AppKit
import SwiftUI

/// A zoom request from the buttons or keyboard; `id` changes with every request.
struct ZoomCommand: Equatable {
    enum Kind { case fit, actual, toggle, zoomIn, zoomOut }
    var id = 0
    var kind: Kind = .fit
}

/// Image in an AppKit scroll view, so the trackpad works natively: pinch with two fingers to zoom (up to
/// 800%, around the fingers), two-finger scroll to pan, click to switch between fit and 100%.
///
/// The document is sized for `pixelSize` (the full RAW) at one image pixel per screen pixel, so magnification 1
/// means 100%. The shown image (embedded preview, later the full RAW) is scaled into that frame, which keeps
/// zoom and position unchanged when the sharper image arrives or when stepping to the next photo.
struct ZoomableImageView: NSViewRepresentable {
    let image: NSImage?
    let pixelSize: CGSize
    let command: ZoomCommand
    /// Magnification (1 = 100%) and whether the image is fitted to the view.
    let onZoomChange: (Double, Bool) -> Void

    func makeNSView(context: Context) -> ZoomScrollView {
        ZoomScrollView()
    }

    func updateNSView(_ view: ZoomScrollView, context: Context) {
        view.onZoomChange = onZoomChange
        view.show(image, pixelSize: pixelSize)
        view.apply(command)
    }
}

final class ZoomScrollView: NSScrollView {
    static let maximumZoom: CGFloat = 8

    var onZoomChange: ((Double, Bool) -> Void)?
    private let imageView = NSImageView()
    private var isFit = true
    private var lastCommandID = 0

    init() {
        super.init(frame: .zero)
        contentView = CenteringClipView()
        drawsBackground = true
        backgroundColor = .black
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        allowsMagnification = true
        maxMagnification = Self.maximumZoom
        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageFrameStyle = .none
        documentView = imageView
        imageView.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked(_:))))
        NotificationCenter.default.addObserver(self, selector: #selector(magnificationEnded),
                                               name: NSScrollView.didEndLiveMagnifyNotification, object: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Shows a new image. Same size as before (next photo of the stack, or the full RAW replacing the
    /// preview): zoom and position stay. Otherwise the image is fitted.
    func show(_ image: NSImage?, pixelSize: CGSize) {
        // While the next photo loads (nil) the previous one stays, so stepping through a stack doesn't flash.
        if let image, imageView.image !== image { imageView.image = image }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let size = NSSize(width: pixelSize.width / scale, height: pixelSize.height / scale)
        guard size.width > 0, size.height > 0, imageView.frame.size != size else { return }
        imageView.frame = NSRect(origin: .zero, size: size)
        isFit = true
        needsLayout = true
    }

    func apply(_ command: ZoomCommand) {
        guard command.id != lastCommandID else { return }
        lastCommandID = command.id
        switch command.kind {
        case .fit: fit()
        case .actual: zoom(to: 1, around: nil)
        case .toggle: isFit ? zoom(to: 1, around: nil) : fit()
        case .zoomIn: zoom(to: magnification * 1.5, around: nil)
        case .zoomOut: zoom(to: magnification / 1.5, around: nil)
        }
    }

    private var fitMagnification: CGFloat {
        let document = imageView.frame.size
        guard document.width > 0, document.height > 0, bounds.width > 0, bounds.height > 0 else { return 1 }
        return min(bounds.width / document.width, bounds.height / document.height)
    }

    private func fit() {
        isFit = true
        minMagnification = min(fitMagnification, 1)
        magnification = fitMagnification
        report()
    }

    /// Zooms to `value` around a point in the image (default: the middle of what is visible now).
    private func zoom(to value: CGFloat, around point: NSPoint?) {
        let clamped = min(max(value, minMagnification), maxMagnification)
        let visible = contentView.documentVisibleRect
        let center = point ?? NSPoint(x: visible.midX, y: visible.midY)
        isFit = abs(clamped - fitMagnification) < 0.001
        setMagnification(clamped, centeredAt: center)
        report()
    }

    override func layout() {
        super.layout()
        minMagnification = min(fitMagnification, 1)
        // Keep the image fitted while the window is resized.
        if isFit, abs(magnification - fitMagnification) > 0.0001 {
            magnification = fitMagnification
            report()
        }
    }

    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        isFit = false
        report()
    }

    override func smartMagnify(with event: NSEvent) {
        // Two-finger double tap: like a click.
        let point = imageView.convert(event.locationInWindow, from: nil)
        isFit ? zoom(to: 1, around: point) : fit()
    }

    @objc private func magnificationEnded() {
        isFit = abs(magnification - fitMagnification) < 0.01
        report()
    }

    @objc private func clicked(_ recognizer: NSClickGestureRecognizer) {
        isFit ? zoom(to: 1, around: recognizer.location(in: imageView)) : fit()
    }

    private func report() {
        let value = Double(magnification), fitted = isFit
        // Not during a SwiftUI update.
        DispatchQueue.main.async { [weak self] in self?.onZoomChange?(value, fitted) }
    }
}

/// Keeps an image smaller than the view centred instead of in the bottom left corner.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView?.frame else { return rect }
        if rect.width > document.width { rect.origin.x = (document.width - rect.width) / 2 }
        if rect.height > document.height { rect.origin.y = (document.height - rect.height) / 2 }
        return rect
    }
}
