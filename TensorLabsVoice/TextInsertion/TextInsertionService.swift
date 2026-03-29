import AppKit
import ApplicationServices

final class TextInsertionService {
    enum InsertionResult {
        case accessibility
        case keyboard
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
            
            if transport == .keyboard {
                RuntimeTrace.mark("LiveTextSession.update keyboard skipping live update, only finalize")
                return true
            }
            
            RuntimeTrace.mark("LiveTextSession.update text='\(text.prefix(50))' lastRenderedText='\(lastRenderedText.prefix(30))'")
            
            if text == lastRenderedText {
                RuntimeTrace.mark("LiveTextSession.update skipping exact duplicate text")
                return true
            }
            
            if !lastKnownValue.isEmpty {
                let utf16Count = lastKnownValue.utf16.count
                let start = max(0, min(trackedRange.location, utf16Count))
                let end = max(start, min(trackedRange.location + trackedRange.length, utf16Count))
                if let stringRange = Range(NSRange(location: start, length: end - start), in: lastKnownValue) {
                    let existingAtRange = String(lastKnownValue[stringRange])
                    if existingAtRange == text {
                        RuntimeTrace.mark("LiveTextSession.update skipping duplicate text already at position")
                        lastRenderedText = text
                        return true
                    }
                }
            }
            
            return replaceTrackedRange(with: text)
        }

        func finalize(text: String) -> Bool {
            defer { isActive = false }
            RuntimeTrace.mark("LiveTextSession.finalize text='\(text.prefix(50))' lastRenderedText='\(lastRenderedText.prefix(30))'")
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
                let trackedTextStillPresent =
                    !lastRenderedText.isEmpty &&
                    Self.text(in: currentValue, for: trackedRange) == lastRenderedText

                RuntimeTrace.mark("LiveSessionStatus trackedTextStillPresent=\(trackedTextStillPresent) selectionCollapsedAtEnd=\(selectionCollapsedAtEnd) selectionMatchesTracked=\(selectionMatchesTracked) selectedRange=(\(selectedRange.location),\(selectedRange.length)) trackedRange=(\(trackedRange.location),\(trackedRange.length))")

                if trackedTextStillPresent && (selectionCollapsedAtEnd || selectionMatchesTracked) {
                    // Preserve the existing dictated span when the host collapses the caret
                    // immediately after our own replacement.
                } else if selectedRange.location != trackedRange.location || selectedRange.length != trackedRange.length {
                    trackedRange = selectedRange
                } else if !currentValue.isEmpty, currentValue != lastKnownValue, !trackedTextStillPresent {
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

            RuntimeTrace.mark("replaceTrackedRange text='\(text.prefix(50))' trackedRange=(\(trackedRange.location),\(trackedRange.length)) lastRenderedText='\(lastRenderedText.prefix(30))'")

            guard let currentValue = Self.readValue(from: target) ?? (!lastKnownValue.isEmpty ? lastKnownValue : nil),
                  let updatedValue = Self.replacing(range: trackedRange, in: currentValue, with: text),
                  AXUIElementSetAttributeValue(target, kAXValueAttribute as CFString, updatedValue as CFTypeRef) == .success
            else {
                if setSelectedRange(trackedRange),
                   AXUIElementSetAttributeValue(target, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success {
                    let length = (text as NSString).length
                    trackedRange = CFRange(location: trackedRange.location, length: length)
                    lastRenderedText = text
                    lastKnownValue = Self.readValue(from: target) ?? lastKnownValue
                    preservesOwnSelection = true
                    _ = setSelectedRange(trackedRange)
                    return true
                }
                return false
            }

            let insertedLength = (text as NSString).length
            trackedRange = CFRange(location: trackedRange.location, length: insertedLength)
            lastRenderedText = text
            lastKnownValue = updatedValue
            preservesOwnSelection = true
            _ = setSelectedRange(trackedRange)
            return true
        }

        private func replaceTypedText(with text: String) -> Bool {
            guard Self.canSendKeyboardEvents(to: targetProcessIdentifier) else { return false }
            
            if text == lastRenderedText {
                return true
            }
            
            let charactersToDelete = lastRenderedText.count

            if charactersToDelete > 0 {
                guard Self.sendBackspaces(charactersToDelete, to: targetProcessIdentifier) else { return false }
            }

            if !text.isEmpty {
                guard Self.sendUnicodeText(text, to: targetProcessIdentifier) else { return false }
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

        fileprivate static func text(in value: String, for range: CFRange) -> String? {
            let utf16Count = value.utf16.count
            let start = max(0, min(range.location, utf16Count))
            let end = max(start, min(range.location + range.length, utf16Count))
            guard let stringRange = Range(NSRange(location: start, length: end - start), in: value) else {
                return nil
            }

            return String(value[stringRange])
        }

        private static func sendBackspaces(_ count: Int, to processIdentifier: pid_t?) -> Bool {
            guard count > 0 else { return true }
            guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }

            for _ in 0..<count {
                guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true),
                      let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false)
                else {
                    return false
                }
                keyDown.flags = []
                keyUp.flags = []
                postKeyboardEvent(keyDown, to: processIdentifier)
                postKeyboardEvent(keyUp, to: processIdentifier)
            }

            return true
        }

        fileprivate static func sendUnicodeText(_ text: String, to processIdentifier: pid_t?) -> Bool {
            guard !text.isEmpty else { return true }
            for scalar in text.utf16 {
                guard sendUnicodeScalar(scalar, to: processIdentifier) else { return false }
            }
            return true
        }

        private static func sendUnicodeScalar(_ scalar: unichar, to processIdentifier: pid_t?) -> Bool {
            guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
            var payload = [scalar]
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else {
                return false
            }

            keyDown.flags = []
            keyUp.flags = []
            keyDown.keyboardSetUnicodeString(stringLength: payload.count, unicodeString: &payload)
            keyUp.keyboardSetUnicodeString(stringLength: payload.count, unicodeString: &payload)
            postKeyboardEvent(keyDown, to: processIdentifier)
            postKeyboardEvent(keyUp, to: processIdentifier)
            return true
        }

        private static func postKeyboardEvent(_ event: CGEvent, to processIdentifier: pid_t?) {
            event.post(tap: .cghidEventTap)
        }

        private static func canSendKeyboardEvents(to processIdentifier: pid_t?) -> Bool {
            guard let processIdentifier else { return true }
            return NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier
        }

        private func pasteText(_ text: String, to processIdentifier: pid_t?) -> Bool {
            guard Self.canSendKeyboardEvents(to: processIdentifier) else { return false }
            guard !text.isEmpty else { return true }

            let pasteboard = NSPasteboard.general
            let previousValue = pasteboard.string(forType: .string)

            pasteboard.clearContents()
            guard pasteboard.setString(text, forType: .string) else { return false }
            guard Self.sendPasteShortcut(to: processIdentifier) else {
                if let previousValue {
                    pasteboard.clearContents()
                    _ = pasteboard.setString(previousValue, forType: .string)
                }
                return false
            }

            lastRenderedText = text
            if let previousValue {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                    pasteboard.clearContents()
                    _ = pasteboard.setString(previousValue, forType: .string)
                }
            }
            return true
        }

