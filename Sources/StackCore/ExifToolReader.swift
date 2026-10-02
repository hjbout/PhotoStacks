import Foundation

public enum ExifToolError: LocalizedError {
    case notFound
    case failed(status: Int32, message: String)
    case invalidOutput

    public var errorDescription: String? {
        switch self {
        case .notFound:
            return "exiftool niet gevonden. Installeer het via https://exiftool.org of met 'brew install exiftool'."
        case let .failed(status, message):
            return "exiftool gaf een fout (code \(status)): \(message)"
        case .invalidOutput:
            return "De uitvoer van exiftool kon niet gelezen worden."
        }
    }
}

/// Reads the Drive Mode of all .ORF files in a folder using exiftool (read-only).
public enum ExifToolReader {
    /// GUI apps don't get the shell PATH, so look in the usual install locations.
    public static let searchPaths = [
        "/opt/homebrew/bin/exiftool",
        "/usr/local/bin/exiftool",
        "/usr/bin/exiftool",
    ]

    public static func locate() -> URL? {
        searchPaths
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Regular .ORF files directly in `folder` (not recursive, symlinks and hidden files skipped).
    public static func orfFiles(in folder: URL) throws -> [String] {
        let fm = FileManager.default
        return try fm.contentsOfDirectory(atPath: folder.path)
            .filter { !$0.hasPrefix(".") && ($0 as NSString).pathExtension.lowercased() == "orf" }
            .filter { name in
                let attributes = try? fm.attributesOfItem(atPath: folder.appendingPathComponent(name).path)
                return attributes?[.type] as? FileAttributeType == .typeRegular
            }
    }

    public static func readPhotos(in folder: URL) throws -> [PhotoInfo] {
        let files = try orfFiles(in: folder)
        if files.isEmpty { return [] }
        guard let exiftool = locate() else { throw ExifToolError.notFound }

        let process = Process()
        process.executableURL = exiftool
        process.currentDirectoryURL = folder
        // File names are passed via stdin ("-@ -") so large folders don't hit the argument limit.
        process.arguments = ["-j", "-q", "-q", "-fast", "-charset", "filename=utf8",
                             "-FileName", "-DriveMode", "-@", "-"]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        let group = DispatchGroup()
        var errorData = Data()
        DispatchQueue.global().async(group: group) {
            stdin.fileHandleForWriting.write(Data((files.joined(separator: "\n") + "\n").utf8))
            try? stdin.fileHandleForWriting.close()
        }
        DispatchQueue.global().async(group: group) {
            errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()

        if output.isEmpty {
            let message = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ExifToolError.failed(status: process.terminationStatus, message: message)
        }
        return try parse(json: output)
    }

    static func parse(json: Data) throws -> [PhotoInfo] {
        guard let records = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]] else {
            throw ExifToolError.invalidOutput
        }
        return records.compactMap { record in
            guard let fileName = record["FileName"].map({ "\($0)" }) else { return nil }
            let driveMode = record["DriveMode"].map { "\($0)" } ?? ""
            return PhotoInfo(fileName: fileName, driveMode: driveMode)
        }
    }
}
