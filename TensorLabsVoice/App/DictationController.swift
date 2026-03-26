import AppKit
@preconcurrency import AVFoundation
import Foundation

struct LiveDictationAccumulator {
    private(set) var committedText: String = ""
    private(set) var activeText: String = ""

    var renderedText: String {
        join(committedText, deduplicatedVolatileText(activeText, against: committedText))
    }

    mutating func update(stableText: String, volatileText: String, isFinalEvent: Bool) -> String {
        RuntimeTrace.mark("LiveDictationAccumulator.update start committed='\(committedText.prefix(30))' activeText='\(activeText.prefix(30))'")
        let stable = normalized(stableText)
        let volatile = normalized(volatileText)
        let previousActiveText = activeText
        let previousRenderedText = renderedText

        if !stable.isEmpty {
            reconcileCommitted(with: stable, previousRenderedText: previousRenderedText)
            activeText = deduplicatedVolatileText(activeText, against: committedText)
            RuntimeTrace.mark("LiveDictationAccumulator after reconcile committed='\(committedText.prefix(30))'")
        }

        if shouldCommitActiveText(beforeReplacingWith: volatile, stableText: stable) {
            replaceCommitted(with: join(committedText, activeText))
            activeText = ""
        }

        activeText = deduplicatedVolatileText(volatile, against: committedText)

        if isFinalEvent {
            let finalCandidate = !activeText.isEmpty ? activeText : previousActiveText
            if shouldCommitFinalCandidate(finalCandidate) {
                replaceCommitted(with: join(committedText, finalCandidate))
                activeText = ""
            } else if !finalCandidate.isEmpty {
                activeText = deduplicatedVolatileText(finalCandidate, against: committedText)
            }
        }

        return renderedText
    }

    mutating func finalizeSession(with transcript: String) -> String {
        replaceCommitted(with: normalized(transcript))
        activeText = ""
        return renderedText
    }

    private mutating func replaceCommitted(with text: String) {
        guard !text.isEmpty else { return }
        committedText = text
    }

    private mutating func reconcileCommitted(with incomingText: String, previousRenderedText: String) {
        let incoming = normalized(incomingText)
        guard !incoming.isEmpty else { return }

        guard !committedText.isEmpty else {
            committedText = incoming
            return
        }

        let renderedWords = words(in: previousRenderedText)
        let incomingWords = words(in: incoming)
        let sharedRenderedPrefix = sharedWordPrefixCount(renderedWords, incomingWords)
        if sharedRenderedPrefix >= 2 {
            committedText = incoming
            return
        }

        if incoming == committedText {
            return
        }

        if incoming.hasPrefix(committedText) {
            committedText = incoming
            return
        }

        if committedText.hasPrefix(incoming) {
            return
        }

        let existingWords = words(in: committedText)
        let sharedPrefix = sharedWordPrefixCount(existingWords, incomingWords)
        if sharedPrefix >= 2 {
            committedText = incoming
            return
        }

        committedText = merge(committedText, incoming)
    }

    private func shouldCommitActiveText(beforeReplacingWith incomingVolatile: String, stableText: String) -> Bool {
        guard !activeText.isEmpty else { return false }
        guard !incomingVolatile.isEmpty else { return false }

        let current = normalized(activeText)
        let incoming = normalized(incomingVolatile)
        let stable = normalized(stableText)
        guard !current.isEmpty else { return false }
        guard current.last.map({ ".!?".contains($0) }) == true else {
            return false
        }

        if !stable.isEmpty, stable != committedText {
            return false
        }

        if incoming.hasPrefix(current) || current.hasPrefix(incoming) {
            return false
        }

        let currentWords = words(in: current)
        let incomingWords = words(in: incoming)
        let overlap = largestWordOverlap(suffix: currentWords, prefix: incomingWords)
        return overlap == 0
    }

