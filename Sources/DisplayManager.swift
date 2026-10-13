import AppKit
import CoreGraphics
import os

private let log = Logger(subsystem: "com.local.HiDpiSwitcher", category: "DisplayManager")

struct DisplayDevice: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
    let isMain: Bool
    let isBuiltin: Bool

    var title: String {
        return name
    }
}

struct ModeEntry: Identifiable, Hashable {
    let id: Int
    let width: Int
    let height: Int
    let freq: Int
    let density: Float
    let isHiDPI: Bool

    var title: String {
        let tag = isHiDPI ? " [Retina 2x]" : " [1x]"
        let hz = freq > 0 ? " @ \(freq)Hz" : ""
        return "\(width) × \(height)\(tag)\(hz)"
    }
}

private struct ModeKey: Hashable {
    let width: Int
    let height: Int
    let freq: Int
    let isHiDPI: Bool
}

/// Слабая ссылка для безопасной передачи в C-callback.
private final class WeakManagerBox: @unchecked Sendable {
    weak var manager: DisplayManager?
    init(_ manager: DisplayManager) { self.manager = manager }
}

@MainActor
final class DisplayManager: ObservableObject {
    @Published var connectedDisplays: [DisplayDevice] = []
    @Published var selectedDisplayID: CGDirectDisplayID = CGMainDisplayID()
    @Published private(set) var availableModes: [ModeEntry] = []
    @Published private(set) var hidpiModes: [ModeEntry] = []
    @Published private(set) var standardModes: [ModeEntry] = []
    @Published var currentMode: ModeEntry?
    @Published var isHiDPIActive: Bool = false
    @Published var lastError: String?

    private nonisolated(unsafe) var callbackContext: UnsafeMutableRawPointer?

    init() {
        registerReconfigCallback()
        refreshDisplays()
    }

    deinit {
        if let ctx = callbackContext {
            CGDisplayRemoveReconfigurationCallback(DisplayManager.reconfigCallback, ctx)
            Unmanaged<WeakManagerBox>.fromOpaque(ctx).release()
        }
    }

    private func registerReconfigCallback() {
        let ctx = Unmanaged.passRetained(WeakManagerBox(self)).toOpaque()
        let err = CGDisplayRegisterReconfigurationCallback(DisplayManager.reconfigCallback, ctx)
        if err == .success {
            callbackContext = ctx
        } else {
            Unmanaged<WeakManagerBox>.fromOpaque(ctx).release()
            log.error("Не удалось зарегистрировать callback: \(err.rawValue)")
        }
    }

    private nonisolated static let reconfigCallback: CGDisplayReconfigurationCallBack = { _, flags, userInfo in
        guard let userInfo = userInfo, !flags.contains(.beginConfigurationFlag) else { return }
        let box = Unmanaged<WeakManagerBox>.fromOpaque(userInfo).takeUnretainedValue()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                box.manager?.refreshDisplays()
            }
        }
    }

    func selectDisplay(_ id: CGDirectDisplayID) {
        self.selectedDisplayID = id
        refreshModes()
    }

    func refreshDisplays() {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            log.error("CGGetActiveDisplayList: нет активных дисплеев")
            return
        }
        var list = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &list, &count) == .success else {
            log.error("CGGetActiveDisplayList: ошибка получения списка")
            return
        }

        let devices: [DisplayDevice] = list.prefix(Int(count)).map { d in
            DisplayDevice(
                id: d,
                name: Self.displayName(for: d),
                isMain: CGDisplayIsMain(d) != 0,
                isBuiltin: CGDisplayIsBuiltin(d) != 0
            )
        }

        if devices != connectedDisplays {
            connectedDisplays = devices
        }

        // Если текущий выбранный экран больше не подключен, выбираем внешний или основной
        if !devices.contains(where: { $0.id == selectedDisplayID }) {
            let preferred = devices.first(where: { !$0.isBuiltin }) ?? devices.first(where: { $0.isMain }) ?? devices.first
            selectedDisplayID = preferred?.id ?? CGMainDisplayID()
        }

        refreshModes()
    }

    func refreshModes() {
        let currentID = CGSBridge.currentModeID(forDisplay: selectedDisplayID)
        let items = CGSBridge.allModes(forDisplay: selectedDisplayID) ?? []

        var modes: [ModeEntry] = []
        var seen = Set<ModeKey>()
        var current: ModeEntry?

        for it in items {
            let entry = ModeEntry(
                id: Int(it.modeID),
                width: Int(it.width),
                height: Int(it.height),
                freq: Int(it.freq),
                density: it.density,
                isHiDPI: it.isHiDPI
            )

            let key = ModeKey(width: entry.width, height: entry.height, freq: entry.freq, isHiDPI: entry.isHiDPI)
            if seen.insert(key).inserted {
                modes.append(entry)
            } else if entry.id == Int(currentID),
                      let idx = modes.firstIndex(where: {
                          ModeKey(width: $0.width, height: $0.height, freq: $0.freq, isHiDPI: $0.isHiDPI) == key
                      }) {
                modes[idx] = entry
            }
            if entry.id == Int(currentID) {
                current = entry
            }
        }

        modes.sort {
            if $0.isHiDPI != $1.isHiDPI { return $0.isHiDPI && !$1.isHiDPI }
            let a0 = $0.width * $0.height, a1 = $1.width * $1.height
            if a0 != a1 { return a0 > a1 }
            return $0.freq > $1.freq
        }

        availableModes = modes
        hidpiModes = modes.filter { $0.isHiDPI && $0.width >= 1280 }
        standardModes = modes.filter { !$0.isHiDPI && $0.width >= 1280 }
        // Всегда сбрасываем состояние, чтобы не оставалось данных от другого экрана
        currentMode = current
        isHiDPIActive = current?.isHiDPI ?? false
    }

    /// Мгновенное переключение HiDPI для текущего выбранного монитора
    func toggleHiDPI() {
        guard let current = currentMode,
              let match = Self.findToggleTarget(from: current, in: availableModes) else { return }
        setMode(match)
    }

    /// Чистая функция подбора режима (удобна для тестов).
    nonisolated static func findToggleTarget(from current: ModeEntry, in modes: [ModeEntry]) -> ModeEntry? {
        let target = !current.isHiDPI
        // 1. Та же геометрия и частота
        if let m = modes.first(where: {
            $0.width == current.width && $0.height == current.height &&
            $0.freq == current.freq && $0.isHiDPI == target
        }) { return m }
        // 2. Та же геометрия
        if let m = modes.first(where: {
            $0.width == current.width && $0.height == current.height && $0.isHiDPI == target
        }) { return m }
        // 3. Фолбэк: ближайший по площади режим нужного типа (а не самый большой)
        let area = current.width * current.height
        return modes
            .filter { $0.isHiDPI == target }
            .min { abs($0.width * $0.height - area) < abs($1.width * $1.height - area) }
    }

    func setMode(_ mode: ModeEntry) {
        if CGSBridge.setDisplayMode(Int32(mode.id), forDisplay: selectedDisplayID) {
            lastError = nil
            // Обновление состояния придёт через reconfiguration callback;
            // вызываем сразу, чтобы UI не ждал события.
            refreshModes()
        } else {
            lastError = "Не удалось переключить режим: \(mode.title)"
            log.error("setDisplayMode failed: \(mode.title)")
        }
    }

    private static func displayName(for displayID: CGDirectDisplayID) -> String {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
        if let name = screen?.localizedName, !name.isEmpty {
            return name
        }
        return CGDisplayIsBuiltin(displayID) != 0 ? "Built-in Display" : "External Display"
    }
}
