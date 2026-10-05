import AppKit
import SwiftUI

/// The settings window (⌘,): which apps open stacks and result photos.
struct SettingsView: View {
    let model: AppModel

    var body: some View {
        Form {
            Section("Stacks openen met") {
                AppChoiceRow(model: model, role: .focusStack)
                AppChoiceRow(model: model, role: .hdrStack)
            }
            Section("Resultaten openen met") {
                AppChoiceRow(model: model, role: .result)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One setting: the chosen app (with its icon), a button to pick another one and one to go back to the default.
private struct AppChoiceRow: View {
    let model: AppModel
    let role: AppRole

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(role.title)
                Spacer(minLength: 12)
                if let icon = model.appIcon(for: role) {
                    Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                }
                if model.apps[role] == nil {
                    Text("\(model.appName(for: role)) (niet gevonden)").foregroundStyle(.orange)
                } else {
                    Text(model.appName(for: role))
                }
                Button("Kies…") { model.chooseApp(for: role) }
                Button("Standaard") { model.resetApp(for: role) }
                    .disabled(!model.isChosen(role))
                    .help("Terug naar \(role.defaultName)")
            }
            Text(role.detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
