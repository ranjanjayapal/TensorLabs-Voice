import Foundation
@preconcurrency import WhisperKit

enum WhisperKitEngineError: Error {
    case modelNotInitialized
}

@MainActor
final class WhisperKitEngine: ASREngine {
    let id = "whisperkit"
    private let modelManager: ModelManager
    private let profileProvider: () -> ModelProfile
    private let languageProvider: () -> TranscriptionLanguage
    private var whisperKit: WhisperKit?

    init(
        modelManager: ModelManager,
        profileProvider: @escaping () -> ModelProfile,
        languageProvider: @escaping () -> TranscriptionLanguage
    ) {
        self.modelManager = modelManager
        self.profileProvider = profileProvider
        self.languageProvider = languageProvider
    }

    func prepare() async throws {
        let profile = profileProvider()
        let modelName = modelManager.whisperKitModel(for: profile)
        let downloadBase = try await modelManager.ensureModelExists(for: profile)
        let modelFolder = try await WhisperKit.download(
            variant: modelName,
            downloadBase: downloadBase
        )

        let config = WhisperKitConfig(
            modelFolder: modelFolder.path,
            load: true,
            download: false
        )
        whisperKit = try await WhisperKit(config)
    }

    func transcribe(audioStream: AsyncThrowingStream<[Float], Error>) -> AsyncThrowingStream<ASREvent, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                do {
                    guard let whisperKit else {
                        throw WhisperKitEngineError.modelNotInitialized
                    }

                    var samples: [Float] = []
                    for try await chunk in audioStream {
                        samples.append(contentsOf: chunk)
                        if samples.count > 16_000 {
                            continuation.yield(.partial("Listening..."))
                        }
                    }

                    if samples.isEmpty {
                        continuation.yield(.final(""))
                        continuation.finish()
                        return
                    }

                    let selectedProfile = profileProvider()
                    let selectedLanguage = languageProvider()
                    let decodeOptions = decodingOptions(
                        for: selectedProfile,
                        language: selectedLanguage
                    )
                    let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: decodeOptions)
                    let text = results.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                    continuation.yield(.final(text))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func decodingOptions(for profile: ModelProfile, language: TranscriptionLanguage) -> DecodingOptions {
        let languageCode = language.whisperLanguageCode
        let shouldDetectLanguage = language == .auto
        let isMultilingual = profile == .multilingual || language == .kannada

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
                concurrentWorkerCount: 4,
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
