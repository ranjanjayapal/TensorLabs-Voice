import AppKit
import ApplicationServices

final class TextInsertionService {
    enum InsertionResult {
        case accessibility
        case pasteboard
        case failed
    }

    enum LiveSessionStatus {
        case active(LiveCompositionContext)
        case focusLost
        case unavailable
    }

    final class LiveTextSession {
        enum Transport {
            case accessibility
            case keyboard
        }

        let transport: Transport
        private let target: AXUIElement?
        private let targetProcessIdentifier: pid_t?
        private var trackedRange: CFRange
        private var lastKnownValue: String = ""
        private var isActive = true
        private var lastRenderedText: String = ""
        private var preservesOwnSelection = false

        init(target: AXUIElement, trackedRange: CFRange) {
            self.transport = .accessibility
            self.target = target
            self.targetProcessIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier
            self.trackedRange = trackedRange
        }

        init(processIdentifier: pid_t) {
            self.transport = .keyboard
            self.target = nil
            self.targetProcessIdentifier = processIdentifier
            self.trackedRange = CFRange(location: 0, length: 0)
        }

        func update(text: String) -> Bool {
            guard isActive else { return false }
            switch transport {
            case .accessibility:
                return replaceTrackedRange(with: text)
            case .keyboard:
                return replaceTypedText(with: text)
            }
        }

        func finalize(text: String) -> Bool {
            defer { isActive = false }
            switch transport {
            case .accessibility:
                return replaceTrackedRange(with: text)
            case .keyboard:
                return replaceTypedText(with: text)
            }
        }

        func cancel() {
            isActive = false
        }

        func status() -> LiveSessionStatus {
            guard isActive else { return .unavailable }
            switch transport {
            case .accessibility:
                guard let target else { return .unavailable }
                guard Self.isFocused(target) else { return .focusLost }

                var selectedRange = CFRange(location: 0, length: 0)
                guard Self.readSelectedRange(from: target, into: &selectedRange) else {
                    return .unavailable
                }

                let currentValue = Self.readValue(from: target) ?? lastKnownValue
                let selectionCollapsedAtEnd =
                    selectedRange.length == 0 &&
                    selectedRange.location == trackedRange.location + trackedRange.length
                let selectionMatchesTracked =
                    selectedRange.location == trackedRange.location &&
                    selectedRange.length == trackedRange.length

                if preservesOwnSelection, currentValue == lastKnownValue, (selectionCollapsedAtEnd || selectionMatchesTracked) {
                    // Preserve the existing dictated span when the host collapses the caret
                    // immediately after our own replacement.
                } else if selectedRange.location != trackedRange.location || selectedRange.length != trackedRange.length {
                    trackedRange = selectedRange
                } else if !currentValue.isEmpty, currentValue != lastKnownValue {
                    trackedRange = selectedRange
                }

                preservesOwnSelection = false
                lastKnownValue = currentValue
                let prefix = prefixText(in: currentValue, upToUTF16Location: trackedRange.location)
                let suffix = suffixText(
                    in: currentValue,
                    fromUTF16Location: trackedRange.location + trackedRange.length
                )
                return .active(LiveCompositionContext(prefixText: prefix, suffixText: suffix))
            case .keyboard:
                guard let targetProcessIdentifier else { return .unavailable }
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetProcessIdentifier else {
                    return .focusLost
                }
                return .active(LiveCompositionContext())
            }
        }

