import CoreGraphics
import Foundation
import Testing
@testable import StackCore

private func fb(_ counter: Int, _ shot: Int) -> PhotoInfo {
    PhotoInfo(fileName: "OM1R\(counter).ORF", driveMode: "Focus Bracketing, Shot \(shot)")
}

private func single(_ counter: Int) -> PhotoInfo {
    PhotoInfo(fileName: "OM1R\(counter).ORF", driveMode: "Single Shot")
}

private func names(_ stack: PhotoStack) -> [String] {
    stack.photos.map(\.stem)
}

private func photo(_ counter: Int, _ driveMode: String) -> PhotoInfo {
    PhotoInfo(fileName: "OM1R\(counter).ORF", driveMode: driveMode)
}

@Test func parsesDriveMode() {
    #expect(PhotoInfo.sequence(from: "Focus Bracketing, Shot 12")?.shot == 12)
    #expect(PhotoInfo.sequence(from: "Focus Bracketing, Shot 3; Mechanical shutter")?.shot == 3)
    #expect(PhotoInfo.sequence(from: "ProCap SH2, Shot 37")?.mode == "ProCap SH2")
    #expect(PhotoInfo.sequence(from: "Single Shot") == nil)
    #expect(PhotoInfo.sequence(from: "Self-Timer 2 sec; Anti-shock") == nil)
    #expect(PhotoInfo.sequence(from: "") == nil)
    #expect(fb(5855, 1).counter == 5855)
}

@Test func recognisesKindsOfSequences() {
    let kinds: [String: StackKind?] = [
        "Focus Bracketing, Shot 5": .focus,
        "AE Bracketing, Shot 2; Anti-shock": .hdr,
        "AE Auto Bracketing, Shot 4": .hdr,
        "AE Bracketing, Shot 1; Mechanical shutter": .hdr,
        "ProCap SH2, Shot 20": .proCap,
        "ProCap, Shot 3": .proCap,
        "Sequential, Shot 1; Anti-shock": .series,
        "Sequential SH2, Shot 11": .series,
        "WB Bracketing, Shot 2": nil,
        "Single Shot; Anti-shock": nil,
        "Self-Timer 2 sec": nil,
    ]
    for (driveMode, kind) in kinds {
        #expect(PhotoInfo(fileName: "X.ORF", driveMode: driveMode).kind == kind, "\(driveMode)")
    }
}

@Test func exposureBracketsSplitOnResetAndOnMode() {
    let photos = (1...5).map { photo(1340 + $0, "AE Bracketing, Shot \($0); Anti-shock") }
        + (1...5).map { photo(1345 + $0, "AE Bracketing, Shot \($0); Anti-shock") }
        + (1...3).map { photo(1350 + $0, "AE Auto Bracketing, Shot \($0)") }
    let result = StackDetector.detect(photos)
    #expect(result.stacks.map(\.count) == [5, 5, 3])
    #expect(result.stacks.allSatisfy { $0.kind == .hdr })
    #expect(result.sequencePhotos == 13)
}

@Test func thinnedOutBurstStaysTogether() {
    // Burst 1: shots 1, 7, 16, 26 kept (offset 17166); burst 2 starts at shot 4 (other offset).
    let photos = [photo(17167, "ProCap SH2, Shot 1"), photo(17173, "ProCap SH2, Shot 7"),
                  photo(17182, "ProCap SH2, Shot 16"), photo(17192, "ProCap SH2, Shot 26"),
                  photo(17367, "ProCap SH2, Shot 4"), photo(17368, "ProCap SH2, Shot 5")]
    let result = StackDetector.detect(photos)
    #expect(result.stacks.map(\.count) == [4, 2])
    #expect(result.stacks[0].kind == .proCap)
}

@Test func differentKindsAreNotMerged() {
    // Consecutive numbers and rising shots, but the mode changes.
    let photos = [fb(1001, 1), fb(1002, 2), photo(1003, "AE Bracketing, Shot 3"), photo(1004, "AE Bracketing, Shot 4"),
                  photo(1005, "ProCap SH1, Shot 5"), photo(1006, "ProCap SH2, Shot 6")]
    let result = StackDetector.detect(photos)
    #expect(result.stacks.map(\.kind) == [.focus, .hdr])
    #expect(result.loosePhotos.map(\.stem) == ["OM1R1005", "OM1R1006"])
}

