import Foundation

public struct TIFFFile: Sendable, Hashable {
    public let fileName: String
    public let modified: Date

    public init(fileName: String, modified: Date) {
        self.fileName = fileName
        self.modified = modified
    }
}

/// TIFFs exported by DxO PhotoLab next to the originals, e.g. OM1R5855.tif, OM1R5855_DxO.tif or
/// OM1R5855_M_DxO (1).tiff. A TIFF belongs to a photo when
/// - its name is exactly the photo's name and only the extension differs (OM1R5855.tif), or
/// - its name starts with the photo's name followed by a separator (not a letter or digit, so OM1R58550_DxO.tif
///   doesn't belong to OM1R5855) and the rest of the name contains "DxO".
/// TIFFs of other programs (_Nik, _openWith …) don't count.
public enum DxOExports {
    /// Subfolder of a stack folder in FocusStacks with links to the stack's TIFFs.
    public static let subfolderName = "TIFF"

    /// Per photo (keyed by file name) its DxO TIFFs, newest first. Reads only one directory listing.
    public static func scan(folder: URL, photos: [PhotoInfo]) -> [String: [TIFFFile]] {
        let fm = FileManager.default
        let stems = Dictionary(photos.map { ($0.stem.lowercased(), $0.fileName) }) { first, _ in first }
        var result: [String: [TIFFFile]] = [:]
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] {
            let fileExtension = (name as NSString).pathExtension.lowercased()
            guard fileExtension == "tif" || fileExtension == "tiff", let photo = photo(for: name, stems: stems),
                  let attributes = try? fm.attributesOfItem(atPath: folder.appendingPathComponent(name).path),
                  attributes[.type] as? FileAttributeType == .typeRegular
            else { continue }
            let modified = attributes[.modificationDate] as? Date ?? .distantPast
            result[photo, default: []].append(TIFFFile(fileName: name, modified: modified))
        }
        return result.mapValues { files in
            files.sorted { ($0.modified, $0.fileName) > ($1.modified, $1.fileName) }
        }
    }

    /// The photo file name a TIFF belongs to; `stems` maps lowercased photo stems to photo file names.
    static func photo(for tiffName: String, stems: [String: String]) -> String? {
        let base = (tiffName.lowercased() as NSString).deletingPathExtension
        if let photo = stems[base] { return photo }
        guard let best = leadingStem(of: base, in: stems), base.dropFirst(best.stem.count).contains("dxo") else { return nil }
        return best.value
    }

    /// The longest photo stem that `base` (a lowercased name without extension) starts with, followed by a
    /// separator (not a letter or digit, so OM1R58550 doesn't belong to OM1R5855).
    static func leadingStem<Value>(of base: String, in stems: [String: Value]) -> (stem: String, value: Value)? {
        var best: (stem: String, value: Value)?
        // Possible ends of the photo name: every separator after the first character.
        for (offset, character) in base.enumerated() where offset > 0 && !(character.isLetter || character.isNumber) {
            let stem = String(base.prefix(offset))
            if let value = stems[stem], stem.count > (best?.stem.count ?? 0) {
                best = (stem, value)
            }
        }
        return best
    }
}
