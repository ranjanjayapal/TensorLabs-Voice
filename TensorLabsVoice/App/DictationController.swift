import AppKit
@preconcurrency import AVFoundation
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
                requiresSpeechRecognition: engine.requiresSpeechRecognitionPermission,
                requiresAccessibility: true
            )
            guard status.satisfiesRequirements(
                requiresSpeechRecognition: engine.requiresSpeechRecognitionPermission,
                requiresAccessibility: true
            ) else {
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
            try? audioCaptureService.primeCapture()

            isEnabled = true
            return
        }

        hotkeyService.stopListening()
        stopCapture(graceful: false)
        audioCaptureService.shutdown()
        isEnabled = false
    }

    func prewarmEngine() {
        Task { @MainActor in
            let status = permissionService.currentStatus()
            guard status.satisfiesRequirements(
                requiresSpeechRecognition: engine.requiresSpeechRecognitionPermission,
                requiresAccessibility: true
            ) else {
                return
            }
            try? audioCaptureService.primeCapture()
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
            defer {
                isCapturing = false
                audioCaptureService.onLevelUpdate = nil
                overlayController.hide()
                audioCaptureService.shutdown()
                captureTask = nil
            }

            guard await prepareIfNeeded() else {
                return
            }

            isCapturing = true
            overlayController.updateStatus("Listening")
            overlayController.updateTranscript("Listening...")
            overlayController.show()
            var sessionMetrics = VoiceSessionMetrics()
            audioCaptureService.onLevelUpdate = { [weak self] level in
                Task { @MainActor [weak self] in
                    self?.overlayController.updateLevel(level)
                }
            }
            let stream = audioCaptureService.startCaptureStream()

            do {
                var finalizedSegments: [String] = []
                var latestPartial = ""
                for try await event in engine.transcribe(audioStream: stream) {
                    switch event {
                    case let .partial(text):
                        sessionMetrics.markFirstPartial()
                        latestPartial = text
                        overlayController.updateTranscript(renderTranscript(finalizedSegments: finalizedSegments, partial: latestPartial))
                    case let .final(text):
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            finalizedSegments.append(trimmed)
                        }
                        latestPartial = ""
                        overlayController.updateTranscript(renderTranscript(finalizedSegments: finalizedSegments, partial: nil))
                    }
                }

                sessionMetrics.markTranscriptionFinished()
                let finalText = renderTranscript(finalizedSegments: finalizedSegments, partial: latestPartial)
                let normalized = postProcessor.normalize(finalText, options: postProcessorOptionsProvider())
                sessionMetrics.markPostProcessingFinished()
                var insertionSucceeded = false
                if !normalized.isEmpty {
                    overlayController.updateStatus("Inserting")
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    insertionSucceeded = textInsertionService.insertText(
                        normalized,
                        mode: insertionModeProvider()
                    )
                }
                sessionMetrics.markInsertionFinished()

                let engineUsed = (engine as? FallbackASREngine)?.lastEngineUsed ?? engine.id
                let fallbackUsed = (engine as? FallbackASREngine)?.lastFallbackUsed ?? false
                metricsLogger.log(event: "capture_complete", metadata: sessionMetrics.metadata(additional: [
                    "raw_characters": "\(finalText.count)",
                    "characters": "\(normalized.count)",
                    "inserted": insertionSucceeded ? "true" : "false",
                    "engine_used": engineUsed,
                    "fallback_used": fallbackUsed ? "true" : "false",
                ]))
            } catch {
                if Task.isCancelled {
                    metricsLogger.log(event: "capture_cancelled", metadata: [
                        "engine_used": (engine as? FallbackASREngine)?.lastEngineUsed ?? engine.id,
                    ])
                } else {
                    metricsLogger.log(event: "capture_failed", metadata: ["error": error.localizedDescription])
                }
            }
        }
    }

    private func stopCapture(graceful: Bool) {
        guard isCapturing else { return }
        audioCaptureService.stopCapture()
        audioCaptureService.onLevelUpdate = nil

        if graceful {
            isCapturing = false
            overlayController.updateStatus("Transcribing")
            return
        }

        if !graceful {
            overlayController.hide()
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

    private func renderTranscript(finalizedSegments: [String], partial: String?) -> String {
        let partialParts: [String]
        if let partial {
            let trimmed = partial.trimmingCharacters(in: .whitespacesAndNewlines)
            partialParts = trimmed.isEmpty ? [] : [trimmed]
        } else {
            partialParts = []
        }
        let parts = finalizedSegments + partialParts
        return parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

protocol AssistantBrain: Sendable {
    func reply(to transcript: String) async -> String
}

private enum AssistantInteractionState: String {
    case idle
    case listening
    case transcribing
    case thinking
    case speaking

    var overlayStatus: String {
        switch self {
        case .idle:
            return "Ready"
        case .listening:
            return "Listening"
        case .transcribing:
            return "Transcribing"
        case .thinking:
            return "Thinking"
        case .speaking:
            return "Speaking"
        }
    }
}

struct RuleBasedAssistantBrain: AssistantBrain {
    func reply(to transcript: String) async -> String {
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = cleaned.lowercased()

        if lowered.contains("what time") {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            return "It is \(formatter.string(from: Date()))."
        }

        if lowered.contains("what day") || lowered.contains("what date") {
            let formatter = DateFormatter()
            formatter.dateStyle = .full
            formatter.timeStyle = .none
            return "Today is \(formatter.string(from: Date()))."
        }

        if lowered.contains("hello") || lowered.contains("hi") {
            return "Hello. Assistant mode is working locally on your Mac."
        }

        if lowered.contains("help") || lowered.contains("what can you do") {
            return "Right now I can listen, transcribe locally, and speak back simple local replies. Next we can wire in a stronger local language model and Mac actions."
        }

        if lowered.contains("repeat that") || lowered.contains("what did i say") {
            return "You said: \(cleaned)"
        }

        return "I heard: \(cleaned). The local assistant mode is wired up, but the full on device language model is still the next step."
    }
}

@MainActor
final class LocalSpeechSynthesizer: NSObject {
    private let synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, language: TranscriptionLanguage) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        stopSpeaking()

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.rate = 0.48
        utterance.voice = voice(for: language)

        await withCheckedContinuation { continuation in
            self.continuation = continuation
            synthesizer.speak(utterance)
        }
    }

    func stopSpeaking() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        finishSpeaking()
    }

    private func finishSpeaking() {
        continuation?.resume()
        continuation = nil
    }

    private func voice(for language: TranscriptionLanguage) -> AVSpeechSynthesisVoice? {
        switch language {
        case .english, .auto:
            return AVSpeechSynthesisVoice(language: "en-US")
        case .kannada:
            return AVSpeechSynthesisVoice(language: "kn-IN")
        }
    }
}

