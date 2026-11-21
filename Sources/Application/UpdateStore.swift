import Foundation
import Observation

/// Управляющий стор проверки и установки обновлений приложения на базе Sparkle.
@Observable
@MainActor
public final class UpdateStore {
    @ObservationIgnored
    private let updateService: any AppUpdateManaging
    @ObservationIgnored
    private let preferencesStore: any UpdatePreferencesStore

    public init(
        updateService: (any AppUpdateManaging)? = nil,
        preferencesStore: any UpdatePreferencesStore = UserDefaultsUpdatePreferencesStore()
    ) {
        let resolvedService = updateService ?? AppUpdateService.shared
        self.updateService = resolvedService
        self.preferencesStore = preferencesStore
        resolvedService.setAutoCheckEnabled(preferencesStore.automaticallyCheckForUpdates)
    }

    public var status: UpdateCheckResult {
        updateService.status
    }

    public var isChecking: Bool {
        updateService.isChecking
    }

    public var currentVersion: String {
        updateService.currentVersion
    }

    public var availableUpdateVersion: String? {
        if case let .updateAvailable(version, _, _, _) = updateService.status {
            return version
        }
        return nil
    }

    public var automaticallyCheckForUpdates: Bool {
        get { preferencesStore.automaticallyCheckForUpdates }
        set {
            preferencesStore.setAutomaticallyCheckForUpdates(newValue)
            updateService.setAutoCheckEnabled(newValue)
        }
    }

    /// Проверяет наличие обновлений через Sparkle.
    public func checkForUpdates(manual: Bool = true) async {
        await updateService.checkForUpdates(isUserInitiated: manual)
    }
}
