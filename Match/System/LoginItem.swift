import Foundation
import ServiceManagement

/// Starts Match when the user logs in to the Mac.
@MainActor
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Launch at login registers the copy of the app that is running, so it is only
    /// offered for a copy in an Applications folder, which will still be there later.
    static var isAvailable: Bool {
        isInstalled(at: Bundle.main.bundlePath)
    }

    static func isInstalled(at path: String, home: String = NSHomeDirectory()) -> Bool {
        path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/")
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
