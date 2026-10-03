import AppKit
import StackCore
import SwiftUI

/// Receives folders dropped on the app icon or opened via "Open With" / `open -a PhotoStacks <map>`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Plain reference instead of @State: the SwiftUI macro plugin is not part of the Command Line Tools.
    let model = AppModel()

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        model.open(url)
    }
}

struct PhotoStacksApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private var model: AppModel { appDelegate.model }

    var body: some Scene {
        Window("PhotoStacks", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 960, minHeight: 520)
        }
        .defaultSize(width: 1120, height: 720)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Kies map…") { model.chooseFolder() }
                    .keyboardShortcut("o")
                Button("Opnieuw scannen") { model.scan() }
                    .keyboardShortcut("r")
                    .disabled(model.folder == nil || model.phase == .scanning)
            }
        }
        Window("Voorbeeld", id: PreviewView.windowID) {
            PreviewView(model: model)
        }
        .defaultSize(width: 1200, height: 860)
        .windowToolbarStyle(.unified)
    }
}

struct ContentView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if model.result != nil { StatusBar(model: model) }
            }
            .navigationTitle(model.folder?.lastPathComponent ?? "PhotoStacks")
            .navigationSubtitle(model.folder.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "")
            .toolbar { toolbar }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                model.open(url)
                return true
            } isTargeted: { model.isDropTargeted = $0 }
            .overlay {
                if model.isDropTargeted { DropHighlight() }
            }
            .onChange(of: model.preview?.fileName) { _, fileName in
                if fileName != nil { openWindow(id: PreviewView.windowID) }
            }
            .modifier(ModelAlerts(model: model, inPreview: false))
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            if model.kindCounts.count > 1 {
                let filter = Binding(get: { model.kindFilter }, set: { model.kindFilter = $0; model.selection = [] })
                Picker("Soort", selection: filter) {
                    Text("Alle (\(model.entries.count))").tag(StackKind?.none)
                    ForEach(model.kindCounts, id: \.kind) { item in
                        Text("\(item.kind.title) (\(item.count))").tag(StackKind?.some(item.kind))
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Toon alleen stacks van één soort")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.chooseFolder() } label: {
                Label("Kies map", systemImage: "folder.badge.plus")
            }
            .help("Kies een map met .ORF-bestanden (⌘O)")
            Button { model.scan() } label: {
                Label("Opnieuw scannen", systemImage: "arrow.clockwise")
            }
            .help("Map opnieuw scannen (⌘R)")
            .disabled(model.folder == nil || model.phase == .scanning || model.phase == .writing)
            Button { model.revealOutput() } label: {
                Label("Toon in Finder", systemImage: "folder")
            }
            .help("Toon de stack-mappen (FocusStacks, HDRStacks …) in de Finder")
            .disabled(!model.hasOutputFolder)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { model.createStacks() } label: {
                Label("Maak stacks", systemImage: "square.stack.3d.up.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .help("Maak of werk de stack-mappen met links bij in FocusStacks, HDRStacks, ProCap en Series")
            .disabled(model.phase != .scanned && model.phase != .done || model.activeStacks.isEmpty)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.errorMessage {
            ContentUnavailableView {
                Label("Er ging iets mis", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Opnieuw proberen") { model.scan() }
                    .disabled(model.folder == nil)
            }
        } else if model.phase == .scanning {
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Foto's lezen…").foregroundStyle(.secondary)
            }
        } else if model.result != nil {
            if model.entries.isEmpty {
                ContentUnavailableView(
                    "Geen reeksen gevonden",
                    systemImage: "square.stack.3d.up.slash",
                    description: Text("\(model.result?.totalPhotos ?? 0) ORF-bestanden gescand, maar geen focus-, HDR-, ProCap- of serie-reeksen.")
                )
            } else {
                stackTable
            }
        } else {
            ContentUnavailableView {
                Label("Kies een map", systemImage: "square.stack.3d.down.right")
            } description: {
                Text("Sleep een map met .ORF-bestanden hierheen of op het app-icoon.")
            } actions: {
                Button("Kies map…") { model.chooseFolder() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
    }

    // MARK: - Table

    /// Stacks with, when expanded, their photos underneath.
    private var rows: [StackRow] {
        model.visibleEntries.flatMap { entry -> [StackRow] in
            let photos = model.expanded.contains(entry.key)
                ? entry.detected.photos.map { StackRow.photo($0, entryKey: entry.key) } : []
            return [StackRow.stack(key: entry.key)] + photos
        }
    }

    private var stackTable: some View {
        let selection = Binding(get: { model.selection }, set: { model.selection = $0 })
        return Table(rows, selection: selection) {
            TableColumn("Stack") { row in nameCell(row).fixedRowHeight() }
                .width(min: 300, ideal: 380)
            TableColumn("Status") { row in statusCell(row).fixedRowHeight() }
                .width(min: 160, ideal: 250)
            TableColumn("Scherpte") { row in sharpnessCell(row).fixedRowHeight() }
                .width(min: 130, ideal: 140)
            TableColumn("") { row in actionCell(row).fixedRowHeight() }
                .width(min: 180, ideal: 190)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .contextMenu(forSelectionType: String.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            // Double-click: a stack expands or collapses, a photo opens in the preview.
            guard let id = ids.first, let row = row(for: id) else { return }
            switch row {
            case let .stack(key):
                toggle(key)
            case let .photo(photo, entryKey):
                model.showPreview(photo, entryKey: entryKey)
            }
        }
        .onDeleteCommand {
            // ⌫ takes the selected photos out of their stack.
            let photos = model.selection.compactMap { id -> PhotoInfo? in
                if case let .photo(photo, _)? = row(for: id), !model.excluded.contains(photo.fileName) { return photo }
                return nil
            }
            model.exclude(photos)
        }
        .onKeyPress(keys: [.rightArrow, .leftArrow]) { press in
            // → / ← expand or collapse the selected stacks, like in the Finder.
            let keys = model.selection.compactMap { id -> String? in
                if case let .stack(key)? = row(for: id) { return key }
                return nil
            }
            guard !keys.isEmpty else { return .ignored }
            withAnimation(.easeInOut(duration: 0.15)) {
                if press.key == .rightArrow { model.expanded.formUnion(keys) } else { model.expanded.subtract(keys) }
            }
            return .handled
        }
    }

    private func toggle(_ key: String) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if model.expanded.contains(key) { model.expanded.remove(key) } else { model.expanded.insert(key) }
        }
    }

    private func row(for id: String) -> StackRow? {
        if id.hasPrefix("s:") {
            return .stack(key: String(id.dropFirst(2)))
        }
        let fileName = String(id.dropFirst(2))
        for entry in model.entries {
            if let photo = entry.detected.photos.first(where: { $0.fileName == fileName }) {
                return .photo(photo, entryKey: entry.key)
            }
        }
        return nil
    }

    @ViewBuilder
    private func nameCell(_ row: StackRow) -> some View {
        switch row {
        case let .stack(key):
            if let entry = model.entry(key) {
                HStack(spacing: 10) {
                    DisclosureChevron(isExpanded: model.expanded.contains(key)) { toggle(key) }
                    Image(systemName: entry.detected.kind.systemImage)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                        .help(entry.detected.kind.title)
                    StackThumbnail(model: model, entry: entry)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(entry.name)
                            .font(.body.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(entry.active == nil ? .secondary : .primary)
                        Text(subtitle(entry))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        case let .photo(photo, _):
            let isExcluded = model.excluded.contains(photo.fileName)
            HStack(spacing: 8) {
                Text(photo.stem)
                    .monospacedDigit()
                    .strikethrough(isExcluded)
                    .foregroundStyle(isExcluded ? .secondary : .primary)
                if let shot = photo.shot {
                    Text("Shot \(shot)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.leading, 26)  // under the thumbnail of the stack
        }
    }

    /// Every row has the same height: SwiftUI's Table doesn't reliably handle rows of different heights (after
    /// expanding or collapsing a stack some rows keep the height of the row that used to be at their position).
    static let rowHeight: CGFloat = 32

    private func subtitle(_ entry: StackEntry) -> String {
        guard let active = entry.active else { return "Te weinig foto's over" }
        let out = entry.detected.count - active.count
        var parts = ["\(active.count) foto's", "Shot \(active.firstShot)–\(active.lastShot)"]
        if model.kindFilter == nil { parts.insert(active.kind.title, at: 0) }
        if out > 0 { parts.append("\(out) uit stack") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func statusCell(_ row: StackRow) -> some View {
        switch row {
        case let .stack(key):
            if let entry = model.entry(key), let active = entry.active {
                let missing = active.kind.reportsMissingShots ? active.missingShots : []
                let tiffs = model.tiffCount(entry)
                HStack(spacing: 4) {
                    if !entry.unsharp.isEmpty {
                        Badge(text: "\(entry.unsharp.count) onscherp", systemImage: "camera.metering.unknown", tint: .red)
                            .help("Niets scherp op: " + entry.unsharp.map(\.stem).joined(separator: ", "))
                    }
                    if tiffs.found > 0 {
                        Badge(text: "TIFF \(tiffs.found)/\(tiffs.total)", systemImage: "photo.stack",
                              tint: tiffs.found == tiffs.total ? .purple : .orange)
                            .help("DxO-TIFFs gevonden voor \(tiffs.found) van de \(tiffs.total) foto's"
                                + (tiffs.found == tiffs.total ? "; standaard worden de TIFFs geopend." : "; standaard worden de RAW-bestanden geopend."))
                    }
                    if !missing.isEmpty {
                        Badge(text: "Mist \(ShotRanges.describe(missing))", systemImage: "exclamationmark.triangle", tint: .orange)
                            .help("Shot \(ShotRanges.describe(missing)) ontbreekt (verwijderd of uit de stack gehaald).")
                    }
                }
            }
        case let .photo(photo, _):
            HStack(spacing: 4) {
                if model.excluded.contains(photo.fileName) {
                    Badge(text: "Uit stack", systemImage: "minus.circle", tint: .secondary)
                }
                if let tiff = model.tiff(for: photo) {
                    let versions = model.tiffVersions(for: photo)
                    Badge(text: versions > 1 ? "TIFF ×\(versions)" : "TIFF", tint: versions > 1 ? .orange : .purple)
                        .help(versions > 1 ? "\(versions) DxO-TIFFs; de nieuwste wordt gebruikt: \(tiff.fileName)"
                            : "DxO-TIFF: \(tiff.fileName)")
                }
            }
        }
    }

    @ViewBuilder
    private func sharpnessCell(_ row: StackRow) -> some View {
        switch row {
        case let .stack(key):
            if model.sharpnessProgress != nil {
                ProgressView().controlSize(.small)
            } else if let active = model.entry(key)?.active, active.kind.measuresSharpness {
                SharpnessSparkline(ratios: active.photos.map { model.ratios[$0.fileName] ?? 0 })
            }
        case let .photo(photo, _):
            if model.excluded.contains(photo.fileName) {
                EmptyView()
            } else if let ratio = model.ratios[photo.fileName] {
                SharpnessBar(ratio: ratio)
            } else if model.sharpnessProgress != nil {
                ProgressView().controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func actionCell(_ row: StackRow) -> some View {
        switch row {
        case let .stack(key):
            if let entry = model.entry(key) {
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    if let active = entry.active {
                        FileDragHandle { model.photoURLs(for: active) }
                            .frame(width: 18, height: 16)
                            .help("Sleep de foto's van deze stack naar een andere app of de Finder")
                        appButton(entry, active: active)
                    }
                    Menu {
                        Button("Hele stack naar Prullenmand…") { model.requestTrashStack(entry) }
                        Button("Alleen DxO-TIFF's naar Prullenmand…") { model.requestTrashTIFFs(entry) }
                            .disabled(!model.hasTIFFs(entry))
                    } label: {
                        Image(systemName: "trash")
                    } primaryAction: {
                        model.requestTrashStack(entry)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.visible)
                    .fixedSize()
                    .foregroundStyle(.secondary)
                    .help("Klik: hele stack met alle foto's naar de Prullenmand; pijltje: alleen de DxO-TIFF's (altijd met bevestiging)")
                }
            }
        case let .photo(photo, entryKey):
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                photoLabButton(photo)
                Button {
                    model.showPreview(photo, entryKey: entryKey)
                } label: {
                    Image(systemName: "eye")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Foto groot bekijken (of dubbelklik)")
            }
        }
    }

    private func photoLabButton(_ photo: PhotoInfo) -> some View {
        Button {
            model.openInPhotoLab(photo)
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .disabled(model.photoLabURL == nil)
        .help(model.photoLabURL == nil ? "DxO PhotoLab is niet gevonden." : "Open deze foto in DxO PhotoLab")
    }

    /// The app that processes a stack of this kind: Helicon Focus for focus stacks, Photomatix for HDR; bursts
    /// have none (the best frame is picked in the preview).
    private func app(for kind: StackKind) -> (name: String, url: URL?, open: (PhotoStack, AppModel.SourceKind) -> Void)? {
        switch kind {
        case .focus: ("Helicon", model.heliconURL, model.openInHelicon)
        case .hdr: ("Photomatix", model.photomatixURL, model.openInPhotomatix)
        case .proCap, .series: nil
        }
    }

    private func appName(_ name: String) -> String {
        name == "Helicon" ? "Helicon Focus" : "Photomatix Pro"
    }

    /// Opens the stack in its app; with DxO TIFFs a menu offers RAW or TIFF, and a click on the button itself opens
    /// TIFF when every photo has one.
    @ViewBuilder
    private func appButton(_ entry: StackEntry, active: PhotoStack) -> some View {
        if let app = app(for: active.kind) {
            let tiffs = model.tiffCount(entry)
            if tiffs.found == 0 {
                Button {
                    app.open(active, .raw)
                } label: {
                    Label(app.name, systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(app.url == nil)
                .help(app.url == nil ? "\(appName(app.name)) is niet gevonden." : "Open deze stack in \(appName(app.name))")
            } else {
                let kind = model.defaultSourceKind(entry)
                Menu {
                    Button("RAW (.ORF)") { app.open(active, .raw) }
                    Button("TIFF (DxO) – \(tiffs.found)/\(tiffs.total)") { app.open(active, .tiff) }
                } label: {
                    Label(kind == .tiff ? "\(app.name) TIFF" : "\(app.name) RAW", systemImage: "arrow.up.forward.app")
                } primaryAction: {
                    app.open(active, kind)
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
                .disabled(app.url == nil)
                .help("Klik: open de \(kind == .tiff ? "TIFFs" : "RAW-bestanden") in \(appName(app.name)); pijltje: kies RAW of TIFF")
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<String>) -> some View {
        if ids.count == 1, let id = ids.first, let row = row(for: id) {
            switch row {
            case let .stack(key):
                if let entry = model.entry(key) {
                    if let active = entry.active, let app = app(for: active.kind) {
                        Button("Open RAW in \(appName(app.name))") { app.open(active, .raw) }
                            .disabled(app.url == nil)
                        if model.tiffCount(entry).found > 0 {
                            Button("Open TIFF in \(appName(app.name))") { app.open(active, .tiff) }
                                .disabled(app.url == nil)
                        }
                    }
                    Button("Toon in Finder") { model.reveal(entry) }
                    Button("Hele stack naar Prullenmand…") { model.requestTrashStack(entry) }
                    Button("Alleen DxO-TIFF's naar Prullenmand…") { model.requestTrashTIFFs(entry) }
                        .disabled(!model.hasTIFFs(entry))
                    if !entry.unsharp.isEmpty {
                        Button("Toon onscherpe foto's in Finder") { model.revealUnsharp(entry) }
                    }
                }
            case let .photo(photo, entryKey):
                Button("Bekijk") { model.showPreview(photo, entryKey: entryKey) }
                Button("Open in DxO PhotoLab") { model.openInPhotoLab(photo) }
                    .disabled(model.photoLabURL == nil)
                if model.excluded.contains(photo.fileName) {
                    Button("Terug in stack") { model.include([photo]) }
                } else {
                    Button("Uit stack") { model.exclude([photo]) }
                }
                Button("Origineel naar Prullenmand…") { model.requestTrash([photo], entryKey: entryKey, fromPreview: false) }
                Divider()
                Button("Toon in Finder") { model.reveal(photo) }
            }
        } else {
            let photos = ids.compactMap { id -> PhotoInfo? in
                if case let .photo(photo, _)? = row(for: id) { return photo }
                return nil
            }
            if !photos.isEmpty {
                Button("\(photos.count) foto's uit stack") { model.exclude(photos) }
                Button("\(photos.count) foto's terug in stack") { model.include(photos) }
            }
        }
    }
}

/// A row in the overview: a stack (expandable) or one of its photos.
enum StackRow: Identifiable, Hashable {
    case stack(key: String)
    case photo(PhotoInfo, entryKey: String)

    var id: String {
        switch self {
        case let .stack(key): "s:" + key
        case let .photo(photo, _): "p:" + photo.fileName
        }
    }
}

/// Small picture of a stack (its first photo); click to open it in the preview.
struct StackThumbnail: View {
    let model: AppModel
    let entry: StackEntry

    var body: some View {
        let photo = model.thumbnailPhoto(for: entry)
        PhotoThumbnail(model: model, photo: photo, width: 38)
            .opacity(entry.active == nil ? 0.5 : 1)
            .onTapGesture { model.showPreview(photo, entryKey: entry.key) }
            .help("\(photo.stem) – klik om groot te bekijken")
    }
}

/// The camera's embedded thumbnail of a photo, loaded lazily.
struct PhotoThumbnail: View {
    let model: AppModel
    let photo: PhotoInfo
    let width: CGFloat

    var body: some View {
        Group {
            if let image = model.thumbnails[photo.fileName] {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: width, height: width * 3 / 4)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
        .contentShape(Rectangle())
        .task(id: photo.fileName) { await model.loadThumbnail(of: photo) }
    }
}

extension View {
    /// The fixed height of every row in the stack table.
    func fixedRowHeight() -> some View {
        frame(height: ContentView.rowHeight)
    }
}
