import Foundation

/// The programs whose output the app recognises next to the originals.
public enum ResultApp: String, CaseIterable, Sendable, Hashable {
    case helicon, photomatix, luminar

    public var displayName: String {
        switch self {
        case .helicon: "Helicon"
        case .photomatix: "Photomatix"
        case .luminar: "Luminar Neo"
        }
    }

    /// What the software tags contain (lowercased), without the version. Not "Luminar AI", an older product.
    var tagName: String {
        switch self {
        case .helicon: "helicon"
        case .photomatix: "photomatix"
        case .luminar: "luminar neo"
        }
    }

    /// Luminar Neo is recognised on its tags only, for focus and HDR stacks.
    func applies(to kind: StackKind) -> Bool {
        self != .luminar || kind == .focus || kind == .hdr
    }

    /// The program that processes stacks of this kind (none for bursts).
    static func native(for kind: StackKind) -> ResultApp? {
        switch kind {
        case .focus: .helicon
        case .hdr: .photomatix
        case .proCap, .series: nil
        }
    }
}

/// An image that Helicon Focus or Photomatix Pro made of (a photo of) a stack.
public struct StackResult: Sendable, Hashable {
    public let fileName: String
    public let app: ResultApp
    public let modified: Date

    public init(fileName: String, app: ResultApp, modified: Date) {
        self.fileName = fileName
        self.app = app
        self.modified = modified
    }

    /// A merged 32-bit file (.hdr, .exr) that Photomatix saves before tone mapping, not the finished picture.
    public var isIntermediate: Bool {
        let fileExtension = (fileName as NSString).pathExtension.lowercased()
        return fileExtension == "hdr" || fileExtension == "exr"
    }
}

/// Remembers the software tags of image files (keyed by name, size and modification date), so exiftool reads each
/// file only once, however often the folder is checked again.
public final class SoftwareTagCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    public init() {}

    /// The software text per file name; `reader` is asked for the files that are new or changed only.
    public func tags(for names: [String], in folder: URL, reader: ([String]) -> [String: String]) -> [String: String] {
        var keys: [String: String] = [:]
        for name in names {
            let attributes = try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)
            let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            keys[name] = "\(folder.path)/\(name)|\(modified)|\(size)"
        }
        lock.lock()
        let unknown = names.filter { values[keys[$0] ?? ""] == nil }
        lock.unlock()
        if !unknown.isEmpty {
            let read = reader(unknown)
            lock.lock()
            for name in unknown { values[keys[name] ?? ""] = read[name] ?? "" }
            lock.unlock()
        }
        lock.lock()
        defer { lock.unlock() }
        return names.reduce(into: [:]) { result, name in result[name] = values[keys[name] ?? ""] ?? "" }
    }
}

/// Finds the images Helicon Focus (focus stacks) and Photomatix Pro (HDR) made of a stack, next to the originals.
///
/// Luminar Neo (focus and HDR stacks) is recognised on its tags only. Two signals:
/// - The software tags (`ProcessingSoftware`, `Software`, `CreatorTool`) contain the program's name. Only the name
///   counts, not the version. Helicon's `ProcessingSoftware` survives a re-export by DxO PhotoLab.
/// - The file name starts with the name of one of the stack's photos (Helicon names its result after the first or
///   the last photo it got). Without usable tags (.hdr, .exr) the usual naming of the programs decides:
///   Helicon: `OM1R1409 11 (B,R4,S2).tif`; Photomatix: `OM1R1308_09_10_Optimizer.tif` (the tail of the next photo
///   numbers, then the preset).
public enum StackResults {
    public static let imageExtensions: Set<String> = ["tif", "tiff", "jpg", "jpeg", "png", "dng", "hdr", "exr"]

    /// An image whose name starts with the name of a photo of a stack.
    struct Candidate: Equatable {
        let fileName: String
        let stackIndex: Int
        /// What the name alone says (nil when it doesn't look like the output of one of the programs).
        let nameApp: ResultApp?
    }

