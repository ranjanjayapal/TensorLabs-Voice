import Foundation

enum ASREvent: Equatable {
    case partial(String)
    case final(String)
}

@MainActor
protocol ASREngine {
    var id: String { get }
    var requiresSpeechRecognitionPermission: Bool { get }
    func prepare() async throws
    func transcribe(audioStream: AsyncThrowingStream<[Float], Error>) -> AsyncThrowingStream<ASREvent, Error>
    func stop() async
}

struct StreamingSegmentationConfig {
    var windowSize = 512
    var onsetThreshold: Float = 0.015
    var offsetThreshold: Float = 0.008
    var minSpeechDuration: Float = 0.18
    var minSilenceDuration: Float = 0.42
    var preSpeechPadding: Float = 0.12
    var partialResultInterval: Float = 0.9
    var maxSegmentDuration: Float = 12.0
    var emitPartialResults = true

    static let `default` = StreamingSegmentationConfig()
}

final class StreamingSegmentTranscriber: @unchecked Sendable {
    typealias SegmentDecoder = @Sendable ([Float]) async throws -> String

    private enum State {
        case idle
        case pendingSpeech(startSample: Int)
        case speech(startSample: Int)
        case pendingSilence(startSample: Int, silenceStartSample: Int)
    }

    private let config: StreamingSegmentationConfig
    private let sampleRate: Int

    init(config: StreamingSegmentationConfig = .default, sampleRate: Int = 16_000) {
        self.config = config
        self.sampleRate = sampleRate
    }

    func transcribe(
        audioStream: AsyncThrowingStream<[Float], Error>,
        decodeSegment: @escaping SegmentDecoder
    ) -> AsyncThrowingStream<ASREvent, Error> {
        AsyncThrowingStream { continuation in
            Task.detached(priority: .userInitiated) { [config, sampleRate] in
                var state: State = .idle
                var samples: [Float] = []
                var analysisBuffer: [Float] = []
                var finalizedSegments: [String] = []
                var processedSamples = 0
                var lastPartialSample = 0
                var emittedAnyTranscript = false

                func speechDuration(from startSample: Int, to endSample: Int) -> Float {
                    Float(max(0, endSample - startSample)) / Float(sampleRate)
                }

                func segmentText(from startSample: Int, to endSample: Int) async throws -> String {
                    let boundedStart = max(0, min(startSample, samples.count))
                    let boundedEnd = max(boundedStart, min(endSample, samples.count))
                    guard boundedEnd > boundedStart else { return "" }
                    let slice = Array(samples[boundedStart..<boundedEnd])
                    return try await decodeSegment(slice).trimmingCharacters(in: .whitespacesAndNewlines)
                }

                func combinedText(with partial: String?) -> String {
                    let parts = finalizedSegments + (partial.map { $0.isEmpty ? [] : [$0] } ?? [])
                    return parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                }

                func emitFinal(startSample: Int, endSample: Int) async throws {
                    let text = try await segmentText(from: startSample, to: endSample)
                    guard !text.isEmpty else { return }
                    finalizedSegments.append(text)
                    emittedAnyTranscript = true
                    continuation.yield(.final(text))
                }

                func maybeEmitPartial(startSample: Int, endSample: Int) async throws {
                    guard config.emitPartialResults else { return }
                    let elapsed = speechDuration(from: lastPartialSample, to: endSample)
                    guard elapsed >= config.partialResultInterval else { return }
                    let partial = try await segmentText(from: startSample, to: endSample)
                    guard !partial.isEmpty else { return }
                    continuation.yield(.partial(combinedText(with: partial)))
                    lastPartialSample = endSample
                }

                func frameRMS(_ frame: ArraySlice<Float>) -> Float {
                    guard !frame.isEmpty else { return 0 }
                    var sum: Float = 0
                    for sample in frame {
                        sum += sample * sample
                    }
                    return sqrt(sum / Float(frame.count))
                }

                func handleFrame(energy: Float, frameEndSample: Int) async throws {
                    let prePaddingSamples = Int(config.preSpeechPadding * Float(sampleRate))

                    switch state {
                    case .idle:
                        if energy >= config.onsetThreshold {
                            let startSample = max(0, frameEndSample - config.windowSize - prePaddingSamples)
                            state = .pendingSpeech(startSample: startSample)
                        }
                    case .pendingSpeech(let startSample):
                        if energy < config.offsetThreshold {
                            state = .idle
                        } else if speechDuration(from: startSample, to: frameEndSample) >= config.minSpeechDuration {
                            state = .speech(startSample: startSample)
                            lastPartialSample = startSample
                        }
                    case .speech(let startSample):
                        try await maybeEmitPartial(startSample: startSample, endSample: frameEndSample)
                        if speechDuration(from: startSample, to: frameEndSample) >= config.maxSegmentDuration {
                            try await emitFinal(startSample: startSample, endSample: frameEndSample)
                            state = .speech(startSample: frameEndSample)
                            lastPartialSample = frameEndSample
                        } else if energy < config.offsetThreshold {
                            state = .pendingSilence(startSample: startSample, silenceStartSample: frameEndSample - config.windowSize)
                        }
                    case .pendingSilence(let startSample, let silenceStartSample):
                        if energy >= config.onsetThreshold {
                            state = .speech(startSample: startSample)
                        } else if speechDuration(from: silenceStartSample, to: frameEndSample) >= config.minSilenceDuration {
                            try await emitFinal(startSample: startSample, endSample: silenceStartSample)
                            state = .idle
                        }
                    }
                }

                do {
                    for try await chunk in audioStream {
                        guard !Task.isCancelled else { break }
                        guard !chunk.isEmpty else { continue }

                        samples.append(contentsOf: chunk)
                        analysisBuffer.append(contentsOf: chunk)

                        while analysisBuffer.count >= config.windowSize {
                            let frame = ArraySlice(analysisBuffer.prefix(config.windowSize))
                            analysisBuffer.removeFirst(config.windowSize)
                            processedSamples += config.windowSize
                            try await handleFrame(energy: frameRMS(frame), frameEndSample: processedSamples)
                        }
                    }

                    let streamEndSample = samples.count
                    switch state {
                    case .idle:
                        if !emittedAnyTranscript {
                            continuation.yield(.final(""))
                        }
                    case .pendingSpeech(let startSample):
                        if speechDuration(from: startSample, to: streamEndSample) >= config.minSpeechDuration {
                            try await emitFinal(startSample: startSample, endSample: streamEndSample)
                        } else if !emittedAnyTranscript {
                            continuation.yield(.final(""))
                        }
                    case .speech(let startSample):
                        try await emitFinal(startSample: startSample, endSample: streamEndSample)
                    case .pendingSilence(let startSample, _):
                        try await emitFinal(startSample: startSample, endSample: streamEndSample)
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

final class UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
