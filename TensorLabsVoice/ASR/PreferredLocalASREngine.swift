import Foundation

@MainActor
final class PreferredLocalASREngine: ASREngine {
    let id = "preferred_local_asr"
    var requiresSpeechRecognitionPermission: Bool { false }

    private let modelManager: ModelManager
    private let modeProvider: () -> DictationMode
    private let languageProvider: () -> TranscriptionLanguage
    private let qwenEngine: Qwen3ASREngine
    private let parakeetEngine: ParakeetASREngine
    private let whisperEngine: WhisperKitEngine
    private var activeEngine: ASREngine?

    var activeEngineID: String {
        (activeEngine ?? selectedEngine()).id
    }

    init(
        modelManager: ModelManager,
        modeProvider: @escaping () -> DictationMode,
        languageProvider: @escaping () -> TranscriptionLanguage,
        qwenEngine: Qwen3ASREngine,
        parakeetEngine: ParakeetASREngine,
        whisperEngine: WhisperKitEngine
    ) {
        self.modelManager = modelManager
        self.modeProvider = modeProvider
        self.languageProvider = languageProvider
        self.qwenEngine = qwenEngine
        self.parakeetEngine = parakeetEngine
        self.whisperEngine = whisperEngine
    }

    func prepare() async throws {
        let engine = selectedEngine()
        try await engine.prepare()
        activeEngine = engine
    }

    func transcribe(audioStream: AsyncThrowingStream<[Float], Error>) -> AsyncThrowingStream<ASREvent, Error> {
        (activeEngine ?? selectedEngine()).transcribe(audioStream: audioStream)
    }

    func stop() async {
        await (activeEngine ?? selectedEngine()).stop()
    }

    private func selectedEngine() -> ASREngine {
        let descriptor = modelManager.descriptor(for: modeProvider(), language: languageProvider())
        switch descriptor.backend {
        case .parakeet:
            return parakeetEngine
        case .qwen3:
            return qwenEngine
        case .whisperKit:
            return whisperEngine
        }
    }
}
