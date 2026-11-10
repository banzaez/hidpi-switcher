import Foundation
import Testing
@testable import HiDpiSwitcher

// MARK: - Mocks

private final class MockUpdateChecker: UpdateCheckingService, @unchecked Sendable {
    var resultToReturn: Result<UpdateCheckResult, Error>

    init(resultToReturn: Result<UpdateCheckResult, Error>) {
        self.resultToReturn = resultToReturn
    }

    func checkForUpdates(currentVersion: SemanticVersion) async throws -> UpdateCheckResult {
        try resultToReturn.get()
    }
}

private final class MockUpdateDownloader: UpdateDownloadingService, @unchecked Sendable {
    var downloadedURLToReturn: URL = URL(fileURLWithPath: "/tmp/mock-update.zip")
    var shouldFail: Bool = false

    func downloadUpdate(
        from url: URL,
        progressHandler: @Sendable @escaping (Double) -> Void
    ) async throws -> URL {
        if shouldFail {
            throw UpdateServiceError.downloadFailed("Mock network failure")
        }
        progressHandler(0.5)
        progressHandler(1.0)
        return downloadedURLToReturn
    }
}

private final class MockUpdateInstaller: UpdateInstallingService, @unchecked Sendable {
    var didCallInstall: Bool = false
    var shouldFail: Bool = false

