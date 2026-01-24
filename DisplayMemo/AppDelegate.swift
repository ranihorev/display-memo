import Cocoa
import os.log

class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private let logger = Logger(subsystem: "com.displaymemo.app", category: "App")

    // Menu items that need dynamic updates
    private var statusMenuItem: NSMenuItem!
    private var saveDefaultMenuItem: NSMenuItem!
    private var applyDefaultMenuItem: NSMenuItem!
    private var clearCustomMenuItem: NSMenuItem!
    private var clearDefaultMenuItem: NSMenuItem!
    private var launchAtLoginMenuItem: NSMenuItem!

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupMenu()
        DisplayManager.shared.delegate = self
        DisplayManager.shared.startObserving()
        updateMenuState()
        logger.info("DisplayMemo ready")
    }

    func applicationWillTerminate(_ notification: Notification) {
        DisplayManager.shared.stopObserving()
    }

    // MARK: - Status Item Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "DisplayMemo") {
                button.image = image
            } else {
                button.title = "DM"
            }
        }
    }

    private func setupMenu() {
        let menu = NSMenu()

        // Status row (disabled)
        statusMenuItem = NSMenuItem(title: "No Default Arrangement", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Save as Default
        saveDefaultMenuItem = NSMenuItem(
            title: "Save as Default Arrangement",
            action: #selector(saveDefaultAction),
            keyEquivalent: "s"
        )
        saveDefaultMenuItem.target = self
        menu.addItem(saveDefaultMenuItem)

        // Apply Default
        applyDefaultMenuItem = NSMenuItem(
            title: "Apply Default Arrangement",
            action: #selector(applyDefaultAction),
            keyEquivalent: "r"
        )
        applyDefaultMenuItem.target = self
        menu.addItem(applyDefaultMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Clear Custom (only visible when custom override is active)
        clearCustomMenuItem = NSMenuItem(
            title: "Clear Custom Arrangement",
            action: #selector(clearCustomAction),
            keyEquivalent: ""
        )
        clearCustomMenuItem.target = self
        menu.addItem(clearCustomMenuItem)

        // Clear Default
        clearDefaultMenuItem = NSMenuItem(
            title: "Clear Default Arrangement",
            action: #selector(clearDefaultAction),
            keyEquivalent: ""
        )
        clearDefaultMenuItem.target = self
        menu.addItem(clearDefaultMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Launch at Login toggle
        launchAtLoginMenuItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchAtLoginMenuItem.target = self
        launchAtLoginMenuItem.state = LoginItemManager.shared.isEnabled ? .on : .off
        menu.addItem(launchAtLoginMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(
            title: "Quit DisplayMemo",
            action: #selector(quitAction),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Menu State

    private func updateMenuState() {
        let signature = DisplayManager.shared.currentSignature
        let hasDefault = ProfileStore.shared.hasDefaultArrangement
        let defaultArrangement = ProfileStore.shared.defaultArrangement
        let hasCustomOverride = ProfileStore.shared.hasCustomOverride(for: signature)

        // Update status text
        if hasDefault {
            if hasCustomOverride {
                statusMenuItem.title = "Custom Arrangement Active"
            } else {
                statusMenuItem.title = "Default: \(defaultArrangement!.displayName)"
            }
        } else {
            statusMenuItem.title = "No Default Arrangement"
        }

        // Apply Default: enabled if default exists
        applyDefaultMenuItem.isEnabled = hasDefault

        // Clear Custom: only visible/enabled if custom override is active
        clearCustomMenuItem.isHidden = !hasCustomOverride
        clearCustomMenuItem.isEnabled = hasCustomOverride

        // Clear Default: enabled if default exists
        clearDefaultMenuItem.isEnabled = hasDefault

        // Launch at Login state
        launchAtLoginMenuItem.state = LoginItemManager.shared.isEnabled ? .on : .off
    }

    // MARK: - Actions

    @objc private func saveDefaultAction() {
        let result = DisplayManager.shared.snapshot()
        switch result {
        case .success(let profile):
            ProfileStore.shared.saveDefaultArrangement(profile)
            DisplayManager.shared.clearTrackedPositions()
            updateMenuState()
            showAlert(title: "DisplayMemo", message: "Default arrangement saved for \(profile.displayName)")
        case .noDisplays, .noMainDisplay, .multipleMainDisplays:
            showAlert(title: "Save Failed", message: result.message)
        }
    }

    @objc private func applyDefaultAction() {
        ProfileStore.shared.clearCustomOverride(for: DisplayManager.shared.currentSignature)
        let result = DisplayManager.shared.restoreDefault()
        updateMenuState()
        if !result.isSuccess {
            showAlert(title: "Apply Failed", message: result.message)
        }
    }

    @objc private func clearCustomAction() {
        ProfileStore.shared.clearCustomOverride(for: DisplayManager.shared.currentSignature)
        DisplayManager.shared.clearTrackedPositions()
        updateMenuState()
        DisplayManager.shared.attemptAutoRestore()
    }

    @objc private func clearDefaultAction() {
        guard let defaultArrangement = ProfileStore.shared.defaultArrangement else { return }

        let alert = NSAlert()
        alert.messageText = "Clear Default Arrangement?"
        alert.informativeText = "Clear the default arrangement for \"\(defaultArrangement.displayName)\"?"
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        if alert.runModal() == .alertFirstButtonReturn {
            ProfileStore.shared.clearDefaultArrangement()
            DisplayManager.shared.clearTrackedPositions()
            updateMenuState()
        }
    }

    @objc private func toggleLaunchAtLogin() {
        LoginItemManager.shared.toggle()
        launchAtLoginMenuItem.state = LoginItemManager.shared.isEnabled ? .on : .off
    }

    @objc private func quitAction() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Helpers

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - DisplayManagerDelegate

extension AppDelegate: DisplayManagerDelegate {
    func displayManagerDidDetectConfigurationChange(_ manager: DisplayManager) {
        updateMenuState()
        manager.attemptAutoRestore()
    }

    func displayManager(_ manager: DisplayManager, didAutoRestore result: RestoreResult) {
        updateMenuState()
    }

    func displayManagerDidDetectManualChange(_ manager: DisplayManager) {
        updateMenuState()
    }
}
