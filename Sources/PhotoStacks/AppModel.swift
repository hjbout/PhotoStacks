import AppKit
import Observation
import StackCore

/// One detected stack in the overview. `key` stays the same while photos are taken out or trashed, so the
/// row keeps its expanded state.
struct StackEntry: Identifiable {
    let key: String
    /// All photos of the stack as detected, including the ones taken out of the stack (trashed ones removed).
    var detected: FocusStack
    /// The stack without the photos taken out; nil when fewer than 2 photos remain.
    var active: FocusStack?
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
    var id: String { photos.map(\.fileName).joined(separator: ",") }

    var title: String {
        if wholeStack { return "Hele stack naar Prullenmand?" }
        return photos.count == 1 ? "Origineel naar Prullenmand?" : "\(photos.count) foto's naar Prullenmand?"
    }

    var message: String {
        let names = files.map(\.lastPathComponent)
        let shown = names.prefix(12).joined(separator: "\n") + (names.count > 12 ? "\n… en nog \(names.count - 12)" : "")
        let restore = "terug te zetten met Finder → Zet terug"
        let tiffs = tiffCount == 0 ? "" : tiffCount == 1 ? ", inclusief de DxO-TIFF" : ", inclusief \(tiffCount) DxO-TIFFs"
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

    var folder: URL?
    var phase: Phase = .idle
    var result: DetectionResult?
    var entries: [StackEntry] = []
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

    var preview: PreviewTarget?
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
    /// DxO TIFF exports per photo (newest first), refreshed when the app becomes active again.
    var tiffIndex: [String: [TIFFFile]] = [:]

    /// Link updates run one after another.
    private let syncQueue = DispatchQueue(label: "PhotoStacks.sync")

    let heliconURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.heliconsoft.heliconfocus")

    var outputFolder: URL? { folder.map(LinkWriter.outputFolder(for:)) }
    var hasOutputFolder: Bool { outputFolder.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    var showReportDetails = false
    var activeStacks: [FocusStack] { entries.compactMap(\.active) }

    /// The newest installed DxO PhotoLab (bundle identifiers com.dxo.PhotoLab<versie>).
    let photoLabURL = [11, 10, 9, 8, 7].lazy
        .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.dxo.PhotoLab\($0)") }
        .first

    enum HeliconKind { case raw, tiff }

    init() {
        // Back from DxO PhotoLab: pick up new TIFF exports (only a directory listing).
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshTIFFs() }
        }
    }

    func entry(_ key: String) -> StackEntry? {
        entries.first { $0.key == key }
    }

