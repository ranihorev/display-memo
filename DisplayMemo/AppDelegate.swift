import Cocoa
import os.log

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

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
        logger.info("DisplayMemo launching")

        // Ensure the app is properly activated (needed without a main nib)
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
        logger.info("DisplayMemo terminating")
    }

    // MARK: - Status Item Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "DisplayMemo") {
                button.image = image
                logger.info("Status item created with SF Symbol")
            } else {
                // Fallback to text if SF Symbol not available
                button.title = "DM"
                logger.warning("SF Symbol not available, using text fallback")
            }
        } else {
            logger.error("Failed to get status item button")
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
        logger.info("Save default action triggered")

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
        logger.info("Apply default action triggered")

        let signature = DisplayManager.shared.currentSignature

        // Clear custom override first so restore will work
        ProfileStore.shared.clearCustomOverride(for: signature)

        let result = DisplayManager.shared.restoreDefault()

        if result.isSuccess {
            updateMenuState()
        } else {
            showAlert(title: "Apply Failed", message: result.message)
            updateMenuState()
        }
    }

    @objc private func clearCustomAction() {
        logger.info("Clear custom action triggered")

        let signature = DisplayManager.shared.currentSignature
        ProfileStore.shared.clearCustomOverride(for: signature)
        DisplayManager.shared.clearTrackedPositions()
        updateMenuState()

        // Optionally auto-apply default after clearing custom
        DisplayManager.shared.attemptAutoRestore()
    }

    @objc private func clearDefaultAction() {
        logger.info("Clear default action triggered")

        guard let defaultArrangement = ProfileStore.shared.defaultArrangement else {
            return
        }

        let alert = NSAlert()
        alert.messageText = "Clear Default Arrangement?"
        alert.informativeText = "Are you sure you want to clear the default arrangement for \"\(defaultArrangement.displayName)\"?"
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        if alert.runModal() == .alertFirstButtonReturn {
            ProfileStore.shared.clearDefaultArrangement()
            DisplayManager.shared.clearTrackedPositions()
            updateMenuState()
            logger.info("Default arrangement cleared")
        }
    }

    @objc private func toggleLaunchAtLogin() {
        LoginItemManager.shared.toggle()
        launchAtLoginMenuItem.state = LoginItemManager.shared.isEnabled ? .on : .off
    }

    @objc private func quitAction() {
        logger.info("Quit action triggered")
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Menu Validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let hasDefault = ProfileStore.shared.hasDefaultArrangement

        if menuItem == applyDefaultMenuItem {
            return hasDefault
        }
        if menuItem == clearDefaultMenuItem {
            return hasDefault
        }
        if menuItem == clearCustomMenuItem {
            let signature = DisplayManager.shared.currentSignature
            return ProfileStore.shared.hasCustomOverride(for: signature)
        }
        return true
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
        logger.info("Configuration change detected")
        updateMenuState()

        // Attempt auto-restore
        manager.attemptAutoRestore()
    }

    func displayManager(_ manager: DisplayManager, didAutoRestore result: RestoreResult) {
        logger.info("Auto-restore result: \(result.message)")
        updateMenuState()
    }

    func displayManagerDidDetectManualChange(_ manager: DisplayManager) {
        logger.info("Manual change detected, custom override now active")
        updateMenuState()
    }
}
