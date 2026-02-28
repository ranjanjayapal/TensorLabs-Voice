import AVFoundation
import Foundation
import Speech

struct PermissionStatus {
    let microphoneGranted: Bool
    let speechGranted: Bool
}

@MainActor
final class PermissionService {
    func requestRequiredPermissions() async -> PermissionStatus {
        let microphoneGranted = microphoneStatusAllowsStart()
        let speechGranted = speechStatusAllowsStart()
        return PermissionStatus(microphoneGranted: microphoneGranted, speechGranted: speechGranted)
    }

    private func microphoneStatusAllowsStart() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            // Avoid calling requestAccess() here. In swift-run contexts this can trap
            // without an app-bundle Info.plist usage string.
            return true
        default:
            return false
        }
    }

    private func speechStatusAllowsStart() -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            // Let primary ASR start; fallback can surface explicit speech auth errors.
            return true
        default:
            return false
        }
    }
}
