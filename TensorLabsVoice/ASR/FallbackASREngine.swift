import Foundation

@MainActor
final class FallbackASREngine: ASREngine {
    let id = "fallback"

    private let primary: ASREngine
    private let fallback: ASREngine
    private var activeEngine: ASREngine?
    private(set) var lastEngineUsed: String = "unknown"
    private(set) var lastFallbackUsed: Bool = false
    private(set) var lastPrimaryPrepareError: String?

    init(primary: ASREngine, fallback: ASREngine) {
        self.primary = primary
        self.fallback = fallback
    }

    func prepare() async throws {
        do {
            try await primary.prepare()
            activeEngine = primary
            lastEngineUsed = primary.id
            lastFallbackUsed = false
            lastPrimaryPrepareError = nil
        } catch {
            lastPrimaryPrepareError = error.localizedDescription
            try await fallback.prepare()
            activeEngine = fallback
            lastEngineUsed = fallback.id
            lastFallbackUsed = true
        }
    }

    func transcribe(audioStream: AsyncThrowingStream<[Float], Error>) -> AsyncThrowingStream<ASREvent, Error> {
        let selected = activeEngine ?? fallback
        lastEngineUsed = selected.id
        lastFallbackUsed = (selected.id == fallback.id)

        return AsyncThrowingStream { continuation in
            Task { @MainActor in
                do {
                    for try await event in selected.transcribe(audioStream: audioStream) {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func stop() async {
        let engine = activeEngine ?? fallback
        await engine.stop()
    }
}
