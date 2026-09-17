import Foundation
import ServiceManagement

/// Login-item registration through `SMAppService`, which needs no helper bundle
/// and no privileged install step.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// `false` when running outside an app bundle (for example `swift run`).
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    static func set(_ enabled: Bool) {
        guard isAvailable else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.app.error("Login item change failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
