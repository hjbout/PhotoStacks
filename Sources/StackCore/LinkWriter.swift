import Foundation

public struct LinkReport: Sendable {
    public var created = 0
    public var alreadyPresent = 0
    public var foldersCreated = 0
    public var foldersRenamed = 0
    public var brokenLinksRemoved = 0
    public var excludedLinksRemoved = 0
    public var tiffLinksCreated = 0
    public var tiffLinksRemoved = 0
    public var foldersRemoved = 0
    public var problems: [String] = []

    public init() {}

    /// Adds the counts and problems of another report (e.g. of another kind's output folder).
    public mutating func merge(_ other: LinkReport) {
        created += other.created
        alreadyPresent += other.alreadyPresent
        foldersCreated += other.foldersCreated
        foldersRenamed += other.foldersRenamed
        brokenLinksRemoved += other.brokenLinksRemoved
        excludedLinksRemoved += other.excludedLinksRemoved
        tiffLinksCreated += other.tiffLinksCreated
        tiffLinksRemoved += other.tiffLinksRemoved
        foldersRemoved += other.foldersRemoved
        problems += other.problems
    }
}

/// Brings <kind folder>/<stack>/<photo> (relative symlinks to the originals) in line with the detected stacks;
/// each kind of sequence has its own output folder (FocusStacks, HDRStacks …) next to the originals.
///
/// Nothing outside the output folder is ever touched. Inside it, the only things ever removed are the app's own
/// links (a symlink "<name>" -> "../../<name>") whose original is gone or that the user took out of the stack
/// (`excluded`), and stack folders that are empty afterwards (apart from a Finder .DS_Store). Each stack folder can
/// have a subfolder `TIFF` with links to the stack's DxO TIFFs (`tiffs`: photo file name -> TIFF file name), managed
/// the same way. Existing stack folders are recognised by the photos
/// their links point to and renamed when the stack's name changed. Existing items are never overwritten.
public enum LinkWriter {
    public static func outputFolder(for folder: URL, kind: StackKind = .focus) -> URL {
        folder.appendingPathComponent(kind.outputFolderName, isDirectory: true)
    }

    /// Writes the stacks of every kind into their own output folder. A kind without stacks is only processed when
    /// its folder exists (to clean up), so no empty output folders are made.
    public static func writeAll(stacks: [PhotoStack], in folder: URL, dryRun: Bool = false,
                                excluded: Set<String> = [], tiffs: [String: String] = [:]) -> LinkReport {
        var report = LinkReport()
        for kind in StackKind.allCases {
            let ofKind = stacks.filter { $0.kind == kind }
            guard !ofKind.isEmpty || fileType(atPath: outputFolder(for: folder, kind: kind).path) != nil else { continue }
            report.merge(write(stacks: ofKind, in: folder, kind: kind, dryRun: dryRun, excluded: excluded, tiffs: tiffs))
        }
        return report
    }

