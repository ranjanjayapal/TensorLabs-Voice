import Foundation
import ParakeetASR

enum ParakeetASREngineError: Error {
    case unsupportedMode
    case modelNotInitialized
}

@MainActor
final class ParakeetASREngine: ASREngine {
    let id = "parakeet_asr"
    var requiresSpeechRecognitionPermission: Bool { false }

    private let modelManager: ModelManager
    private let metricsLogger: LocalMetricsLogger
    private let modeProvider: () -> DictationMode
    private let languageProvider: () -> TranscriptionLanguage
    private var model: ParakeetASRModel?
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
        guard let modelId = modelManager.parakeetModelId(for: mode, language: language) else {
            throw ParakeetASREngineError.unsupportedMode
        }

        if preparedModelId == modelId, model != nil {
            metricsLogger.logStatus(
                "Fast model already ready: \(modelId)",
                metadata: ["engine": id, "model_id": modelId]
            )
            return
        }

        metricsLogger.logStatus(
            "Preparing Fast model: \(modelId)",
            metadata: ["engine": id, "model_id": modelId]
        )
        let loadedModel = try await ParakeetASRModel.fromPretrained(modelId: modelId)
        metricsLogger.logStatus(
            "Warming Fast model: \(modelId)",
            metadata: ["engine": id, "model_id": modelId]
        )
        try loadedModel.warmUp()
        model = loadedModel
        preparedModelId = modelId
        metricsLogger.logStatus(
            "Fast model ready: \(modelId)",
            metadata: ["engine": id, "model_id": modelId]
        )
    }

    func transcribe(audioStream: AsyncThrowingStream<[Float], Error>) -> AsyncThrowingStream<ASREvent, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                do {
                    guard let model else {
                        throw ParakeetASREngineError.modelNotInitialized
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

                    let text = try model.transcribeAudio(samples, sampleRate: 16_000)
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
