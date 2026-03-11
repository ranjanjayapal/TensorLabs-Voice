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
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                do {
                    guard let model else {
                        throw Qwen3ASREngineError.modelNotInitialized
                    }

                    var samples: [Float] = []
                    for try await chunk in audioStream {
                        samples.append(contentsOf: chunk)
                    }

                    if samples.isEmpty {
                        continuation.yield(.final(""))
                        continuation.finish()
                        return
                    }

                    let text = model.transcribe(
                        audio: samples,
                        sampleRate: 16_000,
                        language: languageProvider().qwenLanguageHint
                    )
                    continuation.yield(.final(text.trimmingCharacters(in: .whitespacesAndNewlines)))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func stop() async {}
}