@Test func backToBackStacksSplitOnReset() {
    let photos = [fb(1001, 1), fb(1002, 2), fb(1003, 3), fb(1004, 1), fb(1005, 2)]
    let result = StackDetector.detect(photos)
    #expect(result.stacks.map(names) == [["OM1R1001", "OM1R1002", "OM1R1003"], ["OM1R1004", "OM1R1005"]])
    #expect(result.stacks[0].folderName == "OM1R1001-OM1R1003 (3)")
}

@Test func deletedPhotosKeepStackTogether() {
    let photos = [fb(1001, 1), fb(1002, 2), fb(1005, 5), fb(1006, 6)]
    let result = StackDetector.detect(photos)
    #expect(result.stacks.count == 1)
    #expect(result.stacks[0].count == 4)
    #expect(result.stacks[0].missingShots == [3, 4])
}

@Test func nonBracketingPhotoEndsStack() {
    let photos = [fb(1001, 1), fb(1002, 2), single(1003), fb(1004, 3), fb(1005, 4)]
    let result = StackDetector.detect(photos)
    #expect(result.stacks.map(names) == [["OM1R1001", "OM1R1002"], ["OM1R1004", "OM1R1005"]])
    #expect(result.stacks[1].missingShots == [1, 2])
}

@Test func nextStackWithDeletedFirstShotsIsNotMerged() {
    // Stack A: 1001-1002 (shots 1-2). Stack B: 1003-1006 (shots 1-4), shots 1-2 deleted.
    let photos = [fb(1001, 1), fb(1002, 2), fb(1005, 3), fb(1006, 4)]
    let result = StackDetector.detect(photos)
    #expect(result.stacks.map(names) == [["OM1R1001", "OM1R1002"], ["OM1R1005", "OM1R1006"]])
}

@Test func singleBracketPhotoIsLoose() {
    let photos = [single(1000), fb(1001, 1), single(1002), fb(1003, 1), fb(1004, 2)]
    let result = StackDetector.detect(photos)
    #expect(result.stacks.count == 1)
    #expect(result.loosePhotos.map(\.stem) == ["OM1R1001"])
    #expect(result.totalPhotos == 5)
    #expect(result.sequencePhotos == 3)
}

@Test func sortsByFileNumbering() {
    let photos = [fb(1003, 3), fb(1001, 1), fb(1002, 2)].reversed()
    let result = StackDetector.detect(Array(photos))
    #expect(result.stacks.map(names) == [["OM1R1001", "OM1R1002", "OM1R1003"]])

    let dated = ["PA010001.ORF", "P9300002.ORF", "P9300001.ORF"].map { PhotoInfo(fileName: $0, driveMode: "") }
    #expect(StackDetector.sorted(dated).map(\.fileName) == ["P9300001.ORF", "P9300002.ORF", "PA010001.ORF"])
}

// MARK: - LinkWriter

private func makeTempFolder(files: [String: String]) throws -> URL {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("PhotoStacksTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for (name, content) in files {
        try content.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    return folder
}

@Test func writesRelativeSymlinksAndIsIdempotent() throws {
    let folder = try makeTempFolder(files: ["OM1R1001.ORF": "a", "OM1R1002.ORF": "b", "OM1R1003.ORF": "c"])
    defer { try? FileManager.default.removeItem(at: folder) }
    let stacks = StackDetector.detect([fb(1001, 1), fb(1002, 2), single(1003)]).stacks

    let dry = LinkWriter.write(stacks: stacks, in: folder, dryRun: true)
    #expect(dry.created == 2)
    #expect(!FileManager.default.fileExists(atPath: LinkWriter.outputFolder(for: folder).path))

    let first = LinkWriter.write(stacks: stacks, in: folder)
    #expect(first.created == 2 && first.problems.isEmpty)
    let link = LinkWriter.outputFolder(for: folder).appendingPathComponent("OM1R1001-OM1R1002 (2)/OM1R1001.ORF")
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "../../OM1R1001.ORF")
    #expect(try String(contentsOf: link, encoding: .utf8) == "a")

    let second = LinkWriter.write(stacks: stacks, in: folder)
    #expect(second.created == 0 && second.alreadyPresent == 2 && second.problems.isEmpty)
}

