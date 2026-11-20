import AppKit
import Foundation
import Observation

/// Протокол презентера диалогов обновления.
@MainActor
public protocol UpdateDialogPresenter: AnyObject {
    func showUpdateDialog(store: UpdateStore)
    func dismissUpdateDialog()
    func showUpToDateAlert(version: SemanticVersion)
    func showErrorAlert(message: String, releaseURL: URL?)
}

/// Состояние процесса обновления.
public enum UpdateState: Equatable, Sendable {
    case idle
    case checking
    case upToDate(SemanticVersion)
    case updateAvailable(UpdateInfo)
    case downloading(progress: Double)
    case error(String)
}

/// Управляющий стор проверки и установки обновлений приложения.
@Observable
@MainActor
public final class UpdateStore {
    public private(set) var state: UpdateState = .idle
    public private(set) var lastErrorMessage: String? = nil
    public private(set) var downloadProgress: Double = 0.0

    public let currentVersion: SemanticVersion
    private let currentAppURL: URL

    @ObservationIgnored
    private let updateChecker: UpdateCheckingService
    @ObservationIgnored
    private let updateDownloader: UpdateDownloadingService
    @ObservationIgnored
    private let updateInstaller: UpdateInstallingService
    @ObservationIgnored
    private let preferencesStore: UpdatePreferencesStore
    @ObservationIgnored
    private weak var presenter: (any UpdateDialogPresenter)?
    @ObservationIgnored
    private var latestUpdateInfo: UpdateInfo?
    @ObservationIgnored
    private var activeDownloadTask: Task<URL, Error>?
    @ObservationIgnored
    private var isDownloadCancelled = false

    public init(
        currentVersion: SemanticVersion? = nil,
        currentAppURL: URL? = nil,
        updateChecker: UpdateCheckingService? = nil,
        updateDownloader: UpdateDownloadingService? = nil,
        updateInstaller: UpdateInstallingService? = nil,
        preferencesStore: UpdatePreferencesStore = UserDefaultsUpdatePreferencesStore(),
        presenter: (any UpdateDialogPresenter)? = nil
    ) {
        let versionString = currentVersion?.rawString
            ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            ?? "2.4.0"
        self.currentVersion = currentVersion
            ?? SemanticVersion(fromString: versionString)
            ?? SemanticVersion(major: 2, minor: 4, patch: 0)
        self.currentAppURL = currentAppURL ?? Bundle.main.bundleURL

        let sharedService: GitHubUpdateService? =
            (updateChecker == nil || updateDownloader == nil || updateInstaller == nil)
            ? GitHubUpdateService()
            : nil
        self.updateChecker = updateChecker ?? sharedService!
        self.updateDownloader = updateDownloader ?? sharedService!
        self.updateInstaller = updateInstaller ?? sharedService!
        self.preferencesStore = preferencesStore
        self.presenter = presenter
    }

    public func setPresenter(_ presenter: any UpdateDialogPresenter) {
        self.presenter = presenter
    }

    public var automaticallyCheckForUpdates: Bool {
        get { preferencesStore.automaticallyCheckForUpdates }
        set { preferencesStore.setAutomaticallyCheckForUpdates(newValue) }
    }

    public var availableUpdate: UpdateInfo? {
        switch state {
        case let .updateAvailable(info):
            return info
        case .downloading:
            return latestUpdateInfo
        case .idle, .checking, .upToDate, .error:
            return nil
        }
    }

    public var isUpdateAvailable: Bool {
        availableUpdate != nil
    }

    /// Проверяет наличие обновлений.
    /// - Parameter manual: `true` — если проверку вызвал пользователь из меню; `false` — фоновая автопроверка при старте.
    public func checkForUpdates(manual: Bool = false) async {
        guard state != .checking else { return }
        if case .downloading = state { return }

        if !manual {
            guard preferencesStore.automaticallyCheckForUpdates else { return }
            if let lastDate = preferencesStore.lastCheckDate,
               Date().timeIntervalSince(lastDate) < 24 * 3600 {
                // Менее суток с прошлой проверки — пропускаем автопроверку
                return
            }
        }

        state = .checking
        lastErrorMessage = nil
        downloadProgress = 0.0
        latestUpdateInfo = nil

        do {
            let result = try await updateChecker.checkForUpdates(currentVersion: currentVersion)
            preferencesStore.setLastCheckDate(Date())

            switch result {
            case let .upToDate(version):
                latestUpdateInfo = nil
                state = .upToDate(version)
                if manual {
                    presenter?.showUpToDateAlert(version: version)
                }

            case let .updateAvailable(info):
                // Если пользователь выбрал «Пропустить эту версию» для фоновой проверки — не беспокоим его
                if !manual, let skipped = preferencesStore.skippedVersion {
                    if let skippedVer = SemanticVersion(fromString: skipped), skippedVer == info.version {
                        latestUpdateInfo = nil
                        state = .idle
                        return
                    }
                }

                latestUpdateInfo = info
                state = .updateAvailable(info)
                presenter?.showUpdateDialog(store: self)
            }
        } catch {
            latestUpdateInfo = nil
            state = .error(error.localizedDescription)
            lastErrorMessage = error.localizedDescription
            if manual {
                let releaseURL = URL(string: "https://github.com/\(GitHubUpdateService.defaultRepo)/releases")
                presenter?.showErrorAlert(message: error.localizedDescription, releaseURL: releaseURL)
            }
        }
    }