    // MARK: - Folder and scanning

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Kies"
        panel.message = "Kies de map met .ORF-bestanden"
        if panel.runModal() == .OK, let url = panel.url {
            open(url)
        }
    }

    func open(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            errorMessage = "\(url.lastPathComponent) is geen map."
            return
        }
        folder = url
        scan()
    }

    func scan() {
        guard let folder else { return }
        phase = .scanning
        selection = []
        expanded = []
        preview = nil
        imageCache = [:]
        fullImageCache = [:]
        sharpnessToken?.cancel()
        tiles = [:]
        ratios = [:]
        sharpnessProgress = nil
        sharpnessMeasured = false
        result = nil
        entries = []
        tiffIndex = [:]
        thumbnails = [:]
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
        recompute()
        phase = .scanned
        measureSharpness(of: result.stacks, in: folder)
    }

    /// Updates the active stacks and sharpness ratios after photos were taken out, put back or trashed.
    private func recompute() {
        var ratios: [String: Double] = [:]
        for index in entries.indices {
            let active = entries[index].detected.excluding(excluded)
            entries[index].active = active
            entries[index].unsharp = []
            guard let active, !tiles.isEmpty else { continue }
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

    // MARK: - DxO TIFFs

    func refreshTIFFs() {
        guard let folder, !entries.isEmpty else { return }
        let updated = DxOExports.scan(folder: folder, photos: entries.flatMap(\.detected.photos))
        if updated != tiffIndex { tiffIndex = updated }
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
    func defaultHeliconKind(_ entry: StackEntry) -> HeliconKind {
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
            let report = LinkWriter.write(stacks: stacks, in: folder, excluded: excluded, tiffs: tiffs)
            Task { @MainActor in self.finishWrite(report, for: folder) }
        }
    }

    /// After a photo was taken out, put back or trashed: update FocusStacks if it has stack folders already.
    private func syncIfNeeded() {
        guard let folder, let outputFolder else { return }
        let hasStackFolders = ((try? FileManager.default.contentsOfDirectory(atPath: outputFolder.path)) ?? [])
            .contains { name in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: outputFolder.appendingPathComponent(name).path,
                                                      isDirectory: &isDirectory) && isDirectory.boolValue
            }
        guard hasStackFolders else { return }
        let stacks = activeStacks, excluded = excluded, tiffs = tiffLinks
        syncQueue.async {
            let report = LinkWriter.write(stacks: stacks, in: folder, excluded: excluded, tiffs: tiffs)
            Task { @MainActor in
                guard folder == self.folder else { return }
                self.report = report
            }
        }
    }

    /// The stack's folder in FocusStacks, if it has been created.
    func stackFolder(for stack: FocusStack) -> URL? {
        guard let outputFolder else { return nil }
        let url = outputFolder.appendingPathComponent(stack.folderName, isDirectory: true)
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            ? url : nil
    }

    // MARK: - Helicon and Finder

    /// Opens the stack in Helicon Focus: the RAW links in its stack folder or the TIFF links in its TIFF subfolder.
    /// FocusStacks is brought up to date first (so new DxO exports are included). Helicon ignores macOS "open
    /// documents" requests, but loads all images of a folder passed as command line argument; a new instance is
    /// started so this also works while Helicon is already open (each stack gets its own Helicon window).
    func openInHelicon(_ stack: FocusStack, kind: HeliconKind) {
        guard let heliconURL, let folder, let outputFolder else { return }
        refreshTIFFs()
        let stacks = activeStacks, excluded = excluded, tiffs = tiffLinks
        syncQueue.async {
            let report = LinkWriter.write(stacks: stacks, in: folder, excluded: excluded, tiffs: tiffs)
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
                NSWorkspace.shared.openApplication(at: heliconURL, configuration: configuration) { _, error in
                    guard let error else { return }
                    Task { @MainActor in
                        self.alertMessage = "Openen in Helicon Focus mislukt: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    /// The stack's photos for dragging: the links in its stack folder when that exists, otherwise the originals.
    func photoURLs(for stack: FocusStack) -> [URL] {
        guard let folder else { return [] }
        let base = stackFolder(for: stack) ?? folder
        return stack.photos
            .map { base.appendingPathComponent($0.fileName) }
            .filter { (try? $0.checkResourceIsReachable()) == true }
    }

    /// Opens the original .ORF in DxO PhotoLab.
    func openInPhotoLab(_ photo: PhotoInfo) {
        guard let photoLabURL, let folder else { return }
        let url = folder.appendingPathComponent(photo.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            alertMessage = "\(photo.fileName) is niet (meer) gevonden."
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: photoLabURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            Task { @MainActor in
                self.alertMessage = "Openen in DxO PhotoLab mislukt: \(error.localizedDescription)"
            }
        }
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

    func reveal(_ photo: PhotoInfo) {
        guard let folder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent(photo.fileName)])
    }

    func revealOutput() {
        guard let outputFolder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([outputFolder])
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
        let tiffs = present.flatMap { tiffIndex[$0.0.fileName] ?? [] }
        let tiffFiles = tiffs.flatMap { tiff in
            Sidecars.files(forStem: (tiff.fileName as NSString).deletingPathExtension, first: tiff.fileName, in: folder)
        }
        let files = present.flatMap(\.1) + tiffFiles.filter { url in !present.flatMap(\.1).contains(url) }
        trashRequest = TrashRequest(entryKey: entryKey, stackName: entry.name, photos: present.map(\.0),
                                    files: files, tiffCount: tiffs.count, fromPreview: fromPreview,
                                    wholeStack: wholeStack)
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
            entries[index].detected = FocusStack(photos: remaining)
        }
        for photo in removed {
            tiles[photo.fileName] = nil
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
    private func measureSharpness(of stacks: [FocusStack], in folder: URL) {
        let photos = stacks.flatMap(\.photos)
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
