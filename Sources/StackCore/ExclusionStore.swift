import Foundation

/// Remembers which photos the user took out of their stack, in a hidden file `FocusStacks/.uitgesloten`
/// (one file name per line), so they stay out when the folder is scanned again.
public enum ExclusionStore {
    public static let fileName = ".uitgesloten"

    public static func file(for folder: URL) -> URL {
        LinkWriter.outputFolder(for: folder).appendingPathComponent(fileName)
    }

    public static func load(for folder: URL) -> Set<String> {
        guard let text = try? String(contentsOf: file(for: folder), encoding: .utf8) else { return [] }
        return Set(text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty })
    }

    /// Writes only this file (creating FocusStacks when needed).
    public static func save(_ fileNames: Set<String>, for folder: URL) throws {
        let output = LinkWriter.outputFolder(for: folder)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let text = fileNames.sorted().joined(separator: "\n") + (fileNames.isEmpty ? "" : "\n")
        try text.write(to: file(for: folder), atomically: true, encoding: .utf8)
    }
}
