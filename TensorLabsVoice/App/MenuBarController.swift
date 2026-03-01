import AppKit
import SwiftUI

@MainActor
final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let dictationController: DictationController
    private let settingsStore: SettingsStore
    private var settingsWindow: NSWindow?

    private lazy var toggleItem = NSMenuItem(title: "Enable Dictation", action: #selector(toggleDictation), keyEquivalent: "")

    init(dictationController: DictationController, settingsStore: SettingsStore) {
        self.dictationController = dictationController
        self.settingsStore = settingsStore
        super.init()
        configureStatusItem()
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.title = "Voice"
        }

        let menu = NSMenu()
        toggleItem.target = self
        menu.addItem(toggleItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        refreshMenuState()
    }

    private func refreshMenuState() {
        let enabled = dictationController.isEnabled
        toggleItem.title = enabled ? "Disable Dictation" : "Enable Dictation"
        toggleItem.state = enabled ? .on : .off
    }

    @objc private func toggleDictation() {
        toggleItem.isEnabled = false
        let target = !dictationController.isEnabled

        Task { @MainActor in
            await dictationController.setEnabled(target)
            refreshMenuState()
            toggleItem.isEnabled = true
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(settings: settingsStore)
                .frame(minWidth: 420, minHeight: 280)
            let hostingController = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hostingController)
            window.title = "TensorLabs Voice Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 460, height: 320))
            window.level = .floating
            window.collectionBehavior = [.moveToActiveSpace]
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }

        settingsWindow?.orderFrontRegardless()
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.makeMain()
        NSApp.activate(ignoringOtherApps: true)
    }

    func enableDictationOnLaunch() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !dictationController.isEnabled else { return }
            NSApp.activate(ignoringOtherApps: true)
            toggleItem.isEnabled = false
            await dictationController.setEnabled(true)
            refreshMenuState()
            toggleItem.isEnabled = true
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