    /// Writes `stacks` (all of `kind`) into the kind's output folder.
    public static func write(stacks: [PhotoStack], in folder: URL, kind: StackKind = .focus, dryRun: Bool = false,
                             excluded: Set<String> = [], tiffs: [String: String] = [:]) -> LinkReport {
        let outputFolderName = kind.outputFolderName
        let fm = FileManager.default
        var report = LinkReport()
        let root = folder.standardizedFileURL.path
        let output = (root as NSString).appendingPathComponent(outputFolderName)
        func path(_ components: String...) -> String {
            components.reduce(output) { ($0 as NSString).appendingPathComponent($1) }
        }

        switch fileType(atPath: output) {
        case nil:
            if !dryRun {
                do {
                    try fm.createDirectory(atPath: output, withIntermediateDirectories: false)
                } catch {
                    report.problems.append("Kan map \(outputFolderName) niet maken: \(error.localizedDescription)")
                    return report
                }
            }
            report.foldersCreated += 1
        case .typeDirectory?:
            break
        default:
            report.problems.append("\(outputFolderName) bestaat al maar is geen gewone map; niets gedaan.")
            return report
        }

        // Names present in the output folder; kept up to date so dry runs see the same state as real runs.
        var present = Set((try? fm.contentsOfDirectory(atPath: output)) ?? [])
        var folders = present.sorted()
            .filter { fileType(atPath: path($0)) == .typeDirectory }
            .map { inventory(name: $0, at: path($0), root: root) }

        // 1. Remove broken links the app made earlier (their original was deleted).
        for index in folders.indices {
            for name in folders[index].brokenLinks {
                if dryRun || unlink(path(folders[index].name, name)) == 0 {
                    report.brokenLinksRemoved += 1
                } else {
                    report.problems.append("Kapotte link \(folders[index].name)/\(name) verwijderen mislukt: \(lastError())")
                    folders[index].otherItems.append(name)
                }
            }
        }

        // 1a. The same for TIFF links (the TIFF was deleted).
        let tiffFolder = DxOExports.subfolderName
        for index in folders.indices {
            guard var tiff = folders[index].tiff else { continue }
            for name in tiff.brokenLinks {
                if dryRun || unlink(path(folders[index].name, tiffFolder, name)) == 0 {
                    report.tiffLinksRemoved += 1
                } else {
                    report.problems.append("Kapotte link \(folders[index].name)/\(tiffFolder)/\(name) verwijderen mislukt: \(lastError())")
                    tiff.otherItems.append(name)
                }
            }
            tiff.brokenLinks = []
            folders[index].tiff = tiff
        }

        // 1b. Remove the app's own links of photos the user took out of their stack.
        for index in folders.indices {
            for name in folders[index].validLinks.intersection(excluded).sorted() {
                folders[index].validLinks.remove(name)
                if dryRun || unlink(path(folders[index].name, name)) == 0 {
                    report.excludedLinksRemoved += 1
                } else {
                    report.problems.append("Link \(folders[index].name)/\(name) verwijderen mislukt: \(lastError())")
                    folders[index].otherItems.append(name)
                }
            }
        }

        // 2. Match each stack to the existing folder whose links overlap most with it.
        let folderForStack = match(stacks, to: folders)
        let matchedFolders = Set(folderForStack.values)

        // 3. Remove unmatched folders that are now empty.
        for (index, existing) in folders.enumerated()
        where !matchedFolders.contains(index) && existing.validLinks.isEmpty && existing.otherItems.isEmpty
            && existing.tiff?.isEmpty != false {
            let dir = path(existing.name)
            if !dryRun {
                if let tiff = existing.tiff, !removeEmptyFolder(path(existing.name, tiffFolder), hasDSStore: tiff.hasDSStore) {
                    report.problems.append("Lege map \(existing.name)/\(tiffFolder) verwijderen mislukt: \(lastError())")
                    continue
                }
                if existing.hasDSStore, unlink((dir as NSString).appendingPathComponent(".DS_Store")) != 0 {
                    report.problems.append("Lege map \(existing.name) opruimen mislukt: \(lastError())")
                    continue
                }
                if rmdir(dir) != 0 {
                    report.problems.append("Lege map \(existing.name) verwijderen mislukt: \(lastError())")
                    continue
                }
            }
            present.remove(existing.name)
            report.foldersRemoved += 1
        }

        // 4. Rename matched folders whose stack name changed (e.g. photos were deleted).
        var folderName: [Int: String] = [:]
        for (stackIndex, folderIndex) in folderForStack.sorted(by: { $0.key < $1.key }) {
            let current = folders[folderIndex].name
            let desired = stacks[stackIndex].folderName
            folderName[stackIndex] = current
            guard current != desired else { continue }
            guard isSafeComponent(desired), !present.contains(desired) else {
                report.problems.append("Map \(current) kan niet hernoemd worden naar \(desired): die naam bestaat al.")
                continue
            }
            if !dryRun {
                do {
                    try fm.moveItem(atPath: path(current), toPath: path(desired))
                } catch {
                    report.problems.append("Map \(current) hernoemen mislukt: \(error.localizedDescription)")
                    continue
                }
            }
            present.remove(current)
            present.insert(desired)
            folderName[stackIndex] = desired
            report.foldersRenamed += 1
        }

        // 5. Create folders for new stacks.
        for (stackIndex, stack) in stacks.enumerated() where folderForStack[stackIndex] == nil {
            let name = stack.folderName
            guard isSafeComponent(name), !present.contains(name) else {
                report.problems.append("Map \(name) bestaat al of is ongeldig; stack overgeslagen.")
                continue
            }
            if !dryRun {
                do {
                    try fm.createDirectory(atPath: path(name), withIntermediateDirectories: false)
                } catch {
                    report.problems.append("Kan map \(name) niet maken: \(error.localizedDescription)")
                    continue
                }
            }
            present.insert(name)
            folderName[stackIndex] = name
            report.foldersCreated += 1
        }

        // 6. Add missing links.
        for (stackIndex, stack) in stacks.enumerated() {
            guard let dirName = folderName[stackIndex] else { continue }
            let existing = folderForStack[stackIndex].map { folders[$0] }
            for photo in stack.photos {
                let original = (root as NSString).appendingPathComponent(photo.fileName)
                guard isSafeComponent(photo.fileName), fileType(atPath: original) == .typeRegular else {
                    report.problems.append("\(photo.fileName): origineel niet gevonden of ongeldig pad; overgeslagen.")
                    continue
                }
                if existing?.validLinks.contains(photo.fileName) == true {
                    report.alreadyPresent += 1
                    continue
                }
                if existing?.otherItems.contains(photo.fileName) == true {
                    report.problems.append("\(dirName)/\(photo.fileName) bestaat al en is niet overschreven.")
                    continue
                }
                if !dryRun {
                    do {
                        try fm.createSymbolicLink(atPath: path(dirName, photo.fileName),
                                                  withDestinationPath: "../../" + photo.fileName)
                    } catch {
                        report.problems.append("Link \(photo.fileName) maken mislukt: \(error.localizedDescription)")
                        continue
                    }
                }
                report.created += 1
            }
        }

        // 7. Bring each stack's TIFF subfolder in line with its DxO TIFFs.
        for (stackIndex, stack) in stacks.enumerated() {
            guard let dirName = folderName[stackIndex] else { continue }
            var existing = folderForStack[stackIndex].flatMap { folders[$0].tiff }
            let desired = stack.photos.compactMap { tiffs[$0.fileName] }.filter(isSafeComponent)
            let dir = path(dirName, tiffFolder)

            if var inventory = existing {
                for name in inventory.validLinks.subtracting(desired).sorted() {
                    inventory.validLinks.remove(name)
                    if dryRun || unlink((dir as NSString).appendingPathComponent(name)) == 0 {
                        report.tiffLinksRemoved += 1
                    } else {
                        report.problems.append("Link \(dirName)/\(tiffFolder)/\(name) verwijderen mislukt: \(lastError())")
                        inventory.otherItems.append(name)
                    }
                }
                existing = inventory
            }
            if desired.isEmpty {
                if let inventory = existing, inventory.isEmpty, !dryRun,
                   !removeEmptyFolder(dir, hasDSStore: inventory.hasDSStore) {
                    report.problems.append("Lege map \(dirName)/\(tiffFolder) verwijderen mislukt: \(lastError())")
                }
                continue
            }
            if existing == nil {
                switch fileType(atPath: dir) {
                case nil:
                    if !dryRun {
                        do {
                            try fm.createDirectory(atPath: dir, withIntermediateDirectories: false)
                        } catch {
                            report.problems.append("Kan map \(dirName)/\(tiffFolder) niet maken: \(error.localizedDescription)")
                            continue
                        }
                    }
                case .typeDirectory?:
                    break
                default:
                    report.problems.append("\(dirName)/\(tiffFolder) bestaat al maar is geen map; TIFFs overgeslagen.")
                    continue
                }
            }
            for name in desired {
                guard fileType(atPath: (root as NSString).appendingPathComponent(name)) == .typeRegular else {
                    report.problems.append("\(name): TIFF niet gevonden; overgeslagen.")
                    continue
                }
                if existing?.validLinks.contains(name) == true { continue }
                if existing?.otherItems.contains(name) == true {
                    report.problems.append("\(dirName)/\(tiffFolder)/\(name) bestaat al en is niet overschreven.")
                    continue
                }
                if !dryRun {
                    do {
                        try fm.createSymbolicLink(atPath: (dir as NSString).appendingPathComponent(name),
                                                  withDestinationPath: "../../../" + name)
                    } catch {
                        report.problems.append("Link \(name) maken mislukt: \(error.localizedDescription)")
                        continue
                    }
                }
                report.tiffLinksCreated += 1
            }
        }
        return report
    }

