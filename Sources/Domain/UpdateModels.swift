import Foundation

/// Семантическая версия (SemVer) вида Major.Minor.Patch с поддержкой префиксов 'v' и пре-релизов.
public struct SemanticVersion: Comparable, Equatable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: String?
    public let rawString: String

    public init(major: Int, minor: Int, patch: Int, prerelease: String? = nil, rawString: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
        self.rawString = rawString ?? "\(major).\(minor).\(patch)\(prerelease.map { "-\($0)" } ?? "")"
    }

    /// Парсит строку версии (например: "2.2.0", "v2.3.1", "v2.4.0-beta.1").
    public init?(fromString string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Снимаем ведущий префикс 'v' или 'V'
        var normalized = trimmed
        if normalized.lowercased().hasPrefix("v") {
            normalized.removeFirst()
        }

        // Выделяем пре-релиз (после дефиса '-')
        var prereleasePart: String? = nil
        if let dashIndex = normalized.firstIndex(of: "-") {
            prereleasePart = String(normalized[normalized.index(after: dashIndex)...])
            normalized = String(normalized[..<dashIndex])
        }

        let components = normalized.split(separator: ".")
        guard !components.isEmpty else { return nil }

        guard let major = Int(components[0]) else { return nil }
        let minor = components.count > 1 ? (Int(components[1]) ?? 0) : 0
        let patch = components.count > 2 ? (Int(components[2]) ?? 0) : 0

        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prereleasePart
        self.rawString = trimmed
    }

    public var description: String {
        if let prerelease {
            return "\(major).\(minor).\(patch)-\(prerelease)"
        }
        return "\(major).\(minor).\(patch)"
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major {
            return lhs.major < rhs.major
        }
        if lhs.minor != rhs.minor {
            return lhs.minor < rhs.minor
        }
        if lhs.patch != rhs.patch {
            return lhs.patch < rhs.patch
        }

        // По SemVer 2.0: версия с pre-release меньше полноценной версии без pre-release (2.0.0-beta < 2.0.0)
        switch (lhs.prerelease, rhs.prerelease) {
        case (.none, .none):
            return false
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case let (.some(lPre), .some(rPre)):
            return lPre < rPre
        }
    }

    public static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        lhs.major == rhs.major &&
        lhs.minor == rhs.minor &&
        lhs.patch == rhs.patch &&
        lhs.prerelease == rhs.prerelease
    }
}

/// Информация о доступном релизе.
public struct UpdateInfo: Equatable, Sendable, Identifiable {
    public var id: String { rawTagName }

    public let version: SemanticVersion
    public let rawTagName: String
    public let releaseTitle: String
    public let releaseNotes: String
    public let publishedAt: Date?
    public let htmlURL: URL
    public let downloadURL: URL?
    public let assetName: String?
    public let assetSizeBytes: Int64?

    public init(
        version: SemanticVersion,
        rawTagName: String,
        releaseTitle: String,
        releaseNotes: String,
        publishedAt: Date? = nil,
        htmlURL: URL,
        downloadURL: URL? = nil,
        assetName: String? = nil,
        assetSizeBytes: Int64? = nil
    ) {
        self.version = version
        self.rawTagName = rawTagName
        self.releaseTitle = releaseTitle
        self.releaseNotes = releaseNotes
        self.publishedAt = publishedAt
        self.htmlURL = htmlURL
        self.downloadURL = downloadURL
        self.assetName = assetName
        self.assetSizeBytes = assetSizeBytes
    }

    public var formattedSize: String? {
        guard let bytes = assetSizeBytes, bytes > 0 else { return nil }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

/// Результат проверки обновлений.
public enum UpdateCheckResult: Equatable, Sendable {
    case upToDate(currentVersion: SemanticVersion)
    case updateAvailable(UpdateInfo)
}

/// Протокол проверки обновлений (поддерживает моки для тестов).
public protocol UpdateCheckingService: Sendable {
    func checkForUpdates(currentVersion: SemanticVersion) async throws -> UpdateCheckResult
}

/// Протокол загрузки архива обновления с отслеживанием прогресса.
public protocol UpdateDownloadingService: Sendable {
    func downloadUpdate(
        from url: URL,
        progressHandler: @Sendable @escaping (Double) -> Void
    ) async throws -> URL
}

/// Протокол установки обновления и перезапуска приложения.
public protocol UpdateInstallingService: Sendable {
    func installAndRelaunch(from archiveURL: URL, currentAppURL: URL) throws
}
