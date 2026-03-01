import AppKit
import SwiftUI

@main
struct TensorLabsVoiceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(settings: appDelegate.settingsStore)
                .frame(minWidth: 420, minHeight: 280)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settingsStore = SettingsStore()
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let appIcon = NSImage(named: "AppIcon") {
            NSApp.applicationIconImage = appIcon
        }

        let audioCaptureService = AudioCaptureService()
        let hotkeyService = GlobalHotkeyService()
        let textInsertionService = TextInsertionService()
        let postProcessor = PostProcessor()
        let metricsLogger = LocalMetricsLogger()
        let overlayController = ListeningOverlayController()
        let permissionService = PermissionService()
        let modelManager = ModelManager()

        let whisperEngine = WhisperKitEngine(modelManager: modelManager) { [weak self] in
            self?.settingsStore.modelProfile ?? .balanced
        }
        let appleFallback = AppleSpeechEngine()
        let asrEngine: ASREngine = FallbackASREngine(primary: whisperEngine, fallback: appleFallback)
        let dictationController = DictationController(
            engine: asrEngine,
            audioCaptureService: audioCaptureService,
            hotkeyService: hotkeyService,
            textInsertionService: textInsertionService,
            postProcessor: postProcessor,
            metricsLogger: metricsLogger,
            overlayController: overlayController,
            permissionService: permissionService,
            hotkeyProvider: { [weak self] in
                self?.settingsStore.hotkeyShortcut ?? .default
            }
        )

        menuBarController = MenuBarController(
            dictationController: dictationController,
            settingsStore: settingsStore
        )
        menuBarController?.enableDictationOnLaunch()
        dictationController.prewarmEngine()
    }
}

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Form {
            Picker("Model profile", selection: $settings.modelProfile) {
                Text("Balanced (small.en)").tag(ModelProfile.balanced)
                Text("Fast (base.en)").tag(ModelProfile.fast)
            }

            Picker("Insertion mode", selection: $settings.insertionMode) {
                Text("Accessibility first").tag(InsertionMode.accessibilityFirst)
                Text("Pasteboard fallback").tag(InsertionMode.pasteboardFirst)
            }

            Toggle("Enable diagnostics logging", isOn: $settings.enableDiagnostics)
            Toggle("Launch at login (future)", isOn: $settings.launchAtLogin)

            Picker("Hotkey key", selection: $settings.hotkeyKey) {
                ForEach(HotkeyKey.allCases, id: \.self) { key in
                    Text(key.displayName).tag(key)
                }
            }

            Toggle("Use Command", isOn: $settings.hotkeyCommand)
            Toggle("Use Shift", isOn: $settings.hotkeyShift)
            Toggle("Use Option", isOn: $settings.hotkeyOption)
            Toggle("Use Control", isOn: $settings.hotkeyControl)

            Text("Current hotkey: \(settings.hotkeyShortcut.displayString)")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text("If dictation is already enabled, toggle it off and on to apply a new hotkey.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }
}
