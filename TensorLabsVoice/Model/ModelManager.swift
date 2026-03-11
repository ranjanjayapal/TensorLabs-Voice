import Foundation

enum DictationMode: String, CaseIterable, Codable {
    case fast
    case balanced
    case accurateFast
    case accurate
}

enum ASRBackend: String {
    case parakeet
    case qwen3
    case whisperKit
}

enum TranscriptionLanguage: String, CaseIterable, Codable {
    case auto
    case english
    case kannada

    var whisperLanguageCode: String? {
        switch self {
        case .auto:
            return nil
        case .english:
            return "en"
        case .kannada:
            return "kn"
        }
    }

    var qwenLanguageHint: String? {
        switch self {
        case .auto:
            return nil
        case .english:
            return "english"
        case .kannada:
            return "kannada"
        }
    }

    var appleSpeechLocaleIdentifier: String {
        switch self {
        case .auto:
            return Locale.current.identifier
        case .english:
            return "en-US"
        case .kannada:
            return "kn-IN"
        }
    }
}

struct ASRRuntimeDescriptor {
    let mode: DictationMode
    let backend: ASRBackend
    let displayName: String
    let technicalDetails: String
    let whisperKitModel: String?
    let qwenModelId: String?
    let parakeetModelId: String?
}

@MainActor
final class ModelManager {
    private let fileManager = FileManager.default

    private var modelRoot: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("TensorLabsVoice/models", isDirectory: true)
    }

    func descriptor(for mode: DictationMode, language: TranscriptionLanguage) -> ASRRuntimeDescriptor {
        switch mode {
        case .fast:
            if language == .kannada {
                return ASRRuntimeDescriptor(
                    mode: .fast,
                    backend: .qwen3,
                    displayName: "Fast",
                    technicalDetails: "Qwen3-ASR 0.6B (fallback for Kannada)",
                    whisperKitModel: nil,
                    qwenModelId: "aufklarer/Qwen3-ASR-0.6B-MLX-4bit",
                    parakeetModelId: nil
                )
            }

            return ASRRuntimeDescriptor(
                mode: .fast,
                backend: .parakeet,
                displayName: "Fast",
                technicalDetails: "Parakeet TDT (CoreML)",
                whisperKitModel: nil,
                qwenModelId: nil,
                parakeetModelId: "aufklarer/Parakeet-TDT-v3-CoreML-INT4"
            )
        case .balanced:
            return ASRRuntimeDescriptor(
                mode: .balanced,
                backend: .qwen3,
                displayName: "Balanced",
                technicalDetails: "Qwen3-ASR 0.6B (MLX)",
                whisperKitModel: nil,
                qwenModelId: "aufklarer/Qwen3-ASR-0.6B-MLX-4bit",
                parakeetModelId: nil
            )
        case .accurateFast:
            return ASRRuntimeDescriptor(
                mode: .accurateFast,
                backend: .whisperKit,
                displayName: "Accurate Fast",
                technicalDetails: "Whisper distil-large-v3 (WhisperKit)",
                whisperKitModel: "distil-large-v3",
                qwenModelId: nil,
                parakeetModelId: nil
            )
        case .accurate:
            return ASRRuntimeDescriptor(
                mode: .accurate,
                backend: .whisperKit,
                displayName: "Accurate",
                technicalDetails: "Whisper large-v3 (WhisperKit)",
                whisperKitModel: "large-v3",
                qwenModelId: nil,
                parakeetModelId: nil
            )
        }
    }

    func whisperKitModel(for mode: DictationMode, language: TranscriptionLanguage) -> String? {
        descriptor(for: mode, language: language).whisperKitModel
    }

    func qwenModelId(for mode: DictationMode, language: TranscriptionLanguage) -> String? {
        descriptor(for: mode, language: language).qwenModelId
    }

    func parakeetModelId(for mode: DictationMode, language: TranscriptionLanguage) -> String? {
        descriptor(for: mode, language: language).parakeetModelId
    }

    func localModelPath(for mode: DictationMode, language: TranscriptionLanguage) -> URL? {
        guard let whisperKitModel = descriptor(for: mode, language: language).whisperKitModel else {
            return nil
        }
        let folder = "openai_whisper-\(whisperKitModel)"
        let url = modelRoot.appendingPathComponent(folder, isDirectory: true)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func ensureModelExists(for mode: DictationMode) async throws -> URL {
        try fileManager.createDirectory(at: modelRoot, withIntermediateDirectories: true)
        return modelRoot
    }
}