    /// Per stack (keyed by the given key) its results, newest first. `software` returns the software tags of the
    /// given files (file name → text); it is only asked for files that could be a result.
    public static func scan(folder: URL, stacks: [(key: String, stack: PhotoStack)],
                            software: ([String]) -> [String: String]) -> [String: [StackResult]] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        let found = candidates(names: names, stacks: stacks.map(\.stack))
        if found.isEmpty { return [:] }
        let tags = software(found.map(\.fileName))
        var result: [String: [StackResult]] = [:]
        for candidate in found {
            let kind = stacks[candidate.stackIndex].stack.kind
            guard let app = resolve(candidate.nameApp, tags: tags[candidate.fileName] ?? "", kind: kind),
                  let attributes = try? fm.attributesOfItem(atPath: folder.appendingPathComponent(candidate.fileName).path),
                  attributes[.type] as? FileAttributeType == .typeRegular
            else { continue }
            let modified = attributes[.modificationDate] as? Date ?? .distantPast
            result[stacks[candidate.stackIndex].key, default: []]
                .append(StackResult(fileName: candidate.fileName, app: app, modified: modified))
        }
        return result.mapValues { files in
            files.sorted { ($0.modified, $0.fileName) > ($1.modified, $1.fileName) }
        }
    }

    /// Image files whose name starts with the name of a stack photo (not followed by a digit, so OM1R58550 doesn't
    /// belong to OM1R5855). Files named exactly like a photo (DxO or Luminar exports) are candidates too; only their
    /// tags can make them a result.
    static func candidates(names: [String], stacks: [PhotoStack]) -> [Candidate] {
        var owners: [String: Int] = [:]
        for (index, stack) in stacks.enumerated() {
            for photo in stack.photos { owners[photo.stem.lowercased()] = index }
        }
        let stems = stacks.map { Set($0.photos.map { $0.stem.lowercased() }) }
        return names.compactMap { name in
            guard !name.hasPrefix("."), imageExtensions.contains((name as NSString).pathExtension.lowercased()) else { return nil }
            let base = (name.lowercased() as NSString).deletingPathExtension
            guard let (stem, index) = leadingStem(of: base, in: owners) else { return nil }
            let rest = String(base.dropFirst(stem.count))
            return Candidate(fileName: name, stackIndex: index,
                             nameApp: nameApp(rest: rest, stem: stem, stack: stacks[index], stackStems: stems[index]))
        }
    }

    /// The longest photo stem that `base` is or starts with, when the next character isn't a digit.
    private static func leadingStem(of base: String, in owners: [String: Int]) -> (stem: String, index: Int)? {
        var best: (stem: String, index: Int)?
        for length in 1...max(base.count, 1) {
            let stem = String(base.prefix(length))
            guard let index = owners[stem] else { continue }
            if let next = base.dropFirst(length).first, next.isNumber { continue }
            best = (stem, index)
        }
        return best
    }

    /// The program named in the software tags, if any. Only the name counts, not the version ("Helicon Focus 9.0.7 Mac").
    static func app(inSoftware text: String) -> Set<ResultApp> {
        let lowercased = text.lowercased()
        return Set(ResultApp.allCases.filter { lowercased.contains($0.tagName) })
    }

    /// The tags win over the name. When a file names both programs, the one that processes this kind of stack wins.
    static func resolve(_ nameApp: ResultApp?, tags: String, kind: StackKind) -> ResultApp? {
        let named = app(inSoftware: tags).filter { $0.applies(to: kind) }
        if let native = ResultApp.native(for: kind), named.contains(native) { return native }
        return named.sorted { $0.rawValue < $1.rawValue }.first ?? nameApp
    }

    /// What the naming of Helicon (focus stacks) or Photomatix (HDR stacks) says about the part after the photo name.
    private static func nameApp(rest: String, stem: String, stack: PhotoStack, stackStems: Set<String>) -> ResultApp? {
        switch stack.kind {
        case .focus:
            // "(B,R4,S2)", "(C,S1)", or just the number of photos: " 5".
            if rest.contains(#/\([abc](,r\d+)?(,s\d+)?\)/#) { return .helicon }
            if let match = rest.wholeMatch(of: #/ (\d+)/#), let count = Int(match.1), (2...max(stack.count, 2)).contains(count) {
                return .helicon
            }
            return nil
        case .hdr:
            return isPhotomatixTail(rest, stem: stem, stackStems: stackStems) ? .photomatix : nil
        case .proCap, .series:
            return nil
        }
    }

    /// "_09_10_optimizer" after "om1r1308": the digit groups are the tails of the next photo numbers, which must
    /// be photos of the stack ("_09" → om1r1309, then "_10" → om1r1310); what follows is the preset.
    private static func isPhotomatixTail(_ rest: String, stem: String, stackStems: Set<String>) -> Bool {
        guard rest.hasPrefix("_"), let digits = stem.firstMatch(of: #/(\d+)$/#)?.1 else { return false }
        let prefix = String(stem.dropLast(digits.count))
        var previous = Int(digits) ?? 0
        var groups = 0
        for part in rest.dropFirst().split(separator: "_", omittingEmptySubsequences: false) {
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let tail = Int(part) else { break }
            // The first number above the previous one that ends in these digits.
            let modulus = Int(pow(10, Double(part.count)))
            var next = previous - previous % modulus + tail
            if next <= previous { next += modulus }
            let candidate = prefix + String(format: "%0\(digits.count)d", next)
            guard stackStems.contains(candidate) else { return false }
            previous = next
            groups += 1
        }
        return groups > 0
    }
}