@Test func neverOverwritesExistingFiles() throws {
    let folder = try makeTempFolder(files: ["OM1R1001.ORF": "a", "OM1R1002.ORF": "b"])
    defer { try? FileManager.default.removeItem(at: folder) }
    let stacks = StackDetector.detect([fb(1001, 1), fb(1002, 2)]).stacks
    let stackDir = LinkWriter.outputFolder(for: folder).appendingPathComponent(stacks[0].folderName)
    try FileManager.default.createDirectory(at: stackDir, withIntermediateDirectories: true)
    let existing = stackDir.appendingPathComponent("OM1R1001.ORF")
    try "keep me".write(to: existing, atomically: true, encoding: .utf8)

    let report = LinkWriter.write(stacks: stacks, in: folder)
    #expect(report.created == 1)
    #expect(report.problems.count == 1)
    #expect(try String(contentsOf: existing, encoding: .utf8) == "keep me")
    #expect(try String(contentsOf: folder.appendingPathComponent("OM1R1001.ORF"), encoding: .utf8) == "a")
}

@Test func refusesWhenFocusStacksIsAFile() throws {
    let folder = try makeTempFolder(files: ["OM1R1001.ORF": "a", "OM1R1002.ORF": "b", "FocusStacks": "x"])
    defer { try? FileManager.default.removeItem(at: folder) }
    let stacks = StackDetector.detect([fb(1001, 1), fb(1002, 2)]).stacks
    let report = LinkWriter.write(stacks: stacks, in: folder)
    #expect(report.created == 0 && report.problems.count == 1)
}

@Test func parsesExifToolJSON() throws {
    let json = Data(#"[{"SourceFile":"OM1R1.ORF","FileName":"OM1R1.ORF","DriveMode":"Focus Bracketing, Shot 1"},{"SourceFile":"x.ORF","FileName":"x.ORF"}]"#.utf8)
    let photos = try ExifToolReader.parse(json: json)
    #expect(photos == [PhotoInfo(fileName: "OM1R1.ORF", driveMode: "Focus Bracketing, Shot 1"),
                       PhotoInfo(fileName: "x.ORF", driveMode: "")])
}

// MARK: - Re-running after originals were deleted

private func contents(_ dir: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
}

/// Every path below `dir` with symlink destinations, to prove a dry run changes nothing.
private func snapshot(_ dir: URL) throws -> [String] {
    let fm = FileManager.default
    return try fm.subpathsOfDirectory(atPath: dir.path).sorted().map { sub in
        let full = dir.appendingPathComponent(sub).path
        return sub + " -> " + ((try? fm.destinationOfSymbolicLink(atPath: full)) ?? "")
    }
}

private func removeOriginal(_ name: String, in folder: URL) throws {
    try FileManager.default.removeItem(at: folder.appendingPathComponent(name))
}

@Test func deletedOriginalRenamesFolderAndRemovesBrokenLink() throws {
    let folder = try makeTempFolder(files: ["OM1R1001.ORF": "a", "OM1R1002.ORF": "b", "OM1R1003.ORF": "c", "OM1R1004.ORF": "d"])
    defer { try? FileManager.default.removeItem(at: folder) }
    let output = LinkWriter.outputFolder(for: folder)
    _ = LinkWriter.write(stacks: StackDetector.detect([fb(1001, 1), fb(1002, 2), fb(1003, 3), fb(1004, 4)]).stacks, in: folder)
    #expect(try contents(output) == ["OM1R1001-OM1R1004 (4)"])
    try "stacked".write(to: output.appendingPathComponent("OM1R1001-OM1R1004 (4)/result.tif"), atomically: true, encoding: .utf8)

    try removeOriginal("OM1R1002.ORF", in: folder)
    let report = LinkWriter.write(stacks: StackDetector.detect([fb(1001, 1), fb(1003, 3), fb(1004, 4)]).stacks, in: folder)

    #expect(report.problems.isEmpty)
    #expect(report.foldersRenamed == 1 && report.brokenLinksRemoved == 1)
    #expect(report.created == 0 && report.alreadyPresent == 3 && report.foldersCreated == 0)
    #expect(try contents(output) == ["OM1R1001-OM1R1004 (3)"])
    #expect(try contents(output.appendingPathComponent("OM1R1001-OM1R1004 (3)"))
        == ["OM1R1001.ORF", "OM1R1003.ORF", "OM1R1004.ORF", "result.tif"])
}

