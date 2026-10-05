import AppKit
import Observation
import StackCore

/// One detected stack in the overview. `key` stays the same while photos are taken out or trashed, so the
/// row keeps its expanded state.
struct StackEntry: Identifiable {
    let key: String
    /// All photos of the stack as detected, including the ones taken out of the stack (trashed ones removed).
    var detected: PhotoStack
    /// The stack without the photos taken out; nil when fewer than 2 photos remain.
    var active: PhotoStack?
    /// Photos of the active stack on which nothing is sharp.
    var unsharp: [PhotoInfo] = []

    var id: String { key }
    var name: String { (active ?? detected).folderName }

}

struct PreviewImages {
    /// The camera's embedded JPEG (3200 px).
    let preview: NSImage
    /// Size of the full RAW.
    let pixelSize: CGSize
}

struct PreviewTarget: Identifiable, Equatable {
    let entryKey: String
    let fileName: String
    var id: String { fileName }
}

/// A pending "move the originals to the Trash" that waits for confirmation.
struct TrashRequest: Identifiable {
    let entryKey: String
    let stackName: String
    /// The photos whose originals go, all from the same stack.
    let photos: [PhotoInfo]
    /// Their .ORF files and sidecars, and their DxO TIFFs with sidecars.
    let files: [URL]
    let tiffCount: Int
    /// Asked from the preview window (the confirmation shows there) or from the overview.
    let fromPreview: Bool
    /// The whole stack goes, asked with the trash button on its row.
    var wholeStack = false
    /// Only the DxO TIFFs of the stack go; the originals stay.
    var tiffsOnly = false
    var id: String { photos.map(\.fileName).joined(separator: ",") }

    var title: String {
        if tiffsOnly { return "DxO-TIFF's van stack naar Prullenmand?" }
        if wholeStack { return "Hele stack naar Prullenmand?" }
        return photos.count == 1 ? "Origineel naar Prullenmand?" : "\(photos.count) foto's naar Prullenmand?"
    }