    private func deduplicatedVolatileText(_ incomingVolatile: String, against committed: String) -> String {
        let incoming = normalized(incomingVolatile)
        let existing = normalized(committed)
        guard !incoming.isEmpty, !existing.isEmpty else { return incoming }

        let existingWords = words(in: existing)
        let incomingWords = words(in: incoming)
        let overlap = largestWordOverlap(suffix: existingWords, prefix: incomingWords)
        if overlap == incomingWords.count {
            return ""
        }
        guard overlap >= 2 else { return incoming }
        return incomingWords.dropFirst(overlap).joined(separator: " ")
    }

    private func shouldCommitFinalCandidate(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let trimmed = normalized(text)
        guard let last = trimmed.last else { return false }
        return ".!?".contains(last)
    }

    private func merge(_ existing: String, _ incoming: String) -> String {
        let existingWords = words(in: existing)
        let incomingWords = words(in: incoming)
        let overlap = largestWordOverlap(suffix: existingWords, prefix: incomingWords)

        if overlap == incomingWords.count {
            return existing
        }

        let appendedWords = incomingWords.dropFirst(overlap)
        let appended = appendedWords.joined(separator: " ")
        return join(existing, appended)
    }

    private func sharedWordPrefixCount(_ lhs: [String], _ rhs: [String]) -> Int {
        zip(lhs, rhs).prefix { $0 == $1 }.count
    }

    private func largestWordOverlap(suffix: [String], prefix: [String]) -> Int {
        let maxOverlap = min(suffix.count, prefix.count)
        guard maxOverlap > 0 else { return 0 }

        for candidate in stride(from: maxOverlap, through: 1, by: -1) {
            if Array(suffix.suffix(candidate)) == Array(prefix.prefix(candidate)) {
                return candidate
            }
        }

        return 0
    }