    /// Removes a folder that holds nothing but possibly a .DS_Store (rmdir never removes anything else).
    private static func removeEmptyFolder(_ dir: String, hasDSStore: Bool) -> Bool {
        if hasDSStore, unlink((dir as NSString).appendingPathComponent(".DS_Store")) != 0 { return false }
        return rmdir(dir) == 0
    }

    // MARK: - Existing folders

    /// The contents of a stack folder or its TIFF subfolder.
    private struct LinkInventory {
        /// The app's own links whose original still exists.
        var validLinks: Set<String> = []
        /// The app's own links whose original is gone.
        var brokenLinks: [String] = []
        /// Everything else (user files, other links); never touched.
        var otherItems: [String] = []
        var hasDSStore = false

        var isEmpty: Bool { validLinks.isEmpty && brokenLinks.isEmpty && otherItems.isEmpty }
    }

    private struct ExistingFolder {
        let name: String
        var links: LinkInventory
        /// The TIFF subfolder, if there is one.
        var tiff: LinkInventory?

        var validLinks: Set<String> {
            get { links.validLinks }
            set { links.validLinks = newValue }
        }
        var brokenLinks: [String] { links.brokenLinks }
        var otherItems: [String] {
            get { links.otherItems }
            set { links.otherItems = newValue }
        }
        var hasDSStore: Bool { links.hasDSStore }
    }

