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
            lastEngineUsed = primary.id
            lastFallbackUsed = false
            lastPrimaryPrepareError = nil
            lastPrimaryRuntimeError = nil
        } catch {
            lastPrimaryPrepareError = error.localizedDescription
            try await fallback.prepare()
            activeEngine = fallback
            lastEngineUsed = fallback.id
            lastFallbackUsed = true
            lastPrimaryRuntimeError = nil
        }
    }

    func transcribe(audioStream: AsyncThrowingStream<[Float], Error>) -> AsyncThrowingStream<ASREvent, Error> {
        return AsyncThrowingStream { continuation in
            Task { @MainActor in
                do {
                    let bufferedChunks = try await collectChunks(from: audioStream)
                    let selected = activeEngine ?? fallback
                    lastEngineUsed = selected.id
                    lastFallbackUsed = (selected.id == fallback.id)

                    do {
                        try await replay(bufferedChunks, with: selected, into: continuation)
                    } catch {
                        guard selected.id != fallback.id else {
                            throw error
                        }

                        lastPrimaryRuntimeError = error.localizedDescription
                        try await fallback.prepare()
                        activeEngine = fallback
                        lastEngineUsed = fallback.id
                        lastFallbackUsed = true
                        try await replay(bufferedChunks, with: fallback, into: continuation)
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

    private func collectChunks(from audioStream: AsyncThrowingStream<[Float], Error>) async throws -> [[Float]] {
        var chunks: [[Float]] = []
        for try await chunk in audioStream {
            chunks.append(chunk)
        }
        return chunks
    }

    private func replay(
        _ chunks: [[Float]],
        with engine: ASREngine,
        into continuation: AsyncThrowingStream<ASREvent, Error>.Continuation
    ) async throws {
        for try await event in engine.transcribe(audioStream: Self.stream(from: chunks)) {
            continuation.yield(event)
        }
    }

    private static func stream(from chunks: [[Float]]) -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }
}