@Test func deletedStackRemovesEmptyFolderButKeepsFoldersWithUserFiles() throws {
    let names = (1001...1006).map { "OM1R\($0).ORF" }
    let folder = try makeTempFolder(files: Dictionary(uniqueKeysWithValues: names.map { ($0, "x") }))
    defer { try? FileManager.default.removeItem(at: folder) }
    let output = LinkWriter.outputFolder(for: folder)
    let all = [fb(1001, 1), fb(1002, 2), fb(1003, 1), fb(1004, 2), fb(1005, 1), fb(1006, 2)]
    _ = LinkWriter.write(stacks: StackDetector.detect(all).stacks, in: folder)
    try "finder".write(to: output.appendingPathComponent("OM1R1001-OM1R1002 (2)/.DS_Store"), atomically: true, encoding: .utf8)
    try "mine".write(to: output.appendingPathComponent("OM1R1003-OM1R1004 (2)/notes.txt"), atomically: true, encoding: .utf8)

    for name in names.prefix(4) { try removeOriginal(name, in: folder) }
    let report = LinkWriter.write(stacks: StackDetector.detect(Array(all.suffix(2))).stacks, in: folder)

    #expect(report.problems.isEmpty)
    #expect(report.brokenLinksRemoved == 4 && report.foldersRemoved == 1)
    #expect(try contents(output) == ["OM1R1003-OM1R1004 (2)", "OM1R1005-OM1R1006 (2)"])
    #expect(try contents(output.appendingPathComponent("OM1R1003-OM1R1004 (2)")) == ["notes.txt"])
}

@Test func foreignLinksAreNeverRemoved() throws {
    let folder = try makeTempFolder(files: ["OM1R1001.ORF": "a", "OM1R1002.ORF": "b"])
    defer { try? FileManager.default.removeItem(at: folder) }
    let stacks = StackDetector.detect([fb(1001, 1), fb(1002, 2)]).stacks
    _ = LinkWriter.write(stacks: stacks, in: folder)
    let stackDir = LinkWriter.outputFolder(for: folder).appendingPathComponent(stacks[0].folderName)
    let fm = FileManager.default
    try fm.createSymbolicLink(atPath: stackDir.appendingPathComponent("other.ORF").path, withDestinationPath: "/does/not/exist.ORF")
    try fm.createSymbolicLink(atPath: stackDir.appendingPathComponent("OM1R0999.ORF").path, withDestinationPath: "../../../OM1R0999.ORF")

    let report = LinkWriter.write(stacks: stacks, in: folder)
    #expect(report.brokenLinksRemoved == 0 && report.problems.isEmpty)
    #expect(try contents(stackDir) == ["OM1R0999.ORF", "OM1R1001.ORF", "OM1R1002.ORF", "other.ORF"])
}

@Test func dryRunChangesNothing() throws {
    let folder = try makeTempFolder(files: ["OM1R1001.ORF": "a", "OM1R1002.ORF": "b", "OM1R1003.ORF": "c",
                                            "OM1R1004.ORF": "d", "OM1R1005.ORF": "e"])
    defer { try? FileManager.default.removeItem(at: folder) }
    let all = [fb(1001, 1), fb(1002, 2), fb(1003, 3), fb(1004, 1), fb(1005, 2)]
    _ = LinkWriter.write(stacks: StackDetector.detect(all).stacks, in: folder)
    try removeOriginal("OM1R1003.ORF", in: folder)
    try removeOriginal("OM1R1004.ORF", in: folder)
    try removeOriginal("OM1R1005.ORF", in: folder)
    let before = try snapshot(folder)

    let stacks = StackDetector.detect([fb(1001, 1), fb(1002, 2)]).stacks
    let dry = LinkWriter.write(stacks: stacks, in: folder, dryRun: true)
    #expect(try snapshot(folder) == before)

    let real = LinkWriter.write(stacks: stacks, in: folder)
    #expect(dry.foldersRenamed == 1 && dry.brokenLinksRemoved == 3 && dry.foldersRemoved == 1)
    #expect(real.foldersRenamed == dry.foldersRenamed && real.brokenLinksRemoved == dry.brokenLinksRemoved
        && real.foldersRemoved == dry.foldersRemoved && real.created == dry.created)
    #expect(try contents(LinkWriter.outputFolder(for: folder)) == ["OM1R1001-OM1R1002 (2)"])
}

