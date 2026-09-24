import SwiftUI
import AppKit
import FrameFlowUI

@MainActor
final class FrameFlowDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.isProcessing else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = model.t("quit.title")
        alert.informativeText = model.t("quit.message")
        alert.addButton(withTitle: model.t("action.continue"))
        alert.addButton(withTitle: model.t("quit.stop"))
        if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        model.stopAll()
        Task {
            await model.waitUntilSettled()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
@main
struct FrameFlowApplication: App {
    @NSApplicationDelegateAdaptor(FrameFlowDelegate.self) private var delegate
    @StateObject private var model: AppModel
    init() {
        if CommandLine.arguments.contains("--verify-resources") {
            let valid = L10n.string("drop.title", language: .traditionalChinese) == "拖入影片或資料夾"
                && L10n.string("drop.title", language: .japanese) == "動画またはフォルダをドロップ"
                && L10n.string("drop.title", language: .english) == "Drop Videos or Folders"
            print(valid ? "APP_BUNDLE_THREE_LANGUAGES_OK" : "APP_BUNDLE_RESOURCES_FAILED")
            exit(valid ? 0 : 1)
        }
        _model = StateObject(wrappedValue: AppModel())
    }
    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .environment(\.locale, model.languagePreference.locale)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1440, height: 980)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(model.t("about.title")) {
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .credits: NSAttributedString(string: "Santin Aki")
                    ])
                }
            }
            CommandGroup(after: .newItem) {
                Button(model.t("action.addVideos")) { model.chooseFiles() }.keyboardShortcut("o")
                Button(model.t("action.addFolders")) { model.chooseFolder() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button(model.t("action.continue")) {
                    if model.isProcessing { model.togglePause() } else { model.startOrContinue() }
                }.keyboardShortcut(.space, modifiers: [])
                Button(model.t("action.stopAll")) { model.stopAll() }.keyboardShortcut(".")
            }
        }
        Settings {
            SettingsView(model: model).frame(width: 620, height: 720)
                .environment(\.locale, model.languagePreference.locale)
        }
    }
}



