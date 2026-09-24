import Foundation
@preconcurrency import AVFoundation
import AppKit
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

public enum FrameFlowError: LocalizedError, Equatable {
    case noVideoTrack
    case notPlayable
    case invalidDuration
    case invalidRange
    case noOutputSelected
    case cannotEncodeImage
    case stopped
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "No decodable video track was found."
        case .notPlayable: return "The video cannot be played by macOS."
        case .invalidDuration: return "The video duration is invalid."
        case .invalidRange: return "The selected time range is invalid."
        case .noOutputSelected: return "Select at least one output type."
        case .cannotEncodeImage: return "The image could not be encoded."
        case .stopped: return "Processing was stopped."
        case .unsupported(let detail): return detail
        }
    }
}

public enum SamplingMode: String, Codable, CaseIterable, Sendable {
    case evenlySpaced
    case fixedInterval
    case manualTimes
}

public enum AspectPreset: String, Codable, CaseIterable, Sendable {
    case source
    case sixteenNine
    case nineSixteen
    case fourThree
    case threeFour
    case square

    public var ratio: CGFloat? {
        switch self {
        case .source: return nil
        case .sixteenNine: return 16 / 9
        case .nineSixteen: return 9 / 16
        case .fourThree: return 4 / 3
        case .threeFour: return 3 / 4
        case .square: return 1
        }
    }
}

public enum ScaleMode: String, Codable, CaseIterable, Sendable {
    case fit
    case fill
}

public enum OutputSelection: String, Codable, CaseIterable, Sendable {
    case contactSheet
    case individualFrames
    case both

    public var includesContactSheet: Bool { self == .contactSheet || self == .both }
    public var includesFrames: Bool { self == .individualFrames || self == .both }
}

public enum ImageFormat: String, Codable, CaseIterable, Sendable {
    case jpeg
    case png

    public var fileExtension: String { self == .jpeg ? "jpg" : "png" }
}

public struct ExtractionRecipe: Codable, Equatable, Sendable {
    public var samplingMode: SamplingMode = .evenlySpaced
    public var frameCount: Int = 20
    public var intervalSeconds: Double = 10
    public var rangeStart: Double = 0
    public var rangeEnd: Double? = nil
    public var manualTimes: [Double] = []
    public var maximumFrames: Int = 200
    public var aspectPreset: AspectPreset = .source
    public var scaleMode: ScaleMode = .fit
    public var outputSelection: OutputSelection = .both
    public var imageFormat: ImageFormat = .jpeg
    public var jpegQuality: Double = 0.9
    public var automaticColumns: Bool = true
    public var columns: Int = 5
    public var contactSheetCellWidth: Int = 320
    public var showFilename: Bool = false
    public var showTimestamps: Bool = false
    public var backgroundGray: Double = 0

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case samplingMode, frameCount, intervalSeconds, rangeStart, rangeEnd, manualTimes, maximumFrames, aspectPreset, scaleMode, outputSelection, imageFormat, jpegQuality, automaticColumns, columns, contactSheetCellWidth, showFilename, showTimestamps, backgroundGray
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        samplingMode = try values.decodeIfPresent(SamplingMode.self, forKey: .samplingMode) ?? samplingMode
        frameCount = try values.decodeIfPresent(Int.self, forKey: .frameCount) ?? frameCount
        intervalSeconds = try values.decodeIfPresent(Double.self, forKey: .intervalSeconds) ?? intervalSeconds
        rangeStart = try values.decodeIfPresent(Double.self, forKey: .rangeStart) ?? rangeStart
        rangeEnd = try values.decodeIfPresent(Double.self, forKey: .rangeEnd)
        manualTimes = try values.decodeIfPresent([Double].self, forKey: .manualTimes) ?? manualTimes
        maximumFrames = try values.decodeIfPresent(Int.self, forKey: .maximumFrames) ?? maximumFrames
        aspectPreset = try values.decodeIfPresent(AspectPreset.self, forKey: .aspectPreset) ?? aspectPreset
        scaleMode = try values.decodeIfPresent(ScaleMode.self, forKey: .scaleMode) ?? scaleMode
        outputSelection = try values.decodeIfPresent(OutputSelection.self, forKey: .outputSelection) ?? outputSelection
        imageFormat = try values.decodeIfPresent(ImageFormat.self, forKey: .imageFormat) ?? imageFormat
        jpegQuality = try values.decodeIfPresent(Double.self, forKey: .jpegQuality) ?? jpegQuality
        automaticColumns = try values.decodeIfPresent(Bool.self, forKey: .automaticColumns) ?? automaticColumns
        columns = try values.decodeIfPresent(Int.self, forKey: .columns) ?? columns
        contactSheetCellWidth = try values.decodeIfPresent(Int.self, forKey: .contactSheetCellWidth) ?? contactSheetCellWidth
        showFilename = try values.decodeIfPresent(Bool.self, forKey: .showFilename) ?? showFilename
        showTimestamps = try values.decodeIfPresent(Bool.self, forKey: .showTimestamps) ?? showTimestamps
        backgroundGray = try values.decodeIfPresent(Double.self, forKey: .backgroundGray) ?? backgroundGray
    }

    /// Upgrade saved UI preferences only. Historical run-report decoding stays faithful.
    public static func restoredPreferences(from data: Data) throws -> ExtractionRecipe {
        var recipe = try JSONDecoder().decode(ExtractionRecipe.self, from: data)
        let values = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if values?["showFilename"] == nil {
            // v10 always drew a title and defaulted timestamps on. Adopt the new clean default once.
            recipe.showFilename = false
            recipe.showTimestamps = false
        }
        return recipe
    }

    public func validated() throws -> ExtractionRecipe {
        guard (1...200).contains(frameCount), intervalSeconds.isFinite, intervalSeconds > 0,
              (1...200).contains(maximumFrames), (1...10).contains(columns),
              (120...640).contains(contactSheetCellWidth), rangeStart.isFinite, rangeStart >= 0,
              rangeEnd.map({ $0.isFinite && $0 > rangeStart }) ?? true,
              manualTimes.allSatisfy({ $0.isFinite && $0 >= 0 }),
              (0...1).contains(jpegQuality), (0...1).contains(backgroundGray) else {
            throw FrameFlowError.unsupported("One or more extraction settings are invalid.")
        }
        return self
    }
}

