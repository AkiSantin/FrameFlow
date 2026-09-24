import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FrameFlowCore
import Combine

public enum AppLanguagePreference: String, CaseIterable, Identifiable {
    case system
    case english
    case traditionalChinese
    case japanese

    public var id: String { rawValue }

    public var resourceCode: String {
        switch self {
        case .system:
            return Self.effectiveResourceCode(preferredLanguages: Locale.preferredLanguages)
        case .english:
            return "en"
        case .traditionalChinese:
            return "zh-Hant"
        case .japanese:
            return "ja"
        }
    }

    public var locale: Locale {
        switch resourceCode {
        case "zh-Hant": return Locale(identifier: "zh-Hant-TW")
        case "ja": return Locale(identifier: "ja-JP")
        default: return Locale(identifier: "en")
        }
    }

    public static func effectiveResourceCode(preferredLanguages: [String]) -> String {
        guard let preferred = preferredLanguages.first?.lowercased() else { return "en" }
        if preferred.hasPrefix("ja") { return "ja" }
        if preferred.hasPrefix("zh-hant") ||
            preferred.hasPrefix("zh-tw") ||
            preferred.hasPrefix("zh-hk") ||
            preferred.hasPrefix("zh-mo") {
            return "zh-Hant"
        }
        return "en"
    }
}

public enum L10n {
    public static func string(_ key: String, language: AppLanguagePreference) -> String {
        if let selected = localizedTables[language.resourceCode]?[key] {
            return selected
        }
        return localizedTables["en"]?[key] ?? key
    }

    public static func strings(language: AppLanguagePreference) -> [String: String] {
        localizedTables[language.resourceCode] ?? localizedTables["en"] ?? [:]
    }

    private static let localizedTables: [String: [String: String]] = {
        Dictionary(uniqueKeysWithValues: ["en", "zh-Hant", "ja"].map { code in
            (code, loadTable(code: code))
        })
    }()

    private static func loadTable(code: String) -> [String: String] {
        let resourceDirectory = code
        guard let resourceRoot else { return [:] }
        let url = resourceRoot
            .appendingPathComponent("\(resourceDirectory).lproj", isDirectory: true)
            .appendingPathComponent("Localizable.strings")
        guard let data = try? Data(contentsOf: url),
              let propertyList = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let strings = propertyList as? [String: String] else {
            return [:]
        }
        return strings
    }

    // Resolve resources relative to the application; never embed a developer's build path.
    private static var resourceRoot: URL? {
        if let root = Bundle.main.resourceURL?.appendingPathComponent("FrameFlowResources"),
           FileManager.default.fileExists(atPath: root.path) { return root }
        // Explicit development/test override. The packaged app always prefers its own resources.
        if let path = ProcessInfo.processInfo.environment["FRAMEFLOW_RESOURCE_ROOT"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return nil
    }
}

public enum QueueStatus: String {
    case analyzing
    case waiting
    case processing
    case paused
    case completed
    case failed
    case canceled

    public var localizationKey: String { "status.\(rawValue)" }
}


@MainActor
public final class QueueItem: ObservableObject, Identifiable {
    public let id = UUID()
    public let sourceURL: URL
    @Published public var mediaInfo: MediaInfo?
    @Published public var thumbnail: NSImage?
    @Published public var status: QueueStatus = .analyzing
    @Published public var progress: Double = 0
    @Published public var completedFrames = 0
    @Published public var totalFrames = 0
    @Published public var previews: [NSImage] = []
    @Published public var errorMessage: String?
    @Published public var errorKey: String?
    @Published public var outputURL: URL?
    @Published public var isExpanded = false
    @Published public var recipeOverride: ExtractionRecipe?
    @Published public var usedRecipe: ExtractionRecipe?
    public init(sourceURL: URL) { self.sourceURL = sourceURL }
}

public struct InputGroup: Identifiable {
    public let id = UUID()
    public let url: URL
    public var videoPaths: [String]
}

@MainActor
public final class AppModel: ObservableObject {
    @Published public var items: [QueueItem] = []
    @Published public var recipe = ExtractionRecipe() { didSet { savePreferences() } }
    @Published public var outputDirectory: URL { didSet { savePreferences() } }
    @Published public var recursivelyScanFolders = true { didSet { savePreferences() } }
    @Published public var revealWhenComplete = false { didSet { savePreferences() } }
    @Published public var languagePreference: AppLanguagePreference = .system { didSet { savePreferences() } }
    @Published public var isDropTargeted = false
    @Published public private(set) var isProcessing = false
    @Published public private(set) var isPaused = false
    @Published public private(set) var scanCount = 0
    @Published public private(set) var analyzingCount = 0
    @Published public var scanIssues: [ScanIssue] = []
    @Published public var groups: [InputGroup] = []
    @Published public var showsAdvancedSettings = false
    @Published public var editingItem: QueueItem?
    @Published public var showsScanIssues = false
    @Published public var isVisualTest = false
    private let defaults: UserDefaults?
    private var observations: [UUID: AnyCancellable] = [:]
    private var processingTask: Task<Void, Never>?
    private var stopAllRequested = false
    private var stoppedIDs: Set<UUID> = []
    private var activeID: UUID?
    private var loadingPreferences = true

