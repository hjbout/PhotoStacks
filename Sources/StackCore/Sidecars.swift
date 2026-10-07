import Foundation

/// The files that belong to one photo: the .ORF itself and every regular file next to it with exactly the same
/// name stem (OM1R5855.xmp, .on1, .JPG, .ORI, .xmp_original …). Edited versions with another name
/// ("OM1R5855 bewerkt.tif") are not included.
public enum Sidecars {
    public static func files(for photo: PhotoInfo, in folder: URL) -> [URL] {
        let own = photo.directory.isEmpty ? folder : folder.appendingPathComponent(photo.directory, isDirectory: true)
        return files(forStem: photo.stem, first: photo.baseName, in: own)
    }

    /// Every regular file in `folder` named `<stem>.<anything>` (`first`, if given, at the front).
    public static func files(forStem stem: String, first: String? = nil, in folder: URL) -> [URL] {
        let fm = FileManager.default
        let prefix = stem.lowercased() + "."
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        let matching = names.filter { name in
            guard name.lowercased().hasPrefix(prefix) else { return false }
            let attributes = try? fm.attributesOfItem(atPath: folder.appendingPathComponent(name).path)
            return attributes?[.type] as? FileAttributeType == .typeRegular
        }
        return matching
            .sorted { ($0 == first ? 0 : 1, $0.lowercased()) < ($1 == first ? 0 : 1, $1.lowercased()) }
            .map { folder.appendingPathComponent($0) }
    }
}
