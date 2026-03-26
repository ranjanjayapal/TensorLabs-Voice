import XCTest
@testable import TensorLabsVoice

@MainActor
final class TextInsertionTests: XCTestCase {
    func testSettingsStoreDefaults() {
        let suiteName = "TensorLabsVoiceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(store.dictationMode, .balanced)
        XCTAssertEqual(store.insertionMode, .accessibilityFirst)
        XCTAssertEqual(store.dictationSessionMode, .pushToTalk)
        XCTAssertTrue(store.enableDiagnostics)
        XCTAssertTrue(store.enableLiveTextUpdates)
        XCTAssertFalse(store.launchAtLogin)
    }

    func testPrefersKeyboardInjectionForCodexStyleEditors() {
        XCTAssertTrue(
            TextInsertionService.prefersKeyboardInjection(
                bundleIdentifier: "com.openai.codex",
                localizedName: "Codex"
            )
        )
        XCTAssertTrue(
            TextInsertionService.prefersKeyboardInjection(
                bundleIdentifier: "dev.opencode.desktop",
                localizedName: "OpenCode"
            )
        )
    }

    func testPrefersKeyboardInjectionForKnownTerminalBundles() {
        XCTAssertTrue(
            TextInsertionService.prefersKeyboardInjection(
                bundleIdentifier: "com.apple.Terminal",
                localizedName: "Terminal"
            )
        )
    }

    func testDoesNotForceKeyboardInjectionForStandardTextEditors() {
        XCTAssertFalse(
            TextInsertionService.prefersKeyboardInjection(
                bundleIdentifier: "com.apple.TextEdit",
                localizedName: "TextEdit"
            )
        )
    }
}
