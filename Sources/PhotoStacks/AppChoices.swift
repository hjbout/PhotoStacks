import AppKit
import StackCore
import UniformTypeIdentifiers

/// What an app can be chosen for in the settings.
enum AppRole: String, CaseIterable, Identifiable {
    case focusStack, hdrStack, result

    var id: String { rawValue }

    /// The role of the app that processes stacks of this kind (none for bursts: the best frame is picked in the viewer).
    init?(stackKind: StackKind) {
        switch stackKind {
        case .focus: self = .focusStack
        case .hdr: self = .hdrStack
        case .proCap, .series: return nil
        }
    }

    var title: String {
        switch self {
        case .focusStack: "Focusstacks"
        case .hdrStack: "HDR-stacks"
        case .result: "Resultaatfoto's"
        }
    }

    var detail: String {
        switch self {
        case .focusStack: "Voor de knop en het contextmenu van een focusstack."
        case .hdrStack: "Voor de knop en het contextmenu van een HDR-stack."
        case .result: "Voor de blauwe resultaat-badge in de kolom Status (Helicon, Photomatix, Luminar Neo)."
        }
    }

    /// The app that is used as long as none is chosen: bundle identifiers, most preferred first.
    var defaultBundleIdentifiers: [String] {
        switch self {
        case .focusStack: ["com.heliconsoft.heliconfocus"]
        case .hdrStack: ["com.hdrsoft.PhotomatixPro"]
        case .result: [11, 10, 9, 8, 7].map { "com.dxo.PhotoLab\($0)" }  // the newest installed DxO PhotoLab
        }
    }

    var defaultName: String {
        switch self {
        case .focusStack: "Helicon Focus"
        case .hdrStack: "Photomatix Pro"
        case .result: "DxO PhotoLab"
        }
    }

    /// Grey symbol of the technique on the stack's button: macro for focus stacking, contrast for HDR.
    var systemImage: String {
        switch self {
        case .focusStack: "camera.macro"
        case .hdrStack: "circle.lefthalf.filled"
        case .result: "slider.horizontal.3"
        }
    }
}

/// An app picked in the settings. The path leads; the identifier finds the app again when it was moved.
struct ChosenApp: Codable, Equatable {
    var path: String
    var bundleIdentifier: String?
}

/// An app that is installed and ready to be used.
struct ResolvedApp: Equatable {
    let url: URL
    let name: String
    /// Helicon Focus ignores macOS "open documents" requests; it loads the images of a folder given as an argument.
    let loadsFolderArgument: Bool
}

extension AppModel {
    private static let chosenAppsKey = "chosenApps"
    static let heliconBundleIdentifier = "com.heliconsoft.heliconfocus"

    /// The apps saved in the settings (role → app).
    static func loadChosenApps() -> [AppRole: ChosenApp] {
        guard let data = UserDefaults.standard.data(forKey: chosenAppsKey),
              let stored = try? JSONDecoder().decode([String: ChosenApp].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: stored.compactMap { key, app in AppRole(rawValue: key).map { ($0, app) } })
    }

    private func saveChosenApps() {
        let stored = Dictionary(uniqueKeysWithValues: chosenApps.map { ($0.key.rawValue, $0.value) })
        UserDefaults.standard.set(try? JSONEncoder().encode(stored), forKey: Self.chosenAppsKey)
    }

    /// Looks up the installed apps again (once at launch, after a choice and when the app becomes active), so the table
    /// rows don't have to ask LaunchServices.
    func refreshApps() {
        var found: [AppRole: ResolvedApp] = [:]
        for role in AppRole.allCases {
            if let app = resolve(role) { found[role] = app }
        }
        if found != apps { apps = found }
    }

    private func resolve(_ role: AppRole) -> ResolvedApp? {
        let workspace = NSWorkspace.shared
        let url: URL?
        if let chosen = chosenApps[role] {
            let direct = URL(fileURLWithPath: chosen.path)
            url = FileManager.default.fileExists(atPath: direct.path)
                ? direct : chosen.bundleIdentifier.flatMap { workspace.urlForApplication(withBundleIdentifier: $0) }
        } else {
            url = role.defaultBundleIdentifiers.lazy.compactMap { workspace.urlForApplication(withBundleIdentifier: $0) }.first
        }
        guard let url else { return nil }
        // The default apps keep their well-known names (their files are called HeliconFocus.app, DXOPhotoLab10.app …).
        return ResolvedApp(url: url, name: chosenApps[role] == nil ? role.defaultName : Self.appName(at: url),
                           loadsFolderArgument: Bundle(url: url)?.bundleIdentifier == Self.heliconBundleIdentifier)
    }

    /// The app's own name: its display name or bundle name, otherwise its file name without ".app".
    private static func appName(at url: URL) -> String {
        let bundle = Bundle(url: url)
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let name = bundle?.object(forInfoDictionaryKey: key) as? String, !name.isEmpty { return name }
        }
        return url.deletingPathExtension().lastPathComponent
    }

    /// Name of the app for a role, also when it can't be found (then the name of the chosen or the default app).
    func appName(for role: AppRole) -> String {
        if let app = apps[role] { return app.name }
        if let chosen = chosenApps[role] { return Self.appName(at: URL(fileURLWithPath: chosen.path)) }
        return role.defaultName
    }

    func isChosen(_ role: AppRole) -> Bool { chosenApps[role] != nil }

    func appIcon(for role: AppRole) -> NSImage? {
        apps[role].map { NSWorkspace.shared.icon(forFile: $0.url.path) }
    }

    /// Asks for an app (a panel in /Applications) and remembers it for the role.
    func chooseApp(for role: AppRole) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "Kies"
        panel.message = "Kies de app voor: \(role.title.lowercased())"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        chosenApps[role] = ChosenApp(path: url.path, bundleIdentifier: Bundle(url: url)?.bundleIdentifier)
        saveChosenApps()
        refreshApps()
    }

    /// Back to the default app of the role.
    func resetApp(for role: AppRole) {
        chosenApps[role] = nil
        saveChosenApps()
        refreshApps()
    }
}