// MARK: - Sharpness

/// Grey test image: smooth gradient background with a fine checkerboard in `sharpRect` (if any).
private func testImage(width: Int = 1200, height: Int = 900, sharpRect: CGRect? = nil) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    for x in 0..<width {
        context.setFillColor(gray: 0.3 + 0.4 * CGFloat(x) / CGFloat(width), alpha: 1)
        context.fill(CGRect(x: x, y: 0, width: 1, height: height))
    }
    if let sharpRect {
        for y in stride(from: Int(sharpRect.minY), to: Int(sharpRect.maxY), by: 2) {
            for x in stride(from: Int(sharpRect.minX), to: Int(sharpRect.maxX), by: 2) {
                context.setFillColor(gray: (x / 2 + y / 2) % 2 == 0 ? 0.1 : 0.9, alpha: 1)
                context.fill(CGRect(x: x, y: y, width: 2, height: 2))
            }
        }
    }
    return context.makeImage()!
}

@Test func sharpDetailOnlyRaisesItsOwnTiles() throws {
    let smooth = try #require(SharpnessAnalyzer.tileSharpness(of: testImage()))
    // Sharp 150×150 px area (about 3×3 tiles of the 24×18 grid); the rest is smooth.
    let partly = try #require(SharpnessAnalyzer.tileSharpness(of: testImage(sharpRect: CGRect(x: 500, y: 400, width: 150, height: 150))))
    #expect(smooth.count == SharpnessAnalyzer.gridColumns * SharpnessAnalyzer.gridRows)
    #expect(smooth.allSatisfy { $0 < 1 })
    #expect(partly.filter { $0 > 1000 }.count >= 4)
    #expect(partly.filter { $0 < 1 }.count >= partly.count - 25)  // only tiles at or next to the sharp area
}

/// Tiles of one frame: noise level everywhere, with `values` in the first tiles.
private func frame(_ values: Double...) -> [Double] {
    values + Array(repeating: 10, count: 20 - values.count)
}

@Test func unsharpComparesEachTileWithTheBestFrameForThatTile() {
    let stack = [
        "a.ORF": frame(2000, 60, 10),   // sharp on a high-contrast subject
        "b.ORF": frame(300, 400, 10),   // sharp on a low-contrast subject (second tile): not unsharp
        "c.ORF": frame(250, 70, 10),    // soft everywhere: ~12% of the best in both detail tiles
        "d.ORF": frame(10, 10, 10),     // nothing at all
    ]
    #expect(SharpnessAnalyzer.unsharp(tiles: stack) == ["c.ORF", "d.ORF"])
    let ratios = SharpnessAnalyzer.ratios(tiles: stack)
    #expect(ratios["a.ORF"] == 1 && ratios["b.ORF"] == 1)
}

@Test func stackWithoutAnyDetailIsCompletelyUnsharp() {
    #expect(SharpnessAnalyzer.unsharp(tiles: ["a.ORF": frame(60, 50), "b.ORF": frame(40)]) == ["a.ORF", "b.ORF"])
    #expect(SharpnessAnalyzer.unsharp(tiles: ["a.ORF": frame(900)]).isEmpty)
    #expect(SharpnessAnalyzer.unsharp(tiles: [:]).isEmpty)
}

// MARK: - Taking photos out of a stack

@Test func excludingPhotosFromStack() {
    let stack = StackDetector.detect([fb(1001, 1), fb(1002, 2), fb(1003, 3)]).stacks[0]
    #expect(stack.excluding(["OM1R1003.ORF"])?.folderName == "OM1R1001-OM1R1002 (2)")
    #expect(stack.excluding(["OM1R1001.ORF", "OM1R1003.ORF"]) == nil)
    #expect(stack.excluding([]) == stack)
}

