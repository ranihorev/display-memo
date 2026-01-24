import Foundation
import ServiceManagement
import os.log

/// Manages the app's login item status using SMAppService (macOS 13+)
final class LoginItemManager {
    static let shared = LoginItemManager()

    private let logger = Logger(subsystem: "com.displaymemo.app", category: "LoginItem")
    private let service = SMAppService.mainApp

    private init() {}

    /// Whether the app is currently set to launch at login
    var isEnabled: Bool {
        service.status == .enabled
    }

    /// Enable or disable launch at login
    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try service.register()
                logger.info("Login item registered")
            } else {
                try service.unregister()
                logger.info("Login item unregistered")
            }
        } catch {
            logger.error("Failed to \(enabled ? "register" : "unregister") login item: \(error.localizedDescription)")
        }
    }

    /// Toggle the current state
    func toggle() {
        setEnabled(!isEnabled)
    }
}
