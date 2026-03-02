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

        let whisperEngine = WhisperKitEngine(
            modelManager: modelManager,
            profileProvider: { [weak self] in
                self?.settingsStore.modelProfile ?? .balanced
            },
            languageProvider: { [weak self] in
                self?.settingsStore.transcriptionLanguage ?? .auto
            }
        )
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
            },
            postProcessorOptionsProvider: { [weak self] in
                guard let self else { return .default }
                return PostProcessor.Options(
                    customWordReplacements: self.settingsStore.customWordReplacements,
                    enableSmartListFormatting: self.settingsStore.enableSmartListFormatting,
                    applyEnglishCasingAndPunctuation: self.settingsStore.transcriptionLanguage != .kannada
                )
            },
            preparationKeyProvider: { [weak self] in
                guard let self else { return "balanced:auto" }
                return "\(self.settingsStore.modelProfile.rawValue):\(self.settingsStore.transcriptionLanguage.rawValue)"
            },
            insertionModeProvider: { [weak self] in
                self?.settingsStore.insertionMode ?? .accessibilityFirst
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
        ScrollView {
            Form {
                Picker("Model profile", selection: $settings.modelProfile) {
                    Text("Balanced (small.en)").tag(ModelProfile.balanced)
                    Text("Fast (base.en)").tag(ModelProfile.fast)
                    Text("Multilingual (small)").tag(ModelProfile.multilingual)
                }

                Picker("Insertion mode", selection: $settings.insertionMode) {
                    Text("Accessibility first").tag(InsertionMode.accessibilityFirst)
                    Text("Pasteboard fallback").tag(InsertionMode.pasteboardFirst)
                }

                Picker("Transcription language", selection: $settings.transcriptionLanguage) {
                    Text("Auto detect").tag(TranscriptionLanguage.auto)
                    Text("English").tag(TranscriptionLanguage.english)
                    Text("Kannada").tag(TranscriptionLanguage.kannada)
                }

                Text("For Kannada, use Model profile: Multilingual (small).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

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

                Toggle("Smart spoken list formatting", isOn: $settings.enableSmartListFormatting)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Custom word replacements")
                        .font(.headline)
                    Text("Use either `spoken=Written` or alias mode `Amma: one more, im not, ma`")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $settings.customWordReplacementsRaw)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 96)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(20)
        }
    }
}
