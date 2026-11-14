import Foundation
import ServiceManagement

enum LoginItemController {
    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    /// True only when macOS will actually launch Dimac at login.
    static var isEnabled: Bool {
        status == .enabled
    }

    /// Registered with macOS, including while the user still has to approve it in Login Items.
    static func isRegistered(_ status: SMAppService.Status) -> Bool {
        status == .enabled || status == .requiresApproval
    }

    static var statusDescription: String {
        statusDescription(for: status)
    }

    static func statusDescription(for status: SMAppService.Status) -> String {
        switch status {
        case .enabled:
            return "Enabled"
        case .notRegistered:
            return "Off"
        case .notFound:
            return "Unavailable"
        case .requiresApproval:
            return "Needs approval"
        @unknown default:
            return "Unknown"
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            // Already registered but awaiting approval: registering again does not help.
            if !isRegistered(SMAppService.mainApp.status) {
                try SMAppService.mainApp.register()
            }
        } else if isRegistered(SMAppService.mainApp.status) {
            try SMAppService.mainApp.unregister()
        }
    }

    /// Opens System Settings > General > Login Items so the user can approve Dimac.
    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
