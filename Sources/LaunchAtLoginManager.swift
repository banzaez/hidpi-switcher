import Foundation
import ServiceManagement

final class LaunchAtLoginManager: ObservableObject {
    @Published var isEnabled: Bool = false

    init() {
        self.isEnabled = (SMAppService.mainApp.status == .enabled)
    }

    func toggle() {
        do {
            if isEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            isEnabled = (SMAppService.mainApp.status == .enabled)
        } catch {
            print("Ошибка при изменении статуса автозапуска: \(error.localizedDescription)")
            isEnabled = (SMAppService.mainApp.status == .enabled)
        }
    }
}