public struct MediaInfo: Codable, Equatable, Sendable {
    public let durationSeconds: Double
    public let encodedWidth: Int
    public let encodedHeight: Int
    public let displayWidth: Int
    public let displayHeight: Int
    public let rotationDegrees: Int

    public init(
        durationSeconds: Double,
        encodedWidth: Int,
        encodedHeight: Int,
        displayWidth: Int,
        displayHeight: Int,
        rotationDegrees: Int
    ) {
        self.durationSeconds = durationSeconds
        self.encodedWidth = encodedWidth
        self.encodedHeight = encodedHeight
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        self.rotationDegrees = rotationDegrees
    }

    public var isPortrait: Bool { displayHeight > displayWidth }
}

public struct ProcessResult: Sendable {
    public let outputDirectory: URL
    public let frameCount: Int
    public let contactSheetURL: URL?
    public let frameURLs: [URL]

    public init(outputDirectory: URL, frameCount: Int, contactSheetURL: URL?, frameURLs: [URL]) {
        self.outputDirectory = outputDirectory
        self.frameCount = frameCount
        self.contactSheetURL = contactSheetURL
        self.frameURLs = frameURLs
    }
}

public struct RunReport: Codable, Sendable {
    public let schemaVersion: Int
    public let sourcePath: String
    public let sourceFilename: String
    public let durationSeconds: Double
    public let displayWidth: Int
    public let displayHeight: Int
    public let rotationDegrees: Int
    public let recipe: ExtractionRecipe
    public let requestedTimes: [Double]
    public let completedFrameCount: Int
    public let createdFiles: [String]
    public let completedAtUTC: String
}

public enum SamplingCalculator {
    public static func times(duration: Double, recipe: ExtractionRecipe) throws -> [Double] {
        _ = try recipe.validated()
        guard duration.isFinite, duration > 0 else { throw FrameFlowError.invalidDuration }
        let start = max(0, recipe.rangeStart)
        let end = min(duration, recipe.rangeEnd ?? duration)
        guard start < end else { throw FrameFlowError.invalidRange }

        let result: [Double]
        switch recipe.samplingMode {
        case .evenlySpaced:
            let count = min(recipe.maximumFrames, recipe.frameCount)
            let span = end - start
            result = (0..<count).map { index in
                start + span * Double(index + 1) / Double(count + 1)
            }
        case .fixedInterval:
            var values: [Double] = []
            var cursor = start
            while cursor < end, values.count < recipe.maximumFrames {
                values.append(cursor)
                cursor += recipe.intervalSeconds
            }
            result = values
        case .manualTimes:
            result = Array(Set(recipe.manualTimes.filter { $0 >= start && $0 < end }))
                .sorted()
                .prefix(recipe.maximumFrames)
                .map { $0 }
        }
        guard !result.isEmpty else { throw FrameFlowError.invalidRange }
        return result
    }
}

