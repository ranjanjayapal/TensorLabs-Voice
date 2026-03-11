import AppKit
import Foundation

@MainActor
final class DictationController {
    private let engine: ASREngine
    private let audioCaptureService: AudioCaptureService
    private let hotkeyService: GlobalHotkeyService
    private let textInsertionService: TextInsertionService
    private let postProcessor: PostProcessor
    private let metricsLogger: LocalMetricsLogger
    private let overlayController: ListeningOverlayController
    private let permissionService: PermissionService
    private let hotkeyProvider: () -> HotkeyShortcut
    private let postProcessorOptionsProvider: () -> PostProcessor.Options
    private let preparationKeyProvider: () -> String
    private let insertionModeProvider: () -> InsertionMode

    private var captureTask: Task<Void, Never>?
    private var prepareTask: Task<Bool, Never>?
    private var isCapturing = false
    private var isPrepared = false
    private var lastPreparationKey: String?

    private(set) var isEnabled = false

    init(
        engine: ASREngine,
        audioCaptureService: AudioCaptureService,
        hotkeyService: GlobalHotkeyService,
        textInsertionService: TextInsertionService,
        postProcessor: PostProcessor,
        metricsLogger: LocalMetricsLogger,
        overlayController: ListeningOverlayController,
        permissionService: PermissionService,
        hotkeyProvider: @escaping () -> HotkeyShortcut,
        postProcessorOptionsProvider: @escaping () -> PostProcessor.Options,
        preparationKeyProvider: @escaping () -> String,
        insertionModeProvider: @escaping () -> InsertionMode
    ) {
        self.engine = engine
        self.audioCaptureService = audioCaptureService
        self.hotkeyService = hotkeyService
        self.textInsertionService = textInsertionService
        self.postProcessor = postProcessor
        self.metricsLogger = metricsLogger
        self.overlayController = overlayController
        self.permissionService = permissionService
        self.hotkeyProvider = hotkeyProvider
        self.postProcessorOptionsProvider = postProcessorOptionsProvider
        self.preparationKeyProvider = preparationKeyProvider
        self.insertionModeProvider = insertionModeProvider
    }

    func setEnabled(_ enabled: Bool) async {
        if enabled {
            let status = await permissionService.requestRequiredPermissions(
                requiresSpeechRecognition: engine.requiresSpeechRecognitionPermission
            )
            guard status.satisfiesRequirements(requiresSpeechRecognition: engine.requiresSpeechRecognitionPermission) else {
                metricsLogger.log(event: "permissions_denied", metadata: [
                    "microphone": status.microphoneGranted ? "granted" : "denied",
                    "speech": status.speechGranted ? "granted" : "denied",
                    "accessibility": status.accessibilityGranted ? "granted" : "denied",
                ])
                showPermissionGuidance(
                    microphoneGranted: status.microphoneGranted,
                    speechGranted: status.speechGranted,
                    accessibilityGranted: status.accessibilityGranted
                )
                isEnabled = false
                return
            }

            hotkeyService.startListening(shortcut: hotkeyProvider(), onPress: { [weak self] in
                self?.startCapture()
            }, onRelease: { [weak self] in
                self?.stopCapture(graceful: true)
            })

            isEnabled = true
            return
        }

        hotkeyService.stopListening()
        stopCapture(graceful: false)
        isEnabled = false
    }

    func prewarmEngine() {
        Task { @MainActor in
            let status = permissionService.currentStatus()
            guard status.satisfiesRequirements(requiresSpeechRecognition: engine.requiresSpeechRecognitionPermission) else {
                return
            }
            _ = await prepareIfNeeded()
        }
    }