    public init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        self.outputDirectory = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FrameFlow", isDirectory: true)
        if let defaults {
            if let value = defaults.string(forKey: "FrameFlow.output") {
                outputDirectory = URL(fileURLWithPath: value, isDirectory: true)
            }
            if let data = defaults.data(forKey: "FrameFlow.recipe"),
               let decoded = try? ExtractionRecipe.restoredPreferences(from: data),
               (try? decoded.validated()) != nil { recipe = decoded }
            recursivelyScanFolders = defaults.object(forKey: "FrameFlow.recursive") as? Bool ?? true
            revealWhenComplete = defaults.bool(forKey: "FrameFlow.reveal")
            languagePreference = AppLanguagePreference(rawValue: defaults.string(forKey: "FrameFlow.language") ?? "system") ?? .system
        }
        loadingPreferences = false
    }
    private func savePreferences() {
        guard !loadingPreferences, let defaults else { return }
        defaults.set(outputDirectory.path, forKey: "FrameFlow.output")
        defaults.set(try? JSONEncoder().encode(recipe), forKey: "FrameFlow.recipe")
        defaults.set(recursivelyScanFolders, forKey: "FrameFlow.recursive")
        defaults.set(revealWhenComplete, forKey: "FrameFlow.reveal")
        defaults.set(languagePreference.rawValue, forKey: "FrameFlow.language")
    }
    public func t(_ key: String) -> String { L10n.string(key, language: languagePreference) }
    public func format(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), locale: languagePreference.locale, arguments: args)
    }
    public func effectiveRecipe(_ item: QueueItem) -> ExtractionRecipe {
        item.usedRecipe ?? item.recipeOverride ?? recipe
    }
    public func expectedFrames(_ item: QueueItem) -> Int {
        guard let info = item.mediaInfo else { return 0 }
        return (try? SamplingCalculator.times(duration: info.durationSeconds, recipe: effectiveRecipe(item)).count) ?? 0
    }
    public func errorText(_ item: QueueItem) -> String? {
        if let key = item.errorKey { return t(key) }
        return item.errorMessage
    }
    public var completedCount: Int { items.filter { $0.status == .completed }.count }
    public var processingCount: Int { items.filter { $0.status == .processing || $0.status == .paused }.count }
    public var waitingCount: Int { items.filter { $0.status == .waiting || $0.status == .analyzing }.count }
    public var failedCount: Int { items.filter { $0.status == .failed }.count }
    public var canStart: Bool { !isProcessing && (items.contains { $0.status == .waiting } || analyzingCount > 0 || scanCount > 0) }

    public func setRecursive(_ value: Bool) { recursivelyScanFolders = value }
    private func observe(_ item: QueueItem) {
        observations[item.id] = item.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
    public func addURLs(_ urls: [URL]) {
        scanCount += 1
        let recursive = recursivelyScanFolders
        Task {
            let scanned = await Task.detached {
                VideoScanner.scanDetailed(urls: urls, recursive: recursive)
            }.value
            for source in urls where (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let prefix = source.standardizedFileURL.path + "/"
                let paths = scanned.videos.map { $0.standardizedFileURL.path }.filter { $0.hasPrefix(prefix) }
                if let index = groups.firstIndex(where: { $0.url == source }) {
                    groups[index].videoPaths = paths
                } else { groups.append(InputGroup(url: source, videoPaths: paths)) }
            }
            scanIssues.append(contentsOf: scanned.issues)
            var existing = Set(items.map { $0.sourceURL.standardizedFileURL.path })
            for url in scanned.videos {
                guard existing.insert(url.standardizedFileURL.path).inserted else {
                    scanIssues.append(ScanIssue(url: url, reason: "scan.duplicate")); continue
                }
                let item = QueueItem(sourceURL: url)
                if stopAllRequested { item.status = .canceled }
                items.append(item)
                observe(item)
                if item.status != .canceled { beginAnalysis(item) }
            }
            scanCount -= 1
        }
    }
    private func beginAnalysis(_ item: QueueItem) {
        analyzingCount += 1
        Task {
            defer { analyzingCount -= 1 }
            do {
                let info = try await MediaInspector.inspect(url: item.sourceURL)
                let cg = try await MediaInspector.thumbnail(url: item.sourceURL)
                guard items.contains(where: { $0.id == item.id }), item.status == .analyzing else { return }
                item.mediaInfo = info
                item.thumbnail = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                item.status = .waiting
            } catch {
                guard items.contains(where: { $0.id == item.id }), item.status == .analyzing else { return }
                setError(error, for: item)
                item.status = .failed
            }
        }
    }
    public func waitUntilSettled() async {
        while scanCount > 0 || analyzingCount > 0 || isProcessing {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
    public func chooseInputs() { chooseInputPanel(files: true, folders: true, title: "panel.addInputs.title") }
    public func chooseFiles() { chooseInputPanel(files: true, folders: false, title: "panel.addVideos.title") }
    public func chooseFolder() { chooseInputPanel(files: false, folders: true, title: "panel.addFolder.title") }
    private func chooseInputPanel(files: Bool, folders: Bool, title: String) {
        let panel = NSOpenPanel()
        panel.title = t(title)
        panel.canChooseFiles = files
        panel.canChooseDirectories = folders
        panel.allowsMultipleSelection = true
        // Do not filter by UTType: report unsupported files after selection instead of hiding them.
        if panel.runModal() == .OK { addURLs(panel.urls) }
    }
    public func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.title = t("panel.output.title")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = outputDirectory
        if panel.runModal() == .OK, let url = panel.url { outputDirectory = url }
    }
    public func remove(_ item: QueueItem) {
        guard activeID != item.id else { return }
        items.removeAll { $0.id == item.id }
        observations.removeValue(forKey: item.id)
    }
    public func removeGroup(_ group: InputGroup) {
        for item in items where group.videoPaths.contains(item.sourceURL.standardizedFileURL.path)
            && item.id != activeID && item.status != .completed { remove(item) }
        groups.removeAll { $0.id == group.id }
    }
    public func retry(_ item: QueueItem) {
        guard item.status == .failed || item.status == .canceled else { return }
        item.errorMessage = nil; item.errorKey = nil; item.usedRecipe = nil
        item.outputURL = nil; item.progress = 0; item.completedFrames = 0
        stoppedIDs.remove(item.id)
        if item.mediaInfo == nil { item.status = .analyzing; beginAnalysis(item) }
        else { item.status = .waiting }
        if !isProcessing { startOrContinue() }
    }
    public func reveal(_ item: QueueItem) {
        guard let url = item.outputURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    public func startOrContinue() {
        if isProcessing {
            if isPaused { isPaused = false }
            return
        }
        guard canStart else { return }
        stopAllRequested = false
        isPaused = false
        isProcessing = true
        processingTask = Task { await runBatch() }
    }
    public func togglePause() {
        guard isProcessing else { return }
        isPaused.toggle()
    }
    public func stop(_ item: QueueItem) {
        if activeID == item.id { stoppedIDs.insert(item.id) }
        else if item.status == .waiting || item.status == .analyzing { item.status = .canceled }
    }
    public func stopAll() {
        guard isProcessing else { return }
        stopAllRequested = true
        for item in items where item.id != activeID && (item.status == .waiting || item.status == .analyzing) {
            item.status = .canceled
        }
    }
    public func resetDefaults() {
        recipe = ExtractionRecipe(); recursivelyScanFolders = true; revealWhenComplete = false
    }
    private func setError(_ error: Error, for item: QueueItem) {
        item.errorMessage = error.localizedDescription
        guard let e = error as? FrameFlowError else { item.errorKey = "error.media"; return }
        switch e {
        case .noVideoTrack: item.errorKey = "error.noVideoTrack"
        case .notPlayable: item.errorKey = "error.notPlayable"
        case .invalidDuration: item.errorKey = "error.invalidDuration"
        case .invalidRange: item.errorKey = "error.invalidRange"
        case .noOutputSelected: item.errorKey = "error.noOutputSelected"
        case .cannotEncodeImage: item.errorKey = "error.cannotEncodeImage"
        case .stopped: item.errorKey = "error.stopped"
        case .unsupported: item.errorKey = "error.settings"
        }
    }
    private func runBatch() async {
        defer {
            activeID = nil; isProcessing = false; isPaused = false
            stopAllRequested = false; processingTask = nil
        }
        while !stopAllRequested {
            guard let item = items.first(where: { $0.status == .waiting }) else {
                if scanCount > 0 || analyzingCount > 0 {
                    try? await Task.sleep(for: .milliseconds(20)); continue
                }
                break
            }
            if isPaused { try? await Task.sleep(for: .milliseconds(30)); continue }
            activeID = item.id
            item.status = .processing; item.isExpanded = true
            item.errorKey = nil; item.errorMessage = nil; item.previews = []
            item.completedFrames = 0; item.progress = 0
            let workRecipe = item.recipeOverride ?? recipe
            let destination = outputDirectory
            item.usedRecipe = workRecipe
            do {
                let result = try await FrameFlowProcessor.process(
                    sourceURL: item.sourceURL, destinationRoot: destination, recipe: workRecipe,
                    progress: { [weak item] count, total, latest in
                        guard let item else { return }
                        item.completedFrames = count; item.totalFrames = total
                        item.progress = Double(count) / Double(max(1, total))
                        if let latest {
                            item.previews.append(NSImage(cgImage: latest, size: NSSize(width: latest.width, height: latest.height)))
                            if item.previews.count > 4 { item.previews.removeFirst() }
                        }
                    },
                    checkpoint: { [weak self, weak item] in
                        guard let self, let item else { throw FrameFlowError.stopped }
                        while self.isPaused && !self.stopAllRequested && !self.stoppedIDs.contains(item.id) {
                            item.status = .paused
                            try await Task.sleep(for: .milliseconds(30))
                        }
                        guard !self.stopAllRequested, !self.stoppedIDs.contains(item.id) else {
                            throw FrameFlowError.stopped
                        }
                        item.status = .processing
                    })
                item.outputURL = result.outputDirectory
                item.status = .completed; item.progress = 1
            } catch FrameFlowError.stopped {
                item.status = .canceled; item.errorKey = "error.stopped"
            } catch {
                item.status = .failed; setError(error, for: item)
            }
            stoppedIDs.remove(item.id)
            activeID = nil
        }
        if revealWhenComplete, let last = items.last(where: { $0.status == .completed }) { reveal(last) }
    }
    public static func visualPreview(videoURLs: [URL], language: AppLanguagePreference) async -> AppModel {
        let model = AppModel(defaults: nil)
        model.languagePreference = language; model.isVisualTest = true
        model.outputDirectory = URL(fileURLWithPath: "/Output/FrameFlow")
        let statuses: [QueueStatus] = [.completed,.completed,.processing,.waiting,.waiting,.waiting,.failed,.waiting]
        for index in 0..<8 {
            guard !videoURLs.isEmpty else { break }
            let item = QueueItem(sourceURL: videoURLs[index % videoURLs.count])
            item.mediaInfo = try? await MediaInspector.inspect(url: item.sourceURL)
            if let cg = try? await MediaInspector.thumbnail(url: item.sourceURL) {
                item.thumbnail = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                item.previews = Array(repeating: item.thumbnail!, count: 4)
            }
            item.status = statuses[index]; item.totalFrames = 20
            item.completedFrames = index < 2 ? 20 : (index == 2 ? 8 : 0)
            item.progress = Double(item.completedFrames) / 20
            item.isExpanded = index == 2
            if index == 6 { item.errorKey = "error.noVideoTrack" }
            model.items.append(item); model.observe(item)
        }
        model.isProcessing = true
        return model
    }
}



