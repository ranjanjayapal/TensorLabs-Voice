import Foundation
@preconcurrency import WhisperKit

enum WhisperKitEngineError: Error {
    case modelNotInitialized
}

@MainActor
final class WhisperKitEngine: ASREngine {
    let id = "whisperkit"
    var requiresSpeechRecognitionPermission: Bool { false }
    private let modelManager: ModelManager
    private let metricsLogger: LocalMetricsLogger
    private let modeProvider: () -> DictationMode
    private let languageProvider: () -> TranscriptionLanguage
    private var whisperKit: WhisperKit?
    private var preparedModelName: String?
    private let streamingTranscriber = StreamingSegmentTranscriber(
        config: StreamingSegmentationConfig(
            minSilenceDuration: 0.48,
            partialResultInterval: 1.2,
            maxSegmentDuration: 14.0,
            emitPartialResults: false
        )
    )

    init(
        modelManager: ModelManager,
        metricsLogger: LocalMetricsLogger,
        modeProvider: @escaping () -> DictationMode,
        languageProvider: @escaping () -> TranscriptionLanguage
    ) {
        self.modelManager = modelManager
        self.metricsLogger = metricsLogger
        self.modeProvider = modeProvider
        self.languageProvider = languageProvider
    }

    func prepare() async throws {
        let mode = modeProvider()
        let language = languageProvider()
        let descriptor = modelManager.descriptor(for: mode, language: language)
        guard let modelName = descriptor.whisperKitModel else {
            throw WhisperKitEngineError.modelNotInitialized
        }

        if preparedModelName == modelName, whisperKit != nil {
            metricsLogger.logStatus(
                "\(descriptor.displayName) model already ready: \(modelName)",
                metadata: ["engine": id, "model_name": modelName, "mode": mode.rawValue]
            )
            return
        }

        let downloadBase = try await modelManager.ensureModelExists(for: mode)
        let hadLocalModel = modelManager.localModelPath(for: mode, language: language) != nil
        if hadLocalModel {
            metricsLogger.logStatus(
                "Found local \(descriptor.displayName) model, loading: \(modelName)",
                metadata: ["engine": id, "model_name": modelName, "mode": mode.rawValue]
            )
        } else {
            metricsLogger.logStatus(
                "Downloading \(descriptor.displayName) model: \(modelName)",
                metadata: ["engine": id, "model_name": modelName, "mode": mode.rawValue]
            )
        }
        let modelFolder = try await WhisperKit.download(
            variant: modelName,
            downloadBase: downloadBase
        )
        if !hadLocalModel {
            metricsLogger.logStatus(
                "Finished downloading \(descriptor.displayName) model: \(modelName)",
                metadata: ["engine": id, "model_name": modelName, "model_folder": modelFolder.path, "mode": mode.rawValue]
            )
        }

        metricsLogger.logStatus(
            "Loading \(descriptor.displayName) model into WhisperKit: \(modelName)",
            metadata: ["engine": id, "model_name": modelName, "model_folder": modelFolder.path, "mode": mode.rawValue]
        )

        let config = WhisperKitConfig(
            modelFolder: modelFolder.path,
            load: true,
            download: false
        )
        whisperKit = try await WhisperKit(config)
        preparedModelName = modelName
        metricsLogger.logStatus(
            "\(descriptor.displayName) model ready: \(modelName)",
            metadata: ["engine": id, "model_name": modelName, "model_folder": modelFolder.path, "mode": mode.rawValue]
        )
    }

    func transcribe(audioStream: AsyncThrowingStream<[Float], Error>) -> AsyncThrowingStream<ASREvent, Error> {
        guard let whisperKit else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: WhisperKitEngineError.modelNotInitialized)
            }
        }

        let whisperBox = UncheckedSendableBox(whisperKit)
        let selectedMode = modeProvider()
        let selectedLanguage = languageProvider()
        let decodeOptions = decodingOptions(
            for: selectedMode,
            language: selectedLanguage
        )

        return streamingTranscriber.transcribe(audioStream: audioStream) { samples in
            let results = try await whisperBox.value.transcribe(audioArray: samples, decodeOptions: decodeOptions)
            return results.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
    }

    private func decodingOptions(for mode: DictationMode, language: TranscriptionLanguage) -> DecodingOptions {
        let languageCode = language.whisperLanguageCode
        let shouldDetectLanguage = language == .auto
        let isMultilingual = language == .kannada || mode == .accurate || mode == .accurateFast

        if isMultilingual {
            // Multilingual decoding is heavier; keep worker count lower and use VAD chunking
            // to avoid long decode windows and repeated fallback loops.
            return DecodingOptions(
                task: .transcribe,
                language: languageCode,
                temperature: 0.0,
                temperatureIncrementOnFallback: 0.2,
                temperatureFallbackCount: 2,
                usePrefillPrompt: true,
                detectLanguage: shouldDetectLanguage,
                compressionRatioThreshold: 3.0,
                logProbThreshold: -1.5,
                noSpeechThreshold: 0.6,
                concurrentWorkerCount: mode == .accurateFast ? 6 : 4,
                chunkingStrategy: .vad
            )
        }

        return DecodingOptions(
            task: .transcribe,
            language: languageCode,
            usePrefillPrompt: true,
            detectLanguage: shouldDetectLanguage
        )
    }

    func stop() async {
        whisperKit?.audioProcessor.stopRecording()
    }
}
