import ServiceManagement

/// Thin wrapper over SMAppService.mainApp. Needs a real .app bundle to do
/// anything useful; under `swift run` reads report disabled and writes throw.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
