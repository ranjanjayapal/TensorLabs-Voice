import Foundation

@MainActor
final class HybridStreamingASREngine: ASREngine {
    let id = "hybrid_streaming_asr"
    var requiresSpeechRecognitionPermission: Bool {
        realtimeEngine.requiresSpeechRecognitionPermission || finalizationEngine.requiresSpeechRecognitionPermission
    }

    private let realtimeEngine: ASREngine
    private let finalizationEngine: ASREngine
    private let metricsLogger: LocalMetricsLogger
    private var finalizationAvailable = false

    init(
        realtimeEngine: ASREngine,
        finalizationEngine: ASREngine,
        metricsLogger: LocalMetricsLogger
    ) {
        self.realtimeEngine = realtimeEngine
        self.finalizationEngine = finalizationEngine
        self.metricsLogger = metricsLogger
    }

    func prepare() async throws {
        try await realtimeEngine.prepare()

        do {
            try await finalizationEngine.prepare()
            finalizationAvailable = true
        } catch {
            finalizationAvailable = false
            metricsLogger.log(event: "hybrid_finalization_prepare_failed", metadata: [
                "error": error.localizedDescription,
                "realtime_engine": realtimeEngine.id,
                "finalization_engine": finalizationEngine.id,
            ])
        }
    }

    func transcribe(audioStream: AsyncThrowingStream<[Float], Error>) -> AsyncThrowingStream<ASREvent, Error> {
        guard finalizationAvailable else {
            return realtimeEngine.transcribe(audioStream: audioStream)
        }

        return AsyncThrowingStream { continuation in
            final actor SharedState {
                private(set) var latestRealtimeTranscript = ""
                private(set) var latestRealtimeEventWasFinal = false
                private(set) var latestFinalizationTranscript = ""

                func recordRealtime(_ event: ASREvent) -> Bool {
                    let text: String
                    let isFinal: Bool
                    switch event {
                    case let .partial(value, _):
                        text = value
                        isFinal = false
                    case let .final(value, _):
                        text = value
                        isFinal = true
                    }

                    latestRealtimeTranscript = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    latestRealtimeEventWasFinal = isFinal
                    return latestRealtimeTranscript.isEmpty
                }

                func recordFinalization(_ text: String) {
                    latestFinalizationTranscript = text.trimmingCharacters(in: .whitespacesAndNewlines)
                }

                func finalReplacementEvent() -> ASREvent? {
                    guard !latestFinalizationTranscript.isEmpty else { return nil }
                    guard latestFinalizationTranscript != latestRealtimeTranscript || !latestRealtimeEventWasFinal else {
                        return nil
                    }
                    return .final(latestFinalizationTranscript, scope: .fullTranscript)
                }
            }

            final class Broadcaster: @unchecked Sendable {
                private var continuations: [UUID: AsyncThrowingStream<[Float], Error>.Continuation] = [:]
                private let lock = NSLock()

                func makeStream() -> AsyncThrowingStream<[Float], Error> {
                    let id = UUID()
                    return AsyncThrowingStream { continuation in
                        lock.lock()
                        continuations[id] = continuation
                        lock.unlock()

                        continuation.onTermination = { [weak self] _ in
                            self?.lock.lock()
                            self?.continuations.removeValue(forKey: id)
                            self?.lock.unlock()
                        }
                    }
                }

                func yield(_ chunk: [Float]) {
                    lock.lock()
                    let activeContinuations = continuations.values
                    lock.unlock()
                    for continuation in activeContinuations {
                        continuation.yield(chunk)
                    }
                }

                func finish(throwing error: Error? = nil) {
                    lock.lock()
                    let activeContinuations = continuations.values
                    continuations.removeAll()
                    lock.unlock()

                    for continuation in activeContinuations {
                        if let error {
                            continuation.finish(throwing: error)
                        } else {
                            continuation.finish()
                        }
                    }
                }
            }

            let sharedState = SharedState()
            let broadcaster = Broadcaster()
            let realtimeStream = broadcaster.makeStream()
            let finalizationStream = broadcaster.makeStream()

            Task {
                let realtimeTask = Task {
                    do {
                        for try await event in realtimeEngine.transcribe(audioStream: realtimeStream) {
                            _ = await sharedState.recordRealtime(event)
                            continuation.yield(event)
                        }
                    } catch {
                        throw error
                    }
                }

                let finalizationTask = Task {
                    var composer = TranscriptComposer()
                    do {
                        for try await event in finalizationEngine.transcribe(audioStream: finalizationStream) {
                            composer.apply(event)
                        }
                        await sharedState.recordFinalization(composer.finalTranscript)
                    } catch {
                        metricsLogger.log(event: "hybrid_finalization_runtime_failed", metadata: [
                            "error": error.localizedDescription,
                            "finalization_engine": finalizationEngine.id,
                        ])
                    }
                }

                do {
                    for try await chunk in audioStream {
                        broadcaster.yield(chunk)
                    }
                    broadcaster.finish()

                    do {
                        try await realtimeTask.value
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }

                    await finalizationTask.value
                    if let replacement = await sharedState.finalReplacementEvent() {
                        if case let .final(text, _) = replacement {
                            let realtimeLength = await sharedState.latestRealtimeTranscript.count
                            metricsLogger.log(event: "hybrid_final_replacement", metadata: [
                                "realtime_engine": realtimeEngine.id,
                                "finalization_engine": finalizationEngine.id,
                                "realtime_characters": "\(realtimeLength)",
                                "final_characters": "\(text.count)",
                            ])
                        }
                        continuation.yield(replacement)
                    }
                    continuation.finish()
                } catch {
                    broadcaster.finish(throwing: error)
                    _ = try? await realtimeTask.value
                    await finalizationTask.value
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func stop() async {
        await realtimeEngine.stop()
        await finalizationEngine.stop()
    }
}
