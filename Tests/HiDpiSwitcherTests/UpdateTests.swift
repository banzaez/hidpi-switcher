import Foundation
import Testing
@testable import HiDpiSwitcher

// MARK: - Mocks

@MainActor
private final class MockAppUpdateService: AppUpdateManaging {
    var status: UpdateCheckResult = .idle
    var isChecking: Bool = false
    var currentVersion: String = "2.5.1"
    var automaticallyCheckForUpdates: Bool = true
    var recordedAutoCheckValues: [Bool] = []
    var recordedCheckCalls: [Bool] = []
    var nextResult: UpdateCheckResult = .upToDate(version: "2.5.1")

    func setAutoCheckEnabled(_ enabled: Bool) {
        automaticallyCheckForUpdates = enabled
        recordedAutoCheckValues.append(enabled)
    }

    @discardableResult
    func checkForUpdates(isUserInitiated: Bool) async -> UpdateCheckResult {
        recordedCheckCalls.append(isUserInitiated)
        status = nextResult
        return nextResult
    }
}

private final class MockUpdatePreferencesStore: UpdatePreferencesStore, @unchecked Sendable {
    var automaticallyCheckForUpdates: Bool = true
    var lastCheckDate: Date? = nil
    var skippedVersion: String? = nil

    func setAutomaticallyCheckForUpdates(_ enabled: Bool) {
        automaticallyCheckForUpdates = enabled
    }

    func setLastCheckDate(_ date: Date?) {
        lastCheckDate = date
    }

    func setSkippedVersion(_ version: String?) {
        skippedVersion = version
    }
}

// MARK: - Test Suite

@Suite("HiDpiSwitcher Sparkle Update Service & Store Tests")
struct UpdateTests {

    @Test("AppUpdateService безопасно инициализируется вне .app бандла и сравнивает SemVer")
    @MainActor
    func appUpdateServiceSafeInitAndSemVer() async {
        let service = AppUpdateService()
        #expect(service.isChecking == false)
        #expect(service.status == .idle)

        let result = await service.checkForUpdates(isUserInitiated: false)
        #expect(result == .idle)

        #expect(service.isVersion("2.5.2", greaterThan: "2.5.1") == true)
        #expect(service.isVersion("2.6.0", greaterThan: "2.5.9") == true)
        #expect(service.isVersion("3.0.0", greaterThan: "2.9.9") == true)
        #expect(service.isVersion("2.5.1", greaterThan: "2.5.1") == false)
        #expect(service.isVersion("2.5.0", greaterThan: "2.5.1") == false)
    }

    @Test("UpdateStore синхронизирует настройку автопроверки со Sparkle-сервисом")
    @MainActor
    func updateStoreSyncsAutoCheck() {
        let mockService = MockAppUpdateService()
        let mockPrefs = MockUpdatePreferencesStore()
        mockPrefs.automaticallyCheckForUpdates = false

        let store = UpdateStore(updateService: mockService, preferencesStore: mockPrefs)
        #expect(mockService.recordedAutoCheckValues == [false])
        #expect(store.automaticallyCheckForUpdates == false)

        store.automaticallyCheckForUpdates = true
        #expect(mockPrefs.automaticallyCheckForUpdates == true)
        #expect(mockService.recordedAutoCheckValues == [false, true])
    }

    @Test("UpdateStore проксирует проверку обновлений и отображает доступную версию")
    @MainActor
    func updateStoreCheckAndAvailableVersion() async {
        let mockService = MockAppUpdateService()
        let releaseURL = URL(string: "https://github.com/banzaez/hidpi-switcher/releases/tag/v2.6.0")!
        let downloadURL = URL(string: "https://github.com/banzaez/hidpi-switcher/releases/download/v2.6.0/HiDpiSwitcher-v2.6.0-macOS.zip")!
        mockService.nextResult = .updateAvailable(
            version: "2.6.0",
            releaseNotes: "Поддержка Sparkle",
            releaseURL: releaseURL,
            downloadURL: downloadURL
        )

        let store = UpdateStore(updateService: mockService, preferencesStore: MockUpdatePreferencesStore())
        #expect(store.availableUpdateVersion == nil)

        await store.checkForUpdates(manual: true)
        #expect(mockService.recordedCheckCalls == [true])
        #expect(store.availableUpdateVersion == "2.6.0")
    }
}
