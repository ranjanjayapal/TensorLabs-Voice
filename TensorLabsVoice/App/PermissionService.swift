import AVFoundation
import ApplicationServices
import Foundation
import Speech

enum RuntimeTrace {
    private static let lock = NSLock()
    private static let logURL = URL(fileURLWithPath: "/tmp/tensorlabs_voice_runtime_trace.log")

    static func mark(_ message: String) {
        lock.lock()
        defer { lock.unlock() }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let threadLabel = Thread.isMainThread ? "main" : "background"
        let line = "\(timestamp) [\(threadLabel)] \(message)\n"
        let data = Data(line.utf8)

        if FileManager.default.fileExists(atPath: logURL.path) {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
                return
            }
        }

        try? data.write(to: logURL, options: .atomic)
    }
}

struct PermissionStatus {
    let microphoneGranted: Bool
    let speechGranted: Bool
    let accessibilityGranted: Bool

    func satisfiesRequirements(
        requiresSpeechRecognition: Bool,
        requiresAccessibility: Bool = true
    ) -> Bool {
        microphoneGranted
            && (!requiresAccessibility || accessibilityGranted)
            && (!requiresSpeechRecognition || speechGranted)
    }
}

@MainActor
final class PermissionService {
    func currentStatus() -> PermissionStatus {
        let status = PermissionStatus(
            microphoneGranted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            speechGranted: SFSpeechRecognizer.authorizationStatus() == .authorized,
            accessibilityGranted: AXIsProcessTrusted()
        )
        RuntimeTrace.mark(
            "PermissionService.currentStatus mic=\(status.microphoneGranted) speech=\(status.speechGranted) accessibility=\(status.accessibilityGranted) bundle=\(Bundle.main.bundleIdentifier ?? "nil") exec=\(Bundle.main.executableURL?.path ?? "nil") bundlePath=\(Bundle.main.bundleURL.path)"
        )
        return status
    }

    func requestRequiredPermissions(
        requiresSpeechRecognition: Bool,
        requiresAccessibility: Bool = true
    ) async -> PermissionStatus {
        RuntimeTrace.mark("PermissionService.requestRequiredPermissions begin speech=\(requiresSpeechRecognition) accessibility=\(requiresAccessibility)")
        let microphoneGranted = await requestMicrophonePermission()
        RuntimeTrace.mark("PermissionService microphone result=\(microphoneGranted)")
        let speechGranted = requiresSpeechRecognition ? await requestSpeechPermission() : currentStatus().speechGranted
        RuntimeTrace.mark("PermissionService speech result=\(speechGranted)")
        let accessibilityGranted = requiresAccessibility ? currentStatus().accessibilityGranted : currentStatus().accessibilityGranted
        RuntimeTrace.mark("PermissionService accessibility observed=\(accessibilityGranted)")
        return PermissionStatus(
            microphoneGranted: microphoneGranted,
            speechGranted: speechGranted,
            accessibilityGranted: accessibilityGranted
        )
    }

    private func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            RuntimeTrace.mark("PermissionService microphone already authorized")
            return true
        case .notDetermined:
            RuntimeTrace.mark("PermissionService requesting microphone authorization")
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    RuntimeTrace.mark("PermissionService microphone callback granted=\(granted)")
                    Task { @MainActor in
                        RuntimeTrace.mark("PermissionService microphone resume on MainActor granted=\(granted)")
                        continuation.resume(returning: granted)
                    }
                }
            }
        default:
            RuntimeTrace.mark("PermissionService microphone denied or restricted")
            return false
        }
    }

    private func requestSpeechPermission() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            RuntimeTrace.mark("PermissionService speech already authorized")
            return true
        case .notDetermined:
            RuntimeTrace.mark("PermissionService requesting speech authorization via detached helper")
            return await Self.requestSpeechAuthorizationDetached()
        default:
            RuntimeTrace.mark("PermissionService speech denied or restricted")
            return false
        }
    }

    nonisolated private static func requestSpeechAuthorizationDetached() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                RuntimeTrace.mark("PermissionService detached speech authorization request started")
                SFSpeechRecognizer.requestAuthorization { status in
                    RuntimeTrace.mark("PermissionService speech callback status=\(status.rawValue)")
                    continuation.resume(returning: status == .authorized)
                }
            }
        }
    }

    func promptForAccessibilityPermission() -> Bool {
        RuntimeTrace.mark("PermissionService prompting for accessibility permission")
        return requestAccessibilityPermission()
    }

    private func requestAccessibilityPermission() -> Bool {
        if AXIsProcessTrusted() {
            RuntimeTrace.mark("PermissionService accessibility already trusted")
            return true
        }

        // Swift 6 concurrency workaround: avoid direct reference to the global CF constant.
        let promptKey = "AXTrustedCheckOptionPrompt"
        let options: CFDictionary = [
            promptKey: true,
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        let trusted = AXIsProcessTrusted()
        RuntimeTrace.mark("PermissionService accessibility prompt invoked trustedNow=\(trusted)")
        return trusted
    }
}
