// Renders Support/AppIcon.icns. Run once: swift Support/make_icon.swift
import AppKit

func render(size: CGFloat) -> Data {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        let inset = rect.insetBy(dx: size * 0.09, dy: size * 0.09)
        let background = NSBezierPath(roundedRect: inset, xRadius: size * 0.2, yRadius: size * 0.2)
        NSGradient(colors: [NSColor(red: 0.16, green: 0.38, blue: 0.78, alpha: 1),
                            NSColor(red: 0.09, green: 0.16, blue: 0.40, alpha: 1)])!
            .draw(in: background, angle: -90)
        let config = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .medium)
            .applying(.init(paletteColors: [.white]))
        if let symbol = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            let s = symbol.size
            symbol.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
        }
        return true
    }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(size: CGFloat(base)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(size: CGFloat(base * 2)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Support/AppIcon.icns"]
try! task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Support/AppIcon.icns written" : "iconutil failed")