public enum MediaInspector {
    public static func inspect(url: URL) async throws -> MediaInfo {
        let asset = AVURLAsset(url: url)
        let playable = try await asset.load(.isPlayable)
        guard playable else { throw FrameFlowError.notPlayable }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw FrameFlowError.invalidDuration }
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw FrameFlowError.noVideoTrack }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let transformed = CGRect(origin: .zero, size: natural).applying(transform)
        let displayWidth = max(1, Int(abs(transformed.width).rounded()))
        let displayHeight = max(1, Int(abs(transformed.height).rounded()))
        return MediaInfo(
            durationSeconds: duration,
            encodedWidth: max(1, Int(abs(natural.width).rounded())),
            encodedHeight: max(1, Int(abs(natural.height).rounded())),
            displayWidth: displayWidth,
            displayHeight: displayHeight,
            rotationDegrees: rotationDegrees(from: transform)
        )
    }

    public static func thumbnail(url: URL, maximumSize: CGSize = CGSize(width: 240, height: 160)) async throws -> CGImage {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumSize
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let second = min(max(duration * 0.2, 0), max(duration - 0.05, 0))
        return try await image(generator: generator, seconds: second)
    }

    private static func rotationDegrees(from transform: CGAffineTransform) -> Int {
        let raw = atan2(transform.b, transform.a) * 180 / .pi
        var normalized = Int(raw.rounded()) % 360
        if normalized < 0 { normalized += 360 }
        return normalized
    }

    fileprivate static func image(generator: AVAssetImageGenerator, seconds: Double) async throws -> CGImage {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        return try await withCheckedThrowingContinuation { continuation in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) {
                _, image, _, result, error in
                if let image, result == .succeeded {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? FrameFlowError.unsupported("Frame extraction failed."))
                }
            }
        }
    }
}

public enum AspectRenderer {
    public static func targetSize(source: CGSize, preset: AspectPreset, mode: ScaleMode) -> CGSize {
        guard let targetRatio = preset.ratio else {
            return CGSize(width: max(1, source.width.rounded()), height: max(1, source.height.rounded()))
        }
        let sourceRatio = source.width / source.height
        if mode == .fit {
            if sourceRatio > targetRatio {
                return CGSize(width: source.width.rounded(), height: (source.width / targetRatio).rounded())
            }
            return CGSize(width: (source.height * targetRatio).rounded(), height: source.height.rounded())
        }
        if sourceRatio > targetRatio {
            return CGSize(width: (source.height * targetRatio).rounded(), height: source.height.rounded())
        }
        return CGSize(width: source.width.rounded(), height: (source.width / targetRatio).rounded())
    }

    public static func render(
        image: CGImage,
        preset: AspectPreset,
        mode: ScaleMode,
        background: CGColor = CGColor(gray: 0, alpha: 1)
    ) throws -> CGImage {
        let source = CGSize(width: image.width, height: image.height)
        let target = targetSize(source: source, preset: preset, mode: mode)
        let width = max(1, Int(target.width))
        let height = max(1, Int(target.height))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw FrameFlowError.cannotEncodeImage }
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let scaleX = CGFloat(width) / source.width
        let scaleY = CGFloat(height) / source.height
        let scale = mode == .fit ? min(scaleX, scaleY) : max(scaleX, scaleY)
        let drawSize = CGSize(width: source.width * scale, height: source.height * scale)
        let rect = CGRect(
            x: (CGFloat(width) - drawSize.width) / 2,
            y: (CGFloat(height) - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        context.saveGState()
        context.clip(to: CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        context.restoreGState()
        guard let rendered = context.makeImage() else { throw FrameFlowError.cannotEncodeImage }
        return rendered
    }

    public static func resized(image: CGImage, width: Int) throws -> CGImage {
        let targetWidth = max(1, width)
        let targetHeight = max(1, Int((CGFloat(image.height) * CGFloat(targetWidth) / CGFloat(image.width)).rounded()))
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw FrameFlowError.cannotEncodeImage }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let result = context.makeImage() else { throw FrameFlowError.cannotEncodeImage }
        return result
    }
}

public enum ContactSheetComposer {
    public static func automaticColumns(for image: CGImage, count: Int) -> Int {
        min(max(1, count), image.height > image.width ? 3 : 5)
    }

