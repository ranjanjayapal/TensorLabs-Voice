import AppKit
import Combine
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
    private let launchAtLoginService = LaunchAtLoginService()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

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

        let qwenEngine = Qwen3ASREngine(
            modelManager: modelManager,
            metricsLogger: metricsLogger,
            modeProvider: { [weak self] in
                self?.settingsStore.dictationMode ?? .balanced
            },
            languageProvider: { [weak self] in
                self?.settingsStore.transcriptionLanguage ?? .auto
            }
        )
        let parakeetEngine = ParakeetASREngine(
            modelManager: modelManager,
            metricsLogger: metricsLogger,
            modeProvider: { [weak self] in
                self?.settingsStore.dictationMode ?? .balanced
            },
            languageProvider: { [weak self] in
                self?.settingsStore.transcriptionLanguage ?? .auto
            }
        )
        let whisperEngine = WhisperKitEngine(
            modelManager: modelManager,
            metricsLogger: metricsLogger,
            modeProvider: { [weak self] in
                self?.settingsStore.dictationMode ?? .balanced
            },
            languageProvider: { [weak self] in
                self?.settingsStore.transcriptionLanguage ?? .auto
            }
        )
        let preferredLocalEngine = PreferredLocalASREngine(
            modelManager: modelManager,
            modeProvider: { [weak self] in
                self?.settingsStore.dictationMode ?? .balanced
            },
            languageProvider: { [weak self] in
                self?.settingsStore.transcriptionLanguage ?? .auto
            },
            qwenEngine: qwenEngine,
            parakeetEngine: parakeetEngine,
            whisperEngine: whisperEngine
        )
        let appleFallback = AppleSpeechEngine(languageProvider: { [weak self] in
            self?.settingsStore.transcriptionLanguage ?? .auto
        })
        let asrEngine: ASREngine = FallbackASREngine(primary: preferredLocalEngine, fallback: appleFallback)
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
                return "\(self.settingsStore.dictationMode.rawValue):\(self.settingsStore.transcriptionLanguage.rawValue)"
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

        // Reflect actual system login-item status in settings at launch.
        settingsStore.launchAtLogin = launchAtLoginService.isEnabled()
        settingsStore.launchAtLoginStatusText = settingsStore.launchAtLogin ? "Enabled" : "Disabled"

        settingsStore.$launchAtLogin
            .dropFirst()
            .sink { [weak self] enabled in
                guard let self else { return }
                if !self.launchAtLoginService.setEnabled(enabled) {
                    // Revert to actual state if registration fails.
                    self.settingsStore.launchAtLogin = self.launchAtLoginService.isEnabled()
                }
                self.settingsStore.launchAtLoginStatusText = self.settingsStore.launchAtLogin ? "Enabled" : "Disabled"
            }
            .store(in: &cancellables)
    }
}

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        ScrollView {
            Form {
                Picker("Dictation mode", selection: $settings.dictationMode) {
                    Text("Fast").tag(DictationMode.fast)
                    Text("Balanced").tag(DictationMode.balanced)
                    Text("Accurate Fast").tag(DictationMode.accurateFast)
                    Text("Accurate").tag(DictationMode.accurate)
                }

                Text(settings.selectedModeTechnicalDetails)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Picker("Insertion mode", selection: $settings.insertionMode) {
                    Text("Accessibility first").tag(InsertionMode.accessibilityFirst)
                    Text("Pasteboard fallback").tag(InsertionMode.pasteboardFirst)
                }

                Picker("Transcription language", selection: $settings.transcriptionLanguage) {
                    Text("Auto detect").tag(TranscriptionLanguage.auto)
                    Text("English").tag(TranscriptionLanguage.english)
                    Text("Kannada").tag(TranscriptionLanguage.kannada)
                }

                Text("Kannada works best with Balanced mode. Fast mode automatically falls back to Qwen3 for Kannada.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Toggle("Enable diagnostics logging", isOn: $settings.enableDiagnostics)
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                Text("Login item status: \(settings.launchAtLoginStatusText)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

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
