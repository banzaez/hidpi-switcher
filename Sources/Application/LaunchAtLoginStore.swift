import Foundation
import Observation
import ServiceManagement
import os

private let log = Logger(subsystem: "com.local.HiDpiSwitcher", category: "LaunchAtLoginStore")

/// Сервис управления автозапуском при входе в систему (`SMAppService`) на базе `@Observable`.
@Observable
@MainActor
public final class LaunchAtLoginStore {
    public private(set) var isEnabled: Bool = false
    public private(set) var requiresApproval: Bool = false
    public var lastError: String?

    public init() {
        refresh()
    }

    public func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = (status == .enabled)
        requiresApproval = (status == .requiresApproval)
    }

    public func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            log.error("Ошибка управления автозапуском: \(error.localizedDescription)")
            lastError = "Автозапуск: \(error.localizedDescription)"
        }
        refresh()
        if enabled && requiresApproval {
            lastError = "Разрешите автозапуск в Системных настройках → Объекты входа"
        }
    }

    public func openSystemSettingsLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
