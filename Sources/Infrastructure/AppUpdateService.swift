import AppKit
import Foundation
import Observation
import Sparkle
import os

/// Результат проверки обновлений.
public enum UpdateCheckResult: Equatable, Sendable {
    case idle
    case checking
    case upToDate(version: String)
    case updateAvailable(version: String, releaseNotes: String, releaseURL: URL, downloadURL: URL?)
    case failed(message: String)
}

/// Протокол сервиса проверки обновлений приложения.
@MainActor
public protocol AppUpdateManaging: AnyObject {
    var status: UpdateCheckResult { get }
    var isChecking: Bool { get }
    var currentVersion: String { get }
    var automaticallyCheckForUpdates: Bool { get }
    func setAutoCheckEnabled(_ enabled: Bool)
    @discardableResult
    func checkForUpdates(isUserInitiated: Bool) async -> UpdateCheckResult
}

public extension AppUpdateManaging {
    var automaticallyCheckForUpdates: Bool { true }
    func setAutoCheckEnabled(_ enabled: Bool) {}
}

/// Сервис проверки и установки обновлений HiDpiSwitcher на базе Sparkle.
@Observable
@MainActor
public final class AppUpdateService: NSObject, AppUpdateManaging, SPUUpdaterDelegate {
    public static let shared = AppUpdateService()
    public nonisolated static let releasesURL = URL(string: "https://github.com/banzaez/hidpi-switcher/releases")!

    private let logger = Logger(subsystem: "com.local.HiDpiSwitcher", category: "AppUpdateService")

    public private(set) var status: UpdateCheckResult = .idle
    public private(set) var isChecking: Bool = false

    @ObservationIgnored
    private var updaterController: SPUStandardUpdaterController?

    override public init() {
        super.init()

        // Инициализируем Sparkle только внутри полноценного .app бандла с настроенным SUFeedURL,
        // чтобы модульные тесты (swift test) не падали из-за отсутствия Info.plist.
        if Bundle.main.bundleIdentifier != nil,
           Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil {
            self.updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: self,
                userDriverDelegate: nil
            )
        }
    }

    /// Текущая версия приложения.
    public var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.5.1"
    }

    /// Состояние автоматической проверки обновлений в Sparkle.
    public var automaticallyCheckForUpdates: Bool {
        updaterController?.updater.automaticallyChecksForUpdates ?? true
    }

    /// Синхронизация настройки автоматической проверки обновлений со Sparkle.
    public func setAutoCheckEnabled(_ enabled: Bool) {
        updaterController?.updater.automaticallyChecksForUpdates = enabled
    }

    /// Проверка обновлений через Sparkle.
    @discardableResult
    public func checkForUpdates(isUserInitiated: Bool = true) async -> UpdateCheckResult {
        guard !isChecking else { return status }
        guard let updaterController else {
            logger.warning("Sparkle не инициализирован (запуск вне .app бандла).")
            return .idle
        }

        isChecking = true
        status = .checking
        logger.info("Проверка обновлений через Sparkle (пользовательский запрос: \(isUserInitiated))...")

        if isUserInitiated {
            NSApp.activate(ignoringOtherApps: true)
            updaterController.checkForUpdates(nil)
        } else {
            updaterController.updater.checkForUpdatesInBackground()
        }

        return status
    }

    // MARK: - SPUUpdaterDelegate

    public nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        let notes = item.itemDescription ?? ""
        let releaseURL = item.infoURL ?? Self.releasesURL
        let downloadURL = item.fileURL

        Task { @MainActor in
            self.isChecking = false
            self.status = .updateAvailable(
                version: version,
                releaseNotes: notes,
                releaseURL: releaseURL,
                downloadURL: downloadURL
            )
        }
    }

    public nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in
            self.isChecking = false
            self.status = .upToDate(version: self.currentVersion)
        }
    }

    public nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let nsError = error as NSError
        let domain = nsError.domain
        let code = nsError.code
        let message = error.localizedDescription

        Task { @MainActor in
            self.isChecking = false
            if domain == SUSparkleErrorDomain {
                // 1001 = SUNoUpdateError, 4002 = SUInstallationCanceledError
                if code == 1001 {
                    self.status = .upToDate(version: self.currentVersion)
                    return
                }
                if code == 4002 {
                    self.status = .idle
                    return
                }
            }
            self.logger.error("Sparkle прервал проверку обновлений: \(message)")
            self.status = .failed(message: message)
        }
    }

    public nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        Task { @MainActor in
            self.isChecking = false
        }
    }

    /// Сравнение версий по стандарту SemVer (например 2.5.1 > 2.5.0).
    public func isVersion(_ v1: String, greaterThan v2: String) -> Bool {
        let parts1 = v1.split(separator: ".").compactMap { Int($0.prefix(while: { $0.isNumber })) }
        let parts2 = v2.split(separator: ".").compactMap { Int($0.prefix(while: { $0.isNumber })) }

        let count = max(parts1.count, parts2.count)
        for i in 0..<count {
            let num1 = i < parts1.count ? parts1[i] : 0
            let num2 = i < parts2.count ? parts2[i] : 0
            if num1 > num2 { return true }
            if num1 < num2 { return false }
        }
        return false
    }
}