extension LocalSpeechSynthesizer: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.finishSpeaking()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.finishSpeaking()
        }
    }
}

@MainActor
final class AssistantController {
    private let engine: ASREngine
    private let audioCaptureService: AudioCaptureService
    private let hotkeyService: GlobalHotkeyService
    private let postProcessor: PostProcessor
    private let metricsLogger: LocalMetricsLogger
    private let overlayController: ListeningOverlayController
    private let permissionService: PermissionService
    private let hotkeyProvider: () -> HotkeyShortcut
    private let postProcessorOptionsProvider: () -> PostProcessor.Options
    private let preparationKeyProvider: () -> String
    private let responseLanguageProvider: () -> TranscriptionLanguage
    private let speechSynthesizer: LocalSpeechSynthesizer
    private let assistantBrain: AssistantBrain

    private var captureTask: Task<Void, Never>?
    private var prepareTask: Task<Bool, Never>?
    private var isCapturing = false
    private var isPrepared = false
    private var lastPreparationKey: String?
    private var interactionState: AssistantInteractionState = .idle
    private var shouldRestartAfterCurrentInteraction = false

    private(set) var isEnabled = false

    init(
        engine: ASREngine,
        audioCaptureService: AudioCaptureService,
        hotkeyService: GlobalHotkeyService,
        postProcessor: PostProcessor,
        metricsLogger: LocalMetricsLogger,
        overlayController: ListeningOverlayController,
        permissionService: PermissionService,
        hotkeyProvider: @escaping () -> HotkeyShortcut,
        postProcessorOptionsProvider: @escaping () -> PostProcessor.Options,
        preparationKeyProvider: @escaping () -> String,
        responseLanguageProvider: @escaping () -> TranscriptionLanguage,
        speechSynthesizer: LocalSpeechSynthesizer,
        assistantBrain: AssistantBrain
    ) {
        self.engine = engine
        self.audioCaptureService = audioCaptureService
        self.hotkeyService = hotkeyService
        self.postProcessor = postProcessor
        self.metricsLogger = metricsLogger
        self.overlayController = overlayController
        self.permissionService = permissionService
        self.hotkeyProvider = hotkeyProvider
        self.postProcessorOptionsProvider = postProcessorOptionsProvider
        self.preparationKeyProvider = preparationKeyProvider
        self.responseLanguageProvider = responseLanguageProvider
        self.speechSynthesizer = speechSynthesizer
        self.assistantBrain = assistantBrain
    }

