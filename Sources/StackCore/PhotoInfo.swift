import Foundation

/// Metadata of one .ORF file in the scanned folder.
public struct PhotoInfo: Sendable, Equatable, Hashable, Identifiable {
    /// File name relative to the scanned folder, e.g. "OM1R5855.ORF".
    public let fileName: String
    /// Drive Mode from the Olympus MakerNotes, e.g. "Focus Bracketing, Shot 5".
    public let driveMode: String

    public init(fileName: String, driveMode: String) {
        self.fileName = fileName
        self.driveMode = driveMode
    }

    public var id: String { fileName }

    /// File name without extension, e.g. "OM1R5855".
    public var stem: String {
        (fileName as NSString).deletingPathExtension
    }

    /// Trailing number of the file name, e.g. 5855 for "OM1R5855.ORF".
    public var counter: Int? {
        guard let match = stem.firstMatch(of: #/(\d+)$/#) else { return nil }
        return Int(match.1)
    }

    /// Shot number when this photo is part of a focus bracketing sequence.
    public var bracketShot: Int? {
        PhotoInfo.bracketShot(from: driveMode)
    }

    public static func bracketShot(from driveMode: String) -> Int? {
        guard let match = driveMode.firstMatch(of: #/Focus Bracketing, Shot (\d+)/#) else { return nil }
        return Int(match.1)
    }
}
