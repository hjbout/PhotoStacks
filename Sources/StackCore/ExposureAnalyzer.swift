import Foundation

/// Where and how the sensor data of an .ORF is stored (from its metadata).
public struct RawLayout: Sendable, Equatable {
    public let offset: Int
    public let byteCount: Int
    public let width: Int
    public let height: Int
    /// Black level per position in the 2×2 colour filter pattern (row by row).
    public let black: [Int]
    /// Highest value the sensor can deliver (2^ValidBits − 1).
    public let white: Int
    /// The image area; the rest of the sensor data is masked border.
    public let cropLeft: Int
    public let cropTop: Int
    public let cropWidth: Int
    public let cropHeight: Int
    /// log2(time × ISO / aperture²) of the shot: one higher is one stop more light.
    public let exposure: Double?

    public init(offset: Int, byteCount: Int, width: Int, height: Int, black: [Int], white: Int,
                cropLeft: Int, cropTop: Int, cropWidth: Int, cropHeight: Int, exposure: Double?) {
        self.offset = offset
        self.byteCount = byteCount
        self.width = width
        self.height = height
        self.black = black
        self.white = white
        self.cropLeft = cropLeft
        self.cropTop = cropTop
        self.cropWidth = cropWidth
        self.cropHeight = cropHeight
        self.exposure = exposure
    }
}

/// How much of a photo is clipped, measured on the sensor data like FastRawViewer does.
public struct ExposureStats: Sendable, Equatable {
    /// Fraction of the sensor pixels at the sensor's maximum.
    public let over: Double
    /// Fraction of the sensor pixels more than `ExposureAnalyzer.underexposureStops` below the maximum.
    public let under: Double
    /// log2(time × ISO / aperture²) of the shot, see `ExposureAnalyzer.relativeEV`.
    public let exposure: Double?
    /// Fraction of the sensor pixels per stop below the sensor's maximum (index 0: the brightest stop, the last
    /// index also holds everything darker). Empty when not measured.
    public let stopHistogram: [Double]

    public init(over: Double, under: Double, exposure: Double?, stopHistogram: [Double] = []) {
        self.over = over
        self.under = under
        self.exposure = exposure
        self.stopHistogram = stopHistogram
    }
}

/// Measures over- and underexposure of RAW files on their sensor values (not on a rendered image, which hides
/// clipping behind tone curves and highlight recovery). Reads the Olympus lossless compressed data of OM System and
/// Olympus .ORF files (a port of dcraw's `olympus_load_raw`) or plain 16-bit data. Only reads the originals.
public enum ExposureAnalyzer {
    /// Underexposed: darker than this many stops below the sensor's maximum (about the noise floor).
    public static let underexposureStops = 10
    /// Overexposed: within this many values of the sensor's maximum.
    public static let clipMargin = 1
    /// Number of stops in `ExposureStats.stopHistogram`.
    public static let histogramStops = 16
    /// A stop counts as part of the scene when at least this fraction of the pixels falls in it.
    public static let sceneStopFraction = 0.001

