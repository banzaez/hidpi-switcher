import Foundation
import CoreGraphics

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

final class DisplayManager: ObservableObject {
    @Published var connectedDisplays: [DisplayDevice] = []
    @Published var selectedDisplayID: CGDirectDisplayID = CGMainDisplayID()
    @Published var availableModes: [ModeEntry] = []
    @Published var currentMode: ModeEntry?
    @Published var isHiDPIActive: Bool = false

    private var reconfigCallbackRegistered = false

    init() {
        registerReconfigCallback()
        refreshDisplays()
    }

    deinit {
        if reconfigCallbackRegistered {
            CGDisplayRemoveReconfigurationCallback(DisplayManager.reconfigCallback, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    private func registerReconfigCallback() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let err = CGDisplayRegisterReconfigurationCallback(DisplayManager.reconfigCallback, context)
        if err == .success {
            reconfigCallbackRegistered = true
        }
    }

    private static let reconfigCallback: @convention(c) (CGDirectDisplayID, CGDisplayChangeSummaryFlags, UnsafeMutableRawPointer?) -> Void = { (display, flags, userInfo) in
        guard let userInfo = userInfo else { return }
        if !flags.contains(.beginConfigurationFlag) {
            let manager = Unmanaged<DisplayManager>.fromOpaque(userInfo).takeUnretainedValue()
            DispatchQueue.main.async {
                manager.refreshDisplays()
            }
        }
    }

    func selectDisplay(_ id: CGDirectDisplayID) {
        self.selectedDisplayID = id
        refreshModes()
    }

    func refreshDisplays() {
        var count: UInt32 = 0
        var list = [CGDirectDisplayID](repeating: 0, count: 16)
        CGGetActiveDisplayList(16, &list, &count)

        var devices: [DisplayDevice] = []
        for i in 0..<Int(count) {
            let d = list[i]
            let isMain = CGDisplayIsMain(d) != 0
            let isBuiltin = CGDisplayIsBuiltin(d) != 0
            let name = getDisplayName(d)

            devices.append(DisplayDevice(
                id: d,
                name: name,
                isMain: isMain,
                isBuiltin: isBuiltin
            ))
        }

        self.connectedDisplays = devices

        // Если текущий выбранный экран больше не подключен, выбираем внешний или основной
        if !devices.contains(where: { $0.id == selectedDisplayID }) {
            let preferred = devices.first(where: { !$0.isBuiltin }) ?? devices.first(where: { $0.isMain }) ?? devices.first
            self.selectedDisplayID = preferred?.id ?? CGMainDisplayID()
        }

        refreshModes()
    }

    func refreshModes() {
        let currentID = CGSBridge.currentModeID(forDisplay: selectedDisplayID)
        guard let items = CGSBridge.allModes(forDisplay: selectedDisplayID) else { return }

        var modes: [ModeEntry] = []
        var seen = Set<String>()

        for it in items {
            let w = Int(it.width)
            let h = Int(it.height)
            let f = Int(it.freq)
            let isHi = it.isHiDPI

            let entry = ModeEntry(
                id: Int(it.modeID),
                width: w,
                height: h,
                freq: f,
                density: it.density,
                isHiDPI: isHi
            )

            let key = "\(w)x\(h)@\(f)-\(isHi)"
            if !seen.contains(key) {
                seen.insert(key)
                modes.append(entry)
            }

            if Int(it.modeID) == currentID {
                self.currentMode = entry
                self.isHiDPIActive = isHi
            }
        }

        self.availableModes = modes.sorted {
            if $0.isHiDPI != $1.isHiDPI { return $0.isHiDPI && !$1.isHiDPI }
            if ($0.width * $0.height) != ($1.width * $1.height) {
                return ($0.width * $0.height) > ($1.width * $1.height)
            }
            return $0.freq > $1.freq
        }
    }

    /// Мгновенное переключение HiDPI для текущего выбранного монитора
    func toggleHiDPI() {
        guard let current = currentMode else { return }
        let targetHiDPI = !current.isHiDPI

        // 1. Поиск режима с той же геометрией и частотой
        let exactMatch = availableModes.first {
            $0.width == current.width &&
            $0.height == current.height &&
            $0.freq == current.freq &&
            $0.isHiDPI == targetHiDPI
        }

        if let match = exactMatch {
            setMode(match)
            return
        }

        // 2. Поиск по ширине и высоте
        let resolutionMatch = availableModes.first {
            $0.width == current.width &&
            $0.height == current.height &&
            $0.isHiDPI == targetHiDPI
        }

        if let match = resolutionMatch {
            setMode(match)
            return
        }

        // 3. Фолбэк
        if let fallback = availableModes.first(where: { $0.isHiDPI == targetHiDPI }) {
            setMode(fallback)
        }
    }

    func setMode(_ mode: ModeEntry) {
        if CGSBridge.setDisplayMode(Int32(mode.id), forDisplay: selectedDisplayID) {
            self.currentMode = mode
            self.isHiDPIActive = mode.isHiDPI
            refreshModes()
        }
    }

    private func getDisplayName(_ displayID: CGDirectDisplayID) -> String {
        if CGDisplayIsBuiltin(displayID) != 0 {
            return "Built-in Display"
        }
        let vendor = CGDisplayVendorNumber(displayID)
        let model = CGDisplayModelNumber(displayID)

        switch vendor {
        case 19501: // 0x4C2D Samsung
            if model == 3621 { return "Samsung C34H89x" }
            return "Samsung Display"
        case 4268: // 0x10AC Dell
            return "Dell Display"
        case 7789: // 0x1E6D LG
            return "LG Display"
        case 1552: // Apple
            return "Apple Display"
        default:
            return "External Display"
        }
    }
}
