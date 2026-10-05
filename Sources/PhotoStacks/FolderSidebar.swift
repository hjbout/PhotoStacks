import AppKit
import SwiftUI

/// Folder tree below a chosen top folder; selecting a folder analyses it for stacks.
struct FolderSidebar: View {
    let model: AppModel

    var body: some View {
        let selection = Binding<String?>(
            get: { model.folder?.standardizedFileURL.path },
            set: { id in
                guard let id, let row = model.folderRows.first(where: { $0.id == id }) else { return }
                model.open(row.url)
            }
        )
        List(model.folderRows, selection: selection) { row in
            rowView(row)
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .overlay {
            if model.rootFolder == nil {
                Text("Kies een startmap om de mappen eronder te doorzoeken.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(24)
            }
        }
        .onKeyPress(keys: [.rightArrow, .leftArrow]) { press in
            // → / ← expand or collapse the selected folder.
            guard let id = selection.wrappedValue, let row = model.folderRows.first(where: { $0.id == id }),
                  row.hasChildren != false else { return .ignored }
            withAnimation(.easeInOut(duration: 0.15)) {
                model.setExpanded([row.url], press.key == .rightArrow)
            }
            return .handled
        }
    }

    private var header: some View {
        Button { model.chooseFolder() } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder.badge.plus")
                Text(model.rootFolder?.lastPathComponent ?? "Kies startmap…")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .help(model.rootFolder.map { ($0.path as NSString).abbreviatingWithTildeInPath + " – klik om een andere startmap te kiezen" }
            ?? "Kies de startmap van de mapboom (⌘O)")
    }

    private func rowView(_ row: FolderRow) -> some View {
        HStack(spacing: 4) {
            if row.hasChildren == false {
                Color.clear.frame(width: 16, height: 24)
            } else {
                DisclosureChevron(isExpanded: model.expandedFolders.contains(row.id)) {
                    withAnimation(.easeInOut(duration: 0.15)) { model.toggleFolder(row.url) }
                }
            }
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            Text(row.name)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.leading, CGFloat(row.depth) * 14)
        .help(row.url.path)
    }
}
