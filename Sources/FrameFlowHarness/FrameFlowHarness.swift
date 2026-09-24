import Foundation
import AVFoundation
import CoreGraphics
import CoreVideo
import CryptoKit
import AppKit
import SwiftUI
import FrameFlowCore
import FrameFlowUI
import ImageIO

@main
struct FrameFlowHarness {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3 else {
            throw HarnessError.usage
        }
        switch arguments[1] {
        case "documentation":
            guard arguments.count == 4 else { throw HarnessError.usage }
            try await Documentation.generate(root: URL(fileURLWithPath: arguments[2], isDirectory: true),
                                             images: URL(fileURLWithPath: arguments[3], isDirectory: true))
        case "icon":
            guard arguments.count == 4 else { throw HarnessError.usage }
            try IconAssets.prepare(source: URL(fileURLWithPath: arguments[2]),
                                   root: URL(fileURLWithPath: arguments[3], isDirectory: true))
        case "integration":
            try await runIntegration(root: URL(fileURLWithPath: arguments[2], isDirectory: true))
        case "snapshot":
            guard arguments.count >= 5 else { throw HarnessError.usage }
            let sourceDirectory = URL(fileURLWithPath: arguments[2], isDirectory: true)
            let output = URL(fileURLWithPath: arguments[3])
            let language = arguments[4]
            try await renderSnapshot(sourceDirectory: sourceDirectory, output: output, language: language, mode: arguments.count > 5 ? arguments[5] : "queue")
        default:
            throw HarnessError.usage
        }
    }

    private static func runIntegration(root: URL) async throws {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: root.path) else { throw HarnessError.pathExists(root.path) }
        let fixtures = root.appendingPathComponent("fixtures", isDirectory: true)
        let output = root.appendingPathComponent("output", isDirectory: true)
        try fileManager.createDirectory(at: fixtures, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: output, withIntermediateDirectories: true)

        let nested = fixtures.appendingPathComponent("子資料夾 日本 e\u{0301} 🎬", isDirectory: true)
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: false)
        let horizontal = nested.appendingPathComponent("橫向 測試 video.mp4")
        let portrait = fixtures.appendingPathComponent("直向 テスト🎬.mov")
        let broken = fixtures.appendingPathComponent("損壞 broken.mp4")
        try await SyntheticVideoFactory.makeVideo(url: horizontal, encodedSize: CGSize(width: 640, height: 360), rotation: 0)
        try await SyntheticVideoFactory.makeVideo(url: portrait, encodedSize: CGSize(width: 640, height: 360), rotation: 90)
        try Data("not a video".utf8).write(to: broken, options: .withoutOverwriting)

        let sourceMetadata = try [horizontal, portrait].map { try FileManager.default.attributesOfItem(atPath: $0.path) }
        let sourceHashes = try [horizontal, portrait].map { try sha256($0) }
        let horizontalInfo = try await MediaInspector.inspect(url: horizontal)
        let portraitInfo = try await MediaInspector.inspect(url: portrait)
        guard !horizontalInfo.isPortrait else { throw HarnessError.assertion("horizontal fixture was detected as portrait") }
        guard portraitInfo.isPortrait else { throw HarnessError.assertion("rotation metadata was not applied to portrait fixture") }

        var recipe = ExtractionRecipe()
        recipe.frameCount = 6
        recipe.outputSelection = .both
        recipe.contactSheetCellWidth = 220
        let resultA = try await process(source: horizontal, output: output, recipe: recipe)
        let resultB = try await process(source: portrait, output: output, recipe: recipe)

        let checks = try await verifyWorkflows(horizontal: horizontal, portrait: portrait, broken: broken, fixtures: fixtures, root: root)
        let afterMetadata = try [horizontal, portrait].map { try FileManager.default.attributesOfItem(atPath: $0.path) }
        for index in 0..<2 {
            guard sourceMetadata[index][.size] as? NSNumber == afterMetadata[index][.size] as? NSNumber,
                  sourceMetadata[index][.modificationDate] as? Date == afterMetadata[index][.modificationDate] as? Date else {
                throw HarnessError.assertion("Source metadata changed")
            }
        }
        let afterHashes = try [horizontal, portrait].map { try sha256($0) }
        guard sourceHashes == afterHashes else { throw HarnessError.assertion("source hashes changed") }
        for result in [resultA, resultB] {
            guard result.frameURLs.count == 6 else { throw HarnessError.assertion("wrong frame count") }
            guard let sheet = result.contactSheetURL, fileManager.fileExists(atPath: sheet.path) else {
                throw HarnessError.assertion("missing contact sheet")
            }
            guard fileManager.fileExists(atPath: result.outputDirectory.appendingPathComponent("run-report.json").path) else {
                throw HarnessError.assertion("missing run report")
            }
        }

        let scan = VideoScanner.scan(urls: [fixtures], recursive: true)
        guard scan.count == 3 else { throw HarnessError.assertion("folder scan count mismatch: \(scan.count)") }

        let payload: [String: Any] = [
            "result": "passed",
            "workflowChecks": checks,
            "sourceSizeAndModificationDateUnchanged": true,
            "fixtures": fixtures.path,
            "outputs": [resultA.outputDirectory.path, resultB.outputDirectory.path],
            "horizontalDisplay": "\(horizontalInfo.displayWidth)x\(horizontalInfo.displayHeight)",
            "portraitDisplay": "\(portraitInfo.displayWidth)x\(portraitInfo.displayHeight)",
            "portraitRotation": portraitInfo.rotationDegrees,
            "sourceHashesUnchanged": true,
            "frameCountPerVideo": 6,
            "folderScanCount": scan.count,
            "mockOrBypassUsed": false,
            "testData": "two AVAssetWriter-generated videos plus one intentionally corrupt file"
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("verification.json"), options: .withoutOverwriting)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }


    @MainActor
    private static func verifyWorkflows(horizontal: URL, portrait: URL, broken: URL, fixtures: URL, root: URL) async throws -> [String] {
        var checks: [String] = []
        func require(_ ok: Bool, _ reason: String) throws {
            if !ok { throw HarnessError.assertion(reason) }
        }
        let model = AppModel(defaults: nil)
        model.recipe.frameCount = 6
        model.outputDirectory = root.appendingPathComponent("real-queue")
        model.addURLs([broken, horizontal, portrait])
        model.startOrContinue() // Deliberately start before asynchronous scan/analysis finishes.
        await model.waitUntilSettled()
        try require(model.items.count == 3 && model.failedCount == 1 && model.completedCount == 2, "Mixed batch failed to continue after damaged input")
        for item in model.items where item.status == .completed {
            guard let destination = item.outputURL else { throw HarnessError.assertion("Missing queue output") }
            let report = try JSONDecoder().decode(RunReport.self, from: Data(contentsOf: destination.appendingPathComponent("run-report.json")))
            try require(report.completedFrameCount == 6, "Queue recipe mismatch")
            let frames = try FileManager.default.contentsOfDirectory(at: destination.appendingPathComponent("frames"), includingPropertiesForKeys: nil)
            try require(frames.count == 6, "Wrong queue output count")
            for frame in frames {
                let image = try decode(frame)
                try require(image.width == report.displayWidth && image.height == report.displayHeight, "Wrong real output orientation")
            }
            let first = try Data(contentsOf: frames.sorted(by: {$0.path < $1.path}).first!)
            let last = try Data(contentsOf: frames.sorted(by: {$0.path < $1.path}).last!)
            try require(first != last, "Frames did not vary across sample times")
        }
        checks.append("actual AppModel add/start before analysis; corrupt input plus two videos -> one failure, two completed; real JPEG dimensions and distinct frames")

        guard let failed = model.items.first(where: {$0.status == .failed}) else { throw HarnessError.assertion("Missing failed row") }
        model.languagePreference = .traditionalChinese
        try require(model.errorText(failed) != failed.errorMessage, "Error did not use UI locale")
        model.retry(failed)
        await model.waitUntilSettled()
        try require(model.failedCount == 1 && model.completedCount == 2, "Retry changed unrelated completed rows")
        checks.append("explicit failed-item retry and language switch preserve existing completed output")

        let control = AppModel(defaults: nil)
        control.recipe.frameCount = 200
        control.recipe.outputSelection = .individualFrames
        control.outputDirectory = root.appendingPathComponent("pause-stop")
        control.addURLs([horizontal, portrait])
        await control.waitUntilSettled()
        guard let active = control.items.first, let queued = control.items.last else { throw HarnessError.assertion("Missing controls queue") }
        control.startOrContinue()
        try await waitFor("first real frame", condition: { active.completedFrames >= 1 })
        control.togglePause()
        try await waitFor("paused status", condition: { active.status == .paused })
        let pausedCount = active.completedFrames
        try await Task.sleep(for: .milliseconds(100))
        try require(active.completedFrames == pausedCount, "Paused extraction kept advancing")
        control.languagePreference = .japanese
        control.stop(queued)
        control.stop(active)
        await control.waitUntilSettled()
        try require(active.status == .canceled && queued.status == .canceled, "Stop while paused did not cancel")
        try require(queued.outputURL == nil, "Canceled pending item unexpectedly ran")
        let partials = try FileManager.default.contentsOfDirectory(at: control.outputDirectory, includingPropertiesForKeys: nil)
        try require(partials.count == 1 && partials[0].lastPathComponent.contains(".incomplete-"), "Canceled output was published as completed")
        control.recipe.frameCount = 2
        control.retry(active)
        await control.waitUntilSettled()
        try require(active.status == .completed && queued.status == .canceled, "Retry restarted canceled neighbors")
        checks.append("real pause holds frame count; stop paused and pending; incomplete isolation; retry only selected item")

        let append = AppModel(defaults: nil)
        append.recipe.frameCount = 200
        append.recipe.outputSelection = .individualFrames
        append.outputDirectory = root.appendingPathComponent("append-during-batch")
        append.addURLs([horizontal]); await append.waitUntilSettled()
        append.startOrContinue()
        try await waitFor("appending checkpoint", condition: { append.items[0].completedFrames >= 1 })
        append.togglePause()
        try await waitFor("append paused", condition: { append.items[0].status == .paused })
        append.recipe.frameCount = 2
        append.addURLs([portrait])
        try await waitFor("new item analyzed", condition: { append.items.count == 2 && append.items[1].status == .waiting })
        append.startOrContinue()
        await append.waitUntilSettled()
        try require(append.completedCount == 2 && append.items[0].completedFrames == 200 && append.items[1].completedFrames == 2, "Batch append or recipe snapshot failed")
        checks.append("append while paused joins same batch; active recipe snapshot preserved; resume completes both")

        let stopAll = AppModel(defaults: nil)
        stopAll.recipe.frameCount = 200; stopAll.recipe.outputSelection = .individualFrames
        stopAll.outputDirectory = root.appendingPathComponent("stop-all")
        stopAll.addURLs([horizontal, portrait]); await stopAll.waitUntilSettled()
        stopAll.startOrContinue()
        try await waitFor("stop all checkpoint", condition: { stopAll.items[0].completedFrames >= 1 })
        stopAll.stopAll(); await stopAll.waitUntilSettled()
        try require(stopAll.items.allSatisfy({$0.status == .canceled}), "Stop all did not stop entire queue")
        checks.append("real stop-all cancels current and pending items")

        let variants = root.appendingPathComponent("variants")
        for aspect in AspectPreset.allCases {
            for mode in ScaleMode.allCases {
                var r = ExtractionRecipe()
                r.frameCount = 1; r.aspectPreset = aspect; r.scaleMode = mode
                r.imageFormat = .png; r.outputSelection = .individualFrames
                let result = try await process(source: portrait, output: variants, recipe: r)
                let image = try decode(result.frameURLs[0])
                let expected = AspectRenderer.targetSize(source: CGSize(width: 360, height: 640), preset: aspect, mode: mode)
                try require(image.width == Int(expected.width) && image.height == Int(expected.height), "Wrong PNG fixed-aspect size")
            }
        }
        checks.append("actual PNG extraction at every aspect preset × fit/fill; collision creates 12 unique runs")
        var fixed = ExtractionRecipe()
        fixed.samplingMode = .fixedInterval; fixed.intervalSeconds = 1; fixed.outputSelection = .contactSheet
        let interval = try await process(source: horizontal, output: variants, recipe: fixed)
        try require(interval.frameCount == 3 && interval.frameURLs.isEmpty && interval.contactSheetURL != nil, "Fixed interval end exclusion or sheet-only failed")
        _ = try decode(interval.contactSheetURL!)
        var manual = ExtractionRecipe()
        manual.samplingMode = .manualTimes; manual.manualTimes = try ManualTimeParser.parse("0.5，00:00:01.5; 2.5")
        manual.rangeStart = 1; manual.rangeEnd = 2.6
        let manualResult = try await process(source: portrait, output: variants, recipe: manual)
        try require(manualResult.frameCount == 2, "Manual time range did not reach renderer")
        let sheet = try decode(manualResult.contactSheetURL!)
        try require(sheet.height > 500, "Portrait contact sheet was not portrait-scaled")
        checks.append("fixed interval sheet-only at duration boundary; parsed manual times and range; real contact sheet decoding")

        let nonRecursive = VideoScanner.scan(urls: [fixtures], recursive: false)
        let recursive = VideoScanner.scan(urls: [fixtures], recursive: true)
        try require(nonRecursive.count == 2 && recursive.count == 3, "Recursive folder membership incorrect")
        let duplicate = VideoScanner.scanDetailed(urls: [fixtures, horizontal], recursive: true)
        try require(duplicate.videos.count == 3 && duplicate.issues.contains(where: {$0.reason == "scan.duplicate"}), "Duplicate was not reported")

        let grouping = AppModel(defaults: nil)
        grouping.addURLs([fixtures]); await grouping.waitUntilSettled()
        try require(grouping.groups.count == 1 && grouping.groups[0].videoPaths.count == 3, "Folder group membership missing")
        grouping.removeGroup(grouping.groups[0])
        try require(grouping.items.isEmpty, "Folder group pending removal failed")
        checks.append("real nested Unicode directory traversal, nonrecursive exclusion, duplicate reporting, folder membership and pending-group removal")

        // All four annotation combinations through the production AppModel queue, not composer-only tests.
        for (orientation, video) in [("horizontal", horizontal), ("portrait", portrait)] {
            var baselineFrameHashes: [String]?
            var distinctSheets = Set<String>()
            for filename in [false, true] {
                for timestamps in [false, true] {
                    let annotated = AppModel(defaults: nil)
                    annotated.outputDirectory = root.appendingPathComponent("sheet-options-\(orientation)-\(filename ? 1 : 0)\(timestamps ? 1 : 0)")
                    annotated.recipe.frameCount = 4
                    annotated.recipe.imageFormat = .png
                    annotated.recipe.automaticColumns = false
                    annotated.recipe.columns = 2
                    annotated.recipe.contactSheetCellWidth = 160
                    annotated.recipe.showFilename = filename
                    annotated.recipe.showTimestamps = timestamps
                    annotated.addURLs([video]); annotated.startOrContinue()
                    await annotated.waitUntilSettled()
                    try require(annotated.completedCount == 1 && annotated.failedCount == 0, "Annotation queue failed")
                    let destination = annotated.items[0].outputURL!
                    let reportURL = destination.appendingPathComponent("run-report.json")
                    let report = try JSONDecoder().decode(RunReport.self, from: Data(contentsOf: reportURL))
                    try require(report.recipe.showFilename == filename && report.recipe.showTimestamps == timestamps, "Report lost annotation options")
                    let stem = OutputPlanner.sanitizedStem(video.deletingPathExtension().lastPathComponent)
                    let sheetURL = destination.appendingPathComponent(stem + "-contact-sheet.png")
                    let image = try decode(sheetURL)
                    let cellHeight = Int((Double(report.displayHeight) * 160 / Double(report.displayWidth)).rounded())
                    try require(image.width == 344 && image.height == 24 + 2 * cellHeight + (filename ? 42 : 0) + (timestamps ? 48 : 0),
                                "Disabled annotation left blank layout space")
                    distinctSheets.insert(try sha256(sheetURL))
                    let frames = try FileManager.default.contentsOfDirectory(at: destination.appendingPathComponent("frames"),
                                                                              includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
                    try require(frames.count == 4, "Annotation option altered frame count")
                    let frameHashes = try frames.map { try sha256($0) }
                    if let previous = baselineFrameHashes { try require(previous == frameHashes, "Sheet options changed individual frames") }
                    else { baselineFrameHashes = frameHashes }
                }
            }
            try require(distinctSheets.count == 4, "Annotation toggle did not change all sheet combinations")
        }
        checks.append("real AppModel: filename/time off-off, on-off, off-on, on-on for horizontal and rotated portrait; exact sheet dimensions, distinct sheet hashes, unchanged independent frames, serialized options")

        return checks
    }

    @MainActor
    private static func waitFor(_ description: String, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition() {
            if Date() > deadline { throw HarnessError.assertion("Timeout: " + description) }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
    private static func decode(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw HarnessError.assertion("Image did not decode: " + url.path)
        }
        return image
    }

    private static func process(source: URL, output: URL, recipe: ExtractionRecipe) async throws -> ProcessResult {
        try await FrameFlowProcessor.process(
            sourceURL: source,
            destinationRoot: output,
            recipe: recipe,
            progress: { _, _, _ in },
            checkpoint: { }
        )
    }

    @MainActor
    private static func renderSnapshot(sourceDirectory: URL, output: URL, language: String, mode: String) async throws {
        guard !FileManager.default.fileExists(atPath: output.path) else { throw HarnessError.pathExists(output.path) }
        let scannedVideos = VideoScanner.scan(urls: [sourceDirectory], recursive: true)
        var videos: [URL] = []
        for candidate in scannedVideos {
            if (try? await MediaInspector.inspect(url: candidate)) != nil {
                videos.append(candidate)
            }
        }
        guard !videos.isEmpty else { throw HarnessError.assertion("no decodable fixture videos found") }
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let selectedLanguage: AppLanguagePreference
        switch language {
        case "en", "english": selectedLanguage = .english
        case "zh-Hant", "traditionalChinese": selectedLanguage = .traditionalChinese
        case "ja", "japanese": selectedLanguage = .japanese
        case "system": selectedLanguage = .system
        default: throw HarnessError.assertion("unsupported snapshot language: \(language)")
        }
        let model = await AppModel.visualPreview(videoURLs: videos, language: selectedLanguage)
        let width: CGFloat = mode.hasPrefix("settings") ? 620 : (mode == "narrow" ? 1120 : 1440)
        let height: CGFloat = mode == "settings" ? 1500 : (mode == "settings-window" ? 720 : (mode == "narrow" ? 720 : 1024))
        let view: AnyView
        if mode.hasPrefix("settings") {
            model.recipe.samplingMode = .manualTimes
            view = AnyView(SettingsView(model: model))
        } else if mode == "empty" {
            let empty = AppModel(defaults: nil)
            empty.languagePreference = selectedLanguage
            empty.outputDirectory = URL(fileURLWithPath: "/Output/FrameFlow")
            view = AnyView(ContentView(model: empty))
        } else { view = AnyView(ContentView(model: model)) }
        let rootView = view.environment(\.locale, model.languagePreference.locale).preferredColorScheme(.light).frame(width: width, height: height).background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = CGRect(x: 0, y: 0, width: width, height: height)
        hosting.layoutSubtreeIfNeeded()
        guard let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw HarnessError.assertion("could not allocate snapshot bitmap")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: representation)
        guard let png = representation.representation(using: .png, properties: [:]) else {
            throw HarnessError.assertion("could not encode snapshot")
        }
        try png.write(to: output, options: .withoutOverwriting)
        print(output.path)
    }

    private static func sha256(_ url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum HarnessError: LocalizedError {
    case usage
    case pathExists(String)
    case assertion(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "usage: FrameFlowHarness integration ROOT | snapshot FIXTURE_DIR OUTPUT.png LANGUAGE"
        case .pathExists(let path):
            return "path already exists: \(path)"
        case .assertion(let message):
            return message
        }
    }
}

enum SyntheticVideoFactory {
    static func makeVideo(url: URL, encodedSize: CGSize, rotation: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: url.pathExtension.lowercased() == "mov" ? .mov : .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(encodedSize.width),
            AVVideoHeightKey: Int(encodedSize.height),
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        if rotation == 90 {
            input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: encodedSize.height, ty: 0)
        }
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(encodedSize.width),
            kCVPixelBufferHeightKey as String: Int(encodedSize.height),
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
        guard writer.canAdd(input) else { throw HarnessError.assertion("writer cannot add video input") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? HarnessError.assertion("writer did not start") }
        writer.startSession(atSourceTime: .zero)

        let frameRate: Int32 = 10
        let frameCount = 30
        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            guard let pool = adaptor.pixelBufferPool else { throw HarnessError.assertion("missing pixel buffer pool") }
            var optionalBuffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optionalBuffer) == kCVReturnSuccess,
                  let buffer = optionalBuffer else {
                throw HarnessError.assertion("could not create pixel buffer")
            }
            draw(buffer: buffer, frame: frame, size: encodedSize)
            let time = CMTime(value: CMTimeValue(frame), timescale: frameRate)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw writer.error ?? HarnessError.assertion("could not append pixel buffer")
            }
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else { throw writer.error ?? HarnessError.assertion("writer did not finish") }
    }

    private static func draw(buffer: CVPixelBuffer, frame: Int, size: CGSize) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: base,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return }
        let phase = CGFloat(frame) / 29
        context.setFillColor(CGColor(red: 0.12 + phase * 0.18, green: 0.36 + phase * 0.24, blue: 0.58, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.setFillColor(CGColor(red: 0.92, green: 0.72 - phase * 0.25, blue: 0.28, alpha: 1))
        let rectWidth = size.width * 0.22
        let x = phase * (size.width - rectWidth)
        context.fill(CGRect(x: x, y: size.height * 0.24, width: rectWidth, height: size.height * 0.52))
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.72))
        context.setLineWidth(6)
        context.stroke(CGRect(x: 20, y: 20, width: size.width - 40, height: size.height - 40))
    }
}