        fileprivate static func sendPasteShortcut(to processIdentifier: pid_t?) -> Bool {
            guard let source = CGEventSource(stateID: .combinedSessionState),
                  let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
            else {
                return false
            }

            keyDown.flags = .maskCommand
            keyUp.flags = .maskCommand
            postKeyboardEvent(keyDown, to: processIdentifier)
            postKeyboardEvent(keyUp, to: processIdentifier)
            return true
        }
    }

    func insertText(_ text: String, mode: InsertionMode, preferredProcessIdentifier: pid_t? = nil) -> InsertionResult {
        guard !text.isEmpty else { return .pasteboard }
        let targetApplication = Self.runningApplication(for: preferredProcessIdentifier) ?? NSWorkspace.shared.frontmostApplication

        if Self.prefersKeyboardInjection(for: targetApplication) {
            return insertUsingKeyboard(text, preferredProcessIdentifier: preferredProcessIdentifier) ? .keyboard : .failed
        }

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

        if effectiveMode == .accessibilityFirst {
            if let target = focusedElement(),
               supportsLiveRangeReplacement(target) {
                var selectedRange = CFRange(location: 0, length: 0)
                if readSelectedRange(from: target, into: &selectedRange) {
                    let existingText = LiveTextSession.readValue(from: target) ?? ""
                    RuntimeTrace.mark("beginLiveTextSession accessibility selectedRange=(\(selectedRange.location),\(selectedRange.length)) existingText='\(existingText.prefix(30))'")
                    return LiveTextSession(target: target, trackedRange: selectedRange)
                }
            }
        }

        if let processIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            RuntimeTrace.mark("beginLiveTextSession keyboard pid=\(processIdentifier)")
            return LiveTextSession(processIdentifier: processIdentifier)
        }

        return nil
    }

    private func preferredMode(for configuredMode: InsertionMode) -> InsertionMode {
        guard configuredMode == .accessibilityFirst else { return configuredMode }
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        guard !Self.prefersKeyboardInjection(for: frontmostApplication) else {
            return .pasteboardFirst
        }

        guard let bundleIdentifier = frontmostApplication?.bundleIdentifier else {
            return configuredMode
        }

        if Self.terminalBundleIdentifiers.contains(bundleIdentifier) {
            return .pasteboardFirst
        }

        return configuredMode
    }

    static func prefersKeyboardInjection(bundleIdentifier: String?, localizedName: String?) -> Bool {
        if let bundleIdentifier, terminalBundleIdentifiers.contains(bundleIdentifier) {
            return true
        }

        let normalizedBundleIdentifier = bundleIdentifier?.lowercased() ?? ""
        let normalizedName = localizedName?.lowercased() ?? ""
        return editorLikeAccessibilityBlacklist.contains(where: {
            normalizedBundleIdentifier.contains($0) || normalizedName.contains($0)
        })
    }

    private static func prefersKeyboardInjection(for application: NSRunningApplication?) -> Bool {
        prefersKeyboardInjection(
            bundleIdentifier: application?.bundleIdentifier,
            localizedName: application?.localizedName
        )
    }

    private static func runningApplication(for processIdentifier: pid_t?) -> NSRunningApplication? {
        guard let processIdentifier else { return nil }
        return NSRunningApplication(processIdentifier: processIdentifier)
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
        guard preferredProcessIdentifier == nil || preferredProcessIdentifier == NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return false
        }

        let pasteboard = NSPasteboard.general
        let previousValue = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return false }

        guard LiveTextSession.sendPasteShortcut(to: preferredProcessIdentifier) else { return false }

        // Give the focused app a moment to consume Cmd+V before restoring clipboard.
        if let previousValue {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                pasteboard.clearContents()
                _ = pasteboard.setString(previousValue, forType: .string)
            }
        }

        return true
    }

    private func insertUsingKeyboard(_ text: String, preferredProcessIdentifier: pid_t?) -> Bool {
        guard preferredProcessIdentifier == nil || preferredProcessIdentifier == NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return false
        }

        return LiveTextSession.sendUnicodeText(text, to: preferredProcessIdentifier)
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

    private static let editorLikeAccessibilityBlacklist: Set<String> = [
        "codex",
        "opencode",
    ]
}
