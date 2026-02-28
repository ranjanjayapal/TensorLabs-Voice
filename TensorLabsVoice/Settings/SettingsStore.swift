import Foundation

enum InsertionMode: String, Codable {
    case accessibilityFirst
    case pasteboardFirst
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published var modelProfile: ModelProfile {
        didSet { defaults.set(modelProfile.rawValue, forKey: Keys.modelProfile) }
    }

    @Published var insertionMode: InsertionMode {
        didSet { defaults.set(insertionMode.rawValue, forKey: Keys.insertionMode) }
    }

    @Published var enableDiagnostics: Bool {
        didSet { defaults.set(enableDiagnostics, forKey: Keys.enableDiagnostics) }
    }

    @Published var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Keys.launchAtLogin) }
    }

    @Published var hotkeyKey: HotkeyKey {
        didSet { defaults.set(hotkeyKey.rawValue, forKey: Keys.hotkeyKey) }
    }

    @Published var hotkeyCommand: Bool {
        didSet { defaults.set(hotkeyCommand, forKey: Keys.hotkeyCommand) }
    }

    @Published var hotkeyShift: Bool {
        didSet { defaults.set(hotkeyShift, forKey: Keys.hotkeyShift) }
    }

    @Published var hotkeyOption: Bool {
        didSet { defaults.set(hotkeyOption, forKey: Keys.hotkeyOption) }
    }

    @Published var hotkeyControl: Bool {
        didSet { defaults.set(hotkeyControl, forKey: Keys.hotkeyControl) }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let modelProfile = "settings.modelProfile"
        static let insertionMode = "settings.insertionMode"
        static let enableDiagnostics = "settings.enableDiagnostics"
        static let launchAtLogin = "settings.launchAtLogin"
        static let hotkeyKey = "settings.hotkey.key"
        static let hotkeyCommand = "settings.hotkey.command"
        static let hotkeyShift = "settings.hotkey.shift"
        static let hotkeyOption = "settings.hotkey.option"
        static let hotkeyControl = "settings.hotkey.control"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let profileValue = defaults.string(forKey: Keys.modelProfile)
        modelProfile = ModelProfile(rawValue: profileValue ?? "") ?? .balanced

        let insertionValue = defaults.string(forKey: Keys.insertionMode)
        insertionMode = InsertionMode(rawValue: insertionValue ?? "") ?? .accessibilityFirst

        enableDiagnostics = defaults.object(forKey: Keys.enableDiagnostics) as? Bool ?? true
        launchAtLogin = defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false

        let keyValue = defaults.string(forKey: Keys.hotkeyKey)
        hotkeyKey = HotkeyKey(rawValue: keyValue ?? "") ?? HotkeyShortcut.default.key
        hotkeyCommand = defaults.object(forKey: Keys.hotkeyCommand) as? Bool ?? HotkeyShortcut.default.command
        hotkeyShift = defaults.object(forKey: Keys.hotkeyShift) as? Bool ?? HotkeyShortcut.default.shift
        hotkeyOption = defaults.object(forKey: Keys.hotkeyOption) as? Bool ?? HotkeyShortcut.default.option
        hotkeyControl = defaults.object(forKey: Keys.hotkeyControl) as? Bool ?? HotkeyShortcut.default.control
    }

    var hotkeyShortcut: HotkeyShortcut {
        HotkeyShortcut(
            key: hotkeyKey,
            command: hotkeyCommand,
            shift: hotkeyShift,
            option: hotkeyOption,
            control: hotkeyControl
        )
    }
}