        private func replaceTrackedRange(with text: String) -> Bool {
            guard let target else { return false }

            if setSelectedRange(trackedRange),
               AXUIElementSetAttributeValue(target, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success {
                let length = (text as NSString).length
                trackedRange = CFRange(location: trackedRange.location, length: length)
                lastKnownValue = Self.readValue(from: target) ?? lastKnownValue
                preservesOwnSelection = true
                _ = setSelectedRange(trackedRange)
                return true
            }

            guard let currentValue = Self.readValue(from: target) ?? (!lastKnownValue.isEmpty ? lastKnownValue : nil),
                  let updatedValue = Self.replacing(range: trackedRange, in: currentValue, with: text),
                  AXUIElementSetAttributeValue(target, kAXValueAttribute as CFString, updatedValue as CFTypeRef) == .success
            else {
                return false
            }

            let insertedLength = (text as NSString).length
            trackedRange = CFRange(location: trackedRange.location, length: insertedLength)
            lastKnownValue = updatedValue
            preservesOwnSelection = true
            _ = setSelectedRange(trackedRange)
            return true
        }

        private func replaceTypedText(with text: String) -> Bool {
            guard let targetProcessIdentifier else { return false }
            let prefixLength = text.commonPrefix(with: lastRenderedText).count
            let charactersToDelete = lastRenderedText.count - prefixLength
            let suffixToInsert = String(text.dropFirst(prefixLength))

            if charactersToDelete > 0 {
                guard Self.sendBackspaces(charactersToDelete, to: targetProcessIdentifier) else { return false }
            }

            if !suffixToInsert.isEmpty {
                guard Self.sendUnicodeText(suffixToInsert, to: targetProcessIdentifier) else { return false }
            }

            lastRenderedText = text
            return true
        }

        private func setSelectedRange(_ range: CFRange) -> Bool {
            guard let target else { return false }
            var mutableRange = range
            guard let value = AXValueCreate(.cfRange, &mutableRange) else { return false }
            return AXUIElementSetAttributeValue(target, kAXSelectedTextRangeAttribute as CFString, value) == .success
        }

        private func prefixText(in value: String, upToUTF16Location location: Int) -> String {
            let utf16 = value.utf16
            let boundedLocation = max(0, min(location, utf16.count))
            let index = String.Index(utf16Offset: boundedLocation, in: value)
            return String(value[..<index])
        }

        private func suffixText(in value: String, fromUTF16Location location: Int) -> String {
            let utf16 = value.utf16
            let boundedLocation = max(0, min(location, utf16.count))
            let index = String.Index(utf16Offset: boundedLocation, in: value)
            return String(value[index...])
        }

        private static func isFocused(_ target: AXUIElement) -> Bool {
            let system = AXUIElementCreateSystemWide()
            var focusedElement: CFTypeRef?
            guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success,
                  let focusedElement
            else {
                return false
            }

            return CFEqual(focusedElement, target)
        }

        private static func readSelectedRange(from target: AXUIElement, into range: inout CFRange) -> Bool {
            var selectedRangeRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(target, kAXSelectedTextRangeAttribute as CFString, &selectedRangeRef) == .success,
                  let selectedRangeRef,
                  CFGetTypeID(selectedRangeRef) == AXValueGetTypeID()
            else {
                return false
            }

            let value = selectedRangeRef as! AXValue
            guard AXValueGetType(value) == .cfRange else { return false }
            return AXValueGetValue(value, .cfRange, &range)
        }

        fileprivate static func readValue(from target: AXUIElement) -> String? {
            var valueRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(target, kAXValueAttribute as CFString, &valueRef) == .success else {
                return nil
            }

            return valueRef as? String
        }

        fileprivate static func replacing(range: CFRange, in value: String, with replacement: String) -> String? {
            let utf16Count = value.utf16.count
            let start = max(0, min(range.location, utf16Count))
            let end = max(start, min(range.location + range.length, utf16Count))
            guard let stringRange = Range(NSRange(location: start, length: end - start), in: value) else {
                return nil
            }

            var updated = value
            updated.replaceSubrange(stringRange, with: replacement)
            return updated
        }

        private static func sendBackspaces(_ count: Int, to processIdentifier: pid_t) -> Bool {
            guard count > 0 else { return true }
            guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }

            for _ in 0..<count {
                guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true),
                      let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false)
                else {
                    return false
                }
                keyDown.postToPid(processIdentifier)
                keyUp.postToPid(processIdentifier)
            }

