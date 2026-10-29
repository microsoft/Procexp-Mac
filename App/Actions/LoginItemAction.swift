import ServiceManagement

enum LoginItemStatus {
    case disabled
    case enabled
    case requiresApproval
    case unavailable
}

@MainActor
struct LoginItemConnection {
    var status: () -> LoginItemStatus
    var register: () async throws -> Void
    var unregister: () async throws -> Void
    var openSettings: () -> Void

    static var live: Self {
        Self(status: {
            switch SMAppService.mainApp.status {
            case .enabled: return .enabled
            case .requiresApproval: return .requiresApproval
            case .notRegistered: return .disabled
            case .notFound: return .unavailable
            @unknown default: return .unavailable
            }
        }, register: {
            try SMAppService.mainApp.register()
        }, unregister: {
            try await SMAppService.mainApp.unregister()
        }, openSettings: {
            SMAppService.openSystemSettingsLoginItems()
        })
    }
}

extension AppModel {
    func refreshLoginItemStatus() {
        loginItemStatus = dependencies.loginItem.status()
    }

    func setLaunchAtLogin(_ enabled: Bool) async {
        guard !loginItemUpdating else { return }
        loginItemUpdating = true
        defer {
            refreshLoginItemStatus()
            loginItemUpdating = false
        }
        do {
            if enabled {
                try await dependencies.loginItem.register()
            } else {
                try await dependencies.loginItem.unregister()
            }
            if enabled, dependencies.loginItem.status() != .enabled {
                processActionAlert = ProcessActionAlert(
                    title: "Launch at Login Not Enabled",
                    message: "Approve Sysinternals Process Explorer in System Settings > General > Login Items & Extensions. If it is not listed, install a signed copy of the app in Applications and try again."
                )
            }
        } catch {
            processActionAlert = ProcessActionAlert(
                title: "Could Not Change Launch at Login",
                message: error.localizedDescription
            )
        }
    }
}