    private func showPermissionGuidance(
        microphoneGranted: Bool,
        speechGranted: Bool,
        accessibilityGranted: Bool
    ) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Permissions Required"
        if !microphoneGranted, !speechGranted, !accessibilityGranted {
            alert.informativeText = "Enable Microphone, Speech Recognition, and Accessibility for TensorLabsVoice in System Settings > Privacy & Security."
        } else if !microphoneGranted, !speechGranted {
            alert.informativeText = "Enable Microphone and Speech Recognition for TensorLabsVoice in System Settings > Privacy & Security."
        } else if !microphoneGranted, !accessibilityGranted {
            alert.informativeText = "Enable Microphone and Accessibility for TensorLabsVoice in System Settings > Privacy & Security."
        } else if !speechGranted, !accessibilityGranted {
            alert.informativeText = "Enable Speech Recognition and Accessibility for TensorLabsVoice in System Settings > Privacy & Security."
        } else if !microphoneGranted {
            alert.informativeText = "Enable Microphone for TensorLabsVoice in System Settings > Privacy & Security > Microphone."
        } else if !accessibilityGranted {
            alert.informativeText = "Enable Accessibility for TensorLabsVoice in System Settings > Privacy & Security > Accessibility."
        } else {
            alert.informativeText = "Enable Speech Recognition for TensorLabsVoice in System Settings > Privacy & Security > Speech Recognition."
        }
        alert.addButton(withTitle: "Open Privacy Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            let targetPane: String
            if !accessibilityGranted {
                targetPane = "Privacy_Accessibility"
            } else if !microphoneGranted {
                targetPane = "Privacy_Microphone"
            } else {
                targetPane = "Privacy_SpeechRecognition"
            }
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(targetPane)") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func prepareIfNeeded() async -> Bool {
        let preparationKey = preparationKeyProvider()
        if isPrepared, lastPreparationKey == preparationKey {
            return true
        }

        if let prepareTask {
            return await prepareTask.value
        }

        let task = Task<Bool, Never> { @MainActor in
            defer { prepareTask = nil }

            do {
                metricsLogger.logStatus(
                    "Preparing dictation engine for \(preparationKey)",
                    metadata: ["preparation_key": preparationKey]
                )
                try await engine.prepare()
                isPrepared = true
                lastPreparationKey = preparationKey

                if let fallbackEngine = engine as? FallbackASREngine {
                    var metadata: [String: String] = [
                        "engine_used": fallbackEngine.lastEngineUsed,
                        "fallback_used": fallbackEngine.lastFallbackUsed ? "true" : "false",
                    ]
                    if let primaryError = fallbackEngine.lastPrimaryPrepareError {
                        metadata["primary_prepare_error"] = primaryError
                    }
                    metricsLogger.log(event: "engine_prepared", metadata: metadata)
                    metricsLogger.logStatus(
                        "Dictation engine ready: \(fallbackEngine.lastEngineUsed)",
                        metadata: metadata.merging(["preparation_key": preparationKey]) { _, new in new }
                    )
                } else {
                    metricsLogger.log(event: "engine_prepared", metadata: [
                        "engine_used": engine.id,
                        "fallback_used": "false",
                    ])
                    metricsLogger.logStatus(
                        "Dictation engine ready: \(engine.id)",
                        metadata: [
                            "engine_used": engine.id,
                            "fallback_used": "false",
                            "preparation_key": preparationKey,
                        ]
                    )
                }

                return true
            } catch {
                metricsLogger.log(event: "engine_prepare_failed", metadata: ["error": error.localizedDescription])
                metricsLogger.logStatus(
                    "Dictation engine failed to prepare: \(error.localizedDescription)",
                    metadata: ["preparation_key": preparationKey]
                )
                return false
            }
        }

        prepareTask = task
        return await task.value
    }

    private func startCapture() {
        guard captureTask == nil, !isCapturing else { return }

        captureTask = Task { @MainActor in
            guard await prepareIfNeeded() else {
                captureTask = nil
                return
            }

            isCapturing = true
            overlayController.show()
            let startedAt = Date()
            audioCaptureService.onLevelUpdate = { [weak self] level in
                Task { @MainActor [weak self] in
                    self?.overlayController.updateLevel(level)
                }
            }
            let stream = audioCaptureService.startCaptureStream()

            do {
                var finalText = ""
                for try await event in engine.transcribe(audioStream: stream) {
                    switch event {
                    case .partial:
                        continue
                    case let .final(text):
                        finalText = text
                    }
                }

                let normalized = postProcessor.normalize(finalText, options: postProcessorOptionsProvider())
                var insertionSucceeded = false
                if !normalized.isEmpty {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    insertionSucceeded = textInsertionService.insertText(
                        normalized,
                        mode: insertionModeProvider()
                    )
                }

                let elapsed = Date().timeIntervalSince(startedAt)
                let engineUsed = (engine as? FallbackASREngine)?.lastEngineUsed ?? engine.id
                let fallbackUsed = (engine as? FallbackASREngine)?.lastFallbackUsed ?? false
                metricsLogger.log(event: "capture_complete", metadata: [
                    "elapsed_seconds": String(format: "%.2f", elapsed),
                    "raw_characters": "\(finalText.count)",
                    "characters": "\(normalized.count)",
                    "inserted": insertionSucceeded ? "true" : "false",
                    "engine_used": engineUsed,
                    "fallback_used": fallbackUsed ? "true" : "false",
                ])
            } catch {
                metricsLogger.log(event: "capture_failed", metadata: ["error": error.localizedDescription])
            }

            isCapturing = false
            audioCaptureService.onLevelUpdate = nil
            overlayController.hide()
            captureTask = nil
        }
    }

    private func stopCapture(graceful: Bool) {
        guard isCapturing else { return }
        audioCaptureService.stopCapture()
        overlayController.hide()
        audioCaptureService.onLevelUpdate = nil

        if !graceful {
            Task { @MainActor in
                await engine.stop()
            }
        }

        if !graceful {
            captureTask?.cancel()
            captureTask = nil
            isCapturing = false
        }
    }
}
