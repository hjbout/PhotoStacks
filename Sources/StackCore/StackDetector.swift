import Foundation

/// One sequence of photos: a focus or exposure bracketing series or a burst.
public struct PhotoStack: Identifiable, Sendable, Equatable {
    public let photos: [PhotoInfo]

    public init(photos: [PhotoInfo]) {
        self.photos = photos
    }

    public var id: String { folderName }
    public var count: Int { photos.count }
    public var kind: StackKind { photos.first?.kind ?? .focus }
    public var firstShot: Int { photos.first?.shot ?? 0 }
    public var lastShot: Int { photos.last?.shot ?? 0 }

    /// Shot numbers between 1 and the last shot that are not present (deleted photos).
    public var missingShots: [Int] {
        let present = Set(photos.compactMap(\.shot))
        return (1...max(lastShot, 1)).filter { !present.contains($0) }
    }

    /// This stack without the given photos, nil when fewer than 2 photos remain.
    public func excluding(_ fileNames: Set<String>) -> PhotoStack? {
        let remaining = photos.filter { !fileNames.contains($0.fileName) }
        return remaining.count >= 2 ? PhotoStack(photos: remaining) : nil
    }

    /// Name of the subfolder in the kind's output folder, e.g. "OM1R5855-OM1R5896 (34)".
    public var folderName: String {
        let first = photos.first?.stem ?? ""
        let last = photos.last?.stem ?? ""
        return "\(first)-\(last) (\(count))"
    }
}

public struct DetectionResult: Sendable {
    public let stacks: [PhotoStack]
    public let totalPhotos: Int
    /// Photos that are part of a supported sequence.
    public let sequencePhotos: Int
    /// Sequence photos that ended up in a "stack" smaller than the minimum size.
    public let loosePhotos: [PhotoInfo]

    public init(stacks: [PhotoStack], totalPhotos: Int, sequencePhotos: Int, loosePhotos: [PhotoInfo]) {
        self.stacks = stacks
        self.totalPhotos = totalPhotos
        self.sequencePhotos = sequencePhotos
        self.loosePhotos = loosePhotos
    }
}

public enum StackDetector {
    /// Sorts photos by the numbering in their file names (natural order, so "P9120001" < "PA010001"), with the photos
    /// taken after the camera's numbering started again behind the ones before it.
    public static func sorted(_ photos: [PhotoInfo]) -> [PhotoInfo] {
        let byName = photos.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
        var result: [PhotoInfo] = []
        var start = 0
        while start < byName.count {
            var end = start + 1
            while end < byName.count, byName[end].namePrefix == byName[start].namePrefix { end += 1 }
            result += numberingRestartRemoved(Array(byName[start..<end]))
            start = end
        }
        return result
    }

    /// When the numbering started again (…9999, 0001…) the file names sort the later photos first. That is the case when
    /// the name order is the time order turned around one point: the time goes back exactly once, the last name isn't
    /// newer than the first, and the first number follows the last one in the camera's cycle (not exactly, photos can be
    /// deleted). The point itself is found from the times, which only have whole seconds; the order within each part
    /// stays the file name order. Anything else (no times, a changed camera clock) is left alone.
    private static func numberingRestartRemoved(_ photos: [PhotoInfo]) -> [PhotoInfo] {
        let times = photos.compactMap(\.captureTime)
        guard times.count == photos.count, let first = times.first, let last = times.last, last <= first,
              let lastCounter = photos.last?.counter, let firstCounter = photos.first?.counter,
              PhotoInfo.counterSteps(from: lastCounter, to: firstCounter) < PhotoInfo.counterCycle / 2
        else { return photos }
        let backwards = times.indices.dropLast().filter { times[$0] > times[$0 + 1] }
        guard backwards.count == 1 else { return photos }
        let restart = backwards[0] + 1
        return Array(photos[restart...] + photos[..<restart])
    }

    /// Walks the photos in the order they were taken. A stack continues while the next photo has the same sequence mode
    /// (e.g. "AE Bracketing") with a higher shot number. Gaps (deleted photos) are allowed as long as file
    /// counter minus shot number stays the same, so a following stack whose first shots were deleted is not
    /// merged into the previous one.
    public static func detect(_ photos: [PhotoInfo], minimumSize: Int = 2) -> DetectionResult {
        var stacks: [PhotoStack] = []
        var loose: [PhotoInfo] = []
        var current: [PhotoInfo] = []

        func close() {
            if current.count >= minimumSize {
                stacks.append(PhotoStack(photos: current))
            } else {
                loose.append(contentsOf: current)
            }
            current = []
        }

        var sequencePhotos = 0
        for photo in sorted(photos) {
            guard photo.kind != nil, let sequence = photo.sequence else {
                close()
                continue
            }
            sequencePhotos += 1
            if let previous = current.last?.sequence {
                let continues = sequence.mode == previous.mode && sequence.shot > previous.shot
                    && sameOffset(current[current.count - 1], previous.shot, photo, sequence.shot)
                if !continues { close() }
            }
            current.append(photo)
        }
        close()

        return DetectionResult(
            stacks: stacks,
            totalPhotos: photos.count,
            sequencePhotos: sequencePhotos,
            loosePhotos: loose
        )
    }

    private static func sameOffset(_ a: PhotoInfo, _ shotA: Int, _ b: PhotoInfo, _ shotB: Int) -> Bool {
        guard let counterA = a.counter, let counterB = b.counter else { return true }
        // A multiple of the cycle apart: the numbering started again within the stack (19999 Shot 42, 10001 Shot 43).
        return (counterA - shotA - (counterB - shotB)) % PhotoInfo.counterCycle == 0
    }
}