@Test func exclusionStoreRoundTrip() throws {
    let folder = try makeTempFolder(files: ["OM1R1001.ORF": "a"])
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(ExclusionStore.load(for: folder).isEmpty)
    try ExclusionStore.save(["OM1R1002.ORF", "OM1R1001.ORF"], for: folder)
    #expect(ExclusionStore.load(for: folder) == ["OM1R1001.ORF", "OM1R1002.ORF"])
    try ExclusionStore.save([], for: folder)
    #expect(ExclusionStore.load(for: folder).isEmpty)
    #expect(try contents(LinkWriter.outputFolder(for: folder)) == [".uitgesloten"])
}

@Test func sidecarsHaveExactlyTheSameStem() throws {
    let folder = try makeTempFolder(files: [
        "OM1R1001.ORF": "a", "OM1R1001.xmp": "x", "om1r1001.on1": "o", "OM1R1001.xmp_original": "b",
        "OM1R1001.JPG": "j", "OM1R1001 bewerkt.tif": "t", "OM1R10011.ORF": "c", "OM1R1002.ORF": "d",
    ])
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("OM1R1001.lnk").path,
                                               withDestinationPath: "OM1R1002.ORF")
    let names = Sidecars.files(for: fb(1001, 1), in: folder).map(\.lastPathComponent)
    #expect(names == ["OM1R1001.ORF", "OM1R1001.JPG", "om1r1001.on1", "OM1R1001.xmp", "OM1R1001.xmp_original"])
}

@Test func excludedLinksAreRemovedAndFolderRenamed() throws {
    let folder = try makeTempFolder(files: ["OM1R1001.ORF": "a", "OM1R1002.ORF": "b", "OM1R1003.ORF": "c"])
    defer { try? FileManager.default.removeItem(at: folder) }
    let output = LinkWriter.outputFolder(for: folder)
    let detected = StackDetector.detect([fb(1001, 1), fb(1002, 2), fb(1003, 3)]).stacks
    _ = LinkWriter.write(stacks: detected, in: folder)
    let stackDir = output.appendingPathComponent("OM1R1001-OM1R1003 (3)")
    try "mine".write(to: stackDir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    try ExclusionStore.save(["OM1R1003.ORF"], for: folder)
    let before = try snapshot(folder)

    let excluded: Set<String> = ["OM1R1003.ORF"]
    let stacks = detected.compactMap { $0.excluding(excluded) }
    let dry = LinkWriter.write(stacks: stacks, in: folder, dryRun: true, excluded: excluded)
    #expect(try snapshot(folder) == before)
    let report = LinkWriter.write(stacks: stacks, in: folder, excluded: excluded)

    #expect(dry.excludedLinksRemoved == 1 && report.excludedLinksRemoved == 1 && report.foldersRenamed == 1)
    #expect(report.problems.isEmpty && report.created == 0 && report.alreadyPresent == 2)
    #expect(try contents(output) == [".uitgesloten", "OM1R1001-OM1R1002 (2)"])
    #expect(try contents(output.appendingPathComponent("OM1R1001-OM1R1002 (2)"))
        == ["OM1R1001.ORF", "OM1R1002.ORF", "notes.txt"])
    #expect(try String(contentsOf: folder.appendingPathComponent("OM1R1003.ORF"), encoding: .utf8) == "c")
}

// MARK: - DxO TIFFs

private func setModified(_ url: URL, _ seconds: TimeInterval) throws {
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: url.path)
}

