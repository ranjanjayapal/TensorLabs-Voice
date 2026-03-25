import Foundation
import Speech
import AVFoundation

enum AppleSpeechEngineError: Error {
    case recognizerUnavailable
    case authorizationDenied
    case recognizerNotAvailable
}

@MainActor
final class AppleSpeechEngine: ASREngine {
    let id = "apple_speech"
    var requiresSpeechRecognitionPermission: Bool { true }

    private let languageProvider: () -> TranscriptionLanguage
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private let inputFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!

    init(languageProvider: @escaping () -> TranscriptionLanguage) {
        self.languageProvider = languageProvider
    }

    func prepare() async throws {
        guard let recognizer = recognizer() else {
            throw AppleSpeechEngineError.recognizerUnavailable
        }

        guard await isAuthorized() else {
            throw AppleSpeechEngineError.authorizationDenied
        }

        guard recognizer.isAvailable else {
            throw AppleSpeechEngineError.recognizerNotAvailable
        }
    }

    func transcribe(audioStream: AsyncThrowingStream<[Float], Error>) -> AsyncThrowingStream<ASREvent, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                do {
                    let request = SFSpeechAudioBufferRecognitionRequest()
                    request.requiresOnDeviceRecognition = true
                    request.shouldReportPartialResults = true
                    recognitionRequest = request

                    guard let recognizer = recognizer() else {
                        throw AppleSpeechEngineError.recognizerUnavailable
                    }

                    var lastPartial = ""
                    recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                        if let result {
                            let text = result.bestTranscription.formattedString
                            if !text.isEmpty {
                                lastPartial = text
                            }

                            if result.isFinal {
                                continuation.yield(.final(text, scope: .fullTranscript))
                                continuation.finish()
                                Task { @MainActor in
                                    self?.cleanupRecognition()
                                }
                            } else {
                                continuation.yield(.partial(text, scope: .fullTranscript))
                            }
                        }

                        if let error {
                            if !lastPartial.isEmpty {
                                continuation.yield(.final(lastPartial, scope: .fullTranscript))
                                continuation.finish()
                            } else {
                                continuation.finish(throwing: error)
                            }
                            Task { @MainActor in
                                self?.cleanupRecognition()
                            }
                        }
                    }

                    for try await chunk in audioStream {
                        if Task.isCancelled {
                            break
                        }
                        appendChunk(chunk, to: request)
                    }

                    request.endAudio()
                } catch {
                    continuation.finish(throwing: error)
                    cleanupRecognition()
                }
            }
        }
    }

    func stop() async {
        recognitionRequest?.endAudio()
    }

    private func isAuthorized() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    Task { @MainActor in
                        continuation.resume(returning: status == .authorized)
                    }
                }
            }
        default:
            return false
        }
    }

    private func recognizer() -> SFSpeechRecognizer? {
        let locale = Locale(identifier: languageProvider().appleSpeechLocaleIdentifier)
        return SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    private func appendChunk(_ chunk: [Float], to request: SFSpeechAudioBufferRecognitionRequest) {
        guard !chunk.isEmpty else { return }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(chunk.count)) else {
            return
        }

        buffer.frameLength = AVAudioFrameCount(chunk.count)
        if let channelData = buffer.floatChannelData {
            chunk.withUnsafeBufferPointer { ptr in
                channelData[0].update(from: ptr.baseAddress!, count: chunk.count)
            }
        }

        request.append(buffer)
    }

    private func cleanupRecognition() {
        recognitionTask = nil
        recognitionRequest = nil
    }
}
