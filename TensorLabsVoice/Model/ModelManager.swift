import Foundation

enum ModelProfile: String, CaseIterable, Codable {
    case balanced
    case fast
}

struct ModelDescriptor {
    let profile: ModelProfile
    let whisperKitModel: String
}

@MainActor
final class ModelManager {
    private let fileManager = FileManager.default

    private var modelRoot: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("TensorLabsVoice/models", isDirectory: true)
    }

    func descriptor(for profile: ModelProfile) -> ModelDescriptor {
        switch profile {
        case .balanced:
            return ModelDescriptor(
                profile: .balanced,
                whisperKitModel: "small.en"
            )
        case .fast:
            return ModelDescriptor(
                profile: .fast,
                whisperKitModel: "base.en"
            )
        }
    }

    func whisperKitModel(for profile: ModelProfile) -> String {
        descriptor(for: profile).whisperKitModel
    }

    func localModelPath(for profile: ModelProfile) -> URL? {
        let descriptor = descriptor(for: profile)
        let folder = "openai_whisper-\(descriptor.whisperKitModel)"
        let url = modelRoot.appendingPathComponent(folder, isDirectory: true)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func ensureModelExists(for profile: ModelProfile) async throws -> URL {
        try fileManager.createDirectory(at: modelRoot, withIntermediateDirectories: true)
        return modelRoot
    }
}
