import AVFoundation
import ApplicationServices
import Foundation
import Speech

struct PermissionStatus {
    let microphoneGranted: Bool
    let speechGranted: Bool
    let accessibilityGranted: Bool

    func satisfiesRequirements(requiresSpeechRecognition: Bool) -> Bool {
        microphoneGranted && accessibilityGranted && (!requiresSpeechRecognition || speechGranted)
    }
}

@MainActor
final class PermissionService {
    func currentStatus() -> PermissionStatus {
        PermissionStatus(
            microphoneGranted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            speechGranted: SFSpeechRecognizer.authorizationStatus() == .authorized,
            accessibilityGranted: AXIsProcessTrusted()
        )
    }

    func requestRequiredPermissions(requiresSpeechRecognition: Bool) async -> PermissionStatus {
        let microphoneGranted = await requestMicrophonePermission()
        let speechGranted = requiresSpeechRecognition ? await requestSpeechPermission() : currentStatus().speechGranted
        let accessibilityGranted = requestAccessibilityPermission()
        return PermissionStatus(
            microphoneGranted: microphoneGranted,
            speechGranted: speechGranted,
            accessibilityGranted: accessibilityGranted
        )
    }

    private func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }

    private func requestSpeechPermission() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        default:
            return false
        }
    }

    private func requestAccessibilityPermission() -> Bool {
        if AXIsProcessTrusted() {
            return true
        }

        // Swift 6 concurrency workaround: avoid direct reference to the global CF constant.
        let promptKey = "AXTrustedCheckOptionPrompt"
        let options: CFDictionary = [
            promptKey: true,
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        return AXIsProcessTrusted()
    }
}