    /// Over- and underexposure of one file, nil when its sensor data can't be read.
    public static func stats(of url: URL, layout: RawLayout) -> ExposureStats? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        return stats(of: data, layout: layout)
    }

    public static func stats(of data: Data, layout: RawLayout) -> ExposureStats? {
        let l = layout
        guard l.width > 0, l.height > 0, l.black.count == 4, l.offset >= 0, l.byteCount > 0,
              l.offset + l.byteCount <= data.count,
              l.cropLeft >= 0, l.cropTop >= 0, l.cropWidth > 0, l.cropHeight > 0,
              l.cropLeft + l.cropWidth <= l.width, l.cropTop + l.cropHeight <= l.height
        else { return nil }

        var counter = Counter(layout: l)
        let ok = data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Bool in
            let bytes = UnsafeBufferPointer(rebasing: buffer.bindMemory(to: UInt8.self)[l.offset..<(l.offset + l.byteCount)])
            if l.byteCount == l.width * l.height * 2 {
                return readPlain(bytes, layout: l, counter: &counter)
            }
            return decodeOlympus(bytes, layout: l, counter: &counter)
        }
        guard ok, counter.total > 0 else { return nil }
        return ExposureStats(over: Double(counter.over) / Double(counter.total),
                             under: Double(counter.under) / Double(counter.total), exposure: l.exposure,
                             stopHistogram: counter.histogram.map { Double($0) / Double(counter.total) })
    }

    /// Stats of the given photos (keyed by file name), measured in parallel. Photos that can't be read are left out.
    public static func measure(_ photos: [PhotoInfo], in folder: URL,
                               isCancelled: @escaping @Sendable () -> Bool = { false },
                               progress: @escaping @Sendable (Int) -> Void = { _ in }) -> [String: ExposureStats] {
        guard let layouts = try? ExifToolReader.readRawLayouts(files: photos.map(\.fileName), in: folder) else { return [:] }
        let lock = NSLock()
        var result: [String: ExposureStats] = [:]
        var done = 0
        DispatchQueue.concurrentPerform(iterations: photos.count) { index in
            guard !isCancelled() else { return }
            let photo = photos[index]
            let stats = layouts[photo.fileName].flatMap { stats(of: folder.appendingPathComponent(photo.fileName), layout: $0) }
            lock.lock()
            if let stats { result[photo.fileName] = stats }
            done += 1
            let completed = done
            lock.unlock()
            progress(completed)
        }
        return result
    }

    /// How well a bracket covers the scene: the clipped highlights in its darkest frame (the least overexposed
    /// one) and the lost shadows in its brightest frame. Nil until every frame has been measured.
    public static func coverage(of stack: PhotoStack, stats: [String: ExposureStats])
        -> (highlights: Double, shadows: Double)? {
        let measured = stack.photos.compactMap { stats[$0.fileName] }
        guard !measured.isEmpty, measured.count == stack.photos.count,
              let highlights = measured.map(\.over).min(), let shadows = measured.map(\.under).min()
        else { return nil }
        return (highlights, shadows)
    }

    /// Exposure difference in stops between the brightest and darkest frame of the bracket, e.g. 4 for −2…+2.
    public static func bracketSpan(of stack: PhotoStack, stats: [String: ExposureStats]) -> Double? {
        let exposures = stack.photos.compactMap { stats[$0.fileName]?.exposure }
        guard exposures.count == stack.photos.count, let low = exposures.min(), let high = exposures.max() else { return nil }
        return ((high - low) * 3).rounded() / 3
    }

    /// Dynamic range in stops that the bracket captures of the scene: from the brightest content of its darkest
    /// frame to the darkest content above the noise floor of its brightest frame. Nil when not (fully) measured.
    public static func sceneRange(of stack: PhotoStack, stats: [String: ExposureStats]) -> Double? {
        let frames = stack.photos.compactMap { photo in stats[photo.fileName].flatMap { s in s.exposure.map { ($0, s) } } }
        guard !frames.isEmpty, frames.count == stack.photos.count,
              let darkest = frames.min(by: { $0.0 < $1.0 }), let brightest = frames.max(by: { $0.0 < $1.0 }),
              darkest.1.stopHistogram.count == histogramStops, brightest.1.stopHistogram.count == histogramStops,
              let top = darkest.1.stopHistogram.firstIndex(where: { $0 >= sceneStopFraction }),
              let bottom = brightest.1.stopHistogram.prefix(underexposureStops + 1).lastIndex(where: { $0 >= sceneStopFraction })
        else { return nil }
        return (brightest.0 - darkest.0) + Double(bottom - top)
    }

    /// Exposure of `photo` in stops relative to the first photo of `stack` (the camera's base exposure), e.g. −2.
    /// Uses shutter, aperture and ISO, so it also works in manual mode, where the exposure compensation stays 0.
    public static func relativeEV(of photo: PhotoInfo, in stack: PhotoStack, stats: [String: ExposureStats]) -> Double? {
        guard let first = stack.photos.first, let base = stats[first.fileName]?.exposure,
              let exposure = stats[photo.fileName]?.exposure
        else { return nil }
        return ((exposure - base) * 3).rounded() / 3  // camera steps are 1/3 stop
    }

    // MARK: - Counting

    /// Counts clipped values inside the crop while the rows are being decoded.
    private struct Counter {
        let layout: RawLayout
        let overLimit: Int
        /// Per colour filter position: values below this are underexposed.
        let underLimit: [Int]
        /// Per colour filter position: log2 of the usable range (white − black), to bin values by stop.
        let rangeLog: [Int]
        var over = 0
        var under = 0
        var total = 0
        var histogram = [Int](repeating: 0, count: ExposureAnalyzer.histogramStops)

        init(layout: RawLayout) {
            self.layout = layout
            rangeLog = layout.black.map { Int.bitWidth - 1 - max(layout.white - $0, 1).leadingZeroBitCount }
            overLimit = layout.white - ExposureAnalyzer.clipMargin
            underLimit = layout.black.map { black in
                // Integer values below black + range / 2^stops (rounded up).
                let range = max(layout.white - black, 0)
                let steps = 1 << ExposureAnalyzer.underexposureStops
                return black + (range + steps - 1) / steps
            }
        }

        mutating func count(row: Int, values: UnsafeBufferPointer<UInt16>) {
            guard row >= layout.cropTop, row < layout.cropTop + layout.cropHeight else { return }
            let colourRow = (row & 1) * 2
            let limit0 = underLimit[colourRow], limit1 = underLimit[colourRow + 1]
            let last = ExposureAnalyzer.histogramStops - 1
            for col in layout.cropLeft..<(layout.cropLeft + layout.cropWidth) {
                let value = Int(values[col])
                let colour = colourRow + (col & 1)
                if value >= overLimit { over += 1 }
                if value < ((col & 1) == 0 ? limit0 : limit1) { under += 1 }
                let level = max(value - layout.black[colour], 1)
                let stop = rangeLog[colour] - (Int.bitWidth - 1 - level.leadingZeroBitCount)
                histogram[min(max(stop, 0), last)] += 1
            }
            total += layout.cropWidth
        }
    }

    // MARK: - Reading sensor data

    /// Uncompressed little-endian 16-bit values.
    private static func readPlain(_ bytes: UnsafeBufferPointer<UInt8>, layout: RawLayout, counter: inout Counter) -> Bool {
        var row = [UInt16](repeating: 0, count: layout.width)
        for y in 0..<layout.height {
            let start = y * layout.width * 2
            for x in 0..<layout.width {
                row[x] = UInt16(bytes[start + 2 * x]) | UInt16(bytes[start + 2 * x + 1]) << 8
            }
            row.withUnsafeBufferPointer { counter.count(row: y, values: $0) }
        }
        return true
    }

    /// Olympus lossless compression (dcraw `olympus_load_raw`): per pixel a sign, two low bits and a unary/escaped
    /// high part, predicted from the pixels two columns left and two rows up (same colour). Only three rows are
    /// kept. Returns false for data that decodes to impossible values.
    private static func decodeOlympus(_ bytes: UnsafeBufferPointer<UInt8>, layout: RawLayout,
                                      counter: inout Counter) -> Bool {
        let width = layout.width, height = layout.height
        guard bytes.count > 7, width >= 2 else { return false }

        // Number of leading zeros in a 12 bit window (code length = zeros + 1); all zeros means "escape" (12).
        var huff = [UInt16](repeating: 0, count: 4096)
        huff[0] = 0xc0c
        var n = 0
        for i in stride(from: 11, through: 0, by: -1) {
            for _ in 0..<(2048 >> i) {
                n += 1
                huff[n] = UInt16((i + 1) << 8 | i)
            }
        }

        var rows = [UInt16](repeating: 0, count: width * 3)
        var position = 7  // the data starts after a 7 byte header
        var bitBuffer: UInt64 = 0
        var bitCount = 0
        let end = bytes.count
        var overrun = 0

        @inline(__always) func fill(_ bits: Int) {
            while bitCount < bits {
                var byte: UInt64 = 0
                if position < end { byte = UInt64(bytes[position]) } else { overrun += 1 }
                position += 1
                bitBuffer = (bitBuffer << 8) | byte
                bitCount += 8
            }
        }
        @inline(__always) func bits(_ count: Int) -> Int {
            if count == 0 { return 0 }
            fill(count)
            let value = Int((bitBuffer >> UInt64(bitCount - count)) & ((1 << UInt64(count)) - 1))
            bitCount -= count
            return value
        }
        @inline(__always) func high() -> Int {
            fill(12)
            let code = huff[Int((bitBuffer >> UInt64(bitCount - 12)) & 0xfff)]
            bitCount -= Int(code >> 8)
            return Int(code & 0xff)
        }

        return rows.withUnsafeMutableBufferPointer { r -> Bool in
            for row in 0..<height {
                let current = (row % 3) * width
                let up = ((row + 1) % 3) * width  // row − 2
                var even = (0, 0, 0), odd = (0, 0, 0)
                for col in 0..<width {
                    var carry = (col & 1) == 0 ? even : odd
                    let i = carry.2 < 3 ? 2 : 0
                    var nbits = 2 + i
                    while (Int(UInt16(truncatingIfNeeded: carry.0)) >> (nbits + i)) != 0 { nbits += 1 }
                    let signAndLow = bits(3)
                    let low = signAndLow & 3
                    let sign = (signAndLow & 4) != 0 ? -1 : 0
                    var highBits = high()
                    if highBits == 12 { highBits = bits(16 - nbits) >> 1 }
                    carry.0 = (highBits << nbits) | bits(nbits)
                    let diff = (carry.0 ^ sign) + carry.1
                    carry.1 = (diff * 3 + carry.1) >> 5
                    carry.2 = carry.0 > 16 ? 0 : carry.2 + 1
                    if (col & 1) == 0 { even = carry } else { odd = carry }

                    let prediction: Int
                    if row < 2 && col < 2 {
                        prediction = 0
                    } else if row < 2 {
                        prediction = Int(r[current + col - 2])
                    } else if col < 2 {
                        prediction = Int(r[up + col])
                    } else {
                        let w = Int(r[current + col - 2]), nn = Int(r[up + col]), nw = Int(r[up + col - 2])
                        if (w < nw && nw < nn) || (nn < nw && nw < w) {
                            prediction = abs(w - nw) > 32 || abs(nn - nw) > 32 ? w + nn - nw : (w + nn) >> 1
                        } else {
                            prediction = abs(w - nw) > abs(nn - nw) ? w : nn
                        }
                    }
                    let value = prediction + ((diff << 2) | low)
                    guard value >= 0, value >> 12 == 0 else { return false }
                    r[current + col] = UInt16(value)
                }
                if overrun > 8 { return false }
                counter.count(row: row, values: UnsafeBufferPointer(rebasing: r[current..<(current + width)]))
            }
            return true
        }
    }
}