    var message: String {
        let names = files.map(\.lastPathComponent)
        let shown = names.prefix(12).joined(separator: "\n") + (names.count > 12 ? "\n… en nog \(names.count - 12)" : "")
        let restore = "terug te zetten met Finder → Zet terug"
        let tiffs = tiffCount == 0 ? "" : tiffCount == 1 ? ", inclusief de DxO-TIFF" : ", inclusief \(tiffCount) DxO-TIFFs"
        if tiffsOnly {
            return "Stack \(stackName): \(names.count) bestanden (\(tiffCount) DxO-TIFFs en bijbestanden) gaan naar de Prullenmand "
                + "(\(restore)). De .ORF-originelen blijven staan.\n\n\(shown)"
        }
        if wholeStack {
            return "Stack \(stackName): alle \(photos.count) foto's, \(names.count) bestanden (.ORF en bijbestanden\(tiffs)) "
                + "gaan naar de Prullenmand (\(restore)). Andere stacks blijven ongemoeid.\n\n\(shown)"
        }
        guard photos.count > 1, let first = photos.first, let last = photos.last else {
            return "Deze bestanden gaan naar de Prullenmand (\(restore))\(tiffs):\n\n\(shown)"
        }
        return "\(first.stem) t/m \(last.stem) uit stack \(stackName): \(names.count) bestanden (.ORF en bijbestanden\(tiffs)) "
            + "gaan naar de Prullenmand (\(restore)). Andere stacks blijven ongemoeid.\n\n\(shown)"
    }
}

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case idle, scanning, scanned, writing, done
    }

    /// The folder that is analysed for stacks.
    var folder: URL?
    /// Top of the folder tree in the sidebar, and the folders (by standardised path) that are expanded in it.
    var rootFolder: URL?
    var expandedFolders = Set<String>()
    /// Sub folders of the root and of every expanded folder, by standardised path.
    var folderChildren: [String: [URL]] = [:]
    var phase: Phase = .idle
    var result: DetectionResult?
    var entries: [StackEntry] = []
    /// Shown kind of stack, nil for all kinds.
    var kindFilter: StackKind?
    /// Photos the user took out of their stack (stored in FocusStacks/.uitgesloten).
    var excluded = Set<String>()
    var report: LinkReport?
    var errorMessage: String?
    var alertMessage: String?
    var isDropTargeted = false
    var selection = Set<String>()
    var expanded = Set<String>()

    /// Tile measurements per photo, and per photo of an active stack how close it gets to the sharpest frame.
    private var tiles: [String: [Double]] = [:]
    var ratios: [String: Double] = [:]
    /// Measured / total stack photos while the sharpness measurement runs, nil otherwise.
    var sharpnessProgress: (done: Int, total: Int)?
    var sharpnessMeasured = false
    private var sharpnessToken: CancellationToken?

    /// Over- and underexposure of the photos of HDR stacks, measured on the sensor data.
    var exposure: [String: ExposureStats] = [:]
    /// Measured / total HDR photos while the exposure measurement runs, nil otherwise.
    var exposureProgress: (done: Int, total: Int)?
    private var exposureToken: CancellationToken?

    var preview: PreviewTarget?
    /// Bumped on every request to show the viewer, so the window comes forward even for the photo it already shows.
    var previewRequests = 0
    var zoomCommand = ZoomCommand()
    /// Current zoom of the preview (1 = 100% = one RAW pixel per screen pixel) and whether it is fitted.
    var previewMagnification = 0.0
    var previewIsFit = true
    /// Embedded previews with the size of the full RAW, and full RAW images (loaded when zoomed in), for the
    /// previewed photo and its neighbours.
    private var imageCache: [String: PreviewImages] = [:]
    private var fullImageCache: [String: NSImage] = [:]
    private var fullImageLoading = Set<String>()
    var trashRequest: TrashRequest?
    /// Small pictures for the stack rows (the camera's embedded thumbnail).
    var thumbnails: [String: NSImage] = [:]
    /// Larger pictures for the hover window (kept small: dropped when it grows).
    var hoverImages: [String: NSImage] = [:]
    /// DxO TIFF exports per photo (newest first), refreshed when the app becomes active again.
    var tiffIndex: [String: [TIFFFile]] = [:]
    /// Images that Helicon Focus / Photomatix Pro made of each stack (keyed by `StackEntry.key`), refreshed together
    /// with the DxO TIFFs.
    var resultIndex: [String: [StackResult]] = [:]
    private let softwareCache = SoftwareTagCache()
    private var resultsGeneration = 0

    /// Link updates run one after another.
    private let syncQueue = DispatchQueue(label: "PhotoStacks.sync")

    /// Apps chosen in the settings; a role without an entry uses its default (see `AppRole`).
    var chosenApps: [AppRole: ChosenApp] = AppModel.loadChosenApps()
    /// The apps of the roles that are installed, see `refreshApps()`.
    var apps: [AppRole: ResolvedApp] = [:]

    /// The output folders (FocusStacks, HDRStacks …) that exist.
    var outputFolders: [URL] {
        guard let folder else { return [] }
        return StackKind.allCases.map { LinkWriter.outputFolder(for: folder, kind: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    var hasOutputFolder: Bool { !outputFolders.isEmpty }
    var showReportDetails = false
    var activeStacks: [PhotoStack] { entries.compactMap(\.active) }

    /// The entries of the chosen kind.
    var visibleEntries: [StackEntry] {
        guard let kindFilter else { return entries }
        return entries.filter { $0.detected.kind == kindFilter }
    }

    /// Number of stacks per kind, for the kinds that occur.
    var kindCounts: [(kind: StackKind, count: Int)] {
        StackKind.allCases.compactMap { kind in
            let count = entries.filter { $0.detected.kind == kind }.count
            return count == 0 ? nil : (kind, count)
        }
    }

    /// The newest installed DxO PhotoLab (bundle identifiers com.dxo.PhotoLab<versie>).
    let photoLabURL = [11, 10, 9, 8, 7].lazy
        .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.dxo.PhotoLab\($0)") }
        .first

    /// Which files of a stack go to Helicon or Photomatix.
    enum SourceKind { case raw, tiff }

    init() {
        // Back from DxO PhotoLab: pick up new TIFF exports (only a directory listing).
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshTIFFs()
                self?.refreshResults()
                self?.refreshApps()
            }
        }
        refreshApps()
        restoreTree()
    }

    func entry(_ key: String) -> StackEntry? {
        entries.first { $0.key == key }
    }

    // MARK: - Folder and scanning

    /// Asks for the top folder of the tree and analyses it.
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Kies"
        panel.message = "Kies de startmap van de mapboom"
        if panel.runModal() == .OK, let url = panel.url {
            setRoot(url)
            selectFolder(url)
        }
    }

    /// A folder from outside the tree (dropped, "Open With", the sidebar): inside the tree it is selected there,
    /// elsewhere it becomes the new top of the tree.
    func open(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            errorMessage = "\(url.lastPathComponent) is geen map."
            return
        }
        if isInsideTree(url) {
            expandAncestors(of: url)
        } else {
            setRoot(url)
        }
        selectFolder(url)
    }

    private func selectFolder(_ url: URL) {
        folder = url
        scan()
        showMainWindow()
    }

    /// Brings the main window to the front (also when a folder arrives via Finder or the open panel).
    private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }?.makeKeyAndOrderFront(nil)
    }

    func scan() {
        guard let folder else { return }
        refreshTree()
        phase = .scanning
        selection = []
        expanded = []
        preview = nil
        imageCache = [:]
        fullImageCache = [:]
        sharpnessToken?.cancel()
        exposureToken?.cancel()
        exposure = [:]
        exposureProgress = nil
        tiles = [:]
        ratios = [:]
        sharpnessProgress = nil
        sharpnessMeasured = false
        result = nil
        entries = []
        tiffIndex = [:]
        resultIndex = [:]
        thumbnails = [:]
        hoverImages = [:]
        report = nil
        errorMessage = nil
        Task.detached {
            do {
                let photos = try ExifToolReader.readPhotos(in: folder)
                let result = StackDetector.detect(photos)
                let excluded = ExclusionStore.load(for: folder)
                let tiffs = DxOExports.scan(folder: folder, photos: result.stacks.flatMap(\.photos))
                await self.finishScan(result, excluded: excluded, tiffs: tiffs, for: folder)
            } catch {
                await self.fail(error, for: folder)
            }
        }
    }

    private func finishScan(_ result: DetectionResult, excluded: Set<String>, tiffs: [String: [TIFFFile]],
                            for folder: URL) {
        guard folder == self.folder else { return }
        self.result = result
        self.excluded = excluded
        tiffIndex = tiffs
        entries = result.stacks.map { StackEntry(key: $0.photos[0].fileName, detected: $0) }
        if let kindFilter, !entries.contains(where: { $0.detected.kind == kindFilter }) { self.kindFilter = nil }
        recompute()
        phase = .scanned
        refreshResults()
        measureSharpness(of: result.stacks, in: folder)
        measureExposure(of: result.stacks, in: folder)
    }

    /// Updates the active stacks and sharpness ratios after photos were taken out, put back or trashed.
    private func recompute() {
        var ratios: [String: Double] = [:]
        for index in entries.indices {
            let active = entries[index].detected.excluding(excluded)
            entries[index].active = active
            entries[index].unsharp = []
            guard let active, active.kind.measuresSharpness, !tiles.isEmpty else { continue }
            let stackRatios = SharpnessAnalyzer.ratios(tiles: SharpnessAnalyzer.stackTiles(active, tiles))
            ratios.merge(stackRatios) { $1 }
            entries[index].unsharp = active.photos.filter {
                (stackRatios[$0.fileName] ?? 1) < SharpnessAnalyzer.unsharpRatio
            }
        }
        self.ratios = ratios
    }

    // MARK: - Thumbnails

    /// The photo that represents a stack: its first photo.
    func thumbnailPhoto(for entry: StackEntry) -> PhotoInfo {
        (entry.active ?? entry.detected).photos[0]
    }

    func loadThumbnail(of photo: PhotoInfo) async {
        guard let folder, thumbnails[photo.fileName] == nil else { return }
        let url = folder.appendingPathComponent(photo.fileName)
        let image = await Task.detached(priority: .utility) { () -> NSImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceThumbnailMaxPixelSize: 160,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }.value
        guard folder == self.folder, let image else { return }
        thumbnails[photo.fileName] = image
    }

    /// A larger picture (the camera's embedded preview) for the floating window that follows the pointer.
    func loadHoverImage(of photo: PhotoInfo) async -> NSImage? {
        if let cached = hoverImages[photo.fileName] { return cached }
        guard let folder else { return nil }
        let url = folder.appendingPathComponent(photo.fileName)
        let image = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceThumbnailMaxPixelSize: 1440,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }.value
        guard folder == self.folder, let image else { return nil }
        if hoverImages.count >= 40 { hoverImages = [:] }
        hoverImages[photo.fileName] = image
        return image
    }

    // MARK: - DxO TIFFs

    func refreshTIFFs() {
        guard let folder, !entries.isEmpty else { return }
        let updated = DxOExports.scan(folder: folder, photos: entries.flatMap(\.detected.photos))
        if updated != tiffIndex { tiffIndex = updated }
    }

    /// Looks for images made by Helicon or Photomatix (directory listing, plus exiftool for files not read before),
    /// in the background.
    func refreshResults() {
        guard let folder, !entries.isEmpty else { return }
        let stacks = entries.map { (key: $0.key, stack: $0.detected) }
        let cache = softwareCache
        resultsGeneration += 1
        let generation = resultsGeneration
        Task.detached(priority: .utility) {
            let index = StackResults.scan(folder: folder, stacks: stacks) { names in
                cache.tags(for: names, in: folder) { files in
                    (try? ExifToolReader.readSoftware(files: files, in: folder)) ?? [:]
                }
            }
            await self.applyResults(index, for: folder, generation: generation)
        }
    }

    private func applyResults(_ index: [String: [StackResult]], for folder: URL, generation: Int) {
        guard folder == self.folder, generation == resultsGeneration, index != resultIndex else { return }
        resultIndex = index
    }

    func results(for entry: StackEntry) -> [StackResult] {
        resultIndex[entry.key] ?? []
    }

    /// Newest DxO TIFF per photo, as LinkWriter wants it.
    var tiffLinks: [String: String] {
        tiffIndex.compactMapValues { $0.first?.fileName }
    }

    func tiff(for photo: PhotoInfo) -> TIFFFile? {
        tiffIndex[photo.fileName]?.first
    }

    func tiffVersions(for photo: PhotoInfo) -> Int {
        tiffIndex[photo.fileName]?.count ?? 0
    }

    /// How many photos of the active stack have a DxO TIFF.
    func tiffCount(_ entry: StackEntry) -> (found: Int, total: Int) {
        let photos = entry.active?.photos ?? []
        return (photos.filter { tiffIndex[$0.fileName]?.isEmpty == false }.count, photos.count)
    }

    /// TIFF when every photo of the stack has a DxO TIFF, otherwise RAW.
    func defaultSourceKind(_ entry: StackEntry) -> SourceKind {
        let count = tiffCount(entry)
        return count.total > 0 && count.found == count.total ? .tiff : .raw
    }

    // MARK: - Links

    func createStacks() {
        guard let folder, !activeStacks.isEmpty else { return }
        phase = .writing
        refreshTIFFs()
        let stacks = activeStacks, excluded = excluded, tiffs = tiffLinks
        syncQueue.async {
            let report = LinkWriter.writeAll(stacks: stacks, in: folder, excluded: excluded, tiffs: tiffs)
            Task { @MainActor in self.finishWrite(report, for: folder) }
        }
    }

    /// After a photo was taken out, put back or trashed: update the output folders if they have stack folders already.
    private func syncIfNeeded() {
        guard let folder else { return }
        let hasStackFolders = outputFolders.contains { outputFolder in
            ((try? FileManager.default.contentsOfDirectory(atPath: outputFolder.path)) ?? []).contains { name in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: outputFolder.appendingPathComponent(name).path,
                                                      isDirectory: &isDirectory) && isDirectory.boolValue
            }
        }
        guard hasStackFolders else { return }
        let stacks = activeStacks, excluded = excluded, tiffs = tiffLinks
        syncQueue.async {
            let report = LinkWriter.writeAll(stacks: stacks, in: folder, excluded: excluded, tiffs: tiffs)
            Task { @MainActor in
                guard folder == self.folder else { return }
                self.report = report
            }
        }
    }

    /// The stack's folder in its kind's output folder, if it has been created.
    func stackFolder(for stack: PhotoStack) -> URL? {
        guard let folder else { return nil }
        let url = LinkWriter.outputFolder(for: folder, kind: stack.kind).appendingPathComponent(stack.folderName, isDirectory: true)
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            ? url : nil
    }

    // MARK: - Opening stacks and Finder

    /// Opens the stack in the app chosen for its kind (Helicon Focus for focus stacks and Photomatix Pro for HDR
    /// stacks, unless the settings say otherwise): the RAW files or the newest DxO TIFF of each photo.
    func openStack(_ stack: PhotoStack, kind: SourceKind) {
        guard let role = AppRole(stackKind: stack.kind), let app = apps[role] else { return }
        if app.loadsFolderArgument {
            openStackFolder(stack, kind: kind, in: app)
        } else {
            openStackFiles(stack, kind: kind, in: app)
        }
    }

    /// Opens the links in the stack's folder (or its TIFF subfolder), for Helicon Focus. FocusStacks is brought up to
    /// date first (so new DxO exports are included). Helicon ignores macOS "open documents" requests, but loads all
    /// images of a folder passed as command line argument; a new instance is started so this also works while
    /// Helicon is already open (each stack gets its own Helicon window).
    private func openStackFolder(_ stack: PhotoStack, kind: SourceKind, in app: ResolvedApp) {
        guard let folder else { return }
        let outputFolder = LinkWriter.outputFolder(for: folder, kind: stack.kind)
        refreshTIFFs()
        let stacks = activeStacks, excluded = excluded, tiffs = tiffLinks
        syncQueue.async {
            let report = LinkWriter.writeAll(stacks: stacks, in: folder, excluded: excluded, tiffs: tiffs)
            Task { @MainActor in
                guard folder == self.folder else { return }
                self.report = report
                var target = outputFolder.appendingPathComponent(stack.folderName, isDirectory: true)
                if kind == .tiff { target.appendPathComponent(DxOExports.subfolderName, isDirectory: true) }
                guard FileManager.default.fileExists(atPath: target.path) else {
                    self.alertMessage = "\(target.lastPathComponent) kon niet worden aangemaakt; zie de meldingen onderaan."
                    return
                }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.arguments = [target.path]
                configuration.createsNewApplicationInstance = true
                configuration.activates = true
                NSWorkspace.shared.openApplication(at: app.url, configuration: configuration) { _, error in
                    guard let error else { return }
                    Task { @MainActor in
                        self.alertMessage = "Openen in \(app.name) mislukt: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    /// Opens the stack's originals, or the newest DxO TIFF of each photo, as documents (Photomatix Pro merges them).
    private func openStackFiles(_ stack: PhotoStack, kind: SourceKind, in app: ResolvedApp) {
        guard let folder else { return }
        refreshTIFFs()
        let names = kind == .tiff ? stack.photos.compactMap { tiff(for: $0)?.fileName } : stack.photos.map(\.fileName)
        let urls = names.map { folder.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard urls.count >= 2 else {
            alertMessage = "De bestanden van \(stack.folderName) zijn niet (meer) gevonden."
            return
        }
        NSWorkspace.shared.open(urls, withApplicationAt: app.url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            Task { @MainActor in
                self.alertMessage = "Openen in \(app.name) mislukt: \(error.localizedDescription)"
            }
        }
    }

    /// The stack's photos for dragging: the links in its stack folder when that exists, otherwise the originals.
    func photoURLs(for stack: PhotoStack) -> [URL] {
        guard let folder else { return [] }
        let base = stackFolder(for: stack) ?? folder
        return stack.photos
            .map { base.appendingPathComponent($0.fileName) }
            .filter { (try? $0.checkResourceIsReachable()) == true }
    }

    /// Opens the original .ORF in DxO PhotoLab.
    /// Returns false when nothing was opened.
    @discardableResult
    func openInPhotoLab(_ photo: PhotoInfo) -> Bool {
        guard let photoLabURL else { return false }
        return open(fileName: photo.fileName, with: photoLabURL, appName: "DxO PhotoLab")
    }

    /// Opens a result of Helicon, Photomatix or Luminar (a file of the scanned folder) in the app chosen for results.
    @discardableResult
    func openResult(fileName: String) -> Bool {
        guard let app = apps[.result] else { return false }
        return open(fileName: fileName, with: app.url, appName: app.name)
    }

    private func open(fileName: String, with appURL: URL, appName: String) -> Bool {
        guard let folder else { return false }
        let url = folder.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            alertMessage = "\(fileName) is niet (meer) gevonden."
            return false
        }
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            Task { @MainActor in
                self.alertMessage = "Openen in \(appName) mislukt: \(error.localizedDescription)"
            }
        }
        return true
    }

    func revealUnsharp(_ entry: StackEntry) {
        guard let folder, !entry.unsharp.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(entry.unsharp.map { folder.appendingPathComponent($0.fileName) })
    }

    func reveal(_ entry: StackEntry) {
        guard let folder else { return }
        if let active = entry.active, let url = stackFolder(for: active) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(
                entry.detected.photos.map { folder.appendingPathComponent($0.fileName) })
        }
    }

    /// Selects the original .ORF files of the stack in the Finder (not the links in the stack folder).
    func revealOriginals(_ entry: StackEntry) {
        guard let folder else { return }
        let photos = (entry.active ?? entry.detected).photos
        NSWorkspace.shared.activateFileViewerSelecting(photos.map { folder.appendingPathComponent($0.fileName) })
    }

    func reveal(_ photo: PhotoInfo) {
        guard let folder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent(photo.fileName)])
    }

    func revealOutput() {
        let folders = outputFolders
        guard !folders.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(folders)
    }

    // MARK: - Taking photos out of a stack and trashing originals

    func exclude(_ photos: [PhotoInfo]) { setExcluded(photos, true) }

    func include(_ photos: [PhotoInfo]) { setExcluded(photos, false) }

    private func setExcluded(_ photos: [PhotoInfo], _ isExcluded: Bool) {
        guard let folder else { return }
        var updated = excluded
        let names = photos.map(\.fileName)
        if isExcluded { updated.formUnion(names) } else { updated.subtract(names) }
        guard updated != excluded else { return }
        do {
            try ExclusionStore.save(updated, for: folder)
        } catch {
            alertMessage = "Kon niet opslaan welke foto's uit de stack zijn: \(error.localizedDescription)"
            return
        }
        excluded = updated
        recompute()
        syncIfNeeded()
    }

    /// Asks for confirmation before moving the original .ORF files and their sidecars to the Trash.
    /// `photos` all belong to the stack `entryKey`.
    func requestTrash(_ photos: [PhotoInfo], entryKey: String, fromPreview: Bool, wholeStack: Bool = false) {
        guard let folder, let entry = entry(entryKey) else { return }
        refreshTIFFs()
        let present = photos.filter { entry.detected.photos.contains($0) }.compactMap { photo -> (PhotoInfo, [URL])? in
            let files = Sidecars.files(for: photo, in: folder)
            return files.contains { $0.lastPathComponent == photo.fileName } ? (photo, files) : nil
        }
        guard !present.isEmpty else {
            alertMessage = "\(photos.first?.fileName ?? "De foto") is niet (meer) gevonden."
            return
        }
        // The DxO TIFFs of these photos go along, each with its own sidecars (.dop …).
        let (tiffs, tiffFiles) = tiffFiles(of: present.map(\.0), in: folder)
        let files = present.flatMap(\.1) + tiffFiles.filter { url in !present.flatMap(\.1).contains(url) }
        trashRequest = TrashRequest(entryKey: entryKey, stackName: entry.name, photos: present.map(\.0),
                                    files: files, tiffCount: tiffs.count, fromPreview: fromPreview,
                                    wholeStack: wholeStack)
    }

    /// The DxO TIFFs of `photos`, each with its own sidecars (.dop …).
    private func tiffFiles(of photos: [PhotoInfo], in folder: URL) -> (tiffs: [TIFFFile], files: [URL]) {
        let tiffs = photos.flatMap { tiffIndex[$0.fileName] ?? [] }
        // A TIFF named exactly like its photo (OM1R5855.tif) shares the stem with the .ORF and its sidecars;
        // those belong to the original and must stay.
        let originals = Set(photos.flatMap { Sidecars.files(for: $0, in: folder) })
        let files = tiffs.flatMap { tiff -> [URL] in
            let own = Sidecars.files(forStem: (tiff.fileName as NSString).deletingPathExtension, first: tiff.fileName, in: folder)
            return own.filter { url in
                !originals.contains(url) || url.lastPathComponent.lowercased().hasPrefix(tiff.fileName.lowercased())
            }
        }
        return (tiffs, files)
    }

    /// Whether any photo of the stack (also those taken out) has a DxO TIFF.
    func hasTIFFs(_ entry: StackEntry) -> Bool {
        entry.detected.photos.contains { tiffIndex[$0.fileName]?.isEmpty == false }
    }

    /// Asks for confirmation before moving only the DxO TIFFs of the stack to the Trash.
    func requestTrashTIFFs(_ entry: StackEntry) {
        guard let folder else { return }
        refreshTIFFs()
        let (tiffs, files) = tiffFiles(of: entry.detected.photos, in: folder)
        guard !files.isEmpty else {
            alertMessage = "Deze stack heeft geen DxO-TIFF's."
            return
        }
        trashRequest = TrashRequest(entryKey: entry.key, stackName: entry.name, photos: entry.detected.photos,
                                    files: files, tiffCount: tiffs.count, fromPreview: false, tiffsOnly: true)
    }

    /// Every photo of the stack, also the ones taken out of it, e.g. when Helicon's result is saved and the
    /// originals are no longer needed.
    func requestTrashStack(_ entry: StackEntry) {
        requestTrash(entry.detected.photos, entryKey: entry.key, fromPreview: false, wholeStack: true)
    }

    /// The previewed photo and all photos after it in the same stack (also those taken out of the stack).
    func requestTrashFromPreviewOnwards() {
        guard let preview, let index = previewPhotos.firstIndex(where: { $0.fileName == preview.fileName }) else { return }
        requestTrash(Array(previewPhotos[index...]), entryKey: preview.entryKey, fromPreview: true)
    }

    func confirmTrash(_ request: TrashRequest) {
        guard let folder else { return }
        trashRequest = nil
        NSWorkspace.shared.recycle(request.files) { trashed, error in
            Task { @MainActor in
                self.finishTrash(request, trashed: Array(trashed.keys), error: error, folder: folder)
            }
        }
    }

    private func finishTrash(_ request: TrashRequest, trashed: [URL], error: Error?, folder: URL) {
        if let error {
            alertMessage = "Naar de Prullenmand verplaatsen is (deels) mislukt: \(error.localizedDescription)"
        }
        if request.tiffsOnly {
            guard folder == self.folder else { return }
            refreshTIFFs()
            syncIfNeeded()
            return
        }
        let trashedNames = Set(trashed.map(\.lastPathComponent))
        let removed = Set(request.photos.filter { trashedNames.contains($0.fileName) })
        guard folder == self.folder, !removed.isEmpty,
              let index = entries.firstIndex(where: { $0.key == request.entryKey })
        else { return }

        let photos = entries[index].detected.photos
        let previewPosition = photos.firstIndex { $0.fileName == preview?.fileName }
        let remaining = photos.filter { !removed.contains($0) }
        if remaining.isEmpty {
            entries.remove(at: index)
        } else {
            entries[index].detected = PhotoStack(photos: remaining)
        }
        for photo in removed {
            tiles[photo.fileName] = nil
            exposure[photo.fileName] = nil
            imageCache[photo.fileName] = nil
            fullImageCache[photo.fileName] = nil
        }
        let names = Set(removed.map(\.fileName))
        if !excluded.isDisjoint(with: names) {
            excluded.subtract(names)
            try? ExclusionStore.save(excluded, for: folder)
        }
        refreshTIFFs()
        recompute()
        syncIfNeeded()

        // The previewed photo is gone: show the next remaining one (or the one before when the tail went).
        if let previewPosition, removed.contains(photos[previewPosition]) {
            if remaining.isEmpty {
                closePreview()
            } else {
                let next = photos[previewPosition...].first { !removed.contains($0) }
                    ?? photos[..<previewPosition].last { !removed.contains($0) }
                if let next { showPreview(next, entryKey: request.entryKey) }
            }
        }
    }

    // MARK: - Preview

    func showPreview(_ photo: PhotoInfo, entryKey: String) {
        preview = PreviewTarget(entryKey: entryKey, fileName: photo.fileName)
        previewRequests += 1
    }

    func closePreview() {
        preview = nil
        imageCache = [:]
        fullImageCache = [:]
        previewMagnification = 0
        previewIsFit = true
    }

    /// The photos the preview steps through: all photos of the stack, including the ones taken out.
    var previewPhotos: [PhotoInfo] {
        preview.flatMap { entry($0.entryKey)?.detected.photos } ?? []
    }

    var previewPhoto: PhotoInfo? {
        previewPhotos.first { $0.fileName == preview?.fileName }
    }

    func movePreview(by offset: Int) {
        guard let preview, let index = previewPhotos.firstIndex(where: { $0.fileName == preview.fileName }) else { return }
        let next = index + offset
        guard previewPhotos.indices.contains(next) else { return }
        showPreview(previewPhotos[next], entryKey: preview.entryKey)
    }

    /// Takes the previewed photo out of its stack (or puts it back) and steps to the next one.
    func toggleExclusionInPreview() {
        guard let photo = previewPhoto else { return }
        if excluded.contains(photo.fileName) {
            include([photo])
        } else {
            exclude([photo])
            movePreview(by: 1)
        }
    }

    /// The image to show: the full RAW when it has been loaded, otherwise the embedded preview.
    var previewImage: NSImage? {
        guard let name = preview?.fileName else { return nil }
        return fullImageCache[name] ?? imageCache[name]?.preview
    }

    /// Size of the full RAW (with orientation applied).
    var previewPixelSize: CGSize? {
        preview.flatMap { imageCache[$0.fileName]?.pixelSize }
    }

    var previewIsFullResolution: Bool {
        preview.map { fullImageCache[$0.fileName] != nil } ?? false
    }

    /// True when the embedded preview would be shown enlarged at the current zoom.
    var needsFullResolution: Bool {
        guard let name = preview?.fileName, let images = imageCache[name], images.pixelSize.width > 0 else {
            return false
        }
        return previewMagnification > images.preview.size.width / images.pixelSize.width * 1.02
    }

    func zoom(_ kind: ZoomCommand.Kind) {
        zoomCommand = ZoomCommand(id: zoomCommand.id + 1, kind: kind)
    }

    func previewZoomChanged(_ magnification: Double, isFit: Bool) {
        previewMagnification = magnification
        previewIsFit = isFit
        if needsFullResolution, let photo = previewPhoto {
            Task {
                await loadFullImage(of: photo)
                for neighbour in previewNeighbours(of: photo) { await loadFullImage(of: neighbour) }
            }
        }
    }

    /// The next and previous photo in the preview (the next one first).
    private func previewNeighbours(of photo: PhotoInfo) -> [PhotoInfo] {
        let photos = previewPhotos
        guard let index = photos.firstIndex(of: photo) else { return [] }
        return [index + 1, index - 1].filter(photos.indices.contains).map { photos[$0] }
    }

    /// Loads the embedded preview (max 3200 px) of the previewed photo and its neighbours for quick stepping;
    /// while zoomed in also the full RAW images.
    func loadPreviewImage() async {
        guard let photo = previewPhoto else { return }
        await loadPreview(of: photo)
        guard previewPhoto == photo else { return }
        if needsFullResolution { await loadFullImage(of: photo) }

        // Keep the current photo and its neighbours.
        let neighbours = previewNeighbours(of: photo)
        let keep = Set([photo.fileName] + neighbours.map(\.fileName))
        imageCache = imageCache.filter { keep.contains($0.key) }
        fullImageCache = fullImageCache.filter { keep.contains($0.key) }
        for neighbour in neighbours {
            await loadPreview(of: neighbour)
            if needsFullResolution { await loadFullImage(of: neighbour) }
        }
    }

    private func loadPreview(of photo: PhotoInfo) async {
        guard let folder, imageCache[photo.fileName] == nil,
              let images = await Self.loadPreview(folder.appendingPathComponent(photo.fileName)),
              previewPhotos.contains(photo)
        else { return }
        imageCache[photo.fileName] = images
    }

    private func loadFullImage(of photo: PhotoInfo) async {
        guard let folder, fullImageCache[photo.fileName] == nil, !fullImageLoading.contains(photo.fileName),
              let pixelSize = imageCache[photo.fileName]?.pixelSize
        else { return }
        fullImageLoading.insert(photo.fileName)
        let image = await Self.loadFullImage(folder.appendingPathComponent(photo.fileName),
                                             maxPixelSize: Int(max(pixelSize.width, pixelSize.height)))
        fullImageLoading.remove(photo.fileName)
        guard let image, previewPhotos.contains(photo) else { return }
        fullImageCache[photo.fileName] = image
    }

    /// The camera's embedded JPEG preview, plus the size of the full RAW.
    private nonisolated static func loadPreview(_ url: URL) async -> PreviewImages? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceThumbnailMaxPixelSize: 3200,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            let preview = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
            guard let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int
            else { return PreviewImages(preview: preview, pixelSize: preview.size) }
            // Orientations 5–8 are rotated by 90°.
            let rotated = ((properties[kCGImagePropertyOrientation] as? Int) ?? 1) >= 5
            return PreviewImages(preview: preview,
                                 pixelSize: rotated ? CGSize(width: height, height: width) : CGSize(width: width, height: height))
        }.value
    }

    /// The RAW decoded at full size (about half a second).
    private nonisolated static func loadFullImage(_ url: URL, maxPixelSize: Int) async -> NSImage? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }.value
    }

    // MARK: - Sharpness

    /// Measures all stack photos (also those taken out, so they can be put back) in the background;
    /// only reads the originals.
    private func measureSharpness(of stacks: [PhotoStack], in folder: URL) {
        let photos = stacks.filter(\.kind.measuresSharpness).flatMap(\.photos)
        guard !photos.isEmpty else { return }
        let token = CancellationToken()
        sharpnessToken = token
        sharpnessProgress = (0, photos.count)
        Task.detached {
            let tiles = SharpnessAnalyzer.measure(photos, in: folder, isCancelled: { token.isCancelled }) { done in
                if done % 10 == 0 {
                    Task { @MainActor in self.updateSharpnessProgress(done, token: token) }
                }
            }
            await self.finishSharpness(tiles, token: token)
        }
    }

    private func updateSharpnessProgress(_ done: Int, token: CancellationToken) {
        guard token === sharpnessToken, let total = sharpnessProgress?.total else { return }
        sharpnessProgress = (max(done, sharpnessProgress?.done ?? 0), total)
    }

    private func finishSharpness(_ tiles: [String: [Double]], token: CancellationToken) {
        guard token === sharpnessToken, !token.isCancelled else { return }
        // Photos trashed during the measurement are no longer in any entry; that's fine.
        self.tiles = tiles
        recompute()
        sharpnessProgress = nil
        sharpnessMeasured = true
    }

    // MARK: - Exposure

    /// Measures how much of each HDR photo is clipped, in the background; only reads the originals.
    private func measureExposure(of stacks: [PhotoStack], in folder: URL) {
        let photos = stacks.filter(\.kind.measuresExposure).flatMap(\.photos)
        guard !photos.isEmpty else { return }
        let token = CancellationToken()
        exposureToken = token
        exposureProgress = (0, photos.count)
        Task.detached {
            let stats = ExposureAnalyzer.measure(photos, in: folder, isCancelled: { token.isCancelled }) { done in
                if done % 5 == 0 {
                    Task { @MainActor in self.updateExposureProgress(done, token: token) }
                }
            }
            await self.finishExposure(stats, token: token)
        }
    }

    private func updateExposureProgress(_ done: Int, token: CancellationToken) {
        guard token === exposureToken, let total = exposureProgress?.total else { return }
        exposureProgress = (max(done, exposureProgress?.done ?? 0), total)
    }

    private func finishExposure(_ stats: [String: ExposureStats], token: CancellationToken) {
        guard token === exposureToken, !token.isCancelled else { return }
        // Only photos that still exist (some may have been trashed during the measurement).
        let present = Set(entries.flatMap { $0.detected.photos.map(\.fileName) })
        exposure = stats.filter { present.contains($0.key) }
        exposureProgress = nil
    }

    /// Clipped highlights in the darkest frame and lost shadows in the brightest frame of the active stack.
    func exposureCoverage(_ entry: StackEntry) -> (highlights: Double, shadows: Double)? {
        entry.active.flatMap { ExposureAnalyzer.coverage(of: $0, stats: exposure) }
    }

    /// Exposure of a photo in stops relative to the first photo of its stack.
    /// Dynamic range in stops that the stack captures, once all its frames are measured.
    func sceneRange(_ entry: StackEntry) -> Double? {
        entry.active.flatMap { ExposureAnalyzer.sceneRange(of: $0, stats: exposure) }
    }

    func relativeEV(of photo: PhotoInfo, entryKey: String) -> Double? {
        entry(entryKey).flatMap { ExposureAnalyzer.relativeEV(of: photo, in: $0.detected, stats: exposure) }
    }

    private func finishWrite(_ report: LinkReport, for folder: URL) {
        guard folder == self.folder else { return }
        self.report = report
        phase = .done
    }

    private func fail(_ error: Error, for folder: URL) {
        guard folder == self.folder else { return }
        errorMessage = error.localizedDescription
        phase = .idle
    }
}

/// Lets a background measurement stop early when another folder is scanned.
final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
