import SwiftUI
import AppKit
import FrameFlowCore

public struct ContentView: View {
    @ObservedObject private var model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            dropZone
                .padding(.horizontal, 18)
                .padding(.top, 12)
            recipeBar
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            queueHeader
            Divider()
            queue
            Divider()
            footer
        }
        .frame(minWidth: 1120, minHeight: 720)
        .font(.system(size: 14))
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $model.editingItem) { item in
            SettingsView(model: model, isSheet: true, item: item).frame(width: 620, height: 720)
        }
        .sheet(isPresented: $model.showsScanIssues) { scanDetails }
        .sheet(isPresented: $model.showsAdvancedSettings) {
            SettingsView(model: model, isSheet: true)
                .frame(width: 620, height: 720)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.stack.badge.play")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 0) {
                Text(model.t("app.name")).font(.system(size: 19, weight: .semibold))
                Text(model.t(model.isVisualTest ? "qa.testData" : "app.subtitle")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Label(model.t("output.location"), systemImage: "folder")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Text(model.outputDirectory.path)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 380)
            Button(model.t("action.choose")) { model.chooseOutputDirectory() }
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
    }

    private var dropZone: some View {
        HStack(spacing: 18) {
            Spacer()
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 38, weight: .regular))
                .foregroundStyle(model.isDropTargeted ? .blue : .green)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.t("drop.title")).font(.system(size: 24, weight: .semibold))
                Text(model.t("drop.subtitle")).font(.system(size: 14)).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.chooseInputs()
            } label: {
                Label(model.t("action.add"), systemImage: "plus")
                    .frame(width: 110)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .fixedSize()
            Button(model.t("action.addFolders")) { model.chooseFolder() }
                .controlSize(.large).fixedSize()
        }
        .padding(.horizontal, 28)
        .frame(height: 108)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.green.opacity(model.isDropTargeted ? 0.12 : 0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
                        .foregroundStyle(model.isDropTargeted ? Color.blue : Color.green.opacity(0.55))
                )
        )
        .dropDestination(for: URL.self) { urls, _ in
            model.addURLs(urls)
            return true
        } isTargeted: { targeted in
            model.isDropTargeted = targeted
        }
    }

    private var recipeBar: some View {
        HStack(spacing: 16) {
            Label(model.t("recipe.label"), systemImage: "slider.horizontal.3")
                .font(.headline)
            recipePicker(
                title: model.t("recipe.sampling"),
                selection: Binding(
                    get: { model.recipe.samplingMode },
                    set: { model.recipe.samplingMode = $0 }
                ),
                values: SamplingMode.allCases,
                label: samplingLabel
            )
            recipePicker(
                title: model.t("recipe.aspect"),
                selection: Binding(
                    get: { model.recipe.aspectPreset },
                    set: { model.recipe.aspectPreset = $0 }
                ),
                values: AspectPreset.allCases,
                label: aspectLabel
            )
            recipePicker(
                title: model.t("recipe.output"),
                selection: Binding(
                    get: { model.recipe.outputSelection },
                    set: { model.recipe.outputSelection = $0 }
                ),
                values: OutputSelection.allCases,
                label: outputLabel
            )
            Spacer()
            Button {
                model.showsAdvancedSettings = true
            } label: {
                Label(model.t("action.moreSettings"), systemImage: "chevron.down")
            }
            .buttonStyle(.plain)
        }
        .disabled(model.isProcessing && !model.isPaused)
        .padding(.horizontal, 16)
        .frame(height: 64)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.04), radius: 4, y: 1)
        )
    }

    private func recipePicker<T: Hashable & CaseIterable>(
        title: String,
        selection: Binding<T>,
        values: T.AllCases,
        label: @escaping (T) -> String
    ) -> some View where T.AllCases: RandomAccessCollection {
        HStack(spacing: 7) {
            Text(title).foregroundStyle(.secondary)
            Picker(title, selection: selection) {
                ForEach(Array(values), id: \.self) { value in Text(label(value)).tag(value) }
            }
            .labelsHidden()
            .frame(minWidth: 130)
        }
    }

    private var queueHeader: some View {
        HStack {
            Text(String(format: model.t("queue.title.count"), model.items.count))
                .font(.headline)
            if model.scanCount > 0 || model.analyzingCount > 0 {
                ProgressView().controlSize(.small)
                Text(model.t("status.analyzing")).foregroundStyle(.secondary)
            }
            Spacer()
            if !model.groups.isEmpty { Button(model.t("scan.sources")) { model.showsScanIssues = true } }
            if !model.scanIssues.isEmpty {
                Button(model.format("scan.issues.count", model.scanIssues.count)) { model.showsScanIssues = true }
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 8)
    }


    private var queue: some View {
        Group {
            if model.items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "film.stack").font(.system(size: 36)).foregroundStyle(.tertiary)
                    Text(model.t("queue.empty.title")).font(.headline)
                    Text(model.t("queue.empty.subtitle")).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    let compact = geometry.size.width < 1340
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            QueueColumnHeader(model: model, compact: compact)
                            ForEach(model.items) { item in
                                QueueRow(model: model, item: item, compact: compact)
                                Divider().padding(.leading, 72)
                            }
                        }.frame(width: geometry.size.width)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                }
            }
        }
    }
    private var footer: some View {
        HStack(spacing: 18) {
            StatusCount(color: .green, text: String(format: model.t("footer.completed"), model.completedCount))
            StatusCount(color: .blue, text: String(format: model.t("footer.processing"), model.processingCount))
            StatusCount(color: .gray, text: String(format: model.t("footer.waiting"), model.waitingCount))
            StatusCount(color: .red, text: String(format: model.t("footer.failed"), model.failedCount))
            Spacer()
            if model.isProcessing {
                Button {
                    model.togglePause()
                } label: {
                    Label(model.isPaused ? model.t("action.continue") : model.t("action.pauseAll"),
                          systemImage: model.isPaused ? "play.fill" : "pause.fill")
                }
                Button(role: .destructive) {
                    model.stopAll()
                } label: {
                    Label(model.t("action.stopAll"), systemImage: "stop.fill")
                }
            }
            Button {
                model.startOrContinue()
            } label: {
                Label(primaryActionTitle, systemImage: "play.fill")
                    .frame(minWidth: 148)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isProcessing ? !model.isPaused : !model.canStart)
        }
        .padding(.horizontal, 18)
        .frame(height: 66)
    }


    private var scanDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.t("scan.title")).font(.title2)
            ScrollView {
                LazyVStack(alignment: .leading) {
                    ForEach(model.groups) { group in
                        Text(group.url.path).font(.headline).textSelection(.enabled)
                        HStack {
                            Text(model.format("queue.title.count", group.videoPaths.count))
                            Button(model.t("scan.rescan")) { model.addURLs([group.url]) }
                            Button(model.t("scan.removeGroup")) { model.removeGroup(group) }
                        }
                        Divider()
                    }
                    ForEach(Array(model.scanIssues.enumerated()), id: \.offset) { _, issue in
                        Text(model.t(issue.reason)).fontWeight(.medium)
                        Text(issue.url.path).font(.caption).textSelection(.enabled)
                        Divider()
                    }
                }
            }
            Button(model.t("action.done")) { model.showsScanIssues = false }
        }.padding(24).frame(width: 620, height: 480)
    }
    private var primaryActionTitle: String {
        if model.isPaused { return model.t("action.continue") }
        if model.isProcessing { return String(format: model.t("action.processing.count"), model.waitingCount + model.processingCount) }
        return model.t("action.start")
    }

    private func samplingLabel(_ mode: SamplingMode) -> String {
        switch mode {
        case .evenlySpaced: return String(format: model.t("sampling.even.count"), model.recipe.frameCount)
        case .fixedInterval: return String(format: model.t("sampling.interval.seconds"), model.recipe.intervalSeconds)
        case .manualTimes: return model.t("sampling.manual")
        }
    }

    private func aspectLabel(_ preset: AspectPreset) -> String {
        switch preset {
        case .source: return model.t("aspect.auto")
        case .sixteenNine: return "16:9"
        case .nineSixteen: return "9:16"
        case .fourThree: return "4:3"
        case .threeFour: return "3:4"
        case .square: return "1:1"
        }
    }

    private func outputLabel(_ selection: OutputSelection) -> String {
        switch selection {
        case .contactSheet: return model.t("output.contactSheet")
        case .individualFrames: return model.t("output.frames")
        case .both: return model.t("output.both")
        }
    }
}

