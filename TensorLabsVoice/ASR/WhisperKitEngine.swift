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
    private var whisperKit: WhisperKit?

    init(modelManager: ModelManager, profileProvider: @escaping () -> ModelProfile) {
        self.modelManager = modelManager
        self.profileProvider = profileProvider
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

                    let results = try await whisperKit.transcribe(audioArray: samples)
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

    func stop() async {
        whisperKit?.audioProcessor.stopRecording()
    }
}
