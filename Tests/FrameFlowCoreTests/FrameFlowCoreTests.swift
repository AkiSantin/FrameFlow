import XCTest
import CoreGraphics
@testable import FrameFlowCore

final class FrameFlowCoreTests: XCTestCase {
    func testEvenlySpacedSamplingAvoidsExactEdges() throws {
        var recipe = ExtractionRecipe()
        recipe.frameCount = 4
        let times = try SamplingCalculator.times(duration: 10, recipe: recipe)
        XCTAssertEqual(times, [2, 4, 6, 8])
    }

    func testFixedIntervalHonorsRangeAndMaximum() throws {
        var recipe = ExtractionRecipe()
        recipe.samplingMode = .fixedInterval
        recipe.intervalSeconds = 2.5
        recipe.rangeStart = 1
        recipe.rangeEnd = 9
        recipe.maximumFrames = 3
        XCTAssertEqual(try SamplingCalculator.times(duration: 20, recipe: recipe), [1, 3.5, 6])
    }

    func testManualTimesAreFilteredSortedAndDeduplicated() throws {
        var recipe = ExtractionRecipe()
        recipe.samplingMode = .manualTimes
        recipe.rangeStart = 1
        recipe.rangeEnd = 8
        recipe.manualTimes = [7, 2, 7, 0, 9, 4.5]
        XCTAssertEqual(try SamplingCalculator.times(duration: 10, recipe: recipe), [2, 4.5, 7])
    }

    func testFitAndFillSizes() {
        let landscape = CGSize(width: 1920, height: 1080)
        XCTAssertEqual(
            AspectRenderer.targetSize(source: landscape, preset: .square, mode: .fit),
            CGSize(width: 1920, height: 1920)
        )
        XCTAssertEqual(
            AspectRenderer.targetSize(source: landscape, preset: .square, mode: .fill),
            CGSize(width: 1080, height: 1080)
        )
    }

    func testUnicodeStemIsPreserved() {
        XCTAssertEqual(OutputPlanner.sanitizedStem("台北 テスト🎬 01"), "台北 テスト🎬 01")
        XCTAssertEqual(OutputPlanner.sanitizedStem("a/b:c"), "a_b_c")
    }