    /// Фоновая автопроверка при запуске приложения (с задержкой).
    public func performStartupCheckIfNeeded() async {
        guard preferencesStore.automaticallyCheckForUpdates else { return }
        // Небольшая задержка, чтобы приложение мгновенно появилось в статус-баре
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        await checkForUpdates(manual: false)
    }

    /// Загружает и устанавливает найденное обновление.
    public func downloadAndInstall() async {
        guard case .updateAvailable = state, let update = availableUpdate else { return }

        guard let downloadURL = update.downloadURL else {
            // Если в релизе нет прямого .zip архива, открываем страницу GitHub Releases в браузере
            openReleaseWebPage()
            return
        }

        latestUpdateInfo = update
        isDownloadCancelled = false
        state = .downloading(progress: 0.0)
        downloadProgress = 0.0
        lastErrorMessage = nil

        let downloader = updateDownloader
        let progressCallback: @Sendable (Double) -> Void = { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, !self.isDownloadCancelled, case .downloading = self.state else { return }
                let clamped = min(1.0, max(self.downloadProgress, progress))
                self.downloadProgress = clamped
                self.state = .downloading(progress: clamped)
            }
        }
        let task = Task<URL, Error> {
            try await downloader.downloadUpdate(from: downloadURL, progressHandler: progressCallback)
        }
        activeDownloadTask = task

        var downloadedArchiveURL: URL?
        do {
            let localZipURL = try await task.value
            downloadedArchiveURL = localZipURL
            activeDownloadTask = nil

            guard !isDownloadCancelled, !Task.isCancelled else {
                try? FileManager.default.removeItem(at: localZipURL)
                state = .updateAvailable(update)
                downloadProgress = 0.0
                return
            }

            downloadProgress = 1.0
            state = .downloading(progress: 1.0)

            // Атомарная установка и перезапуск
            try updateInstaller.installAndRelaunch(from: localZipURL, currentAppURL: currentAppURL)
        } catch is CancellationError {
            activeDownloadTask = nil
            if let url = downloadedArchiveURL {
                try? FileManager.default.removeItem(at: url)
            }
            state = .updateAvailable(update)
            downloadProgress = 0.0
        } catch {
            activeDownloadTask = nil
            if let url = downloadedArchiveURL {
                try? FileManager.default.removeItem(at: url)
            }
            state = .updateAvailable(update)
            downloadProgress = 0.0
            if !isDownloadCancelled {
                lastErrorMessage = error.localizedDescription
            }
        }
    }

    /// Пропустить указанную версию.
    public func skipVersion(_ version: SemanticVersion) {
        preferencesStore.setSkippedVersion(version.rawString)
        latestUpdateInfo = nil
        state = .idle
        dismiss()
    }

    /// Открыть веб-страницу релиза на GitHub.
    public func openReleaseWebPage() {
        if let update = availableUpdate {
            NSWorkspace.shared.open(update.htmlURL)
        } else if let fallback = URL(string: "https://github.com/\(GitHubUpdateService.defaultRepo)/releases") {
            NSWorkspace.shared.open(fallback)
        }
    }

    /// Показать окно обновления (например, при клике на бейдж в строке меню).
    public func presentUpdateDialog() {
        presenter?.showUpdateDialog(store: self)
    }

    /// Скрыть диалог обновления (и отменить активную загрузку, если она выполняется).
    public func dismiss() {
        presenter?.dismissUpdateDialog()
        if case .downloading = state {
            isDownloadCancelled = true
            activeDownloadTask?.cancel()
            activeDownloadTask = nil
            state = latestUpdateInfo.map { .updateAvailable($0) } ?? .idle
            downloadProgress = 0.0
        }
    }
}