@Test func recognisesOnlyDxOTIFFsOfTheRightPhoto() throws {
    let folder = try makeTempFolder(files: [
        "OM1R1001.ORF": "o", "OM1R1002.ORF": "o", "OM1R10011.ORF": "o", "_OM13266.ORF": "o",
        "OM1R1001_DxO.tif": "t", "OM1R1001_DxO (1).tif": "t2", "OM1R1001_DxO.tif.dop": "d",
        "OM1R1001_Nik.tif": "n", "OM1R1002_M_DXO.TIFF": "m", "OM1R10011_DxO.tif": "x",
        "_OM13266_DxO.tif": "u", "OM1R1002.tif": "same name", "OM1R1003.TIF": "same name, capitals",
        "OM1R1003.jpg": "not a tiff",
    ])
    defer { try? FileManager.default.removeItem(at: folder) }
    try setModified(folder.appendingPathComponent("OM1R1001_DxO.tif"), 1000)
    try setModified(folder.appendingPathComponent("OM1R1001_DxO (1).tif"), 2000)
    try setModified(folder.appendingPathComponent("OM1R1002.tif"), 3000)
    try setModified(folder.appendingPathComponent("OM1R1002_M_DXO.TIFF"), 2000)
    let photos = ["OM1R1001.ORF", "OM1R1002.ORF", "OM1R1003.ORF", "OM1R10011.ORF", "_OM13266.ORF"].map {
        PhotoInfo(fileName: $0, driveMode: "")
    }
    let found = DxOExports.scan(folder: folder, photos: photos).mapValues { $0.map(\.fileName) }
    #expect(found == [
        "OM1R1001.ORF": ["OM1R1001_DxO (1).tif", "OM1R1001_DxO.tif"],  // newest first
        "OM1R1002.ORF": ["OM1R1002.tif", "OM1R1002_M_DXO.TIFF"],  // same name counts too; newest first
        "OM1R1003.ORF": ["OM1R1003.TIF"],
        "OM1R10011.ORF": ["OM1R10011_DxO.tif"],
        "_OM13266.ORF": ["_OM13266_DxO.tif"],
    ])
}

@Test func sidecarsOfATIFF() throws {
    let folder = try makeTempFolder(files: [
        "OM1R1001_DxO.tif": "t", "OM1R1001_DxO.tif.dop": "d", "OM1R1001_DxO.xmp": "x", "OM1R1001_DxO (1).tif": "t2",
    ])
    defer { try? FileManager.default.removeItem(at: folder) }
    let names = Sidecars.files(forStem: "OM1R1001_DxO", first: "OM1R1001_DxO.tif", in: folder).map(\.lastPathComponent)
    #expect(names == ["OM1R1001_DxO.tif", "OM1R1001_DxO.tif.dop", "OM1R1001_DxO.xmp"])
}

@Test func tiffSubfolderFollowsTheStack() throws {
    let fm = FileManager.default
    let folder = try makeTempFolder(files: [
        "OM1R1001.ORF": "a", "OM1R1002.ORF": "b", "OM1R1003.ORF": "c",
        "OM1R1001_DxO.tif": "ta", "OM1R1002_DxO.tif": "tb", "OM1R1003_DxO.tif": "tc",
    ])
    defer { try? fm.removeItem(at: folder) }
    let output = LinkWriter.outputFolder(for: folder)
    let detected = StackDetector.detect([fb(1001, 1), fb(1002, 2), fb(1003, 3)]).stacks
    let tiffs = ["OM1R1001.ORF": "OM1R1001_DxO.tif", "OM1R1002.ORF": "OM1R1002_DxO.tif", "OM1R1003.ORF": "OM1R1003_DxO.tif"]

    let first = LinkWriter.write(stacks: detected, in: folder, tiffs: tiffs)
    #expect(first.tiffLinksCreated == 3 && first.problems.isEmpty)
    let tiffDir = output.appendingPathComponent("OM1R1001-OM1R1003 (3)/TIFF")
    #expect(try contents(tiffDir) == ["OM1R1001_DxO.tif", "OM1R1002_DxO.tif", "OM1R1003_DxO.tif"])
    #expect(try fm.destinationOfSymbolicLink(atPath: tiffDir.appendingPathComponent("OM1R1001_DxO.tif").path)
        == "../../../OM1R1001_DxO.tif")
    #expect(try String(contentsOf: tiffDir.appendingPathComponent("OM1R1002_DxO.tif"), encoding: .utf8) == "tb")
    #expect(LinkWriter.write(stacks: detected, in: folder, tiffs: tiffs).tiffLinksCreated == 0)

    // Take 1003 out of the stack and delete the TIFF of 1001; a user file in TIFF/ stays.
    try "mine".write(to: tiffDir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    try fm.removeItem(at: folder.appendingPathComponent("OM1R1001_DxO.tif"))
    let excluded: Set<String> = ["OM1R1003.ORF"]
    let stacks = detected.compactMap { $0.excluding(excluded) }
    let before = try snapshot(folder)
    _ = LinkWriter.write(stacks: stacks, in: folder, dryRun: true, excluded: excluded, tiffs: tiffs)
    #expect(try snapshot(folder) == before)
    let report = LinkWriter.write(stacks: stacks, in: folder, excluded: excluded, tiffs: ["OM1R1002.ORF": "OM1R1002_DxO.tif"])
    #expect(report.problems.isEmpty && report.foldersRenamed == 1 && report.tiffLinksRemoved == 2)
    let renamedTIFF = output.appendingPathComponent("OM1R1001-OM1R1002 (2)/TIFF")
    #expect(try contents(renamedTIFF) == ["OM1R1002_DxO.tif", "notes.txt"])
    #expect(try String(contentsOf: renamedTIFF.appendingPathComponent("OM1R1002_DxO.tif"), encoding: .utf8) == "tb")

    // No TIFFs left: our links go, the folder stays because of the user's file.
    try fm.removeItem(at: renamedTIFF.appendingPathComponent("notes.txt"))
    let noTIFFs = LinkWriter.write(stacks: stacks, in: folder, excluded: excluded)
    #expect(noTIFFs.tiffLinksRemoved == 1)
    #expect(try contents(output.appendingPathComponent("OM1R1001-OM1R1002 (2)")) == ["OM1R1001.ORF", "OM1R1002.ORF"])
}

