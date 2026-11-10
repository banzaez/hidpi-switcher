import AppKit
import Foundation
import Observation

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

    private let updateChecker: UpdateCheckingService
    private let updateDownloader: UpdateDownloadingService
    private let updateInstaller: UpdateInstallingService
    private let preferencesStore: UpdatePreferencesStore
    private weak var presenter: (any UpdateDialogPresenter)?

    public init(
        currentVersion: SemanticVersion? = nil,
        currentAppURL: URL? = nil,
        updateChecker: UpdateCheckingService = GitHubUpdateService(),
        updateDownloader: UpdateDownloadingService = GitHubUpdateService(),
        updateInstaller: UpdateInstallingService = GitHubUpdateService(),
        preferencesStore: UpdatePreferencesStore = UserDefaultsUpdatePreferencesStore(),
        presenter: (any UpdateDialogPresenter)? = nil
    ) {
        let versionString = currentVersion?.rawString
            ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            ?? "2.2.0"
        self.currentVersion = currentVersion ?? SemanticVersion(fromString: versionString) ?? SemanticVersion(major: 2, minor: 2, patch: 0)
        self.currentAppURL = currentAppURL ?? Bundle.main.bundleURL
        self.updateChecker = updateChecker
        self.updateDownloader = updateDownloader
        self.updateInstaller = updateInstaller
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
        if case let .updateAvailable(info) = state {
            return info
        }
        return nil
    }

    public var isUpdateAvailable: Bool {
        availableUpdate != nil
    }

    /// Проверяет наличие обновлений.
    /// - Parameter manual: `true` — если проверку вызвал пользователь из меню; `false` — фоновая автопроверка при старте.
    public func checkForUpdates(manual: Bool = false) async {
        guard state != .checking else { return }

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

        do {
            let result = try await updateChecker.checkForUpdates(currentVersion: currentVersion)
            preferencesStore.setLastCheckDate(Date())

            switch result {
            case let .upToDate(version):
                state = .upToDate(version)
                if manual {
                    presenter?.showUpToDateAlert(version: version)
                }

            case let .updateAvailable(info):
                // Если пользователь выбрал «Пропустить эту версию» для фоновой проверки — не беспокоим его
                if !manual, let skipped = preferencesStore.skippedVersion {
                    if let skippedVer = SemanticVersion(fromString: skipped), skippedVer == info.version {
                        state = .idle
                        return
                    }
                }

                state = .updateAvailable(info)
                presenter?.showUpdateDialog(store: self)
            }
        } catch {
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
        guard let update = availableUpdate else { return }

        guard let downloadURL = update.downloadURL else {
            // Если в релизе нет прямого .zip архива, открываем страницу GitHub Releases в браузере
            openReleaseWebPage()
            return
        }

        state = .downloading(progress: 0.0)
        downloadProgress = 0.0
        lastErrorMessage = nil

        do {
            let localZipURL = try await updateDownloader.downloadUpdate(from: downloadURL) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.downloadProgress = progress
                    self.state = .downloading(progress: progress)
                }
            }

            // Атомарная установка и перезапуск
            try updateInstaller.installAndRelaunch(from: localZipURL, currentAppURL: currentAppURL)
        } catch {
            state = .updateAvailable(update)
            lastErrorMessage = error.localizedDescription
        }
    }

    /// Пропустить указанную версию.
    public func skipVersion(_ version: SemanticVersion) {
        preferencesStore.setSkippedVersion(version.rawString)
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

    /// Скрыть диалог обновления.
    public func dismiss() {
        presenter?.dismissUpdateDialog()
        if case .downloading = state {
            state = availableUpdate.map { .updateAvailable($0) } ?? .idle
        }
    }
}
