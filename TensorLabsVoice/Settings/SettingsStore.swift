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

    @Published var enableSmartListFormatting: Bool {
        didSet { defaults.set(enableSmartListFormatting, forKey: Keys.enableSmartListFormatting) }
    }

    @Published var customWordReplacementsRaw: String {
        didSet { defaults.set(customWordReplacementsRaw, forKey: Keys.customWordReplacementsRaw) }
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
        static let enableSmartListFormatting = "settings.text.enableSmartListFormatting"
        static let customWordReplacementsRaw = "settings.text.customWordReplacementsRaw"
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
        enableSmartListFormatting = defaults.object(forKey: Keys.enableSmartListFormatting) as? Bool ?? true
        customWordReplacementsRaw = defaults.string(forKey: Keys.customWordReplacementsRaw) ?? ""
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

    var customWordReplacements: [String: String] {
        let lines = customWordReplacementsRaw.components(separatedBy: .newlines)
        var dictionary: [String: String] = [:]

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            // Alias format:
            // Amma: one more, im not, ma
            // maps all aliases (and Amma itself) -> Amma
            let aliasParts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            if aliasParts.count == 2 {
                let canonical = String(aliasParts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
                let aliasesRaw = String(aliasParts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !canonical.isEmpty else { continue }

                dictionary[canonical.lowercased()] = canonical
                let aliases = aliasesRaw
                    .split(separator: ",")
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                    .filter { !$0.isEmpty }
                for alias in aliases {
                    dictionary[alias] = canonical
                }
                continue
            }

            // Direct replacement format:
            // spoken=Written
            let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }

            let spoken = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let written = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !spoken.isEmpty, !written.isEmpty else { continue }
            dictionary[spoken] = written
        }

        return dictionary
    }
}
