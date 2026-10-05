import Foundation

/// The kinds of sequences the camera records in the Drive Mode ("<mode>, Shot N").
public enum StackKind: String, CaseIterable, Sendable, Hashable {
    case focus, hdr, proCap, series

    /// Recognises a Drive Mode without its ", Shot N" part, e.g. "AE Auto Bracketing" or "ProCap SH2".
    /// WB, FL, ISO and MF bracketing are not supported.
    public init?(mode: String) {
        if mode == "Focus Bracketing" {
            self = .focus
        } else if mode.hasSuffix("Bracketing"), mode.hasPrefix("AE") {
            self = .hdr
        } else if mode.hasPrefix("ProCap") {
            self = .proCap
        } else if mode.hasPrefix("Sequential") {
            self = .series
        } else {
            return nil
        }
    }

    /// The folder next to the originals that holds the stack folders of this kind.
    public var outputFolderName: String {
        switch self {
        case .focus: "FocusStacks"
        case .hdr: "HDRStacks"
        case .proCap: "ProCap"
        case .series: "Series"
        }
    }

    public var title: String {
        switch self {
        case .focus: "Focus"
        case .hdr: "HDR"
        case .proCap: "ProCap"
        case .series: "Serie"
        }
    }

    public var systemImage: String {
        switch self {
        case .focus: "square.stack.3d.up"
        case .hdr: "plusminus.circle"
        case .proCap: "bolt.circle"
        case .series: "square.3.layers.3d.down.right"
        }
    }

    /// Comparing sharpness within the sequence makes sense (not for HDR: the exposure differs per frame).
    public var measuresSharpness: Bool { self != .hdr }

    /// Over- and underexposure is what matters for HDR; every kind measures either this or sharpness.
    public var measuresExposure: Bool { self == .hdr }

    /// Missing shot numbers mean deleted photos (bursts are usually thinned out, so there gaps are normal).
    public var reportsMissingShots: Bool { self == .focus || self == .hdr }
}

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

    /// The sequence part of the Drive Mode, e.g. ("ProCap SH2", 7) for "ProCap SH2, Shot 7; Anti-shock".
    public var sequence: (mode: String, shot: Int)? {
        PhotoInfo.sequence(from: driveMode)
    }

    /// Mode of the sequence this photo belongs to, e.g. "AE Bracketing".
    public var sequenceMode: String? { sequence?.mode }

    /// Shot number within its sequence.
    public var shot: Int? { sequence?.shot }

    /// Kind of the sequence, nil for single shots and unsupported sequences.
    public var kind: StackKind? { sequenceMode.flatMap(StackKind.init(mode:)) }

    public static func sequence(from driveMode: String) -> (mode: String, shot: Int)? {
        guard let match = driveMode.firstMatch(of: #/^(.+?), Shot (\d+)/#), let shot = Int(match.2) else { return nil }
        return (String(match.1), shot)
    }
}
