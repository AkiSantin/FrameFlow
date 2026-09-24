import Foundation
import AppKit
import SwiftUI
import ImageIO
import CryptoKit
import FrameFlowCore
import FrameFlowUI

enum Documentation {
    @MainActor
    static func generate(root: URL, images: URL) async throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: root.path), !fm.fileExists(atPath: images.path) else {
            throw HarnessError.assertion("Documentation destinations must be new")
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: images, withIntermediateDirectories: true)
        let inputs = root.appendingPathComponent("generated-videos")
        try fm.createDirectory(at: inputs, withIntermediateDirectories: false)
        let videos = [
            inputs.appendingPathComponent("Demo_Landscape.mp4"),
            inputs.appendingPathComponent("示範_直向.mov"),
            inputs.appendingPathComponent("デモ_正方形.mp4")
        ]
        try await SyntheticVideoFactory.makeVideo(url: videos[0], encodedSize: CGSize(width: 640, height: 360), rotation: 0)
        try await SyntheticVideoFactory.makeVideo(url: videos[1], encodedSize: CGSize(width: 640, height: 360), rotation: 90)
        try await SyntheticVideoFactory.makeVideo(url: videos[2], encodedSize: CGSize(width: 480, height: 480), rotation: 0)
        let sourceHashes = try videos.map { SHA256.hash(data: try Data(contentsOf: $0)) }
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let model = AppModel(defaults: nil)
        model.recipe.frameCount = 20
        model.recipe.automaticColumns = false
        model.recipe.columns = 4
        model.recipe.contactSheetCellWidth = 160
        model.recipe.imageFormat = .png
        model.outputDirectory = root.appendingPathComponent("actual-output")
        model.addURLs(videos)
        model.startOrContinue()
        await model.waitUntilSettled()
        guard model.completedCount == 3, model.failedCount == 0 else {
            throw HarnessError.assertion("Documentation batch did not really complete")
        }
        var checks: [[String: Any]] = []
        for (count, columns) in [(9, 3), (20, 4), (18, 3)] {
            for (orientation, video) in [("landscape", videos[0]), ("portrait", videos[1])] {
                let example = AppModel(defaults: nil)
                example.recipe.frameCount = count
                example.recipe.automaticColumns = false
                example.recipe.columns = columns
                example.recipe.contactSheetCellWidth = 160
                example.recipe.imageFormat = .png
                example.recipe.outputSelection = .contactSheet
                example.outputDirectory = root.appendingPathComponent("layout-\(count)-\(columns)-\(orientation)")
                example.addURLs([video]); example.startOrContinue()
                await example.waitUntilSettled()
                guard example.completedCount == 1, let output = example.items[0].outputURL else {
                    throw HarnessError.assertion("Example extraction failed")
                }
                let report = try JSONDecoder().decode(RunReport.self, from: Data(contentsOf: output.appendingPathComponent("run-report.json")))
                let sheet = output.appendingPathComponent(video.deletingPathExtension().lastPathComponent + "-contact-sheet.png")
                guard let source = CGImageSourceCreateWithURL(sheet as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw HarnessError.assertion("Missing example image") }
                let rows = count / columns
                let cellHeight = Int((Double(report.displayHeight) * 160 / Double(report.displayWidth)).rounded())
                guard report.completedFrameCount == count, image.width == columns * 168 + 8,
                      image.height == rows * (cellHeight + 8) + 8,
                      !report.recipe.showFilename, !report.recipe.showTimestamps else {
                    throw HarnessError.assertion("Layout count, dimensions or annotation regression")
                }
                let filename = "sheet-\(columns)x\(rows)-\(orientation).png"
                try Data(contentsOf: sheet).write(to: images.appendingPathComponent(filename), options: .withoutOverwriting)
                checks.append(["file": filename, "frames": count, "columns": columns, "rows": rows,
                               "width": image.width, "height": image.height])
            }
        }
        // Presentation-only paths are fictional; processing above used the real application queue.
        model.isVisualTest = true
        model.outputDirectory = URL(fileURLWithPath: "/Demo/Output")
        for item in model.items {
            item.isExpanded = item.sourceURL == videos[1]
            item.outputURL = URL(fileURLWithPath: "/Demo/Output/" + item.sourceURL.deletingPathExtension().lastPathComponent + "-screenshots")
        }
        for (code, language) in [("en", AppLanguagePreference.english), ("zh-Hant", .traditionalChinese), ("ja", .japanese)] {
            model.languagePreference = language
            try render(ContentView(model: model), language: language, width: 1440, height: 720,
                       output: images.appendingPathComponent("overview-\(code).png"))
            for automatic in [true, false] {
                model.recipe.automaticColumns = automatic
                try render(SettingsView(model: model, isSheet: true), language: language, width: 620, height: 1400,
                           output: images.appendingPathComponent("settings-\(automatic ? "auto" : "manual")-\(code).png"))
            }
        }
        let afterHashes = try videos.map { SHA256.hash(data: try Data(contentsOf: $0)) }
        guard sourceHashes == afterHashes else { throw HarnessError.assertion("Demo sources changed") }
        let report: [String: Any] = ["result": "passed", "layouts": checks, "completedDemoVideos": 3,
            "personalMediaUsed": false, "queueStatusesSynthesized": false,
            "screenshotMethod": "Production SwiftUI views, offscreen NSHostingView; fictional display paths only",
            "data": "Three AVAssetWriter-generated geometric videos", "sourceHashesUnchanged": true]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("documentation-verification.json"), options: .withoutOverwriting)
        print("DOCUMENTATION_REAL_QUEUE_AND_SIX_LAYOUTS_OK")
    }

    @MainActor
    private static func render<V: View>(_ view: V, language: AppLanguagePreference, width: CGFloat, height: CGFloat, output: URL) throws {
        let root = view.environment(\.locale, language.locale).preferredColorScheme(.light)
            .frame(width: width, height: height).background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(x: 0, y: 0, width: width, height: height)
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw HarnessError.assertion("Cannot allocate documentation screenshot")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw HarnessError.assertion("Cannot encode documentation screenshot")
        }
        try png.write(to: output, options: .withoutOverwriting)
    }
}

