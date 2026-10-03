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
    /// Sorts photos by the numbering in their file names (natural order, so "P9120001" < "PA010001").
    public static func sorted(_ photos: [PhotoInfo]) -> [PhotoInfo] {
        photos.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
    }

    /// Walks the photos in file name order. A stack continues while the next photo has the same sequence mode
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
        return counterA - shotA == counterB - shotB
    }
}
