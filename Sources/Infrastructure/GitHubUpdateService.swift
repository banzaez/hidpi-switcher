import AppKit
import Foundation
import os

public enum UpdateServiceError: LocalizedError, Sendable {
    case invalidReleaseData
    case releaseParsingFailed(String)
    case downloadFailed(String)
    case extractionFailed(String)
    case invalidExtractedBundle(String)
    case appDirectoryNotWritable(URL)

    public var errorDescription: String? {
        switch self {
        case .invalidReleaseData:
            return "Не удалось получить корректные данные о релизе с GitHub"
        case let .releaseParsingFailed(reason):
            return "Ошибка при разборе информации о релизе: \(reason)"
        case let .downloadFailed(reason):
            return "Ошибка загрузки обновления: \(reason)"
        case let .extractionFailed(reason):
            return "Не удалось распаковать архив обновления: \(reason)"
        case let .invalidExtractedBundle(path):
            return "Распакованный архив не содержит корректного бандла HiDpiSwitcher.app: \(path)"
        case let .appDirectoryNotWritable(url):
            return "Папка приложения недоступна для записи (\(url.path)). Переместите HiDpiSwitcher в папку «Программы» (/Applications)."
        }
    }
}

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    private let progressHandler: @Sendable (Double) -> Void
    private let lastReportedProgress = OSAllocatedUnfairLock<Double>(initialState: 0.0)

    init(progressHandler: @escaping @Sendable (Double) -> Void) {
        self.progressHandler = progressHandler
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = min(1.0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        let shouldReport = lastReportedProgress.withLock { last -> Bool in
            if progress - last >= 0.01 || progress >= 1.0 {
                last = progress
                return true
            }
            return false
        }
        if shouldReport {
            progressHandler(progress)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Файл перемещается после завершения session.download(for:delegate:)
    }
}

/// Сервис взаимодействия с GitHub Releases API и атомарного обновления бандла.
public final class GitHubUpdateService: UpdateCheckingService, UpdateDownloadingService, UpdateInstallingService, Sendable {
    public static let defaultRepo = "banzaez/hidpi-switcher"

    private let repo: String
    private let session: URLSession

    public init(repo: String = GitHubUpdateService.defaultRepo, session: URLSession = .shared) {
        self.repo = repo
        self.session = session
    }

    // MARK: - UpdateCheckingService

    public func checkForUpdates(currentVersion: SemanticVersion) async throws -> UpdateCheckResult {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            throw UpdateServiceError.releaseParsingFailed("Некорректный URL репозитория")
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("HiDpiSwitcher/\(currentVersion.rawString)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateServiceError.invalidReleaseData
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw UpdateServiceError.releaseParsingFailed("GitHub API вернул статус \(httpResponse.statusCode)")
        }

        let release = try parseRelease(from: data)

        if release.version > currentVersion {
            return .updateAvailable(release)
        } else {
            return .upToDate(currentVersion: currentVersion)
        }
    }

    /// Парсит DTO из JSON GitHub Release.
    public func parseRelease(from data: Data) throws -> UpdateInfo {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        struct GitHubAssetDTO: Decodable {
            let name: String
            let browser_download_url: String
            let size: Int64
        }

        struct GitHubReleaseDTO: Decodable {
            let tag_name: String
            let name: String?
            let body: String?
            let html_url: String
            let published_at: Date?
            let assets: [GitHubAssetDTO]
        }

        let dto: GitHubReleaseDTO
        do {
            dto = try decoder.decode(GitHubReleaseDTO.self, from: data)
        } catch {
            throw UpdateServiceError.releaseParsingFailed(error.localizedDescription)
        }

        guard let version = SemanticVersion(fromString: dto.tag_name) else {
            throw UpdateServiceError.releaseParsingFailed("Не удалось распарсить тег релиза: \(dto.tag_name)")
        }

        // Поиск .zip архива с приложением (предпочтительно с 'HiDpiSwitcher' в имени)
        let matchingAsset = dto.assets.first(where: {
            $0.name.lowercased().hasSuffix(".zip") && $0.name.localizedCaseInsensitiveContains("HiDpiSwitcher")
        }) ?? dto.assets.first(where: { $0.name.lowercased().hasSuffix(".zip") })

        let downloadURL = matchingAsset.flatMap { URL(string: $0.browser_download_url) }
        let htmlURL = URL(string: dto.html_url) ?? URL(string: "https://github.com/\(repo)/releases")!

        return UpdateInfo(
            version: version,
            rawTagName: dto.tag_name,
            releaseTitle: dto.name ?? dto.tag_name,
            releaseNotes: dto.body ?? "Описание релиза отсутствует.",
            publishedAt: dto.published_at,
            htmlURL: htmlURL,
            downloadURL: downloadURL,
            assetName: matchingAsset?.name,
            assetSizeBytes: matchingAsset?.size
        )
    }

    // MARK: - UpdateDownloadingService

    public func downloadUpdate(
        from url: URL,
        progressHandler: @Sendable @escaping (Double) -> Void
    ) async throws -> URL {
        var request = URLRequest(url: url)
        request.setValue("HiDpiSwitcher", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60

        progressHandler(0.0)
        let delegate = DownloadProgressDelegate(progressHandler: progressHandler)
        let (tempDownloadedURL, response) = try await session.download(for: request, delegate: delegate)

        let fileManager = FileManager.default
        let destinationURL = fileManager.temporaryDirectory
            .appendingPathComponent("HiDpiSwitcher-Update-\(UUID().uuidString).zip")

        do {
            try Task.checkCancellation()
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw UpdateServiceError.downloadFailed("Сервер вернул статус \(statusCode)")
            }
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: tempDownloadedURL, to: destinationURL)
            progressHandler(1.0)
            return destinationURL
        } catch {
            try? fileManager.removeItem(at: tempDownloadedURL)
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
    }

    // MARK: - UpdateInstallingService

    public func installAndRelaunch(from archiveURL: URL, currentAppURL: URL) throws {
        let fileManager = FileManager.default
        let stagingDir = fileManager.temporaryDirectory.appendingPathComponent("HiDpiSwitcher-Staging-\(UUID().uuidString)")

        try fileManager.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        // 1. Распаковка архива с помощью нативной утилиты ditto (сохраняет права и атрибуты)
        let dittoProcess = Process()
        dittoProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        dittoProcess.arguments = ["-xk", archiveURL.path, stagingDir.path]

        try dittoProcess.run()
        dittoProcess.waitUntilExit()

        guard dittoProcess.terminationStatus == 0 else {
            try? fileManager.removeItem(at: stagingDir)
            throw UpdateServiceError.extractionFailed("ditto завершился с кодом \(dittoProcess.terminationStatus)")
        }

        // 2. Поиск HiDpiSwitcher.app в распакованной директории
        guard let extractedAppURL = findAppBundle(in: stagingDir) else {
            try? fileManager.removeItem(at: stagingDir)
            throw UpdateServiceError.invalidExtractedBundle(stagingDir.path)
        }

        // 3. Проверка прав на запись в целевую папку
        let targetDirectory = currentAppURL.deletingLastPathComponent()
        guard fileManager.isWritableFile(atPath: targetDirectory.path) else {
            try? fileManager.removeItem(at: stagingDir)
            throw UpdateServiceError.appDirectoryNotWritable(currentAppURL)
        }

        // 4. Формирование атомарного скрипта подмены и перезапуска приложения
        let scriptURL = fileManager.temporaryDirectory.appendingPathComponent("relaunch-\(UUID().uuidString).sh")
        let currentPID = ProcessInfo.processInfo.processIdentifier

        let scriptContent = """
        #!/bin/sh
        # Скрипт атомарной замены бандла HiDpiSwitcher и перезапуска
        PID="$1"
        DEST="$2"
        NEW_APP="$3"
        STAGING="$4"
        ARCHIVE="$5"

        # Ждём завершения текущего процесса (макс. 10 сек)
        COUNT=0
        while kill -0 "$PID" 2>/dev/null; do
            sleep 0.2
            COUNT=$((COUNT + 1))
            if [ "$COUNT" -gt 50 ]; then
                kill -9 "$PID" 2>/dev/null || true
                break
            fi
        done

        # Атомарная замена приложения
        rm -rf "$DEST"
        cp -R "$NEW_APP" "$DEST"
        xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

        # Очистка временных файлов
        rm -rf "$STAGING"
        rm -f "$ARCHIVE"

        # Запуск обновлённой версии
        open "$DEST"

        # Удаление самого скрипта
        rm -f "$0"
        """

        try scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        // 5. Запуск отсоединённого процесса обновления в фоне
        let relaunchProcess = Process()
        relaunchProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunchProcess.arguments = [
            scriptURL.path,
            String(currentPID),
            currentAppURL.path,
            extractedAppURL.path,
            stagingDir.path,
            archiveURL.path
        ]
        try relaunchProcess.run()

        // 6. Завершение работы текущего приложения
        Task { @MainActor in
            NSApplication.shared.terminate(nil)
        }
    }

    private func findAppBundle(in directory: URL) -> URL? {
        let fileManager = FileManager.default
        let directApp = directory.appendingPathComponent("HiDpiSwitcher.app")
        if fileManager.fileExists(atPath: directApp.path) {
            return directApp
        }

        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension == "app" {
                return fileURL
            }
        }
        return nil
    }
}
