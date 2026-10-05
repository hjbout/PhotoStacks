import Foundation
import StackCore

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--cli") {
            exit(CLI.run(arguments: CommandLine.arguments))
        }
        PhotoStacksApp.main()
    }
}

/// Hidden command line mode, mainly for testing: PhotoStacks --cli <map> [--dry-run | --sharpness | --exposure]
enum CLI {
    static func run(arguments: [String]) -> Int32 {
        let dryRun = arguments.contains("--dry-run")
        guard let path = arguments.dropFirst().first(where: { !$0.hasPrefix("--") }) else {
            print("Gebruik: PhotoStacks --cli <map> [--dry-run | --sharpness | --exposure]")
            return 2
        }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        do {
            let photos = try ExifToolReader.readPhotos(in: folder)
            let detected = StackDetector.detect(photos)
            let excluded = ExclusionStore.load(for: folder)
            let result = DetectionResult(
                stacks: detected.stacks.compactMap { $0.excluding(excluded) },
                totalPhotos: detected.totalPhotos,
                sequencePhotos: detected.sequencePhotos,
                loosePhotos: detected.loosePhotos
            )
            if !excluded.isEmpty {
                print("\(excluded.count) foto's uit hun stack gehaald (\(StackKind.focus.outputFolderName)/\(ExclusionStore.fileName))")
            }
            let perKind = StackKind.allCases.compactMap { kind -> String? in
                let count = result.stacks.filter { $0.kind == kind }.count
                return count == 0 ? nil : "\(count) \(kind.title)"
            }
            print("\(result.totalPhotos) ORF-bestanden, \(result.sequencePhotos) in een reeks, \(result.stacks.count) stacks"
                + (perKind.isEmpty ? "" : " (\(perKind.joined(separator: ", ")))"))
            for stack in result.stacks {
                let missing = stack.kind.reportsMissingShots ? stack.missingShots : []
                let note = missing.isEmpty ? "" : "  ontbreekt: \(ShotRanges.describe(missing))"
                print("  [\(stack.kind.title)] \(stack.kind.outputFolderName)/\(stack.folderName)  Shot \(stack.firstShot)–\(stack.lastShot)\(note)")
            }
            for photo in result.loosePhotos {
                print("  los (geen stack): \(photo.fileName) \(photo.driveMode)")
            }
            if arguments.contains("--exposure") {
                printExposure(of: result.stacks.filter(\.kind.measuresExposure), in: folder)
                return 0
            }
            if arguments.contains("--sharpness") {
                printSharpness(of: result.stacks.filter(\.kind.measuresSharpness), in: folder)
                return 0
            }
            let found = StackResults.scan(folder: folder, stacks: detected.stacks.map { ($0.photos[0].fileName, $0) }) { names in
                (try? ExifToolReader.readSoftware(files: names, in: folder)) ?? [:]
            }
            for stack in detected.stacks {
                for result in found[stack.photos[0].fileName] ?? [] {
                    print("  resultaat [\(result.app.displayName)] \(stack.folderName): \(result.fileName)")
                }
            }
            let tiffs = DxOExports.scan(folder: folder, photos: detected.stacks.flatMap(\.photos))
                .compactMapValues { $0.first?.fileName }
            if !tiffs.isEmpty { print("\(tiffs.count) foto's met een DxO-TIFF") }
            let report = LinkWriter.writeAll(stacks: result.stacks, in: folder, dryRun: dryRun, excluded: excluded, tiffs: tiffs)
            print("\(dryRun ? "[dry-run] " : "")links aangemaakt: \(report.created), bestonden al: \(report.alreadyPresent), "
                + "mappen aangemaakt: \(report.foldersCreated), hernoemd: \(report.foldersRenamed), "
                + "kapotte links opgeruimd: \(report.brokenLinksRemoved), uitgesloten links weg: \(report.excludedLinksRemoved), "
                + "TIFF-links aangemaakt: \(report.tiffLinksCreated), TIFF-links weg: \(report.tiffLinksRemoved), "
                + "lege mappen verwijderd: \(report.foldersRemoved)")
            report.problems.forEach { print("  probleem: \($0)") }
            return report.problems.isEmpty ? 0 : 1
        } catch {
            print("Fout: \(error.localizedDescription)")
            return 1
        }
    }

    /// Prints per HDR frame how much is over- and underexposed, and per stack how well it covers the scene.
    private static func printExposure(of stacks: [PhotoStack], in folder: URL) {
        let start = Date()
        let photos = stacks.flatMap(\.photos)
        let stats = ExposureAnalyzer.measure(photos, in: folder)
        func percent(_ value: Double) -> String { String(format: "%.2f%%", value * 100) }
        for stack in stacks {
            if let coverage = ExposureAnalyzer.coverage(of: stack, stats: stats) {
                let range = ExposureAnalyzer.sceneRange(of: stack, stats: stats).map { String(format: ", bereik %.1f stops", $0) } ?? ""
                let span = ExposureAnalyzer.bracketSpan(of: stack, stats: stats).map { String(format: ", reeks %.1f stops", $0) } ?? ""
                print("\(stack.folderName): hoog \(percent(coverage.highlights)), schaduw \(percent(coverage.shadows))\(span)\(range)")
            } else {
                print("\(stack.folderName): niet (volledig) gemeten")
            }
            for photo in stack.photos {
                guard let frame = stats[photo.fileName] else { print("    \(photo.stem): ?"); continue }
                let ev = ExposureAnalyzer.relativeEV(of: photo, in: stack, stats: stats).map { String(format: "%+.1f EV", $0) } ?? "? EV"
                print("    \(photo.stem) \(ev)  over \(percent(frame.over))  onder \(percent(frame.under))")
            }
        }
        print(String(format: "%d van %d foto's gemeten in %.1f s", stats.count, photos.count, Date().timeIntervalSince(start)))
    }

    /// Prints per stack frame how close it gets to the sharpest frame in its best detail tile, and the verdict.
    private static func printSharpness(of stacks: [PhotoStack], in folder: URL) {
        let start = Date()
        let tiles = SharpnessAnalyzer.measure(stacks.flatMap(\.photos), in: folder)
        for stack in stacks {
            let ratios = SharpnessAnalyzer.ratios(tiles: SharpnessAnalyzer.stackTiles(stack, tiles))
            let unsharp = stack.photos.filter { (ratios[$0.fileName] ?? 1) < SharpnessAnalyzer.unsharpRatio }
            print("\(stack.folderName): \(unsharp.count) onscherp")
            let line = stack.photos.map { photo -> String in
                guard let ratio = ratios[photo.fileName] else { return "\(photo.stem):?" }
                return String(format: "%@:%.2f%@", photo.stem, ratio, ratio < SharpnessAnalyzer.unsharpRatio ? "*" : "")
            }
            print("    " + line.joined(separator: "  "))
        }
        print(String(format: "%d foto's gemeten in %.1f s", tiles.count, Date().timeIntervalSince(start)))
    }
}

enum ShotRanges {
    /// [3, 4, 5, 9] -> "3–5, 9"
    static func describe(_ shots: [Int]) -> String {
        var parts: [String] = []
        var index = 0
        while index < shots.count {
            var end = index
            while end + 1 < shots.count, shots[end + 1] == shots[end] + 1 { end += 1 }
            parts.append(end == index ? "\(shots[index])" : "\(shots[index])–\(shots[end])")
            index = end + 1
        }
        return parts.joined(separator: ", ")
    }
}
