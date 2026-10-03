import AppKit
import StackCore
import SwiftUI

/// Large view of one stack photo, to step through a stack and take photos out or trash them.
struct PreviewView: View {
    static let windowID = "preview"

    let model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        imageArea
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .frame(minWidth: 760, minHeight: 520)
            .navigationTitle(model.previewPhoto?.stem ?? "Voorbeeld")
            .navigationSubtitle(subtitle)
            .toolbar { toolbar }
            .background { shortcuts }
            .task(id: model.preview?.fileName) { await model.loadPreviewImage() }
            .onChange(of: model.preview == nil) { _, isClosed in
                if isClosed { dismissWindow(id: Self.windowID) }
            }
            .onAppear {
                // Restored at launch without a photo to show.
                if model.preview == nil { dismissWindow(id: Self.windowID) }
            }
            .onDisappear { model.closePreview() }
            .modifier(ModelAlerts(model: model, inPreview: true))
    }

    /// The viewer has done its job once the photo is open in PhotoLab.
    private func openInPhotoLab(_ photo: PhotoInfo) {
        if model.openInPhotoLab(photo) { model.closePreview() }
    }

    private var isExcluded: Bool {
        model.previewPhoto.map { model.excluded.contains($0.fileName) } ?? false
    }

    /// "Shot 5 · OM1R5855-OM1R5896 (34) · 5 van 34"
    private var subtitle: String {
        guard let photo = model.previewPhoto else { return "" }
        var parts: [String] = []
        if let shot = photo.shot { parts.append("Shot \(shot)") }
        if let entry = model.preview.flatMap({ model.entry($0.entryKey) }) { parts.append(entry.name) }
        if let index = model.previewPhotos.firstIndex(of: photo) {
            parts.append("\(index + 1) van \(model.previewPhotos.count)")
        }
        return parts.joined(separator: " · ")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            ControlGroup {
                Button { model.movePreview(by: -1) } label: { Label("Vorige", systemImage: "chevron.left") }
                    .help("Vorige foto (←)")
                Button { model.movePreview(by: 1) } label: { Label("Volgende", systemImage: "chevron.right") }
                    .help("Volgende foto (→)")
            }
            .controlGroupStyle(.navigation)
        }
        ToolbarItem(placement: .status) {
            if let photo = model.previewPhoto {
                if isExcluded {
                    Badge(text: "Uit stack", systemImage: "minus.circle", tint: .orange)
                } else if let ratio = model.ratios[photo.fileName] {
                    SharpnessBar(ratio: ratio)
                }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            ControlGroup {
                Button { model.zoom(.zoomOut) } label: { Label("Uitzoomen", systemImage: "minus.magnifyingglass") }
                    .help("Uitzoomen (⌘−)")
                Button { model.zoom(.toggle) } label: {
                    Text("\(Int((model.previewMagnification * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(minWidth: 44)
                }
                .help("Wissel tussen passend en 100% (Z of klik op de foto). 100% = één pixel van de RAW"
                    + (model.previewIsFullResolution ? " (volledige resolutie geladen)." : "."))
                Button { model.zoom(.zoomIn) } label: { Label("Inzoomen", systemImage: "plus.magnifyingglass") }
                    .help("Inzoomen (⌘+), of knijp met twee vingers op het trackpad")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if let photo = model.previewPhoto, let entryKey = model.preview?.entryKey {
                Button { openInPhotoLab(photo) } label: {
                    Label("DxO PhotoLab", systemImage: "slider.horizontal.3")
                }
                .disabled(model.photoLabURL == nil)
                .help(model.photoLabURL == nil ? "DxO PhotoLab is niet gevonden." : "Open het origineel in DxO PhotoLab (⌘E)")
                Button { model.reveal(photo) } label: { Label("Toon in Finder", systemImage: "folder") }
                    .help("Toon het origineel in de Finder")
                Button { model.toggleExclusionInPreview() } label: {
                    Label(isExcluded ? "Terug in stack" : "Uit stack",
                          systemImage: isExcluded ? "arrow.uturn.backward.circle" : "minus.circle")
                }
                .help(isExcluded ? "Zet de foto terug in de stack (⌫)"
                    : "Haal de foto uit de stack; het origineel blijft staan (⌫)")
                let following = followingCount(after: photo)
                Button {
                    model.requestTrash([photo], entryKey: entryKey, fromPreview: true)
                } label: {
                    Label("Prullenmand", systemImage: "trash")
                        .labelStyle(.titleAndIcon)
                }
                .help("Deze foto (.ORF, bijbestanden en DxO-TIFF) naar de Prullenmand (⌘⌫)")
                Button {
                    model.requestTrashFromPreviewOnwards()
                } label: {
                    Label("Deze + volgende", systemImage: "trash.fill")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(following == 0)
                .help(following == 0 ? "Dit is de laatste foto van de stack; er komen geen foto's meer na."
                    : "Deze foto en de \(following) foto's die erna komen in deze stack naar de Prullenmand (⇧⌘⌫)")
            }
        }
    }

    /// Keyboard shortcuts for actions that live in toolbar menus (and for stepping and zooming).
    private var shortcuts: some View {
        Group {
            Button("") { model.movePreview(by: -1) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { model.movePreview(by: 1) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { model.zoom(.toggle) }.keyboardShortcut("z", modifiers: [])
            Button("") { if let photo = model.previewPhoto { openInPhotoLab(photo) } }
                .keyboardShortcut("e", modifiers: .command)
            Button("") { model.zoom(.zoomIn) }.keyboardShortcut("=", modifiers: .command)
            Button("") { model.zoom(.zoomOut) }.keyboardShortcut("-", modifiers: .command)
            Button("") { model.toggleExclusionInPreview() }.keyboardShortcut(.delete, modifiers: [])
            Button("") {
                if let photo = model.previewPhoto, let entryKey = model.preview?.entryKey {
                    model.requestTrash([photo], entryKey: entryKey, fromPreview: true)
                }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            Button("") { model.requestTrashFromPreviewOnwards() }.keyboardShortcut(.delete, modifiers: [.command, .shift])
            Button("") { dismissWindow(id: Self.windowID) }.keyboardShortcut(.cancelAction)
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var imageArea: some View {
        // Stays in place while stepping through the stack, so zoom and position are kept.
        ZoomableImageView(image: model.previewImage, pixelSize: model.previewPixelSize ?? .zero,
                          command: model.zoomCommand) { magnification, isFit in
            model.previewZoomChanged(magnification, isFit: isFit)
        }
        .overlay {
            if model.previewImage == nil {
                ProgressView().controlSize(.large).tint(.white)
            }
        }
        .overlay(alignment: .topTrailing) {
            if model.needsFullResolution && !model.previewIsFullResolution {
                Label("RAW laden…", systemImage: "hourglass")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(12)
            }
        }
    }
}

extension PreviewView {
    /// Number of photos after `photo` in the previewed stack.
    func followingCount(after photo: PhotoInfo) -> Int {
        guard let index = model.previewPhotos.firstIndex(of: photo) else { return 0 }
        return model.previewPhotos.count - index - 1
    }
}

/// Bar with percentage: how close a photo gets to the sharpest photo of its stack in its best spot.
struct SharpnessBar: View {
    let ratio: Double
    @Environment(\.backgroundProminence) private var prominence

    private var color: Color { Self.color(for: ratio, onSelection: prominence == .increased) }

    /// Red, orange or green; on a selected row shades of white (fainter = less sharp), so it stays readable.
    static func color(for ratio: Double, onSelection: Bool = false) -> Color {
        let level = ratio < SharpnessAnalyzer.unsharpRatio ? 0 : ratio < 0.5 ? 1 : 2
        if onSelection { return Color.white.opacity([0.4, 0.65, 0.95][level]) }
        return [Color.red, .orange, .green][level].opacity(0.9)
    }

    var body: some View {
        let percentage = Int((ratio * 100).rounded())
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                Capsule().fill(prominence == .increased ? Color.white.opacity(0.25) : Color.secondary.opacity(0.25))
                Capsule().fill(color).frame(width: 50 * min(max(ratio, 0.04), 1))
            }
            .frame(width: 50, height: 6)
            Text("\(percentage)%").monospacedDigit().font(.callout)
        }
        .help("Scherpte \(percentage)%: hoe scherp het scherpste deel is, vergeleken met de scherpste foto van de stack op diezelfde plek. Onder \(Int(SharpnessAnalyzer.unsharpRatio * 100))% is er niets scherp.")
    }
}

/// The confirmation for trashing an original and general messages, shown in the window the action came from
/// (messages go to the preview window while that is open).
struct ModelAlerts: ViewModifier {
    let model: AppModel
    let inPreview: Bool

    func body(content: Content) -> some View {
        content
            .alert(
                model.trashRequest?.title ?? "Naar Prullenmand?",
                isPresented: Binding(
                    get: { model.trashRequest?.fromPreview == inPreview },
                    set: { if !$0 { model.trashRequest = nil } }
                ),
                presenting: model.trashRequest
            ) { request in
                Button("Naar Prullenmand", role: .destructive) { model.confirmTrash(request) }
                Button("Annuleer", role: .cancel) {}
            } message: { request in
                Text(request.message)
            }
            .alert(
                "PhotoStacks",
                isPresented: Binding(
                    get: { model.alertMessage != nil && (model.preview != nil) == inPreview },
                    set: { if !$0 { model.alertMessage = nil } }
                )
            ) {
                Button("OK") {}
            } message: {
                Text(model.alertMessage ?? "")
            }
    }
}