private struct QueueColumnHeader: View {
    @ObservedObject var model: AppModel
    let compact: Bool
    var body: some View {
        HStack(spacing: 12) {
            Text("#").frame(width: 44)
            Text(model.t("column.thumbnail")).frame(width: 92, alignment: .leading)
            Text(model.t("column.filename")).frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
            if !compact { Text(model.t("column.duration")).frame(width: 82, alignment: .leading) }
            Text(model.t("column.size")).frame(width: 110, alignment: .leading)
            Text(model.t("column.direction")).frame(width: 90, alignment: .leading)
            if !compact { Text(model.t("column.output")).frame(width: 180, alignment: .leading) }
            Text(model.t("column.status")).frame(width: 180, alignment: .leading)
            Text(model.t("column.actions")).frame(width: 200, alignment: .trailing)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .frame(height: 34)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct QueueRow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var item: QueueItem
    let compact: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { item.isExpanded.toggle() } label: {
                    HStack(spacing: 3) {
                        Image(systemName: item.isExpanded ? "chevron.down" : "chevron.right").font(.system(size: 10))
                        Text(indexText)
                    }.frame(width: 44)
                }.buttonStyle(.plain)
                    .accessibilityLabel(model.t(item.isExpanded ? "action.collapseDetails" : "action.expandDetails"))
                    .help(model.t(item.isExpanded ? "action.collapseDetails" : "action.expandDetails"))
                thumbnail
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.sourceURL.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        .help(item.sourceURL.path)
                    if let error = model.errorText(item), item.status == .failed {
                        Text(error).font(.caption).foregroundStyle(.red).lineLimit(1)
                    }
                }
                .frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
                if !compact { Text(durationText).frame(width: 82, alignment: .leading) }
                Text(sizeText).frame(width: 110, alignment: .leading)
                Label(directionText, systemImage: item.mediaInfo?.isPortrait == true ? "rectangle.portrait" : "rectangle")
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .frame(width: 90, alignment: .leading)
                if !compact {
                VStack(alignment: .leading, spacing: 2) {
                    Text(outputSummary).lineLimit(1)
                    Text(String(format: model.t("output.estimated.count"), item.totalFrames > 0 ? item.totalFrames : model.expectedFrames(item)))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(width: 180, alignment: .leading)
                }
                statusView.frame(width: 180, alignment: .leading)
                actions.frame(width: 200, alignment: .trailing)
            }
            .font(.system(size: 14))
            .padding(.horizontal, 18)
            .padding(.vertical, 5)
            .background(rowBackground)
            .contentShape(Rectangle())
            .onTapGesture { item.isExpanded.toggle() }
            if item.isExpanded { expandedPreview }
        }
    }

    private var indexText: String {
        guard let index = model.items.firstIndex(where: { $0.id == item.id }) else { return "–" }
        return String(index + 1)
    }

    private var thumbnail: some View {
        Group {
            if let image = item.thumbnail {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                ZStack {
                    Color(nsColor: .controlBackgroundColor)
                    if item.status == .analyzing { ProgressView().controlSize(.small) }
                    else { Image(systemName: "film").foregroundStyle(.secondary) }
                }
            }
        }
        .frame(width: 92, height: 50)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var durationText: String {
        item.mediaInfo.map { TimecodeFormatter.string(seconds: $0.durationSeconds) } ?? "—"
    }

    private var sizeText: String {
        item.mediaInfo.map { "\($0.displayWidth) × \($0.displayHeight)" } ?? "—"
    }

    private var directionText: String {
        guard let info = item.mediaInfo else { return "—" }
        return model.t(info.isPortrait ? "direction.portrait" : "direction.landscape")
    }

    private var outputSummary: String {
        switch model.effectiveRecipe(item).outputSelection {
        case .contactSheet: return model.t("output.contactSheet")
        case .individualFrames: return model.t("output.frames")
        case .both: return model.t("output.both")
        }
    }

    private var statusView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(model.t(item.status.localizationKey), systemImage: statusIcon)
                .foregroundStyle(statusColor)
            if item.status != .analyzing {
                HStack(spacing: 8) {
                    ProgressView(value: item.progress).tint(item.status == .completed ? .green : .blue).frame(width: 112)
                    Text("\(item.completedFrames)/\(item.totalFrames > 0 ? item.totalFrames : model.expectedFrames(item))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            switch item.status {
            case .completed:
                Button(model.t("action.reveal")) { model.reveal(item) }
            case .failed, .canceled:
                Button(model.t("action.retry")) { model.retry(item) }
                Button { item.isExpanded.toggle() } label: { Image(systemName: "info.circle") }
                    .help(model.t("action.showReason")).accessibilityLabel(model.t("action.showReason"))
            case .processing, .paused:
                Button(model.t("action.stopItem")) { model.stop(item) }
            default:
                Button(model.t("action.cancel")) { model.remove(item) }
                if item.status == .waiting {
                    Button { model.editingItem = item } label: { Image(systemName: "slider.horizontal.3") }
                        .help(model.t("action.itemSettings")).accessibilityLabel(model.t("action.itemSettings"))
                }
            }
            Menu {
                Button(model.t("action.removeQueue"), role: .destructive) { model.remove(item) }
                    .disabled(item.status == .processing || item.status == .paused)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
        }
        .controlSize(.regular)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var expandedPreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = model.errorText(item) { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let diagnostic = item.errorMessage { Text(diagnostic).font(.caption).textSelection(.enabled) }
            HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(format: model.t("preview.progress"), item.completedFrames, item.totalFrames))
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    ForEach(Array(item.previews.enumerated()), id: \.offset) { _, image in
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: compact ? 100 : 150, height: 108)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    if item.previews.isEmpty {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .frame(width: 150, height: 108)
                            .overlay(ProgressView())
                    }
                }
            }
            Divider().frame(height: 112)
            VStack(alignment: .leading, spacing: 5) {
                DetailLine(label: model.t("detail.filename"), value: item.sourceURL.lastPathComponent)
                DetailLine(label: model.t("detail.duration"), value: durationText)
                DetailLine(label: model.t("detail.size"), value: sizeText)
                DetailLine(label: model.t("detail.output"), value: outputSummary)
                DetailLine(label: model.t("detail.destination"), value: item.outputURL?.path ?? model.outputDirectory.path)
            }
            .font(.system(size: 12))
            Spacer()
        }
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 12)
        .background(Color.blue.opacity(0.055))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.blue.opacity(0.22)))
    }

    private var rowBackground: Color {
        switch item.status {
        case .processing, .paused: return Color.blue.opacity(0.07)
        case .failed: return Color.red.opacity(0.065)
        default: return Color.clear
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .completed: return .green
        case .processing, .paused: return .blue
        case .failed: return .red
        default: return .secondary
        }
    }

    private var statusIcon: String {
        switch item.status {
        case .completed: return "checkmark.circle.fill"
        case .processing: return "arrow.triangle.2.circlepath.circle.fill"
        case .paused: return "pause.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .canceled: return "xmark.circle"
        case .analyzing: return "waveform.path.ecg"
        case .waiting: return "clock"
        }
    }
}