    private func words(in text: String) -> [String] {
        normalized(text)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    private func join(_ lhs: String, _ rhs: String) -> String {
        switch (lhs.isEmpty, rhs.isEmpty) {
        case (true, true):
            return ""
        case (true, false):
            return rhs
        case (false, true):
            return lhs
        case (false, false):
            return lhs + " " + rhs
        }
    }

    private func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class DictationController {
    private let engine: ASREngine
    private let audioCaptureService: AudioCaptureService
    private let hotkeyService: GlobalHotkeyService
    private let textInsertionService: TextInsertionService
    private let postProcessor: PostProcessor
    private let liveTranscriptFormatter: LiveTranscriptFormatter
    private let metricsLogger: LocalMetricsLogger
    private let overlayController: ListeningOverlayController
    private let permissionService: PermissionService
    private let hotkeyProvider: () -> HotkeyShortcut
    private let postProcessorOptionsProvider: () -> PostProcessor.Options
    private let preparationKeyProvider: () -> String
    private let insertionModeProvider: () -> InsertionMode
    private let liveTextUpdatesProvider: () -> Bool

    private var captureTask: Task<Void, Never>?
    private var prepareTask: Task<Bool, Never>?
    private var isCapturing = false
    private var isPrepared = false
    private var lastPreparationKey: String?
    private var hasShownAccessibilityGuidance = false
    private var hotkeyHoldTask: Task<Void, Never>?
    private var activeHotkeyMode: HotkeyMode = .idle

    private enum HotkeyMode {
        case idle
        case pending
        case continuous
        case pushToTalk
    }

    private(set) var isEnabled = false

    init(
        engine: ASREngine,
        audioCaptureService: AudioCaptureService,
        hotkeyService: GlobalHotkeyService,
        textInsertionService: TextInsertionService,
        postProcessor: PostProcessor,
        liveTranscriptFormatter: LiveTranscriptFormatter = LiveTranscriptFormatter(),
        metricsLogger: LocalMetricsLogger,
        overlayController: ListeningOverlayController,
        permissionService: PermissionService,
        hotkeyProvider: @escaping () -> HotkeyShortcut,
        postProcessorOptionsProvider: @escaping () -> PostProcessor.Options,
        preparationKeyProvider: @escaping () -> String,
        insertionModeProvider: @escaping () -> InsertionMode,
        liveTextUpdatesProvider: @escaping () -> Bool
    ) {
        self.engine = engine
        self.audioCaptureService = audioCaptureService
        self.hotkeyService = hotkeyService
        self.textInsertionService = textInsertionService
        self.postProcessor = postProcessor
        self.liveTranscriptFormatter = liveTranscriptFormatter
        self.metricsLogger = metricsLogger
        self.overlayController = overlayController
        self.permissionService = permissionService
        self.hotkeyProvider = hotkeyProvider
        self.postProcessorOptionsProvider = postProcessorOptionsProvider
        self.preparationKeyProvider = preparationKeyProvider
        self.insertionModeProvider = insertionModeProvider
        self.liveTextUpdatesProvider = liveTextUpdatesProvider
    }

    func setEnabled(_ enabled: Bool) async {
        RuntimeTrace.mark("DictationController.setEnabled begin enabled=\(enabled)")
        if enabled {
            let status = await permissionService.requestRequiredPermissions(
                requiresSpeechRecognition: engine.requiresSpeechRecognitionPermission,
                requiresAccessibility: false
            )
            RuntimeTrace.mark("DictationController permissions microphone=\(status.microphoneGranted) speech=\(status.speechGranted) accessibility=\(status.accessibilityGranted)")
            guard status.satisfiesRequirements(
                requiresSpeechRecognition: engine.requiresSpeechRecognitionPermission,
                requiresAccessibility: false
            ) else {
                metricsLogger.log(event: "permissions_denied", metadata: [
                    "microphone": status.microphoneGranted ? "granted" : "denied",
                    "speech": status.speechGranted ? "granted" : "denied",
                    "accessibility": status.accessibilityGranted ? "granted" : "denied",
                ])
                showPermissionGuidance(
                    microphoneGranted: status.microphoneGranted,
                    speechGranted: status.speechGranted,
                    accessibilityGranted: true
                )
                isEnabled = false
                RuntimeTrace.mark("DictationController.setEnabled denied")
                return
            }

            RuntimeTrace.mark("DictationController starting hotkey listener")
            hotkeyService.startListening(shortcut: hotkeyProvider(), onPress: { [weak self] in
                self?.handleHotkeyPress()
            }, onRelease: { [weak self] in
                self?.handleHotkeyRelease()
            })

            isEnabled = true
            presentAccessibilityGuidanceIfNeeded()
            RuntimeTrace.mark("DictationController.setEnabled success")
            return
        }

        hotkeyService.stopListening()
        stopCapture(graceful: false)
        audioCaptureService.shutdown()
        isEnabled = false
        RuntimeTrace.mark("DictationController.setEnabled disabled")
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

    private func presentAccessibilityGuidanceIfNeeded() {
        guard !hasShownAccessibilityGuidance else { return }

        let status = permissionService.currentStatus()
        guard !status.accessibilityGranted else { return }
        guard liveTextUpdatesProvider() || insertionModeProvider() == .accessibilityFirst else { return }

        hasShownAccessibilityGuidance = true
        metricsLogger.log(event: "dictation_accessibility_guidance_needed", metadata: [
            "live_text_updates": liveTextUpdatesProvider() ? "true" : "false",
            "insertion_mode": insertionModeProvider().rawValue,
        ])

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            let trustedAfterPrompt = permissionService.promptForAccessibilityPermission()
            guard !trustedAfterPrompt else { return }

            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Enable Accessibility For Live Dictation"
            alert.informativeText = "Speech recognition is working, but live text streaming into other apps needs Accessibility permission. macOS should have opened the Accessibility settings panel. Turn on TensorLabsVoice there, then come back and try dictation again."
            alert.addButton(withTitle: "Open Accessibility Settings")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
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
            let targetProcessIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let liveTextSession = liveTextUpdatesProvider()
                ? textInsertionService.beginLiveTextSession(mode: insertionModeProvider())
                : nil
            RuntimeTrace.mark("LiveTextSession started session=\(liveTextSession != nil)")
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
                var transcriptComposer = TranscriptComposer()
                var transcriptStabilizer = TranscriptStabilizer()
                var liveAccumulator = LiveDictationAccumulator()
                var lastRenderedLiveText = ""
                var focusMonitorTask: Task<Void, Never>?
                var didLoseTextFocus = false

                if let liveTextSession {
                    focusMonitorTask = Task { @MainActor [weak self] in
                        while !(Task.isCancelled) {
                            try? await Task.sleep(nanoseconds: 180_000_000)
                            switch liveTextSession.status() {
                            case .active:
                                continue
                            case .focusLost:
                                didLoseTextFocus = true
                                self?.stopCapture(graceful: true)
                                return
                            case .unavailable:
                                continue
                            }
                        }
                    }
                }
                defer {
                    focusMonitorTask?.cancel()
                }

                for try await event in engine.transcribe(audioStream: stream) {
                    let rawHypothesis: String
                    let stabilization: TranscriptStabilizer.Snapshot
                    let isFinalEvent: Bool
                    switch event {
                    case .partial:
                        sessionMetrics.markFirstPartial()
                        transcriptComposer.apply(event)
                        rawHypothesis = transcriptComposer.renderedText
                        stabilization = transcriptStabilizer.update(with: rawHypothesis)
                        isFinalEvent = false
                    case .final:
                        transcriptComposer.apply(event)
                        rawHypothesis = transcriptComposer.renderedText
                        stabilization = transcriptStabilizer.commit(rawHypothesis)
                        isFinalEvent = true
                    }

                    sessionMetrics.recordTranscriptStabilization(stabilization)

                    let compositionContext: LiveCompositionContext
                    if let liveTextSession {
                        switch liveTextSession.status() {
                        case let .active(context):
                            compositionContext = context
                        case .focusLost:
                            didLoseTextFocus = true
                            stopCapture(graceful: true)
                            compositionContext = LiveCompositionContext()
                        case .unavailable:
                            compositionContext = LiveCompositionContext()
                        }
                    } else {
                        compositionContext = LiveCompositionContext()
                    }

                    let displayBasis = liveAccumulator.update(
                        stableText: stabilization.stableText,
                        volatileText: stabilization.volatileText,
                        isFinalEvent: isFinalEvent
                    )
                    RuntimeTrace.mark("LiveAccumulator stable='\(stabilization.stableText.prefix(30))' volatile='\(stabilization.volatileText.prefix(30))' displayBasis='\(displayBasis.prefix(50))'")
                    let liveTranscript = liveTranscriptFormatter.format(
                        displayBasis,
                        options: postProcessorOptionsProvider(),
                        context: compositionContext
                    )
                    if !liveTranscript.isEmpty {
                        sessionMetrics.markFirstVisibleText()
                    }
                    overlayController.updateTranscript(liveTranscript)
                    if let liveTextSession, !liveTranscript.isEmpty {
                        let textChanged = liveTranscript != lastRenderedLiveText
                        let updateResult = liveTextSession.update(text: liveTranscript)
                        RuntimeTrace.mark("LiveTextUpdate textChanged=\(textChanged) updateResult=\(updateResult) liveTranscript='\(liveTranscript.prefix(50))' lastRendered='\(lastRenderedLiveText.prefix(50))'")
                        if updateResult {
                            lastRenderedLiveText = liveTranscript
                        }
                    }

                    if stabilization.revisionCount <= 5 || stabilization.revisionCount % 5 == 0 || isFinalEvent {
                        metricsLogger.log(event: "dictation_live_update", metadata: [
                            "revision_count": "\(stabilization.revisionCount)",
                            "stable_word_count": "\(stabilization.stableWordCount)",
                            "volatile_word_count": "\(stabilization.volatileWordCount)",
                            "display_characters": "\(liveTranscript.count)",
                            "mid_sentence": compositionContext.isMidSentence ? "true" : "false",
                            "has_continuation_suffix": compositionContext.hasContinuationSuffix ? "true" : "false",
                            "is_final_event": isFinalEvent ? "true" : "false",
                        ])
                    }
                }

                sessionMetrics.markTranscriptionFinished()
                let finalText = transcriptComposer.finalTranscript
                let sessionTranscript = liveAccumulator.finalizeSession(with: finalText)
                let finalContext: LiveCompositionContext
                if let liveTextSession {
                    switch liveTextSession.status() {
                    case let .active(context):
                        finalContext = context
                    case .focusLost, .unavailable:
                        finalContext = LiveCompositionContext()
                    }
                } else {
                    finalContext = LiveCompositionContext()
                }

                let normalized = postProcessor.normalize(
                    sessionTranscript,
                    options: postProcessorOptionsProvider(),
                    context: finalContext
                )
                sessionMetrics.markPostProcessingFinished()
                var insertionSucceeded = false
                var insertionMethod = "none"
                if !normalized.isEmpty {
                    overlayController.updateStatus("Inserting")
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    if let liveTextSession {
                        insertionSucceeded = liveTextSession.finalize(text: normalized)
                        switch liveTextSession.transport {
                        case .accessibility:
                            insertionMethod = insertionSucceeded ? "live_accessibility" : "live_accessibility_failed"
                        case .keyboard:
                            insertionMethod = insertionSucceeded ? "live_keyboard" : "live_keyboard_failed"
                        }
                    } else {
                        let result = textInsertionService.insertText(
                            normalized,
                            mode: insertionModeProvider(),
                            preferredProcessIdentifier: targetProcessIdentifier
                        )
                        switch result {
                        case .accessibility:
                            insertionSucceeded = true
                            insertionMethod = "accessibility"
                        case .pasteboard:
                            insertionSucceeded = true
                            insertionMethod = "pasteboard"
                        case .failed:
                            insertionSucceeded = false
                            insertionMethod = "failed"
                        }
                    }
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
                    "focus_lost_stop": didLoseTextFocus ? "true" : "false",
                    "insertion_method": insertionMethod,
                    "live_text_session": liveTextSession == nil ? "false" : "true",
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

    private func handleHotkeyPress() {
        if isCapturing || captureTask != nil {
            if activeHotkeyMode == .continuous {
                hotkeyHoldTask?.cancel()
                hotkeyHoldTask = nil
                activeHotkeyMode = .idle
                stopCapture(graceful: true)
            }
            return
        }

        activeHotkeyMode = .pending
        startCapture()
        hotkeyHoldTask?.cancel()
        hotkeyHoldTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, self.activeHotkeyMode == .pending, self.isCapturing else { return }
            self.activeHotkeyMode = .pushToTalk
        }
    }

    private func handleHotkeyRelease() {
        hotkeyHoldTask?.cancel()
        hotkeyHoldTask = nil

        switch activeHotkeyMode {
        case .pending:
            activeHotkeyMode = .continuous
        case .pushToTalk:
            activeHotkeyMode = .idle
            stopCapture(graceful: true)
        case .continuous, .idle:
            break
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
                var transcriptComposer = TranscriptComposer()

                for try await event in engine.transcribe(audioStream: stream) {
                    if Task.isCancelled {
                        sessionMetrics.markInterrupted()
                        metricsLogger.log(event: "assistant_capture_interrupted", metadata: sessionMetrics.metadata(additional: [
                            "engine_used": (engine as? FallbackASREngine)?.lastEngineUsed ?? engine.id,
                        ]))
                        return
                    }

                    switch event {
                    case .partial:
                        sessionMetrics.markFirstPartial()
                        transcriptComposer.apply(event)
                        overlayController.updateTranscript(transcriptComposer.renderedText)
                    case .final:
                        transcriptComposer.apply(event)
                        overlayController.updateTranscript(transcriptComposer.renderedText)
                    }
                }

                sessionMetrics.markTranscriptionFinished()
                let finalText = transcriptComposer.finalTranscript
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

}
