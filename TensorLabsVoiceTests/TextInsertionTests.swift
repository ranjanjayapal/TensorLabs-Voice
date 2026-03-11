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
        XCTAssertTrue(store.enableDiagnostics)
        XCTAssertFalse(store.launchAtLogin)
    }
}
