import Foundation
import ServiceManagement
import os

private let log = Logger(subsystem: "com.local.HiDpiSwitcher", category: "LaunchAtLogin")

@MainActor
final class LaunchAtLoginManager: ObservableObject {
    @Published private(set) var isEnabled: Bool = false
    @Published var lastError: String?

    init() {
        refresh()
    }

    func refresh() {
        isEnabled = (SMAppService.mainApp.status == .enabled)
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            log.error("Ошибка автозапуска: \(error.localizedDescription)")
            lastError = "Автозапуск: \(error.localizedDescription)"
        }
        refresh()
    }
}