private struct DetailLine: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 86, alignment: .leading)
            Text(value).lineLimit(1).truncationMode(.middle)
        }
    }
}

private struct StatusCount: View {
    let color: Color
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(text).font(.callout)
        }
    }
}


public struct SettingsView: View {
    @ObservedObject private var model: AppModel
    private let isSheet: Bool
    private let item: QueueItem?
    @Environment(\.dismiss) private var dismiss
    @State private var manualText = ""
    @State private var manualInvalid = false

    public init(model: AppModel, isSheet: Bool = false, item: QueueItem? = nil) {
        self.model = model; self.isSheet = isSheet; self.item = item
    }
    private var recipe: ExtractionRecipe { item?.recipeOverride ?? model.recipe }
    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.t(item == nil ? "action.moreSettings" : "action.itemSettings")).font(.title2.bold())
                Spacer()
                if item == nil {
                    Picker(model.t("settings.language"), selection: $model.languagePreference) {
                        Text(model.t("language.system")).tag(AppLanguagePreference.system)
                        Text("English").tag(AppLanguagePreference.english)
                        Text("繁體中文").tag(AppLanguagePreference.traditionalChinese)
                        Text("日本語").tag(AppLanguagePreference.japanese)
                    }.frame(width: 220)
                }
                if isSheet { Button(model.t("action.done")) { dismiss() }.keyboardShortcut(.defaultAction) }
            }.padding(20)
            Form {
                Section(model.t("settings.sampling")) {
                    Picker(model.t("recipe.sampling"), selection: binding(\.samplingMode)) {
                        Text(model.t("sampling.even")).tag(SamplingMode.evenlySpaced)
                        Text(model.t("sampling.interval")).tag(SamplingMode.fixedInterval)
                        Text(model.t("sampling.manual")).tag(SamplingMode.manualTimes)
                    }
                    if recipe.samplingMode == .evenlySpaced {
                        Stepper(value: binding(\.frameCount), in: 1...200) {
                            Text(String(format: model.t("settings.frameCount"), recipe.frameCount))
                        }
                    }
                    if recipe.samplingMode == .fixedInterval {
                        TextField(model.t("settings.interval"), value: binding(\.intervalSeconds), format: .number)
                    }
                    if recipe.samplingMode == .manualTimes {
                        TextField(model.t("settings.manualTimes"), text: $manualText, axis: .vertical)
                            .lineLimit(2...4)
                            .onChange(of: manualText) { _, text in
                                do {
                                    binding(\.manualTimes).wrappedValue = try ManualTimeParser.parse(text)
                                    manualInvalid = false
                                } catch {
                                    binding(\.manualTimes).wrappedValue = []
                                    manualInvalid = true
                                }
                            }
                        Text(model.t(manualInvalid ? "settings.manualInvalid" : "settings.manualHint"))
                            .font(.caption).foregroundStyle(manualInvalid ? .red : .secondary)
                    }
                    Stepper(value: binding(\.maximumFrames), in: 1...200) {
                        Text(String(format: model.t("settings.maximum"), recipe.maximumFrames))
                    }
                    TextField(model.t("settings.rangeStart"), value: binding(\.rangeStart), format: .number)
                    TextField(model.t("settings.rangeEnd"), value: binding(\.rangeEnd), format: .number)
                    Text(model.t("settings.rangeHint")).font(.caption).foregroundStyle(.secondary)
                }
                Section(model.t("settings.image")) {
                    Picker(model.t("recipe.aspect"), selection: binding(\.aspectPreset)) {
                        Text(model.t("aspect.auto")).tag(AspectPreset.source)
                        Text("16:9").tag(AspectPreset.sixteenNine)
                        Text("9:16").tag(AspectPreset.nineSixteen)
                        Text("4:3").tag(AspectPreset.fourThree)
                        Text("3:4").tag(AspectPreset.threeFour)
                        Text("1:1").tag(AspectPreset.square)
                    }
                    Picker(model.t("settings.scaleMode"), selection: binding(\.scaleMode)) {
                        Text(model.t("scale.fit")).tag(ScaleMode.fit)
                        Text(model.t("scale.fill")).tag(ScaleMode.fill)
                    }
                    Picker(model.t("settings.background"), selection: binding(\.backgroundGray)) {
                        Text(model.t("color.black")).tag(0.0)
                        Text(model.t("color.white")).tag(1.0)
                        Text(model.t("color.gray")).tag(0.5)
                    }
                    Picker(model.t("recipe.output"), selection: binding(\.outputSelection)) {
                        Text(model.t("output.both")).tag(OutputSelection.both)
                        Text(model.t("output.contactSheet")).tag(OutputSelection.contactSheet)
                        Text(model.t("output.frames")).tag(OutputSelection.individualFrames)
                    }
                    Picker(model.t("settings.format"), selection: binding(\.imageFormat)) {
                        Text("JPEG").tag(ImageFormat.jpeg)
                        Text("PNG").tag(ImageFormat.png)
                    }
                    if recipe.imageFormat == .jpeg {
                        LabeledContent(model.t("settings.quality")) {
                            Slider(value: binding(\.jpegQuality), in: 0.1...1)
                            Text(recipe.jpegQuality, format: .percent.precision(.fractionLength(0))).frame(width: 44)
                        }
                    }
                }
                if recipe.outputSelection.includesContactSheet {
                    Section(model.t("output.contactSheet")) {
                        Toggle(model.t("settings.autoColumns"), isOn: binding(\.automaticColumns))
                        if !recipe.automaticColumns {
                            Stepper(value: binding(\.columns), in: 1...10) {
                                Text(String(format: model.t("settings.columns"), recipe.columns))
                            }
                        }
                        Stepper(value: binding(\.contactSheetCellWidth), in: 120...640, step: 20) {
                            Text(String(format: model.t("settings.cellWidth"), recipe.contactSheetCellWidth))
                        }
                        Toggle(model.t("settings.filename"), isOn: binding(\.showFilename))
                        Toggle(model.t("settings.timestamps"), isOn: binding(\.showTimestamps))
                        Text(model.t("settings.cleanSheetHint")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if item == nil {
                    Section(model.t("settings.general")) {
                        Toggle(model.t("settings.recursive"), isOn: $model.recursivelyScanFolders)
                        Toggle(model.t("settings.reveal"), isOn: $model.revealWhenComplete)
                        Picker(model.t("settings.language"), selection: $model.languagePreference) {
                            Text(model.t("language.system")).tag(AppLanguagePreference.system)
                            Text("English").tag(AppLanguagePreference.english)
                            Text("繁體中文").tag(AppLanguagePreference.traditionalChinese)
                            Text("日本語").tag(AppLanguagePreference.japanese)
                        }
                        Text(model.outputDirectory.path).font(.caption).textSelection(.enabled)
                        Button(model.t("action.choose")) { model.chooseOutputDirectory() }
                        Button(model.t("settings.reset")) { model.resetDefaults() }
                    }
                } else {
                    Button(model.t("settings.useGlobal")) { item?.recipeOverride = nil; dismiss() }
                }
            }.formStyle(.grouped)
            .onAppear { manualText = recipe.manualTimes.map { String($0) }.joined(separator: ", ") }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.locale, model.languagePreference.locale)
    }
    private func binding<T>(_ keyPath: WritableKeyPath<ExtractionRecipe, T>) -> Binding<T> {
        Binding(
            get: { recipe[keyPath: keyPath] },
            set: { value in
                if let item {
                    var custom = item.recipeOverride ?? model.recipe
                    custom[keyPath: keyPath] = value
                    item.recipeOverride = custom
                } else { model.recipe[keyPath: keyPath] = value }
            })
    }
}