    func installAndRelaunch(from archiveURL: URL, currentAppURL: URL) throws {
        if shouldFail {
            throw UpdateServiceError.extractionFailed("Mock extraction error")
        }
        didCallInstall = true
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

@MainActor
private final class MockUpdatePresenter: UpdateDialogPresenter {
    var didShowUpdateDialog: Bool = false
    var didDismissUpdateDialog: Bool = false
    var upToDateAlertVersion: SemanticVersion? = nil
    var errorMessage: String? = nil

    func showUpdateDialog(store: UpdateStore) {
        didShowUpdateDialog = true
    }

    func dismissUpdateDialog() {
        didDismissUpdateDialog = true
    }

    func showUpToDateAlert(version: SemanticVersion) {
        upToDateAlertVersion = version
    }

    func showErrorAlert(message: String, releaseURL: URL?) {
        errorMessage = message
    }
}

// MARK: - Test Suite

@Suite("HiDpiSwitcher Professional Update Checker & Updater Tests")
struct UpdateTests {

    @Test("Семантическое версионирование: корректное сравнение версий и префиксов")
    func semanticVersionComparison() {
        let v210 = SemanticVersion(fromString: "2.1.0")
        let v210WithPrefix = SemanticVersion(fromString: "v2.1.0")
        let v220 = SemanticVersion(fromString: "2.2.0")
        let v221 = SemanticVersion(fromString: "v2.2.1")
        let v230 = SemanticVersion(fromString: "2.3.0")
        let v300 = SemanticVersion(fromString: "3.0.0")
        let v230Beta = SemanticVersion(fromString: "v2.3.0-beta.1")

        #expect(v210 != nil)
        #expect(v210 == v210WithPrefix)
        #expect(v210! < v220!)
        #expect(v220! < v221!)
        #expect(v221! < v230!)
        #expect(v230! < v300!)

        // Pre-release версия должна быть меньше релизной версии с тем же номером
        #expect(v230Beta! < v230!)
        #expect(v221! < v230Beta!)

        // Описание версий
        #expect(v220!.description == "2.2.0")
        #expect(v230Beta!.description == "2.3.0-beta.1")

        // Обработка некорректных строк
        #expect(SemanticVersion(fromString: "") == nil)
        #expect(SemanticVersion(fromString: "invalid") == nil)
    }

    @Test("Парсинг JSON ответа GitHub Releases API с выделением .zip архива")
    func gitHubReleaseJsonParsing() throws {
        let json = """
        {
          "tag_name": "v2.3.0",
          "name": "HiDpiSwitcher 2.3.0 — Обновления",
          "body": "### Что нового:\\n- Новая функция",
          "html_url": "https://github.com/banzaez/hidpi-switcher/releases/tag/v2.3.0",
          "published_at": "2026-11-10T12:00:00Z",
          "assets": [
            {
              "name": "HiDpiSwitcher-v2.3.0.zip",
              "browser_download_url": "https://github.com/banzaez/hidpi-switcher/releases/download/v2.3.0/HiDpiSwitcher-v2.3.0.zip",
              "size": 1500000
            }
          ]
        }
        """

        let data = try #require(json.data(using: .utf8))
        let service = GitHubUpdateService()
        let releaseInfo = try service.parseRelease(from: data)

        #expect(releaseInfo.version == SemanticVersion(major: 2, minor: 3, patch: 0))
        #expect(releaseInfo.rawTagName == "v2.3.0")
        #expect(releaseInfo.releaseTitle == "HiDpiSwitcher 2.3.0 — Обновления")
        #expect(releaseInfo.downloadURL?.absoluteString == "https://github.com/banzaez/hidpi-switcher/releases/download/v2.3.0/HiDpiSwitcher-v2.3.0.zip")
        #expect(releaseInfo.assetName == "HiDpiSwitcher-v2.3.0.zip")
        #expect(releaseInfo.assetSizeBytes == 1500000)
        #expect(releaseInfo.formattedSize?.contains("MB") == true || releaseInfo.formattedSize?.contains("МБ") == true)
    }

    @Test("Ручная проверка при наличии новой версии открывает диалог обновления")
    @MainActor
    func manualCheckFindsNewUpdate() async {
        let currentVersion = SemanticVersion(major: 2, minor: 2, patch: 0)
        let newVersion = SemanticVersion(major: 2, minor: 3, patch: 0)
        let sampleInfo = UpdateInfo(
            version: newVersion,
            rawTagName: "v2.3.0",
            releaseTitle: "HiDpiSwitcher 2.3.0",
            releaseNotes: "Новый функционал",
            htmlURL: URL(string: "https://github.com/banzaez/hidpi-switcher/releases/tag/v2.3.0")!,
            downloadURL: URL(string: "https://github.com/banzaez/hidpi-switcher/releases/download/v2.3.0/HiDpiSwitcher-v2.3.0.zip")!
        )

        let mockChecker = MockUpdateChecker(resultToReturn: .success(.updateAvailable(sampleInfo)))
        let mockDownloader = MockUpdateDownloader()
        let mockInstaller = MockUpdateInstaller()
        let mockPrefs = MockUpdatePreferencesStore()
        let mockPresenter = MockUpdatePresenter()

        let store = UpdateStore(
            currentVersion: currentVersion,
            updateChecker: mockChecker,
            updateDownloader: mockDownloader,
            updateInstaller: mockInstaller,
            preferencesStore: mockPrefs,
            presenter: mockPresenter
        )

        await store.checkForUpdates(manual: true)

        #expect(store.isUpdateAvailable == true)
        #expect(store.availableUpdate?.version == newVersion)
        #expect(mockPresenter.didShowUpdateDialog == true)
        #expect(mockPrefs.lastCheckDate != nil)
    }

    @Test("Ручная проверка при актуальной версии выводит информационный алерт")
    @MainActor
    func manualCheckUpToDate() async {
        let currentVersion = SemanticVersion(major: 2, minor: 2, patch: 0)
        let mockChecker = MockUpdateChecker(resultToReturn: .success(.upToDate(currentVersion: currentVersion)))
        let mockDownloader = MockUpdateDownloader()
        let mockInstaller = MockUpdateInstaller()
        let mockPrefs = MockUpdatePreferencesStore()
        let mockPresenter = MockUpdatePresenter()

        let store = UpdateStore(
            currentVersion: currentVersion,
            updateChecker: mockChecker,
            updateDownloader: mockDownloader,
            updateInstaller: mockInstaller,
            preferencesStore: mockPrefs,
            presenter: mockPresenter
        )

        await store.checkForUpdates(manual: true)

        #expect(store.isUpdateAvailable == false)
        #expect(mockPresenter.upToDateAlertVersion == currentVersion)
        #expect(mockPresenter.didShowUpdateDialog == false)
    }

    @Test("Фоновая проверка не беспокоит пользователя, если версия была пропущена")
    @MainActor
    func automaticCheckIgnoresSkippedVersion() async {
        let currentVersion = SemanticVersion(major: 2, minor: 2, patch: 0)
        let newVersion = SemanticVersion(major: 2, minor: 3, patch: 0)
        let sampleInfo = UpdateInfo(
            version: newVersion,
            rawTagName: "v2.3.0",
            releaseTitle: "HiDpiSwitcher 2.3.0",
            releaseNotes: "Новый функционал",
            htmlURL: URL(string: "https://github.com/banzaez/hidpi-switcher/releases/tag/v2.3.0")!
        )

        let mockChecker = MockUpdateChecker(resultToReturn: .success(.updateAvailable(sampleInfo)))
        let mockDownloader = MockUpdateDownloader()
        let mockInstaller = MockUpdateInstaller()
        let mockPrefs = MockUpdatePreferencesStore()
        mockPrefs.skippedVersion = "v2.3.0"
        let mockPresenter = MockUpdatePresenter()

        let store = UpdateStore(
            currentVersion: currentVersion,
            updateChecker: mockChecker,
            updateDownloader: mockDownloader,
            updateInstaller: mockInstaller,
            preferencesStore: mockPrefs,
            presenter: mockPresenter
        )

        // Фоновая проверка (manual: false)
        await store.checkForUpdates(manual: false)

        #expect(store.isUpdateAvailable == false)
        #expect(mockPresenter.didShowUpdateDialog == false)

        // Ручная проверка (manual: true) всё равно должна открыть диалог
        await store.checkForUpdates(manual: true)
        #expect(store.isUpdateAvailable == true)
        #expect(mockPresenter.didShowUpdateDialog == true)
    }

    @Test("Пропуск версии сохраняет тег в хранилище настроек")
    @MainActor
    func skipVersionPersists() {
        let mockChecker = MockUpdateChecker(resultToReturn: .success(.upToDate(currentVersion: SemanticVersion(major: 2, minor: 2, patch: 0))))
        let mockDownloader = MockUpdateDownloader()
        let mockInstaller = MockUpdateInstaller()
        let mockPrefs = MockUpdatePreferencesStore()
        let mockPresenter = MockUpdatePresenter()

        let store = UpdateStore(
            updateChecker: mockChecker,
            updateDownloader: mockDownloader,
            updateInstaller: mockInstaller,
            preferencesStore: mockPrefs,
            presenter: mockPresenter
        )

        let versionToSkip = SemanticVersion(major: 2, minor: 4, patch: 0)
        store.skipVersion(versionToSkip)

        #expect(mockPrefs.skippedVersion == "2.4.0")
        #expect(mockPresenter.didDismissUpdateDialog == true)
    }

    @Test("Загрузка обновления вызывает установщик и передаёт прогресс")
    @MainActor
    func downloadAndInstallFlow() async {
        let newVersion = SemanticVersion(major: 2, minor: 3, patch: 0)
        let sampleInfo = UpdateInfo(
            version: newVersion,
            rawTagName: "v2.3.0",
            releaseTitle: "HiDpiSwitcher 2.3.0",
            releaseNotes: "Новый релиз",
            htmlURL: URL(string: "https://github.com/banzaez/hidpi-switcher")!,
            downloadURL: URL(string: "https://github.com/banzaez/hidpi-switcher/releases/download/v2.3.0/HiDpiSwitcher-v2.3.0.zip")!
        )

        let mockChecker = MockUpdateChecker(resultToReturn: .success(.updateAvailable(sampleInfo)))
        let mockDownloader = MockUpdateDownloader()
        let mockInstaller = MockUpdateInstaller()
        let mockPrefs = MockUpdatePreferencesStore()
        let mockPresenter = MockUpdatePresenter()

        let store = UpdateStore(
            updateChecker: mockChecker,
            updateDownloader: mockDownloader,
            updateInstaller: mockInstaller,
            preferencesStore: mockPrefs,
            presenter: mockPresenter
        )

        await store.checkForUpdates(manual: true)
        #expect(store.isUpdateAvailable == true)

        await store.downloadAndInstall()

        #expect(mockInstaller.didCallInstall == true)
        #expect(store.downloadProgress == 1.0)
    }
}
