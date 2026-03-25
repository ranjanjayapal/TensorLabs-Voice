import AppKit
import SwiftUI

@MainActor
final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let dictationController: DictationController
    private let assistantController: AssistantController
    private let settingsStore: SettingsStore
    private var settingsWindow: NSWindow?

    private lazy var toggleItem = NSMenuItem(title: "Enable Dictation", action: #selector(toggleMode), keyEquivalent: "")

    init(dictationController: DictationController, assistantController: AssistantController, settingsStore: SettingsStore) {
        self.dictationController = dictationController
        self.assistantController = assistantController
        self.settingsStore = settingsStore
        super.init()
        configureStatusItem()
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            let statusIcon = NSImage(named: "StatusBarIcon")
                ?? NSImage(named: "menuBarIcon")
                ?? NSImage(named: "MenuBarIcon")

            if let statusIcon {
                statusIcon.size = NSSize(width: 18, height: 18)
                statusIcon.isTemplate = false
                button.image = statusIcon
                button.imageScaling = .scaleProportionallyUpOrDown
                button.imagePosition = .imageOnly
                button.title = ""
            } else {
                button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "TensorLabs Voice")
                button.imagePosition = .imageOnly
                button.title = ""
            }
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

    func refreshMenuState() {
        let enabled = currentModeEnabled
        let title = settingsStore.appMode == .assistant ? "Assistant" : "Dictation"
        toggleItem.title = enabled ? "Disable \(title)" : "Enable \(title)"
        toggleItem.state = enabled ? .on : .off
    }

    @objc private func toggleMode() {
        RuntimeTrace.mark("MenuBarController.toggleMode begin currentEnabled=\(currentModeEnabled) appMode=\(settingsStore.appMode.rawValue)")
        toggleItem.isEnabled = false
        let target = !currentModeEnabled

        Task { @MainActor in
            RuntimeTrace.mark("MenuBarController.toggleMode task start target=\(target)")
            if settingsStore.appMode == .assistant {
                await assistantController.setEnabled(target)
            } else {
                await dictationController.setEnabled(target)
            }
            RuntimeTrace.mark("MenuBarController.toggleMode task finished target=\(target)")
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
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 460, height: 320))
            window.minSize = NSSize(width: 420, height: 280)
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

    func enableSelectedModeOnLaunch() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !currentModeEnabled else { return }
            toggleItem.isEnabled = false
            if settingsStore.appMode == .assistant {
                await assistantController.setEnabled(true)
            } else {
                await dictationController.setEnabled(true)
            }
            refreshMenuState()
            toggleItem.isEnabled = true
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private var currentModeEnabled: Bool {
        settingsStore.appMode == .assistant ? assistantController.isEnabled : dictationController.isEnabled
    }
}
