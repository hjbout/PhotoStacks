import Foundation

/// The JPG that the camera composed of a focus stack (focus stacking in the camera), next to the originals.
public struct StackedImage: Sendable, Hashable {
    public let fileName: String
    /// How many shots the camera combined (the stack may have lost photos since).
    public let imageCount: Int

    public init(fileName: String, imageCount: Int) {
        self.fileName = fileName
        self.imageCount = imageCount
    }

    /// The file as a photo (without Drive Mode), so it can be shown like the photos of the stack.
    public var photo: PhotoInfo {
        PhotoInfo(fileName: fileName, driveMode: "")
    }
}

/// Finds the stacked JPG of focus stacks. When the camera stacks the shots itself it saves the result as a JPG with
/// the next file number after the last shot and tags it in the MakerNotes (`StackedImage`: "Focus-stacked
/// (8 images)"): the shots OM1R5855–OM1R5862 give OM1R5863.JPG. So the stacked JPG of a stack has the number of Shot 1
/// plus the number of images, and only a JPG whose tag says so counts. The camera's JPGs of single shots and of the
/// next stack lie in the same area but are not tagged, and copies of the stacked JPG that other programs made
/// (OM1R5863_NIK.JPG) have another name.
public enum StackedImages {
    public static let imageExtensions: Set<String> = ["jpg", "jpeg"]

    /// The most shots the camera combines in a stack.
    static let maxImages = 15

    /// A JPG that could be the stacked image of a stack.
    struct Candidate: Equatable {
        let fileName: String
        let stackIndex: Int
        let counter: Int
    }

    /// Per stack (keyed by the given key) its stacked image. `imageCounts` returns the number of shots in the
    /// `StackedImage` tag of the given files (only the focus-stacked ones); it is only asked for the candidates.
    public static func scan(folder: URL, stacks: [(key: String, stack: PhotoStack)],
                            imageCounts: ([String]) -> [String: Int]) -> [String: StackedImage] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        let found = candidates(names: names, stacks: stacks.map(\.stack))
        if found.isEmpty { return [:] }
        let counts = imageCounts(found.map(\.fileName))
        var result: [String: StackedImage] = [:]
        for candidate in found.sorted(by: { $0.fileName < $1.fileName }) {
            let (key, stack) = stacks[candidate.stackIndex]
            guard result[key] == nil, let count = counts[candidate.fileName], let base = base(of: stack),
                  candidate.counter == base + count + 1,
                  let attributes = try? fm.attributesOfItem(atPath: folder.appendingPathComponent(candidate.fileName).path),
                  attributes[.type] as? FileAttributeType == .typeRegular
            else { continue }
            result[key] = StackedImage(fileName: candidate.fileName, imageCount: count)
        }
        return result
    }

    /// JPGs with the name pattern of the camera (the photos' prefix and a number) that lie after the last photo of a
    /// focus stack and within reach of the most shots the camera combines.
    static func candidates(names: [String], stacks: [PhotoStack]) -> [Candidate] {
        let jpgs = names.compactMap { name -> (name: String, prefix: String, counter: Int)? in
            guard !name.hasPrefix("."), imageExtensions.contains((name as NSString).pathExtension.lowercased()) else { return nil }
            let photo = PhotoInfo(fileName: name, driveMode: "")
            return photo.counter.map { (name, photo.namePrefix.lowercased(), $0) }
        }
        var result: [Candidate] = []
        for (index, stack) in stacks.enumerated() where stack.kind == .focus {
            guard let base = base(of: stack), let prefix = stack.photos.first?.namePrefix.lowercased(),
                  let last = stack.photos.last?.counter
            else { continue }
            for jpg in jpgs where jpg.prefix == prefix && jpg.counter > last && jpg.counter <= base + maxImages + 1 {
                result.append(Candidate(fileName: jpg.name, stackIndex: index, counter: jpg.counter))
            }
        }
        return result
    }

    /// The file number of the photo before Shot 1: every photo has this plus its Shot number as file number
    /// (the stack detection keeps photos together only while that holds).
    private static func base(of stack: PhotoStack) -> Int? {
        guard let first = stack.photos.first, let counter = first.counter, let shot = first.shot else { return nil }
        return counter - shot
    }
}
