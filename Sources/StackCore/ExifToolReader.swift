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

/// Reads metadata of the .ORF files in a folder using exiftool (read-only).
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
        return try parse(json: records(["-fast", "-FileName", "-DriveMode"], files: files, in: folder))
    }

    /// Where the sensor data of each file is and how to read it (only works for the files exiftool can read).
    public static func readRawLayouts(files: [String], in folder: URL) throws -> [String: RawLayout] {
        if files.isEmpty { return [:] }
        let json = try records(["-n", "-FileName", "-StripOffsets", "-StripByteCounts", "-ImageWidth", "-ImageHeight",
                                "-BlackLevel2", "-ValidBits", "-CropLeft", "-CropTop", "-CropWidth", "-CropHeight",
                                "-ExposureTime", "-FNumber", "-ISO"], files: files, in: folder)
        return try parseRawLayouts(json: json)
    }

    /// exiftool's JSON output for `files` (names relative to `folder`) with the given tag arguments.
    private static func records(_ tags: [String], files: [String], in folder: URL) throws -> Data {
        guard let exiftool = locate() else { throw ExifToolError.notFound }

        let process = Process()
        process.executableURL = exiftool
        process.currentDirectoryURL = folder
        // File names are passed via stdin ("-@ -") so large folders don't hit the argument limit.
        process.arguments = ["-j", "-q", "-q", "-charset", "filename=utf8"] + tags + ["-@", "-"]
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
        return output
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

    static func parseRawLayouts(json: Data) throws -> [String: RawLayout] {
        guard let records = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]] else {
            throw ExifToolError.invalidOutput
        }
        /// Numbers of a tag; exiftool gives one number as a number and several as a space separated string.
        func numbers(_ value: Any?) -> [Int] {
            if let number = value as? NSNumber { return [number.intValue] }
            guard let text = value as? String else { return [] }
            return text.split(separator: " ").compactMap { Double($0).map { Int($0) } }
        }
        var layouts: [String: RawLayout] = [:]
        for record in records {
            guard let fileName = record["FileName"].map({ "\($0)" }),
                  let offset = numbers(record["StripOffsets"]).first,
                  let byteCount = numbers(record["StripByteCounts"]).first,
                  let width = numbers(record["ImageWidth"]).first,
                  let height = numbers(record["ImageHeight"]).first,
                  let bits = numbers(record["ValidBits"]).first, (8...16).contains(bits)
            else { continue }
            let black = numbers(record["BlackLevel2"])
            let left = numbers(record["CropLeft"]).first ?? 0, top = numbers(record["CropTop"]).first ?? 0
            let cropWidth = numbers(record["CropWidth"]).first ?? width - left
            let cropHeight = numbers(record["CropHeight"]).first ?? height - top
            layouts[fileName] = RawLayout(
                offset: offset, byteCount: byteCount, width: width, height: height,
                black: black.count == 4 ? black : [0, 0, 0, 0], white: (1 << bits) - 1,
                cropLeft: left, cropTop: top, cropWidth: cropWidth, cropHeight: cropHeight,
                exposure: exposure(time: record["ExposureTime"], aperture: record["FNumber"], iso: record["ISO"])
            )
        }
        return layouts
    }

    /// log2(time × ISO / aperture²): one higher is one stop more light on the sensor.
    private static func exposure(time: Any?, aperture: Any?, iso: Any?) -> Double? {
        guard let time = (time as? NSNumber)?.doubleValue, let aperture = (aperture as? NSNumber)?.doubleValue,
              let iso = (iso as? NSNumber)?.doubleValue, time > 0, aperture > 0, iso > 0
        else { return nil }
        return log2(time * iso / (aperture * aperture))
    }
}
