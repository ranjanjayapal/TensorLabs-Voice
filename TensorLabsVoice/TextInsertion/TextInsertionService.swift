import AppKit
import ApplicationServices

final class TextInsertionService {
    func insertText(_ text: String, mode: InsertionMode) -> Bool {
        guard !text.isEmpty else { return true }

        let effectiveMode = preferredMode(for: mode)

        switch effectiveMode {
        case .accessibilityFirst:
            if insertUsingAccessibility(text) { return true }
            return insertUsingPasteboard(text)
        case .pasteboardFirst:
            if insertUsingPasteboard(text) { return true }
            return insertUsingAccessibility(text)
        }
    }

    private func preferredMode(for configuredMode: InsertionMode) -> InsertionMode {
        guard configuredMode == .accessibilityFirst else { return configuredMode }
        guard let bundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return configuredMode
        }

        if Self.terminalBundleIdentifiers.contains(bundleIdentifier) {
            return .pasteboardFirst
        }

        return configuredMode
    }

    private func insertUsingAccessibility(_ text: String) -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?

        let status = AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        guard status == .success, let focused = focusedElement else { return false }
        let target = focused as! AXUIElement

        if AXUIElementSetAttributeValue(target, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success {
            return true
        }

        if AXUIElementSetAttributeValue(target, kAXValueAttribute as CFString, text as CFTypeRef) == .success {
            return true
        }

        return false
    }

    private func insertUsingPasteboard(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        let previousValue = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return false }

        let source = CGEventSource(stateID: .combinedSessionState)
        guard source != nil else { return false }
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        keyUp?.flags = .maskCommand
        guard let keyDown, let keyUp else { return false }

        if let processIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            keyDown.postToPid(processIdentifier)
            keyUp.postToPid(processIdentifier)
        } else {
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }

        // Give the focused app a moment to consume Cmd+V before restoring clipboard.
        if let previousValue {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                pasteboard.clearContents()
                _ = pasteboard.setString(previousValue, forType: .string)
            }
        }

        return true
    }

    private static let terminalBundleIdentifiers: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "net.kovidgoyal.kitty",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp",
        "io.alacritty",
        "co.zeit.hyper",
    ]
}
