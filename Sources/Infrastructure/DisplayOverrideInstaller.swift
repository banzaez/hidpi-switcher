import Foundation
import os

private let log = Logger(subsystem: "com.local.HiDpiSwitcher", category: "DisplayOverrideInstaller")

/// Протокол управления системными файлами Override Plist (`/Library/Displays/Contents/Resources/Overrides/...`).
@MainActor
public protocol DisplayOverrideInstallerProtocol: AnyObject {
    func isOverrideInstalled(for device: DisplayDevice) -> Bool
    func installOverride(for device: DisplayDevice, nativeWidth: Int, nativeHeight: Int) throws
    func removeOverride(for device: DisplayDevice) throws
}

public enum DisplayOverrideError: LocalizedError {
    case serializationFailed
    case privilegedExecutionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .serializationFailed:
            return "Не удалось сериализовать профиль Override Plist"
        case .privilegedExecutionFailed(let message):
            return "Не удалось выполнить операцию с правами администратора: \(message)"
        }
    }
}

/// Установщик профилей `scale-resolutions` в `/Library/Displays/Contents/Resources/Overrides`.
@MainActor
public final class SystemDisplayOverrideInstaller: DisplayOverrideInstallerProtocol {
    private let baseDirectory: String

    public init(baseDirectory: String = CustomHiDPISpec.overridesBaseDirectory) {
        self.baseDirectory = baseDirectory
    }

    public func isOverrideInstalled(for device: DisplayDevice) -> Bool {
        let path = CustomHiDPISpec.overrideFilePath(
            vendorID: device.vendorNumber,
            productID: device.modelNumber,
            baseDirectory: baseDirectory
        )
        return FileManager.default.fileExists(atPath: path)
    }

    public func installOverride(for device: DisplayDevice, nativeWidth: Int, nativeHeight: Int) throws {
        let resolutions = CustomHiDPISpec.recommendedResolutions(
            nativeWidth: nativeWidth,
            nativeHeight: nativeHeight
        )
        let plistDict = CustomHiDPISpec.buildOverridePlistPlistSafe(device: device, resolutions: resolutions)
        let data = try PropertyListSerialization.data(
            fromPropertyList: plistDict,
            format: .xml,
            options: 0
        )

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hidpi-override-\(device.vendorNumber)-\(device.modelNumber).plist")
        try data.write(to: tempURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let targetPath = CustomHiDPISpec.overrideFilePath(
            vendorID: device.vendorNumber,
            productID: device.modelNumber,
            baseDirectory: baseDirectory
        )
        let targetDir = (targetPath as NSString).deletingLastPathComponent

        let command = "mkdir -p '\(Self.shellEscape(targetDir))' && cp '\(Self.shellEscape(tempURL.path))' '\(Self.shellEscape(targetPath))' && chmod 644 '\(Self.shellEscape(targetPath))'"
        try runWithAdminPrivileges(command)
        log.notice("Установлен системный HiDPI Override: \(targetPath)")
    }

    public func removeOverride(for device: DisplayDevice) throws {
        let targetPath = CustomHiDPISpec.overrideFilePath(
            vendorID: device.vendorNumber,
            productID: device.modelNumber,
            baseDirectory: baseDirectory
        )
        guard FileManager.default.fileExists(atPath: targetPath) else { return }

        let command = "rm -f '\(Self.shellEscape(targetPath))'"
        try runWithAdminPrivileges(command)
        log.notice("Удалён системный HiDPI Override: \(targetPath)")
    }

    private func runWithAdminPrivileges(_ shellCommand: String) throws {
        let escapedForAppleScript = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script = "do shell script \"\(escapedForAppleScript)\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let errPipe = Pipe()
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Код \(process.terminationStatus)"
            throw DisplayOverrideError.privilegedExecutionFailed(errText)
        }
    }

    private static func shellEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "'\\''")
    }
}

extension CustomHiDPISpec {
    static func buildOverridePlistPlistSafe(
        device: DisplayDevice,
        resolutions: [HiDPIResolutionPair]
    ) -> [String: Any] {
        buildOverridePlistDictionary(device: device, resolutions: resolutions)
    }
}
