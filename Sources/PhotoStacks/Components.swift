import StackCore
import SwiftUI

/// Chevron to expand or collapse a stack; turns when it opens and stays vertically centred in tall rows.
struct DisclosureChevron: View {
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 16, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isExpanded)
        .help(isExpanded ? "Inklappen (←)" : "Uitklappen (→)")
        .accessibilityLabel(isExpanded ? "Inklappen" : "Uitklappen")
    }
}

/// Small coloured label with an optional icon. On a selected (highlighted) row it turns white, like other
/// content of the row, so it stays readable on the accent colour.
struct Badge: View {
    let text: String
    var systemImage: String?
    let tint: Color
    @Environment(\.backgroundProminence) private var prominence

    private var isOnSelection: Bool { prominence == .increased }

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage).imageScale(.small)
            }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .monospacedDigit()
        .lineLimit(1)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .foregroundStyle(isOnSelection ? Color.white : tint)
        .background(isOnSelection ? Color.white.opacity(0.22) : tint.opacity(0.13), in: Capsule())
        .fixedSize()
    }
}

/// Sharpness of every photo of a stack, from first to last, as a small bar chart.
struct SharpnessSparkline: View {
    let ratios: [Double]
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let onSelection = prominence == .increased
        Canvas { context, size in
            guard !ratios.isEmpty else { return }
            let gap: CGFloat = ratios.count > 40 ? 0.5 : 1
            let width = max(1, (size.width - gap * CGFloat(ratios.count - 1)) / CGFloat(ratios.count))
            for (index, ratio) in ratios.enumerated() {
                let height = max(2, size.height * CGFloat(min(max(ratio, 0), 1)))
                let rect = CGRect(x: CGFloat(index) * (width + gap), y: size.height - height, width: width, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: min(1, width / 2)),
                             with: .color(SharpnessBar.color(for: ratio, onSelection: onSelection)))
            }
        }
        .frame(width: 110, height: 20)
        .help("Scherpte per foto, van de eerste tot de laatste foto van de stack. Rood: niets scherp.")
        .accessibilityLabel("Scherpte per foto")
    }
}

/// Bottom bar with counts, progress and the result of the last update of FocusStacks.
struct StatusBar: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 16) {
            if let result = model.result {
                Label("\(result.totalPhotos) foto's", systemImage: "photo.on.rectangle")
                Label("\(model.activeStacks.count) stacks", systemImage: "square.stack.3d.up")
                if !model.excluded.isEmpty {
                    Label("\(model.excluded.count) uit stack", systemImage: "minus.circle")
                }
                if !result.loosePhotos.isEmpty {
                    Label("\(result.loosePhotos.count) los", systemImage: "square.dashed")
                        .help("Reeksfoto's (bracketing, ProCap, serie) die geen stack vormen (alleen staand)")
                }
            }
            if let progress = model.sharpnessProgress {
                HStack(spacing: 6) {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                        .frame(width: 90)
                    Text("Scherpte meten")
                }
            } else if model.sharpnessMeasured {
                let unsharp = model.entries.reduce(0) { $0 + $1.unsharp.count }
                Label(unsharp == 0 ? "Alles scherp" : "\(unsharp) onscherp",
                      systemImage: unsharp == 0 ? "checkmark.circle" : "camera.metering.unknown")
                    .foregroundStyle(unsharp == 0 ? Color.secondary : Color.red)
            }
            Spacer(minLength: 8)
            if model.phase == .writing {
                ProgressView().controlSize(.small)
                Text("FocusStacks bijwerken…")
            } else if let report = model.report {
                reportButton(report)
            } else {
                Text("Originelen blijven onaangeroerd")
                    .help("Alleen links in FocusStacks; een origineel gaat alleen na bevestiging naar de Prullenmand.")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func reportButton(_ report: LinkReport) -> some View {
        let hasProblems = !report.problems.isEmpty
        return Button {
            model.showReportDetails.toggle()
        } label: {
            Label(hasProblems ? "\(report.problems.count) meldingen" : "FocusStacks bijgewerkt",
                  systemImage: hasProblems ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(hasProblems ? Color.orange : Color.green)
        }
        .buttonStyle(.plain)
        .help("Details van de laatste update van FocusStacks")
        .popover(isPresented: Binding(get: { model.showReportDetails }, set: { model.showReportDetails = $0 }),
                 arrowEdge: .top) {
            ReportDetails(report: report)
        }
    }
}

struct ReportDetails: View {
    let report: LinkReport

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Laatste update van FocusStacks").font(.headline)
            ForEach(Self.lines(report), id: \.self) { line in
                Text(line)
            }
            if !report.problems.isEmpty {
                Divider()
                ForEach(report.problems, id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
        }
        .font(.callout)
        .padding(14)
        .frame(minWidth: 280, maxWidth: 520, alignment: .leading)
    }

    static func lines(_ report: LinkReport) -> [String] {
        var lines = ["\(report.created) links aangemaakt, \(report.alreadyPresent) bestonden al"]
        if report.foldersCreated > 0 { lines.append("\(report.foldersCreated) mappen aangemaakt") }
        if report.foldersRenamed > 0 { lines.append("\(report.foldersRenamed) mappen hernoemd") }
        if report.brokenLinksRemoved > 0 { lines.append("\(report.brokenLinksRemoved) kapotte links opgeruimd") }
        if report.excludedLinksRemoved > 0 { lines.append("\(report.excludedLinksRemoved) links van uitgesloten foto's weggehaald") }
        if report.tiffLinksCreated > 0 { lines.append("\(report.tiffLinksCreated) TIFF-links aangemaakt") }
        if report.tiffLinksRemoved > 0 { lines.append("\(report.tiffLinksRemoved) TIFF-links weggehaald") }
        if report.foldersRemoved > 0 { lines.append("\(report.foldersRemoved) lege mappen verwijderd") }
        return lines
    }
}

/// Shown over the window while a folder is dragged onto it.
struct DropHighlight: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
            Label("Laat los om deze map te scannen", systemImage: "folder.badge.plus")
                .font(.title3.weight(.medium))
                .foregroundStyle(Color.accentColor)
        }
        .padding(10)
        .allowsHitTesting(false)
    }
}
