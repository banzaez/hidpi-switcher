import AppKit
import CoreGraphics
import os

private let log = Logger(subsystem: "com.local.HiDpiSwitcher", category: "DisplayHardwareClient")

/// Протокол взаимодействия с подсистемой экранов macOS (позволяет подменять реальное оборудование в тестах).
@MainActor
public protocol DisplayHardwareClientProtocol {
    func activeDisplays() -> [DisplayDevice]
    func currentModeID(for displayID: CGDirectDisplayID) -> Int
    func allModes(for displayID: CGDirectDisplayID) -> [DisplayMode]
    func setDisplayMode(_ modeID: Int, for displayID: CGDirectDisplayID) -> Bool
    func reconfigurationEvents() -> AsyncStream<Void>
}

/// Бокс для передачи `AsyncStream.Continuation` в сишный колбэк реконфигурации CoreGraphics.
private final class ReconfigContinuationBox: Sendable {
    let continuation: AsyncStream<Void>.Continuation

    init(_ continuation: AsyncStream<Void>.Continuation) {
        self.continuation = continuation
    }
}

/// Реализация клиента поверх CoreGraphics, AppKit и CGSNative.
@MainActor
public struct LiveDisplayHardwareClient: DisplayHardwareClientProtocol {
    public init() {}

    public func activeDisplays() -> [DisplayDevice] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            log.error("CGGetActiveDisplayList: нет активных дисплеев")
            return []
        }

        var list = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &list, &count) == .success else {
            log.error("CGGetActiveDisplayList: ошибка получения списка дисплеев")
            return []
        }

        // Предварительно собираем словарь локализованных имен за O(N) вместо вложенного линейного поиска
        let screenNamesByID = Self.buildScreenNamesMap()

        return list.prefix(Int(count)).map { displayID in
            let isBuiltin = CGDisplayIsBuiltin(displayID) != 0
            let fallbackName = isBuiltin ? "Built-in Display" : "External Display"
            let name = screenNamesByID[displayID] ?? fallbackName

            return DisplayDevice(
                id: displayID,
                name: name,
                isMain: CGDisplayIsMain(displayID) != 0,
                isBuiltin: isBuiltin,
                vendorNumber: CGDisplayVendorNumber(displayID),
                modelNumber: CGDisplayModelNumber(displayID)
            )
        }
    }

    public func currentModeID(for displayID: CGDirectDisplayID) -> Int {
        CGSNative.currentModeID(for: displayID)
    }

    public func allModes(for displayID: CGDirectDisplayID) -> [DisplayMode] {
        CGSNative.allModes(for: displayID)
    }

    public func setDisplayMode(_ modeID: Int, for displayID: CGDirectDisplayID) -> Bool {
        CGSNative.setDisplayMode(modeID, for: displayID)
    }

    public func reconfigurationEvents() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let box = ReconfigContinuationBox(continuation)
            let rawContext = Unmanaged.passRetained(box).toOpaque()

            let err = CGDisplayRegisterReconfigurationCallback(Self.reconfigCallback, rawContext)
            if err != .success {
                Unmanaged<ReconfigContinuationBox>.fromOpaque(rawContext).release()
                log.error("Не удалось зарегистрировать CGDisplayReconfigurationCallBack: \(err.rawValue)")
                continuation.finish()
                return
            }

            nonisolated(unsafe) let capturedContext = rawContext
            continuation.onTermination = { _ in
                CGDisplayRemoveReconfigurationCallback(Self.reconfigCallback, capturedContext)
                Unmanaged<ReconfigContinuationBox>.fromOpaque(capturedContext).release()
            }
        }
    }

    private nonisolated static let reconfigCallback: CGDisplayReconfigurationCallBack = { _, flags, userInfo in
        guard let userInfo, !flags.contains(.beginConfigurationFlag) else { return }
        let box = Unmanaged<ReconfigContinuationBox>.fromOpaque(userInfo).takeUnretainedValue()
        box.continuation.yield(())
    }

    private static func buildScreenNamesMap() -> [CGDirectDisplayID: String] {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        var map: [CGDirectDisplayID: String] = [:]
        map.reserveCapacity(NSScreen.screens.count)

        for screen in NSScreen.screens {
            guard let id = (screen.deviceDescription[key] as? NSNumber)?.uint32Value else { continue }
            let localized = screen.localizedName
            if !localized.isEmpty {
                map[id] = localized
            }
        }
        return map
    }
}
