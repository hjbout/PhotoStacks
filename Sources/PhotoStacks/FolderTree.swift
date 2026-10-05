import AppKit
import StackCore

/// One visible line of the folder tree in the sidebar.
struct FolderRow: Identifiable {
    let url: URL
    let depth: Int
    /// nil while the sub folders have not been read yet.
    let hasChildren: Bool?

    var id: String { url.standardizedFileURL.path }
    var name: String { url.lastPathComponent }
}

extension AppModel {
    private static let rootKey = "rootFolder"
    private static let expandedKey = "expandedFolders"

    /// The tree as visible lines: the root and, below every expanded folder, its sub folders.
    var folderRows: [FolderRow] {
        guard let rootFolder else { return [] }
        var rows: [FolderRow] = []
        func add(_ url: URL, depth: Int) {
            let path = url.standardizedFileURL.path
            let children = folderChildren[path]
            rows.append(FolderRow(url: url, depth: depth, hasChildren: children.map { !$0.isEmpty }))
            if expandedFolders.contains(path), let children {
                for child in children { add(child, depth: depth + 1) }
            }
        }
        add(rootFolder, depth: 0)
        return rows
    }

    func isInsideTree(_ url: URL) -> Bool {
        guard let rootFolder else { return false }
        let root = rootFolder.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }

    // MARK: - Root and expansion

    func setRoot(_ url: URL) {
        rootFolder = url
        expandedFolders = []
        folderChildren = [:]
        loadChildren(of: url)
        saveTree()
    }

    func toggleFolder(_ url: URL) {
        let path = url.standardizedFileURL.path
        if expandedFolders.contains(path) {
            expandedFolders.remove(path)
        } else {
            expandedFolders.insert(path)
            loadChildren(of: url)
        }
        saveTree()
    }

    func setExpanded(_ urls: [URL], _ expanded: Bool) {
        for url in urls {
            let path = url.standardizedFileURL.path
            if expanded {
                expandedFolders.insert(path)
                loadChildren(of: url)
            } else {
                expandedFolders.remove(path)
            }
        }
        saveTree()
    }

    /// Opens the folders between the root and `url`, so that `url` is visible in the tree.
    func expandAncestors(of url: URL) {
        guard let rootFolder, isInsideTree(url) else { return }
        var ancestors: [URL] = []
        var current = url.standardizedFileURL.deletingLastPathComponent()
        let root = rootFolder.standardizedFileURL
        while current.path.count >= root.path.count {
            ancestors.append(current)
            if current == root { break }
            current = current.deletingLastPathComponent()
        }
        for ancestor in ancestors.reversed() {
            expandedFolders.insert(ancestor.path)
            loadChildren(of: ancestor)
        }
        saveTree()
    }

    /// Reads the sub folders again (after a rescan, folders may have been added or removed).
    func refreshTree() {
        guard let rootFolder else { return }
        let paths = expandedFolders.union([rootFolder.standardizedFileURL.path])
        folderChildren = [:]
        for path in paths where FileManager.default.fileExists(atPath: path) {
            loadChildren(of: URL(fileURLWithPath: path, isDirectory: true))
        }
        expandedFolders = expandedFolders.filter { folderChildren[$0] != nil }
    }

    /// The sub folders of `url`, without hidden folders, packages and the folders this app writes its links to.
    private func loadChildren(of url: URL) {
        let fm = FileManager.default
        let own = Set(StackKind.allCases.map(\.outputFolderName))
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        let contents = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys,
                                                    options: [.skipsHiddenFiles])) ?? []
        let folders = contents.filter { child in
            guard !own.contains(child.lastPathComponent) else { return false }
            let resolved = child.resolvingSymlinksInPath()
            let values = try? resolved.resourceValues(forKeys: Set(keys))
            return values?.isDirectory == true && values?.isPackage != true
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        folderChildren[url.standardizedFileURL.path] = folders
    }

    // MARK: - Remembering the tree

    func saveTree() {
        let defaults = UserDefaults.standard
        defaults.set(rootFolder?.standardizedFileURL.path, forKey: Self.rootKey)
        defaults.set(Array(expandedFolders), forKey: Self.expandedKey)
    }

    func restoreTree() {
        let defaults = UserDefaults.standard
        guard let path = defaults.string(forKey: Self.rootKey),
              FileManager.default.fileExists(atPath: path) else { return }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        rootFolder = root
        loadChildren(of: root)
        for expanded in defaults.stringArray(forKey: Self.expandedKey) ?? [] {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue,
                  isInsideTree(URL(fileURLWithPath: expanded)) else { continue }
            expandedFolders.insert(expanded)
            loadChildren(of: URL(fileURLWithPath: expanded, isDirectory: true))
        }
    }
}
