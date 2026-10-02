import Foundation

/// One focus bracketing sequence.
public struct FocusStack: Identifiable, Sendable, Equatable {
    public let photos: [PhotoInfo]

    public init(photos: [PhotoInfo]) {
        self.photos = photos
    }

    public var id: String { folderName }
    public var count: Int { photos.count }
    public var firstShot: Int { photos.first?.bracketShot ?? 0 }
    public var lastShot: Int { photos.last?.bracketShot ?? 0 }

    /// Shot numbers between 1 and the last shot that are not present (deleted photos).
    public var missingShots: [Int] {
        let present = Set(photos.compactMap(\.bracketShot))
        return (1...max(lastShot, 1)).filter { !present.contains($0) }
    }

    /// This stack without the given photos, nil when fewer than 2 photos remain.
    public func excluding(_ fileNames: Set<String>) -> FocusStack? {
        let remaining = photos.filter { !fileNames.contains($0.fileName) }
        return remaining.count >= 2 ? FocusStack(photos: remaining) : nil
    }

    /// Name of the subfolder in FocusStacks, e.g. "OM1R5855-OM1R5896 (34)".
    public var folderName: String {
        let first = photos.first?.stem ?? ""
        let last = photos.last?.stem ?? ""
        return "\(first)-\(last) (\(count))"
    }
}

public struct DetectionResult: Sendable {
    public let stacks: [FocusStack]
    public let totalPhotos: Int
    public let bracketPhotos: Int
    /// Focus bracketing photos that ended up in a "stack" smaller than the minimum size.
    public let looseBracketPhotos: [PhotoInfo]

    public init(stacks: [FocusStack], totalPhotos: Int, bracketPhotos: Int, looseBracketPhotos: [PhotoInfo]) {
        self.stacks = stacks
        self.totalPhotos = totalPhotos
        self.bracketPhotos = bracketPhotos
        self.looseBracketPhotos = looseBracketPhotos
    }
}

public enum StackDetector {
    /// Sorts photos by the numbering in their file names (natural order, so "P9120001" < "PA010001").
    public static func sorted(_ photos: [PhotoInfo]) -> [PhotoInfo] {
        photos.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
    }

    /// Walks the photos in file name order. A stack continues while the next photo is
    /// focus bracketing with a higher shot number. Gaps (deleted photos) are allowed as long
    /// as file counter minus shot number stays the same, so a following stack whose first
    /// shots were deleted is not merged into the previous one.
    public static func detect(_ photos: [PhotoInfo], minimumSize: Int = 2) -> DetectionResult {
        var stacks: [FocusStack] = []
        var loose: [PhotoInfo] = []
        var current: [PhotoInfo] = []

        func close() {
            if current.count >= minimumSize {
                stacks.append(FocusStack(photos: current))
            } else {
                loose.append(contentsOf: current)
            }
            current = []
        }

        for photo in sorted(photos) {
            guard let shot = photo.bracketShot else {
                close()
                continue
            }
            if let previous = current.last, let previousShot = previous.bracketShot {
                let continues = shot > previousShot && sameOffset(previous, previousShot, photo, shot)
                if !continues { close() }
            }
            current.append(photo)
        }
        close()

        return DetectionResult(
            stacks: stacks,
            totalPhotos: photos.count,
            bracketPhotos: photos.filter { $0.bracketShot != nil }.count,
            looseBracketPhotos: loose
        )
    }

    private static func sameOffset(_ a: PhotoInfo, _ shotA: Int, _ b: PhotoInfo, _ shotB: Int) -> Bool {
        guard let counterA = a.counter, let counterB = b.counter else { return true }
        return counterA - shotA == counterB - shotB
    }
}