    func setEnabled(_ enabled: Bool) async {
        if enabled {
            let status = await permissionService.requestRequiredPermissions(
                requiresSpeechRecognition: engine.requiresSpeechRecognitionPermission,
                requiresAccessibility: false
            )
            guard status.satisfiesRequirements(
                requiresSpeechRecognition: engine.requiresSpeechRecognitionPermission,
                requiresAccessibility: false
            ) else {
                metricsLogger.log(event: "assistant_permissions_denied", metadata: [
                    "microphone": status.microphoneGranted ? "granted" : "denied",
                    "speech": status.speechGranted ? "granted" : "denied",
                    "accessibility": status.accessibilityGranted ? "granted" : "denied",
                ])
                showPermissionGuidance(
                    microphoneGranted: status.microphoneGranted,
                    speechGranted: status.speechGranted
                )
                isEnabled = false
                return
            }

            hotkeyService.startListening(shortcut: hotkeyProvider(), onPress: { [weak self] in
                self?.handleHotkeyPress()
            }, onRelease: { [weak self] in
                self?.handleHotkeyRelease()
            })
            try? audioCaptureService.primeCapture()

            isEnabled = true
            return
        }

        hotkeyService.stopListening()
        shouldRestartAfterCurrentInteraction = false
        stopCapture(graceful: false)
        audioCaptureService.shutdown()
        speechSynthesizer.stopSpeaking()
        interactionState = .idle
        isEnabled = false
    }

    func prewarmEngine() {
        Task { @MainActor in
            let status = permissionService.currentStatus()
            guard status.satisfiesRequirements(
                requiresSpeechRecognition: engine.requiresSpeechRecognitionPermission,
                requiresAccessibility: false
            ) else {
                return
            }
            try? audioCaptureService.primeCapture()
            _ = await prepareIfNeeded()
        }
    }