    func testUniqueOutputDirectoryNeverChoosesExistingPath() throws {
        let root = try newTestDirectory(name: "unique-output")
        let existing = root.appendingPathComponent("影片-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        let result = OutputPlanner.uniqueDirectory(parent: root, stem: "影片")
        XCTAssertEqual(result.lastPathComponent, "影片-screenshots-2")
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.path))
    }

    func testRecursiveScannerPreservesUnicodeAndSkipsDuplicates() throws {
        let root = try newTestDirectory(name: "scan")
        let child = root.appendingPathComponent("子フォルダ", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        let movie = child.appendingPathComponent("影片🎬.MP4")
        let text = child.appendingPathComponent("note.txt")
        try Data().write(to: movie, options: .withoutOverwriting)
        try Data().write(to: text, options: .withoutOverwriting)
        let found = VideoScanner.scan(urls: [root, movie], recursive: true)
        XCTAssertEqual(found.map(\.lastPathComponent), ["影片🎬.MP4"])
    }

    func testTimecodeFormattingIsStableAndLocaleIndependent() {
        XCTAssertEqual(TimecodeFormatter.string(seconds: 3723.456, includeMilliseconds: true), "01-02-03.456")
        XCTAssertEqual(TimecodeFormatter.string(seconds: 3723.456), "01:02:03")
    }


    func testManualParserAndEndExclusion() throws {
        XCTAssertEqual(try ManualTimeParser.parse("1，00:00:02.5\n1; 00:01:00"), [1,2.5,60])
        XCTAssertThrowsError(try ManualTimeParser.parse("00:99:00"))
        XCTAssertThrowsError(try ManualTimeParser.parse("NaN"))
        var r = ExtractionRecipe(); r.samplingMode = .fixedInterval; r.intervalSeconds = 1
        XCTAssertEqual(try SamplingCalculator.times(duration: 3, recipe: r), [0,1,2])
    }
    func testRejectsNonFiniteAndUnsafeRecipeSizes() {
        var r = ExtractionRecipe(); r.rangeStart = .nan
        XCTAssertThrowsError(try r.validated())
        r = ExtractionRecipe(); r.columns = Int.max
        XCTAssertThrowsError(try r.validated())
    }
    func testUnicodeCodePointsIncludingCombiningMarksArePreserved() {
        let source = "  臺灣・日本🎬 e\u{0301} Ａ مرحبا ' \" \\  "
        XCTAssertEqual(Array(OutputPlanner.sanitizedStem(source).unicodeScalars), Array(source.unicodeScalars))
    }

    func testContactSheetAnnotationsDefaultOff() {
        let recipe = ExtractionRecipe()
        XCTAssertFalse(recipe.showFilename)
        XCTAssertFalse(recipe.showTimestamps)
    }

    func testAnnotationPreferencesRoundTripAllFourCombinations() throws {
        for filename in [false, true] {
            for timestamps in [false, true] {
                var recipe = ExtractionRecipe()
                recipe.showFilename = filename; recipe.showTimestamps = timestamps
                let encoded = try JSONEncoder().encode(recipe)
                XCTAssertEqual(try ExtractionRecipe.restoredPreferences(from: encoded), recipe)
            }
        }
    }

    func testLegacyPreferenceUpgradePreservesOtherSettingsAndReportMeaning() throws {
        var original = ExtractionRecipe()
        original.frameCount = 37; original.maximumFrames = 75
        original.aspectPreset = .nineSixteen; original.scaleMode = .fill
        original.manualTimes = [0.5, 2.5]; original.rangeStart = 0.2; original.rangeEnd = 8.5
        original.imageFormat = .png; original.jpegQuality = 0.76
        original.automaticColumns = false; original.columns = 4
        original.contactSheetCellWidth = 480; original.backgroundGray = 0.5
        original.showTimestamps = true
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        json.removeValue(forKey: "showFilename") // v10 saved schema
        let legacy = try JSONSerialization.data(withJSONObject: json)
        var expected = original
        expected.showFilename = false; expected.showTimestamps = false
        XCTAssertEqual(try ExtractionRecipe.restoredPreferences(from: legacy), expected)
        XCTAssertTrue(try JSONDecoder().decode(ExtractionRecipe.self, from: legacy).showTimestamps)
    }

    func testSheetAnnotationsChangeOnlyTheirOwnLayoutAndText() throws {
        let context = CGContext(data: nil, width: 160, height: 90, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.1, green: 0.45, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 160, height: 90))
        let frame = context.makeImage()!
        func render(_ filename: Bool, _ timestamps: Bool, _ title: String, _ times: [Double]) throws -> CGImage {
            try ContactSheetComposer.compose(images: [frame, frame], times: times, columns: 2, cellWidth: 160,
                                             showTimestamps: timestamps, showFilename: filename, title: title)
        }
        func bytes(_ image: CGImage) -> Data { image.dataProvider!.data! as Data }
        for filename in [false, true] {
            for timestamps in [false, true] {
                let result = try render(filename, timestamps, "臺灣 日本🎬 e\u{0301}.mov", [0.5, 1.5])
                XCTAssertEqual(result.width, 344)
                XCTAssertEqual(result.height, 106 + (filename ? 42 : 0) + (timestamps ? 24 : 0))
                XCTAssertEqual(bytes(result).prefix(3), Data([0, 0, 0]))
                let otherTitle = try render(filename, timestamps, "別の檔名.mp4", [0.5, 1.5])
                let otherTimes = try render(filename, timestamps, "臺灣 日本🎬 e\u{0301}.mov", [2.5, 9.5])
                XCTAssertEqual(bytes(result) == bytes(otherTitle), !filename)
                XCTAssertEqual(bytes(result) == bytes(otherTimes), !timestamps)
            }
        }
    }

    private func newTestDirectory(name: String) throws -> URL {
        let basePath = ProcessInfo.processInfo.environment["FRAMEFLOW_TEST_ROOT"]
            ?? FileManager.default.temporaryDirectory.path
        let base = URL(fileURLWithPath: basePath, isDirectory: true)
        if !FileManager.default.fileExists(atPath: base.path) {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        }
        let directory = base.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}



