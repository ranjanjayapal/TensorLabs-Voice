import Foundation

@MainActor
final class FallbackASREngine: ASREngine {
    let id = "fallback"
    var requiresSpeechRecognitionPermission: Bool { false }

    private let primary: ASREngine
    private let fallback: ASREngine
    private var activeEngine: ASREngine?
    private(set) var lastEngineUsed: String = "unknown"
    private(set) var lastFallbackUsed: Bool = false
    private(set) var lastPrimaryPrepareError: String?
    private(set) var lastPrimaryRuntimeError: String?

    init(primary: ASREngine, fallback: ASREngine) {
        self.primary = primary
        self.fallback = fallback
    }

    func prepare() async throws {
        do {
            try await primary.prepare()
            activeEngine = primary
            lastEngineUsed = runtimeEngineID(for: primary)
            lastFallbackUsed = false
            lastPrimaryPrepareError = nil
            lastPrimaryRuntimeError = nil
        } catch {
            lastPrimaryPrepareError = error.localizedDescription
            try await fallback.prepare()
            activeEngine = fallback
            lastEngineUsed = runtimeEngineID(for: fallback)
            lastFallbackUsed = true
            lastPrimaryRuntimeError = nil
        }
    }

    func transcribe(audioStream: AsyncThrowingStream<[Float], Error>) -> AsyncThrowingStream<ASREvent, Error> {
        let selected = activeEngine ?? fallback
        lastEngineUsed = runtimeEngineID(for: selected)
        lastFallbackUsed = (selected.id == fallback.id)
        return selected.transcribe(audioStream: audioStream)
    }

    func stop() async {
        let engine = activeEngine ?? fallback
        await engine.stop()
    }

    private func runtimeEngineID(for engine: ASREngine) -> String {
        if let preferred = engine as? PreferredLocalASREngine {
            return preferred.activeEngineID
        }
        return engine.id
    }
}