            return true
        }

        private static func sendUnicodeText(_ text: String, to processIdentifier: pid_t) -> Bool {
            guard !text.isEmpty else { return true }
            guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }

            let scalars = Array(text.utf16)
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else {
                return false
            }

            keyDown.keyboardSetUnicodeString(stringLength: scalars.count, unicodeString: scalars)
            keyUp.keyboardSetUnicodeString(stringLength: scalars.count, unicodeString: scalars)
            keyDown.postToPid(processIdentifier)
            keyUp.postToPid(processIdentifier)
            return true
        }
    }

    func insertText(_ text: String, mode: InsertionMode, preferredProcessIdentifier: pid_t? = nil) -> InsertionResult {
        guard !text.isEmpty else { return .pasteboard }

        let effectiveMode = preferredMode(for: mode)

        switch effectiveMode {
        case .accessibilityFirst:
            if insertUsingAccessibility(text) { return .accessibility }
            return insertUsingPasteboard(text, preferredProcessIdentifier: preferredProcessIdentifier) ? .pasteboard : .failed
        case .pasteboardFirst:
            if insertUsingPasteboard(text, preferredProcessIdentifier: preferredProcessIdentifier) { return .pasteboard }
            return insertUsingAccessibility(text) ? .accessibility : .failed
        }
    }

    func beginLiveTextSession(mode: InsertionMode) -> LiveTextSession? {
        let effectiveMode = preferredMode(for: mode)
        guard effectiveMode == .accessibilityFirst else { return nil }
        if let target = focusedElement(), supportsLiveRangeReplacement(target) {
            var selectedRange = CFRange(location: 0, length: 0)
            if readSelectedRange(from: target, into: &selectedRange) {
                return LiveTextSession(target: target, trackedRange: selectedRange)
            }
        }

        if let processIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            return LiveTextSession(processIdentifier: processIdentifier)
        }

        return nil
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
        guard let target = focusedElement() else { return false }

        if AXUIElementSetAttributeValue(target, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success {
            return true
        }

        var selectedRange = CFRange(location: 0, length: 0)
        if readSelectedRange(from: target, into: &selectedRange),
           let currentValue = LiveTextSession.readValue(from: target),
           let updatedValue = LiveTextSession.replacing(range: selectedRange, in: currentValue, with: text),
           AXUIElementSetAttributeValue(target, kAXValueAttribute as CFString, updatedValue as CFTypeRef) == .success {
            let insertedLength = (text as NSString).length
            var newRange = CFRange(location: selectedRange.location, length: insertedLength)
            if let value = AXValueCreate(.cfRange, &newRange) {
                _ = AXUIElementSetAttributeValue(target, kAXSelectedTextRangeAttribute as CFString, value)
            }
            return true
        }

        if AXUIElementSetAttributeValue(target, kAXValueAttribute as CFString, text as CFTypeRef) == .success {
            return true
        }

        return false
    }

    private func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?

        let status = AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        guard status == .success, let focused = focusedElement else { return nil }
        return (focused as! AXUIElement)
    }

    private func supportsLiveRangeReplacement(_ target: AXUIElement) -> Bool {
        var namesRef: CFArray?
        guard AXUIElementCopyAttributeNames(target, &namesRef) == .success, let namesRef else {
            return false
        }

        let names = namesRef as! [String]
        let hasSelectionRange = names.contains(kAXSelectedTextRangeAttribute as String)
        let hasWritableTextSurface = names.contains(kAXValueAttribute as String) || names.contains(kAXSelectedTextAttribute as String)
        return hasSelectionRange && hasWritableTextSurface
    }

    private func readSelectedRange(from target: AXUIElement, into range: inout CFRange) -> Bool {
        var selectedRangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(target, kAXSelectedTextRangeAttribute as CFString, &selectedRangeRef) == .success,
              let selectedRangeRef,
              CFGetTypeID(selectedRangeRef) == AXValueGetTypeID()
        else {
            return false
        }

        let value = selectedRangeRef as! AXValue
        guard AXValueGetType(value) == .cfRange else { return false }
        return AXValueGetValue(value, .cfRange, &range)
    }

    private func insertUsingPasteboard(_ text: String, preferredProcessIdentifier: pid_t?) -> Bool {
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

        if let processIdentifier = preferredProcessIdentifier ?? NSWorkspace.shared.frontmostApplication?.processIdentifier {
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