    private func showPermissionGuidance(
        microphoneGranted: Bool,
        speechGranted: Bool
    ) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Permissions Required"
        if !microphoneGranted, !speechGranted {
            alert.informativeText = "Enable Microphone and Speech Recognition for TensorLabsVoice in System Settings > Privacy & Security."
        } else if !microphoneGranted {
            alert.informativeText = "Enable Microphone for TensorLabsVoice in System Settings > Privacy & Security > Microphone."
        } else {
            alert.informativeText = "Enable Speech Recognition for TensorLabsVoice in System Settings > Privacy & Security > Speech Recognition."
        }
        alert.addButton(withTitle: "Open Privacy Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            let targetPane = !microphoneGranted ? "Privacy_Microphone" : "Privacy_SpeechRecognition"
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
                try await engine.prepare()
                isPrepared = true
                lastPreparationKey = preparationKey
                metricsLogger.log(event: "assistant_engine_prepared", metadata: [
                    "engine_used": (engine as? FallbackASREngine)?.lastEngineUsed ?? engine.id,
                    "preparation_key": preparationKey,
                ])
                return true
            } catch {
                metricsLogger.log(event: "assistant_engine_prepare_failed", metadata: [
                    "error": error.localizedDescription,
                    "preparation_key": preparationKey,
                ])
                return false
            }
        }

        prepareTask = task
        return await task.value
    }

    private func startCapture() {
        guard captureTask == nil, !isCapturing else { return }

        captureTask = Task { @MainActor in
            defer {
                completeInteraction()
            }

            guard await prepareIfNeeded() else {
                return
            }

            speechSynthesizer.stopSpeaking()
            isCapturing = true
            interactionState = .listening
            overlayController.updateStatus(interactionState.overlayStatus)
            overlayController.updateTranscript("Listening...")
            overlayController.show()
            var sessionMetrics = VoiceSessionMetrics()

            audioCaptureService.onLevelUpdate = { [weak self] level in
                Task { @MainActor [weak self] in
                    self?.overlayController.updateLevel(level)
                }
            }

            let stream = audioCaptureService.startCaptureStream()

            do {
                var finalizedSegments: [String] = []
                var latestPartial = ""

                for try await event in engine.transcribe(audioStream: stream) {
                    if Task.isCancelled {
                        sessionMetrics.markInterrupted()
                        metricsLogger.log(event: "assistant_capture_interrupted", metadata: sessionMetrics.metadata(additional: [
                            "engine_used": (engine as? FallbackASREngine)?.lastEngineUsed ?? engine.id,
                        ]))
                        return
                    }

                    switch event {
                    case let .partial(text):
                        sessionMetrics.markFirstPartial()
                        latestPartial = text
                        overlayController.updateTranscript(renderTranscript(finalizedSegments: finalizedSegments, partial: latestPartial))
                    case let .final(text):
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            finalizedSegments.append(trimmed)
                        }
                        latestPartial = ""
                        overlayController.updateTranscript(renderTranscript(finalizedSegments: finalizedSegments, partial: nil))
                    }
                }

                sessionMetrics.markTranscriptionFinished()
                let finalText = renderTranscript(finalizedSegments: finalizedSegments, partial: latestPartial)
                let normalized = postProcessor.normalize(finalText, options: postProcessorOptionsProvider())
                sessionMetrics.markPostProcessingFinished()

                guard !normalized.isEmpty else {
                    metricsLogger.log(event: "assistant_capture_complete", metadata: sessionMetrics.metadata(additional: [
                        "heard_text": "",
                        "reply_text": "",
                        "engine_used": (engine as? FallbackASREngine)?.lastEngineUsed ?? engine.id,
                    ]))
                    return
                }

                interactionState = .thinking
                overlayController.updateStatus(interactionState.overlayStatus)
                overlayController.updateTranscript("Thinking...")
                sessionMetrics.markThinkingStarted()
                let reply = await assistantBrain.reply(to: normalized)
                sessionMetrics.markReplyReady()

                if Task.isCancelled {
                    sessionMetrics.markInterrupted()
                    metricsLogger.log(event: "assistant_capture_interrupted", metadata: sessionMetrics.metadata(additional: [
                        "heard_text": normalized,
                        "engine_used": (engine as? FallbackASREngine)?.lastEngineUsed ?? engine.id,
                    ]))
                    return
                }

                interactionState = .speaking
                overlayController.updateStatus(interactionState.overlayStatus)
                overlayController.updateTranscript(reply)
                sessionMetrics.markSpeechStarted()
                await speechSynthesizer.speak(reply, language: responseLanguageProvider())

                if Task.isCancelled {
                    sessionMetrics.markInterrupted()
                    metricsLogger.log(event: "assistant_capture_interrupted", metadata: sessionMetrics.metadata(additional: [
                        "heard_text": normalized,
                        "reply_text": reply,
                        "engine_used": (engine as? FallbackASREngine)?.lastEngineUsed ?? engine.id,
                    ]))
                    return
                }

                sessionMetrics.markSpeechFinished()

                metricsLogger.log(event: "assistant_capture_complete", metadata: sessionMetrics.metadata(additional: [
                    "heard_text": normalized,
                    "reply_text": reply,
                    "engine_used": (engine as? FallbackASREngine)?.lastEngineUsed ?? engine.id,
                ]))
            } catch {
                if Task.isCancelled {
                    var sessionMetrics = VoiceSessionMetrics()
                    sessionMetrics.markInterrupted()
                    metricsLogger.log(event: "assistant_capture_interrupted", metadata: sessionMetrics.metadata(additional: [
                        "engine_used": (engine as? FallbackASREngine)?.lastEngineUsed ?? engine.id,
                    ]))
                } else {
                    metricsLogger.log(event: "assistant_capture_failed", metadata: [
                        "error": error.localizedDescription,
                    ])
                }
            }
        }
    }

    private func handleHotkeyPress() {
        if interactionState == .speaking {
            shouldRestartAfterCurrentInteraction = true
            stopCapture(graceful: false)
            return
        }

        startCapture()
    }

    private func handleHotkeyRelease() {
        stopCapture(graceful: true)
    }

    private func stopCapture(graceful: Bool) {
        let isAssistantBusy = isCapturing || interactionState == .thinking || interactionState == .speaking
        guard isAssistantBusy else { return }

        if graceful {
            guard isCapturing else { return }
            audioCaptureService.stopCapture()
            audioCaptureService.onLevelUpdate = nil
            isCapturing = false
            interactionState = .transcribing
            overlayController.updateStatus(interactionState.overlayStatus)
            return
        }

        audioCaptureService.stopCapture()
        audioCaptureService.onLevelUpdate = nil
        speechSynthesizer.stopSpeaking()
        if !graceful {
            overlayController.hide()
            Task { @MainActor in
                await engine.stop()
            }
        }

        if !graceful {
            captureTask?.cancel()
            captureTask = nil
            isCapturing = false
            interactionState = .idle
        }
    }

    private func completeInteraction() {
        isCapturing = false
        audioCaptureService.onLevelUpdate = nil
        overlayController.hide()
        captureTask = nil
        interactionState = .idle

        if shouldRestartAfterCurrentInteraction, isEnabled {
            shouldRestartAfterCurrentInteraction = false
            startCapture()
        }
    }

    private func renderTranscript(finalizedSegments: [String], partial: String?) -> String {
        let partialParts: [String]
        if let partial {
            let trimmed = partial.trimmingCharacters(in: .whitespacesAndNewlines)
            partialParts = trimmed.isEmpty ? [] : [trimmed]
        } else {
            partialParts = []
        }
        let parts = finalizedSegments + partialParts
        return parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
