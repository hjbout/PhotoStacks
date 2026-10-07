import Foundation

/// Scanning a folder together with all its subfolders. Every folder is analysed on its own (the stack detection,
/// the DxO TIFFs, the result images and the stack folders of one folder never mix with those of another); a photo in a
/// subfolder has its path relative to the scanned folder as file name ("Sub/OM1R5855.ORF"), so it stays unique and
/// `folder.appendingPathComponent(photo.fileName)` is its file.
public enum Tree {
    public static func join(_ directory: String, _ name: String) -> String {
        directory.isEmpty ? name : directory + "/" + name
    }

    public static func url(_ root: URL, _ directory: String) -> URL {
        directory.isEmpty ? root : root.appendingPathComponent(directory, isDirectory: true)
    }

    /// The folder itself ("") and all its subfolders (relative paths), sorted. Hidden folders, packages and the output
    /// folders of the stacks (FocusStacks, HDRStacks …) are skipped.
    public static func directories(under root: URL) -> [String] {
        let skipped = Set(StackKind.allCases.map(\.outputFolderName))
        var result = [""]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return result }
        let prefix = root.standardizedFileURL.path + "/"
        for case let item as URL in enumerator {
            guard (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            if skipped.contains(item.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            let path = item.standardizedFileURL.path
            if path.hasPrefix(prefix) { result.append(String(path.dropFirst(prefix.count))) }
        }
        return result.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// All .ORF files of the folder and its subfolders.
    public static func readPhotos(under root: URL) throws -> [PhotoInfo] {
        var photos: [PhotoInfo] = []
        for directory in directories(under: root) {
            for photo in try ExifToolReader.readPhotos(in: url(root, directory)) {
                photos.append(PhotoInfo(fileName: join(directory, photo.fileName), driveMode: photo.driveMode))
            }
        }
        return photos
    }

    /// Stack detection per folder.
    public static func detect(_ photos: [PhotoInfo], minimumSize: Int = 2) -> DetectionResult {
        var stacks: [PhotoStack] = []
        var sequencePhotos = 0
        var loose: [PhotoInfo] = []
        let groups = Dictionary(grouping: photos, by: \.directory)
        for directory in groups.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            let local = groups[directory]!.map(\.local)
            let result = StackDetector.detect(local, minimumSize: minimumSize)
            stacks += result.stacks.map { stack in
                PhotoStack(photos: stack.photos.map { PhotoInfo(fileName: join(directory, $0.fileName), driveMode: $0.driveMode) })
            }
            sequencePhotos += result.sequencePhotos
            loose += result.loosePhotos.map { PhotoInfo(fileName: join(directory, $0.fileName), driveMode: $0.driveMode) }
        }
        return DetectionResult(stacks: stacks, totalPhotos: photos.count, sequencePhotos: sequencePhotos, loosePhotos: loose)
    }

    // MARK: - Per folder helpers

    private static func groups(_ photos: [PhotoInfo]) -> [String: [PhotoInfo]] {
        Dictionary(grouping: photos, by: \.directory)
    }

    private static func strip(_ names: Set<String>, directory: String) -> Set<String> {
        Set(names.filter { ($0 as NSString).deletingLastPathComponent == directory }.map { ($0 as NSString).lastPathComponent })
    }

    // MARK: - Photos taken out of stacks

    public static func loadExcluded(root: URL, directories: Set<String>) -> Set<String> {
        var result = Set<String>()
        for directory in directories {
            for name in ExclusionStore.load(for: url(root, directory)) { result.insert(join(directory, name)) }
        }
        return result
    }

    /// Writes the exclusion file of each of `directories` (the others are left alone).
    public static func saveExcluded(_ excluded: Set<String>, directories: Set<String>, root: URL) throws {
        for directory in directories {
            try ExclusionStore.save(strip(excluded, directory: directory), for: url(root, directory))
        }
    }

    // MARK: - Files next to the photos

    public static func tiffs(root: URL, photos: [PhotoInfo]) -> [String: [TIFFFile]] {
        var result: [String: [TIFFFile]] = [:]
        for (directory, group) in groups(photos) {
            let found = DxOExports.scan(folder: url(root, directory), photos: group.map(\.local))
            for (name, files) in found {
                result[join(directory, name)] = files.map { TIFFFile(fileName: join(directory, $0.fileName), modified: $0.modified) }
            }
        }
        return result
    }

    public static func stackedImages(root: URL, stacks: [(key: String, stack: PhotoStack)]) -> [String: StackedImage] {
        var result: [String: StackedImage] = [:]
        let byDirectory = Dictionary(grouping: stacks, by: { $0.stack.photos.first?.directory ?? "" })
        for (directory, group) in byDirectory {
            let folder = url(root, directory)
            let local = group.map { (key: $0.key, stack: PhotoStack(photos: $0.stack.photos.map(\.local))) }
            let found = StackedImages.scan(folder: folder, stacks: local) { names in
                (try? ExifToolReader.readStackedImages(files: names, in: folder)) ?? [:]
            }
            for (key, image) in found {
                result[key] = StackedImage(fileName: join(directory, image.fileName), imageCount: image.imageCount)
            }
        }
        return result
    }

    public static func results(root: URL, stacks: [(key: String, stack: PhotoStack)],
                               cache: SoftwareTagCache) -> [String: [StackResult]] {
        var result: [String: [StackResult]] = [:]
        let byDirectory = Dictionary(grouping: stacks, by: { $0.stack.photos.first?.directory ?? "" })
        for (directory, group) in byDirectory {
            let folder = url(root, directory)
            let local = group.map { (key: $0.key, stack: PhotoStack(photos: $0.stack.photos.map(\.local))) }
            let found = StackResults.scan(folder: folder, stacks: local) { names in
                cache.tags(for: names, in: folder) { files in
                    (try? ExifToolReader.readSoftware(files: files, in: folder)) ?? [:]
                }
            }
            for (key, files) in found {
                result[key] = files.map { StackResult(fileName: join(directory, $0.fileName), app: $0.app, modified: $0.modified) }
            }
        }
        return result
    }

    public static func frameJPGs(root: URL, photos: [PhotoInfo], cache: SoftwareTagCache) -> [String: String] {
        var result: [String: String] = [:]
        for (directory, group) in groups(photos) {
            let found = FrameJPGs.find(in: url(root, directory), photos: group.map(\.local), cache: cache)
            for (name, jpg) in found { result[join(directory, name)] = join(directory, jpg) }
        }
        return result
    }

    // MARK: - Stack folders

    /// Brings the stack folders of every folder in `directories` (and of the folders the stacks are in) in line with
    /// `stacks`. `tiffs` maps photo → TIFF, both relative to `root`.
    public static func writeAll(stacks: [PhotoStack], root: URL, directories: Set<String>, excluded: Set<String>,
                                tiffs: [String: String]) -> LinkReport {
        var report = LinkReport()
        let byDirectory = Dictionary(grouping: stacks, by: { $0.photos.first?.directory ?? "" })
        for directory in directories.union(byDirectory.keys).sorted() {
            let local = (byDirectory[directory] ?? []).map { PhotoStack(photos: $0.photos.map(\.local)) }
            var localTiffs: [String: String] = [:]
            for (photo, tiff) in tiffs where (photo as NSString).deletingLastPathComponent == directory {
                localTiffs[(photo as NSString).lastPathComponent] = (tiff as NSString).lastPathComponent
            }
            report.merge(LinkWriter.writeAll(stacks: local, in: url(root, directory),
                                             excluded: strip(excluded, directory: directory), tiffs: localTiffs))
        }
        return report
    }
}
