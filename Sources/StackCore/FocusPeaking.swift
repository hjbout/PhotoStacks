import CoreGraphics
import Foundation

/// Focus peaking: marks the pixels with sharp detail in red, like a camera does.
///
/// The picture is made grey and lightly blurred (so sensor noise isn't taken for detail), then the Sobel gradient
/// is taken. The ridge of every edge above the threshold is painted, three pixels wide. The threshold follows the
/// picture's size: the same edge spans more pixels in a bigger picture, so its gradient per pixel is weaker.
public enum FocusPeaking {
    /// Size (long side) at which `baseThreshold` applies; the embedded RAW preview.
    public static let referenceSize = 3200.0
    /// Sobel gradient (|gx| + |gy|, max 2040) that counts as in focus at `referenceSize`.
    public static let baseThreshold = 120.0

    /// Factor by which a frame must beat its neighbours in the stack to be marked there; 1 = at least as sharp as both.
    public static let neighbourRatio = 1.0

    /// A transparent picture of the same size as `image` with the sharp areas in opaque red, nil when it can't be made.
    /// `sensitivity` above 1 marks more (lower threshold), below 1 less.
    ///
    /// With `neighbours` (the stack's previous and next frame, same size) only the places where `image` is clearly
    /// sharper than they are get marked, so the marking falls off quickly from one frame to the next and shows where
    /// the focus plane of this frame is. The neighbours' edges are compared within a few pixels, to forgive a small shift.
    public static func overlay(for image: CGImage, neighbours: [CGImage] = [], sensitivity: Double = 1,
                               thickness: Int = 1) -> CGImage? {
        let width = image.width, height = image.height
        // The picture and its neighbours are measured side by side.
        let pictures = [image] + neighbours
        var measured = [[Int32]?](repeating: nil, count: pictures.count)
        measured.withUnsafeMutableBufferPointer { results in
            let output = results
            DispatchQueue.concurrentPerform(iterations: pictures.count) { index in
                output[index] = magnitudes(of: pictures[index], width: width, height: height)
            }
        }
        guard var magnitude = measured[0] else { return nil }
        let longSide = Double(max(width, height))
        let threshold = Int((baseThreshold * referenceSize / longSide / max(sensitivity, 0.1)).rounded())

        if !neighbours.isEmpty {
            var strongest = [Int32](repeating: 0, count: width * height)
            for other in measured.dropFirst().compactMap({ $0 }) {
                for i in 0..<other.count where other[i] > strongest[i] { strongest[i] = other[i] }
            }
            strongest = localMaximum(strongest, width: width, height: height, radius: 2)
            // Not clearly sharper than the neighbours: no marking (zeroed in a copy, so the ridge test below still sees the edge).
            let ratio = Float(neighbourRatio)
            for i in 0..<magnitude.count where Float(magnitude[i]) < ratio * Float(strongest[i]) { magnitude[i] = 0 }
        }

        var thick = [UInt8](repeating: 0, count: width * height)
        let limit = Int32(threshold)
        for y in 2..<(height - 2) {
            let row = y * width
            for x in 2..<(width - 2) {
                let i = row + x, m = magnitude[i]
                guard m > limit else { continue }
                // Compare along the dominant direction of the gradient (across the edge).
                let horizontal = abs(Int(magnitude[i + 1]) - Int(magnitude[i - 1])) >= abs(Int(magnitude[i + width]) - Int(magnitude[i - width]))
                let before = horizontal ? magnitude[i - 1] : magnitude[i - width]
                let after = horizontal ? magnitude[i + 1] : magnitude[i + width]
                if m >= before && m >= after { thick[i] = 1 }
            }
        }

        if thickness > 0 { thick = dilate(thick, width: width, height: height, radius: thickness) }

        // Premultiplied red with a little transparency.
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) where thick[i] != 0 {
            pixels[i * 4] = 235
            pixels[i * 4 + 3] = 235
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// 3×3 average.
    static func boxBlur(_ pixels: UnsafePointer<UInt8>, width: Int, height: Int) -> [UInt8] {
        var horizontal = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                let left = Int(pixels[row + max(x - 1, 0)]), middle = Int(pixels[row + x])
                let right = Int(pixels[row + min(x + 1, width - 1)])
                horizontal[row + x] = UInt8((left + middle + right) / 3)
            }
        }
        var result = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let above = max(y - 1, 0) * width, row = y * width, below = min(y + 1, height - 1) * width
            for x in 0..<width {
                result[row + x] = UInt8((Int(horizontal[above + x]) + Int(horizontal[row + x]) + Int(horizontal[below + x])) / 3)
            }
        }
        return result
    }

    /// Grows every marked pixel to a square of `2 * radius + 1` pixels.
    static func dilate(_ mask: [UInt8], width: Int, height: Int, radius: Int) -> [UInt8] {
        var horizontal = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where mask[row + x] != 0 {
                for dx in max(x - radius, 0)...min(x + radius, width - 1) { horizontal[row + dx] = 1 }
            }
        }
        var result = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where horizontal[row + x] != 0 {
                for dy in max(y - radius, 0)...min(y + radius, height - 1) { result[dy * width + x] = 1 }
            }
        }
        return result
    }

    /// Sobel gradient (|gx| + |gy|) of the blurred grey picture, scaled to `width` × `height` when it has another size.
    static func magnitudes(of image: CGImage, width: Int, height: Int) -> [Int32]? {
        guard width >= 8, height >= 8,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let grey = data.bindMemory(to: UInt8.self, capacity: width * height)
        let blurred = boxBlur(grey, width: width, height: height)
        var magnitude = [Int32](repeating: 0, count: width * height)
        blurred.withUnsafeBufferPointer { p in
            for y in 1..<(height - 1) {
                let row = y * width
                for x in 1..<(width - 1) {
                    let i = row + x
                    let a = Int(p[i - width - 1]), b = Int(p[i - width]), c = Int(p[i - width + 1])
                    let d = Int(p[i - 1]), f = Int(p[i + 1])
                    let g = Int(p[i + width - 1]), h = Int(p[i + width]), k = Int(p[i + width + 1])
                    let gx = (c + 2 * f + k) - (a + 2 * d + g)
                    let gy = (g + 2 * h + k) - (a + 2 * b + c)
                    magnitude[i] = Int32(abs(gx) + abs(gy))
                }
            }
        }
        return magnitude
    }

    /// The largest value within `radius` pixels (a square).
    static func localMaximum(_ values: [Int32], width: Int, height: Int, radius: Int) -> [Int32] {
        var horizontal = values
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                var best = values[row + x]
                for dx in max(x - radius, 0)...min(x + radius, width - 1) where values[row + dx] > best { best = values[row + dx] }
                horizontal[row + x] = best
            }
        }
        var result = horizontal
        for y in 0..<height {
            for x in 0..<width {
                var best = horizontal[y * width + x]
                for dy in max(y - radius, 0)...min(y + radius, height - 1) where horizontal[dy * width + x] > best {
                    best = horizontal[dy * width + x]
                }
                result[y * width + x] = best
            }
        }
        return result
    }
}
