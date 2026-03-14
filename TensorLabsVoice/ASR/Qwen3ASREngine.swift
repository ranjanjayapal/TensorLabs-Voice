import Foundation
import Qwen3ASR

enum Qwen3ASREngineError: Error {
    case unsupportedMode
    case modelNotInitialized
}

@MainActor
final class Qwen3ASREngine: ASREngine {
    let id = "qwen3_asr"
    var requiresSpeechRecognitionPermission: Bool { false }

    private let modelManager: ModelManager
    private let metricsLogger: LocalMetricsLogger
    private let modeProvider: () -> DictationMode
    private let languageProvider: () -> TranscriptionLanguage
    private var model: Qwen3ASRModel?
    private var preparedModelId: String?
    private let streamingTranscriber = StreamingSegmentTranscriber()

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
        guard let modelId = modelManager.qwenModelId(for: mode, language: language) else {
            throw Qwen3ASREngineError.unsupportedMode
        }

        if preparedModelId == modelId, model != nil {
            metricsLogger.logStatus(
                "Balanced model already ready: \(modelId)",
                metadata: ["engine": id, "model_id": modelId]
            )
            return
        }

        metricsLogger.logStatus(
            "Preparing Balanced model: \(modelId)",
            metadata: ["engine": id, "model_id": modelId]
        )
        model = try await Qwen3ASRModel.fromPretrained(modelId: modelId)
        preparedModelId = modelId
        metricsLogger.logStatus(
            "Balanced model ready: \(modelId)",
            metadata: ["engine": id, "model_id": modelId]
        )
    }

    func transcribe(audioStream: AsyncThrowingStream<[Float], Error>) -> AsyncThrowingStream<ASREvent, Error> {
        guard let model else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: Qwen3ASREngineError.modelNotInitialized)
            }
        }

        let modelBox = UncheckedSendableBox(model)
        let language = languageProvider().qwenLanguageHint
        return streamingTranscriber.transcribe(audioStream: audioStream) { samples in
            modelBox.value.transcribe(
                audio: samples,
                sampleRate: 16_000,
                language: language
            )
        }
    }

    func stop() async {}
}