@Test func stackFolderWithOnlyBrokenLinksAndTIFFsIsRemoved() throws {
    let fm = FileManager.default
    let folder = try makeTempFolder(files: ["OM1R1001.ORF": "a", "OM1R1002.ORF": "b",
                                            "OM1R1001_DxO.tif": "ta", "OM1R1002_DxO.tif": "tb"])
    defer { try? fm.removeItem(at: folder) }
    let stacks = StackDetector.detect([fb(1001, 1), fb(1002, 2)]).stacks
    _ = LinkWriter.write(stacks: stacks, in: folder,
                         tiffs: ["OM1R1001.ORF": "OM1R1001_DxO.tif", "OM1R1002.ORF": "OM1R1002_DxO.tif"])
    for name in ["OM1R1001.ORF", "OM1R1002.ORF", "OM1R1001_DxO.tif", "OM1R1002_DxO.tif"] {
        try fm.removeItem(at: folder.appendingPathComponent(name))
    }
    let report = LinkWriter.write(stacks: [], in: folder)
    #expect(report.problems.isEmpty && report.foldersRemoved == 1 && report.tiffLinksRemoved == 2)
    #expect(try contents(LinkWriter.outputFolder(for: folder)).isEmpty)
}

@Test func writeAllUsesAFolderPerKind() throws {
    let folder = try makeTempFolder(files: ["OM1R1001.ORF": "", "OM1R1002.ORF": "", "OM1R1003.ORF": "", "OM1R1004.ORF": ""])
    let photos = [fb(1001, 1), fb(1002, 2), photo(1003, "AE Bracketing, Shot 1"), photo(1004, "AE Bracketing, Shot 2")]
    let stacks = StackDetector.detect(photos).stacks
    let report = LinkWriter.writeAll(stacks: stacks, in: folder)
    #expect(report.problems.isEmpty)
    #expect(report.created == 4)

    let hdr = LinkWriter.outputFolder(for: folder, kind: .hdr)
    #expect(try contents(hdr) == ["OM1R1003-OM1R1004 (2)"])
    let link = hdr.appendingPathComponent("OM1R1003-OM1R1004 (2)/OM1R1003.ORF")
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "../../OM1R1003.ORF")
    #expect(try contents(LinkWriter.outputFolder(for: folder)) == ["OM1R1001-OM1R1002 (2)"])
    // No folders for kinds without stacks.
    #expect(!FileManager.default.fileExists(atPath: LinkWriter.outputFolder(for: folder, kind: .proCap).path))
    #expect(!FileManager.default.fileExists(atPath: LinkWriter.outputFolder(for: folder, kind: .series).path))

    // The HDR stack is gone (photos taken out): its folder in HDRStacks is cleaned up, FocusStacks stays.
    let cleanup = LinkWriter.writeAll(stacks: Array(stacks.prefix(1)), in: folder,
                                      excluded: ["OM1R1003.ORF", "OM1R1004.ORF"])
    #expect(cleanup.excludedLinksRemoved == 2)
    #expect(cleanup.foldersRemoved == 1)
    #expect(try contents(hdr).isEmpty)
    #expect(try contents(LinkWriter.outputFolder(for: folder)) == ["OM1R1001-OM1R1002 (2)"])
}