    private static func inventory(name: String, at dir: String, root: String) -> ExistingFolder {
        var tiff: LinkInventory?
        let links = scanLinks(at: dir, prefix: "../../", root: root) { item, type in
            guard item == DxOExports.subfolderName, type == .typeDirectory else { return false }
            tiff = scanLinks(at: (dir as NSString).appendingPathComponent(item), prefix: "../../../", root: root)
            return true
        }
        var folder = ExistingFolder(name: name, links: links, tiff: tiff)
        // Files of the user in the TIFF subfolder keep the stack folder from being removed.
        if let tiff, !tiff.otherItems.isEmpty { folder.otherItems.append(DxOExports.subfolderName) }
        return folder
    }

    /// Classifies the items of `dir`; the app's own links are `<name>` -> `<prefix><name>`. Items for which
    /// `handled` returns true are left out.
    private static func scanLinks(at dir: String, prefix: String, root: String,
                                  handled: (String, FileAttributeType?) -> Bool = { _, _ in false }) -> LinkInventory {
        var inventory = LinkInventory()
        let fm = FileManager.default
        for item in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
            let itemPath = (dir as NSString).appendingPathComponent(item)
            let type = fileType(atPath: itemPath)
            if handled(item, type) { continue }
            if item == ".DS_Store", type == .typeRegular {
                inventory.hasDSStore = true
            } else if type == .typeSymbolicLink, isSafeComponent(item),
                      (try? fm.destinationOfSymbolicLink(atPath: itemPath)) == prefix + item {
                if fileType(atPath: (root as NSString).appendingPathComponent(item)) == nil {
                    inventory.brokenLinks.append(item)
                } else {
                    inventory.validLinks.insert(item)
                }
            } else {
                inventory.otherItems.append(item)
            }
        }
        return inventory
    }

    /// Greedy matching on the number of shared photos; an identical name wins ties.
    private static func match(_ stacks: [PhotoStack], to folders: [ExistingFolder]) -> [Int: Int] {
        var pairs: [(stack: Int, folder: Int, overlap: Int, sameName: Int)] = []
        for (stackIndex, stack) in stacks.enumerated() {
            let names = Set(stack.photos.map(\.fileName))
            for (folderIndex, folder) in folders.enumerated() {
                let overlap = names.intersection(folder.validLinks).count
                let sameName = folder.name == stack.folderName ? 1 : 0
                if overlap > 0 || sameName == 1 {
                    pairs.append((stackIndex, folderIndex, overlap, sameName))
                }
            }
        }
        pairs.sort { ($0.overlap, $0.sameName, -$0.stack, -$0.folder) > ($1.overlap, $1.sameName, -$1.stack, -$1.folder) }

        var result: [Int: Int] = [:]
        var usedFolders = Set<Int>()
        for pair in pairs where result[pair.stack] == nil && !usedFolders.contains(pair.folder) {
            result[pair.stack] = pair.folder
            usedFolders.insert(pair.folder)
        }
        return result
    }

    // MARK: - Helpers

    /// Type of the item itself (symlinks are not followed), nil if nothing exists there.
    private static func fileType(atPath path: String) -> FileAttributeType? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType
    }

    /// A single path component that cannot point outside its parent directory.
    private static func isSafeComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }

    private static func lastError() -> String {
        String(cString: strerror(errno))
    }
}