    public static func compose(
        images: [CGImage],
        times: [Double],
        columns requestedColumns: Int,
        cellWidth: Int,
        showTimestamps: Bool,
        showFilename: Bool = false,
        title: String
    ) throws -> CGImage {
        guard let first = images.first, images.count == times.count else {
            throw FrameFlowError.cannotEncodeImage
        }
        let columns = min(images.count, max(1, requestedColumns))
        let rows = Int(ceil(Double(images.count) / Double(columns)))
        let gap = 8
        let margin = 8
        let headerHeight = showFilename ? 42 : 0
        let labelHeight = showTimestamps ? 24 : 0
        let cellHeight = max(1, Int((CGFloat(first.height) * CGFloat(cellWidth) / CGFloat(first.width)).rounded()))
        let canvasWidth = margin * 2 + columns * cellWidth + (columns - 1) * gap
        let canvasHeight = margin * 2 + headerHeight + rows * (cellHeight + labelHeight) + (rows - 1) * gap
        guard Double(canvasWidth) * Double(canvasHeight) <= 80_000_000 else {
            throw FrameFlowError.unsupported("Contact sheet exceeds 80 megapixels. Reduce cell width or frame count.")
        }
        guard let context = CGContext(
            data: nil,
            width: canvasWidth,
            height: canvasHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw FrameFlowError.cannotEncodeImage }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
        if showFilename {
            drawText(title, x: CGFloat(margin), y: CGFloat(canvasHeight - margin - 28), size: 20, weight: .bold, context: context)
        }

        for index in images.indices {
            let row = index / columns
            let column = index % columns
            let x = margin + column * (cellWidth + gap)
            let top = canvasHeight - margin - headerHeight - row * (cellHeight + labelHeight + gap)
            let y = top - cellHeight
            context.interpolationQuality = .high
            context.draw(images[index], in: CGRect(x: x, y: y, width: cellWidth, height: cellHeight))
            if showTimestamps {
                drawText(
                    TimecodeFormatter.string(seconds: times[index], includeMilliseconds: true).replacingOccurrences(of: "-", with: ":"),
                    x: CGFloat(x),
                    y: CGFloat(y - 19),
                    size: 13,
                    weight: .regular,
                    context: context
                )
            }
        }
        guard let result = context.makeImage() else { throw FrameFlowError.cannotEncodeImage }
        return result
    }

    private static func drawText(
        _ text: String,
        x: CGFloat,
        y: CGFloat,
        size: CGFloat,
        weight: NSFont.Weight,
        context: CGContext
    ) {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(calibratedWhite: 0.94, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)
    }
}

public enum TimecodeFormatter {
    public static func string(seconds: Double, includeMilliseconds: Bool = false) -> String {
        let safe = max(0, seconds)
        let totalMilliseconds = Int((safe * 1000).rounded())
        let hours = totalMilliseconds / 3_600_000
        let minutes = (totalMilliseconds / 60_000) % 60
        let secs = (totalMilliseconds / 1000) % 60
        let millis = totalMilliseconds % 1000
        if includeMilliseconds {
            return String(format: "%02d-%02d-%02d.%03d", hours, minutes, secs, millis)
        }
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }
}

public enum OutputPlanner {
    public static func sanitizedStem(_ stem: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\0")
        let parts = stem.components(separatedBy: forbidden)
        let joined = parts.joined(separator: "_")
        return joined.isEmpty ? "video" : joined
    }

    public static func uniqueDirectory(parent: URL, stem: String, fileManager: FileManager = .default) -> URL {
        let base = sanitizedStem(stem) + "-screenshots"
        var candidate = parent.appendingPathComponent(base, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(base)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }
}

public enum ImageWriter {
    public static func data(image: CGImage, format: ImageFormat, jpegQuality: Double) throws -> Data {
        let mutable = NSMutableData()
        let type = format == .jpeg ? UTType.jpeg.identifier as CFString : UTType.png.identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(mutable, type, 1, nil) else {
            throw FrameFlowError.cannotEncodeImage
        }
        let properties: CFDictionary
        if format == .jpeg {
            properties = [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary
        } else {
            properties = [:] as CFDictionary
        }
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { throw FrameFlowError.cannotEncodeImage }
        return mutable as Data
    }

    public static func write(image: CGImage, to url: URL, format: ImageFormat, jpegQuality: Double) throws {
        let encoded = try data(image: image, format: format, jpegQuality: jpegQuality)
        try encoded.write(to: url, options: .withoutOverwriting)
    }
}

public enum FrameFlowProcessor {
    public typealias ProgressHandler = @MainActor (_ completed: Int, _ total: Int, _ latest: CGImage?) -> Void
    public typealias Checkpoint = @MainActor () async throws -> Void

