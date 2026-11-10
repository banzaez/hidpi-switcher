import Foundation
import AppKit

public enum UpdateServiceError: LocalizedError, Sendable {
    case invalidReleaseData
    case releaseParsingFailed(String)
    case noValidDownloadAsset(String)
    case downloadFailed(String)
    case extractionFailed(String)
    case invalidExtractedBundle(String)
    case appDirectoryNotWritable(URL)
    case installerScriptFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidReleaseData:
            return "Не удалось получить корректные данные о релизе с GitHub"
        case let .releaseParsingFailed(reason):
            return "Ошибка при разборе информации о релизе: \(reason)"
        case let .noValidDownloadAsset(tag):
            return "В релизе \(tag) не найден подходящий архив .zip с приложением"
        case let .downloadFailed(reason):
            return "Ошибка загрузки обновления: \(reason)"
        case let .extractionFailed(reason):
            return "Не удалось распаковать архив обновления: \(reason)"
        case let .invalidExtractedBundle(path):
            return "Распакованный архив не содержит корректного бандла HiDpiSwitcher.app: \(path)"
        case let .appDirectoryNotWritable(url):
            return "Папка приложения недоступна для записи (\(url.path)). Переместите HiDpiSwitcher в папку «Программы» (/Applications)."
        case let .installerScriptFailed(reason):
            return "Не удалось запустить скрипт обновления: \(reason)"
        }
    }
}

/// Сервис взаимодействия с GitHub Releases API и атомарного обновления бандла.
public final class GitHubUpdateService: UpdateCheckingService, UpdateDownloadingService, UpdateInstallingService, @unchecked Sendable {
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

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue("HiDpiSwitcher/\(currentVersion.rawString)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

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

        let (bytes, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw UpdateServiceError.downloadFailed("Сервер вернул статус \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }

        let expectedLength = response.expectedContentLength
        let tempDir = FileManager.default.temporaryDirectory
        let destinationURL = tempDir.appendingPathComponent("HiDpiSwitcher-Update-\(UUID().uuidString).zip")

        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        guard let fileHandle = try? FileHandle(forWritingTo: destinationURL) else {
            throw UpdateServiceError.downloadFailed("Не удалось создать временный файл на диске")
        }

        var downloadedBytes: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)

        var lastReportedProgress: Double = 0.0
        progressHandler(0.0)

        for try await byte in bytes {
            buffer.append(byte)
            downloadedBytes += 1

            if buffer.count >= 64 * 1024 {
                try fileHandle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)

                if expectedLength > 0 {
                    let progress = min(1.0, Double(downloadedBytes) / Double(expectedLength))
                    if progress - lastReportedProgress >= 0.01 || progress >= 1.0 {
                        lastReportedProgress = progress
                        progressHandler(progress)
                    }
                }
            }
        }

        if !buffer.isEmpty {
            try fileHandle.write(contentsOf: buffer)
        }
        try fileHandle.close()

        progressHandler(1.0)
        return destinationURL
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
        PID=\(currentPID)
        DEST="\(currentAppURL.path)"
        NEW_APP="\(extractedAppURL.path)"
        STAGING="\(stagingDir.path)"
        ARCHIVE="\(archiveURL.path)"

        # Ждём завершения текущего процесса (макс. 10 сек)
        COUNT=0
        while kill -0 $PID 2>/dev/null; do
            sleep 0.2
            COUNT=$((COUNT + 1))
            if [ $COUNT -gt 50 ]; then
                kill -9 $PID 2>/dev/null || true
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

        let chmodProcess = Process()
        chmodProcess.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmodProcess.arguments = ["+x", scriptURL.path]
        try chmodProcess.run()
        chmodProcess.waitUntilExit()

        // 5. Запуск отсоединённого процесса обновления в фоне
        let relaunchProcess = Process()
        relaunchProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunchProcess.arguments = [scriptURL.path]
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
