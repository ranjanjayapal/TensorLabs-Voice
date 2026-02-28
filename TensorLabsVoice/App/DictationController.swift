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
    private let hotkeyProvider: () -> HotkeyShortcut

    private var captureTask: Task<Void, Never>?
    private var prepareTask: Task<Bool, Never>?
    private var isCapturing = false
    private var isPrepared = false

    private(set) var isEnabled = false

    init(
        engine: ASREngine,
        audioCaptureService: AudioCaptureService,
        hotkeyService: GlobalHotkeyService,
        textInsertionService: TextInsertionService,
        postProcessor: PostProcessor,
        metricsLogger: LocalMetricsLogger,
        overlayController: ListeningOverlayController,
        hotkeyProvider: @escaping () -> HotkeyShortcut
    ) {
        self.engine = engine
        self.audioCaptureService = audioCaptureService
        self.hotkeyService = hotkeyService
        self.textInsertionService = textInsertionService
        self.postProcessor = postProcessor
        self.metricsLogger = metricsLogger
        self.overlayController = overlayController
        self.hotkeyProvider = hotkeyProvider
    }

    func setEnabled(_ enabled: Bool) async {
        if enabled {
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
            _ = await prepareIfNeeded()
        }
    }

    private func prepareIfNeeded() async -> Bool {
        guard !isPrepared else { return true }
        if let prepareTask {
            return await prepareTask.value
        }

        let task = Task<Bool, Never> { @MainActor in
            defer { prepareTask = nil }

            do {
                try await engine.prepare()
                isPrepared = true

                if let fallbackEngine = engine as? FallbackASREngine {
                    var metadata: [String: String] = [
                        "engine_used": fallbackEngine.lastEngineUsed,
                        "fallback_used": fallbackEngine.lastFallbackUsed ? "true" : "false",
                    ]
                    if let primaryError = fallbackEngine.lastPrimaryPrepareError {
                        metadata["primary_prepare_error"] = primaryError
                    }
                    metricsLogger.log(event: "engine_prepared", metadata: metadata)
                } else {
                    metricsLogger.log(event: "engine_prepared", metadata: [
                        "engine_used": engine.id,
                        "fallback_used": "false",
                    ])
                }

                return true
            } catch {
                metricsLogger.log(event: "engine_prepare_failed", metadata: ["error": error.localizedDescription])
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

                let normalized = postProcessor.normalize(finalText)
                var insertionSucceeded = false
                if !normalized.isEmpty {
                    insertionSucceeded = textInsertionService.insertText(normalized)
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