    public static func process(
        sourceURL: URL,
        destinationRoot: URL,
        recipe: ExtractionRecipe,
        progress: @escaping ProgressHandler,
        checkpoint: @escaping Checkpoint
    ) async throws -> ProcessResult {
        let validated = try recipe.validated()
        guard validated.outputSelection.includesContactSheet || validated.outputSelection.includesFrames else {
            throw FrameFlowError.noOutputSelected
        }
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: destinationRoot.path) {
            try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        }
        let media = try await MediaInspector.inspect(url: sourceURL)
        let times = try SamplingCalculator.times(duration: media.durationSeconds, recipe: validated)
        let finalDirectory = OutputPlanner.uniqueDirectory(
            parent: destinationRoot,
            stem: sourceURL.deletingPathExtension().lastPathComponent
        )
        let temporaryDirectory = destinationRoot.appendingPathComponent(
            ".\(finalDirectory.lastPathComponent).incomplete-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
        let framesDirectory = temporaryDirectory.appendingPathComponent("frames", isDirectory: true)
        if validated.outputSelection.includesFrames {
            try fileManager.createDirectory(at: framesDirectory, withIntermediateDirectories: false)
        }

        let asset = AVURLAsset(url: sourceURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let stem = OutputPlanner.sanitizedStem(sourceURL.deletingPathExtension().lastPathComponent)
        var frameURLs: [URL] = []
        var sheetImages: [CGImage] = []

        for (index, seconds) in times.enumerated() {
            try await checkpoint()
            if Task.isCancelled { throw FrameFlowError.stopped }
            let raw = try await MediaInspector.image(generator: generator, seconds: seconds)
            let rendered = try AspectRenderer.render(
                image: raw,
                preset: validated.aspectPreset,
                mode: validated.scaleMode,
                background: CGColor(gray: validated.backgroundGray, alpha: 1)
            )
            if validated.outputSelection.includesFrames {
                let filename = String(
                    format: "%@-%04d-%@.%@",
                    stem,
                    index + 1,
                    TimecodeFormatter.string(seconds: seconds, includeMilliseconds: true),
                    validated.imageFormat.fileExtension
                )
                let url = framesDirectory.appendingPathComponent(filename)
                try ImageWriter.write(
                    image: rendered,
                    to: url,
                    format: validated.imageFormat,
                    jpegQuality: validated.jpegQuality
                )
                frameURLs.append(url)
            }
            if validated.outputSelection.includesContactSheet {
                sheetImages.append(try AspectRenderer.resized(image: rendered, width: validated.contactSheetCellWidth))
            }
            await progress(index + 1, times.count, try AspectRenderer.resized(image: rendered, width: 240))
        }

        try await checkpoint()
        var contactSheetTemporaryURL: URL?
        if validated.outputSelection.includesContactSheet, let first = sheetImages.first {
            let columns = validated.automaticColumns
                ? ContactSheetComposer.automaticColumns(for: first, count: sheetImages.count)
                : validated.columns
            let sheet = try ContactSheetComposer.compose(
                images: sheetImages,
                times: times,
                columns: columns,
                cellWidth: validated.contactSheetCellWidth,
                showTimestamps: validated.showTimestamps,
                showFilename: validated.showFilename,
                title: sourceURL.lastPathComponent
            )
            let url = temporaryDirectory.appendingPathComponent("\(stem)-contact-sheet.\(validated.imageFormat.fileExtension)")
            try ImageWriter.write(image: sheet, to: url, format: validated.imageFormat, jpegQuality: validated.jpegQuality)
            contactSheetTemporaryURL = url
        }

        let created = try fileManager.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent).sorted()
        let formatter = ISO8601DateFormatter()
        let report = RunReport(
            schemaVersion: 1,
            sourcePath: sourceURL.path,
            sourceFilename: sourceURL.lastPathComponent,
            durationSeconds: media.durationSeconds,
            displayWidth: media.displayWidth,
            displayHeight: media.displayHeight,
            rotationDegrees: media.rotationDegrees,
            recipe: validated,
            requestedTimes: times,
            completedFrameCount: times.count,
            createdFiles: created,
            completedAtUTC: formatter.string(from: Date())
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let reportData = try encoder.encode(report)
        try reportData.write(
            to: temporaryDirectory.appendingPathComponent("run-report.json"),
            options: .withoutOverwriting
        )
        try await checkpoint()
        guard !fileManager.fileExists(atPath: finalDirectory.path) else {
            throw FrameFlowError.unsupported("The output destination changed during processing. Retry to create a new version.")
        }
        try fileManager.moveItem(at: temporaryDirectory, to: finalDirectory)
        let finalFrames = frameURLs.map { finalDirectory.appendingPathComponent("frames/\($0.lastPathComponent)") }
        let finalSheet = contactSheetTemporaryURL.map { finalDirectory.appendingPathComponent($0.lastPathComponent) }
        return ProcessResult(
            outputDirectory: finalDirectory,
            frameCount: times.count,
            contactSheetURL: finalSheet,
            frameURLs: finalFrames
        )
    }
}


public struct ScanIssue: Sendable, Identifiable {
    public var id: String { url.path + reason }
    public let url: URL
    public let reason: String
    public init(url: URL, reason: String) { self.url = url; self.reason = reason }
}
public struct ScanResult: Sendable {
    public var videos: [URL] = []
    public var issues: [ScanIssue] = []
}
public enum VideoScanner {
    public static let supportedExtensions: Set<String> = [
        "avi", "m2ts", "m4v", "mov", "mp4", "mts", "mxf", "mkv", "webm"
    ]
    public static func scan(urls: [URL], recursive: Bool) -> [URL] {
        scanDetailed(urls: urls, recursive: recursive).videos
    }
    public static func scanDetailed(urls: [URL], recursive: Bool) -> ScanResult {
        var result = ScanResult()
        var seen: Set<String> = []
        func append(_ url: URL) {
            guard let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  info.isRegularFile == true, info.isSymbolicLink != true else {
                result.issues.append(ScanIssue(url: url, reason: "scan.unreadable")); return
            }
            guard supportedExtensions.contains(url.pathExtension.lowercased()) else {
                result.issues.append(ScanIssue(url: url, reason: "scan.nonVideo")); return
            }
            guard seen.insert(url.standardizedFileURL.path).inserted else {
                result.issues.append(ScanIssue(url: url, reason: "scan.duplicate")); return
            }
            result.videos.append(url)
        }
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                result.issues.append(ScanIssue(url: url, reason: "scan.unreadable")); continue
            }
            if isDirectory.boolValue {
                let options: FileManager.DirectoryEnumerationOptions = recursive
                    ? [.skipsHiddenFiles] : [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
                var traversalIssues: [ScanIssue] = []
                let enumeration = FileManager.default.enumerator(
                    at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                    options: options, errorHandler: { failed, _ in
                        traversalIssues.append(ScanIssue(url: failed, reason: "scan.unreadable")); return true
                    })
                if enumeration == nil { result.issues.append(ScanIssue(url: url, reason: "scan.unreadable")) }
                var children: [URL] = []
                while let child = enumeration?.nextObject() as? URL {
                    if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
                    children.append(child)
                }
                for child in children.sorted(by: { $0.path < $1.path }) { append(child) }
                result.issues.append(contentsOf: traversalIssues)
            } else { append(url) }
        }
        return result
    }
}

public enum ManualTimeParser {
    public static func parse(_ text: String) throws -> [Double] {
        let tokens = text.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "，" || $0 == ";" || $0 == "；" })
        guard !tokens.isEmpty else { throw FrameFlowError.invalidRange }
        var result: [Double] = []
        for token in tokens {
            let parts = token.split(separator: ":", omittingEmptySubsequences: false)
            guard (1...3).contains(parts.count) else { throw FrameFlowError.invalidRange }
            var total: Double = 0
            for (index, part) in parts.enumerated() {
                guard let value = Double(part), value.isFinite, value >= 0,
                      (parts.count == 1 || index == 0 || value < 60),
                      (index == parts.count - 1 || value.rounded() == value) else {
                    throw FrameFlowError.invalidRange
                }
                total = total * 60 + value
            }
            result.append(total)
        }
        return Array(Set(result)).sorted()
    }
}



