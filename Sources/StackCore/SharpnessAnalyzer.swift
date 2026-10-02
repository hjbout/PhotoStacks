import CoreGraphics
import Foundation
import ImageIO

/// Finds stack frames on which nothing is in focus (e.g. the bracketing went past the subject).
/// Only reads the originals.
///
/// Per photo, the camera's embedded JPEG preview (scaled to 1200 px, grey) is filtered with a Laplacian and the
/// variance of that is computed per tile of a 24×18 grid. Each frame's noise floor (its median tile) is
/// subtracted. Within a stack every tile is then compared with the sharpest frame for that same tile, like a
/// stacking program does. A frame is unsharp when it doesn't reach `unsharpRatio` of the best frame in any tile
/// that has real detail in at least one frame. Comparing per tile keeps low-contrast subjects (dark rock, a small
/// bud on a smooth background) from being marked; subtracting the noise floor keeps weak tiles from making a
/// blurry frame look half sharp.
public enum SharpnessAnalyzer {
    public static let analysisSize = 1200
    public static let gridColumns = 24
    public static let gridRows = 18

    /// Tiles whose best frame stays below this (after noise subtraction) have no real detail (smooth background,
    /// bokeh) and are ignored.
    public static let detailThreshold = 150.0
    /// A frame is unsharp when it reaches less than this fraction of the best frame in every detail tile.
    public static let unsharpRatio = 0.25

    /// Laplacian variance per tile (row by row), nil when the image can't be read.
    public static func tileSharpness(of url: URL) -> [Double]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: analysisSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return tileSharpness(of: image)
    }

    public static func tileSharpness(of image: CGImage) -> [Double]? {
        let scale = min(1, Double(analysisSize) / Double(max(image.width, image.height)))
        let width = Int((Double(image.width) * scale).rounded())
        let height = Int((Double(image.height) * scale).rounded())
        guard width >= gridColumns + 2, height >= gridRows + 2,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height)

        // Laplacian on the interior pixels, accumulated per tile.
        let innerWidth = width - 2, innerHeight = height - 2
        let tileColumn = (0..<innerWidth).map { min($0 * gridColumns / innerWidth, gridColumns - 1) }
        var sum = [Int](repeating: 0, count: gridColumns * gridRows)
        var sumOfSquares = sum
        var count = sum
        for y in 1...innerHeight {
            let tileRowStart = min((y - 1) * gridRows / innerHeight, gridRows - 1) * gridColumns
            let row = y * width
            for x in 1...innerWidth {
                let index = row + x
                let laplacian = Int(pixels[index - width]) + Int(pixels[index + width])
                    + Int(pixels[index - 1]) + Int(pixels[index + 1]) - 4 * Int(pixels[index])
                let tile = tileRowStart + tileColumn[x - 1]
                sum[tile] += laplacian
                sumOfSquares[tile] += laplacian * laplacian
                count[tile] += 1
            }
        }
        return (0..<sum.count).map { tile in
            let n = Double(count[tile])
            let mean = Double(sum[tile]) / n
            return Double(sumOfSquares[tile]) / n - mean * mean
        }
    }

    /// Tile sharpness of the given photos (keyed by file name), measured in parallel.
    /// Photos that can't be read are left out.
    public static func measure(_ photos: [PhotoInfo], in folder: URL,
                               isCancelled: @escaping @Sendable () -> Bool = { false },
                               progress: @escaping @Sendable (Int) -> Void = { _ in }) -> [String: [Double]] {
        let lock = NSLock()
        var result: [String: [Double]] = [:]
        var done = 0
        DispatchQueue.concurrentPerform(iterations: photos.count) { index in
            guard !isCancelled() else { return }
            let photo = photos[index]
            let tiles = tileSharpness(of: folder.appendingPathComponent(photo.fileName))
            lock.lock()
            if let tiles { result[photo.fileName] = tiles }
            done += 1
            let completed = done
            lock.unlock()
            progress(completed)
        }
        return result
    }

    /// Per frame of one stack: the highest fraction of the best frame it reaches in any detail tile
    /// (1 = sharpest frame somewhere, 0 = no detail tiles at all).
    public static func ratios(tiles: [String: [Double]]) -> [String: Double] {
        guard let tileCount = tiles.values.first?.count, tiles.values.allSatisfy({ $0.count == tileCount }) else {
            return [:]
        }
        let signal = tiles.mapValues { frame -> [Double] in
            let noise = frame.sorted()[frame.count / 2]
            return frame.map { max($0 - noise, 0) }
        }
        let best = (0..<tileCount).map { tile in signal.values.map { $0[tile] }.max() ?? 0 }
        let detailTiles = best.indices.filter { best[$0] >= detailThreshold }
        return signal.mapValues { frame in
            detailTiles.map { frame[$0] / best[$0] }.max() ?? 0
        }
    }

    /// File names of the frames of one stack on which nothing is sharp.
    public static func unsharp(tiles: [String: [Double]]) -> Set<String> {
        Set(ratios(tiles: tiles).filter { $0.value < unsharpRatio }.keys)
    }

    /// The frames of `stack` on which nothing is sharp, given the measurements of (at least) its photos.
    public static func unsharpPhotos(in stack: FocusStack, tiles: [String: [Double]]) -> [PhotoInfo] {
        let names = unsharp(tiles: stackTiles(stack, tiles))
        return stack.photos.filter { names.contains($0.fileName) }
    }

    /// The measurements of just the photos of `stack`.
    public static func stackTiles(_ stack: FocusStack, _ tiles: [String: [Double]]) -> [String: [Double]] {
        Dictionary(uniqueKeysWithValues: stack.photos.compactMap { photo in
            tiles[photo.fileName].map { (photo.fileName, $0) }
        })
    }
}
