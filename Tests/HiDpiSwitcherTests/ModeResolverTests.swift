import CoreGraphics
import Foundation
import Testing
@testable import HiDpiSwitcher

@Suite("HiDpiSwitcher Domain, Store & Binary Layout Tests")
struct ModeResolverTests {

    @Test("Бинарная раскладка CGSModeRaw строго соответствует ABI SkyLight (0xD4 / 0xDC)")
    func verifyCGSModeRawMemoryLayout() {
        #expect(MemoryLayout<CGSModeRaw>.offset(of: \.mode) == 0)
        #expect(MemoryLayout<CGSModeRaw>.offset(of: \.flags) == 4)
        #expect(MemoryLayout<CGSModeRaw>.offset(of: \.width) == 8)
        #expect(MemoryLayout<CGSModeRaw>.offset(of: \.height) == 12)
        #expect(MemoryLayout<CGSModeRaw>.offset(of: \.depth) == 16)
        #expect(MemoryLayout<CGSModeRaw>.offset(of: \.dc3) == 188)
        #expect(MemoryLayout<CGSModeRaw>.offset(of: \.freq) == 190)
        #expect(MemoryLayout<CGSModeRaw>.offset(of: \.density) == 0xD0) // 208 байт
        #expect(MemoryLayout<CGSModeRaw>.size == CGSModeRaw.expectedBufferSize) // 0xDC (220 байт)
    }

    @Test("Дедупликация сохраняет режим с currentModeID при коллизии параметров")
    func deduplicationPreservesCurrentModeID() {
        let rawModes = [
            DisplayMode(id: 10, width: 1920, height: 1080, freq: 60, density: 2.0, isHiDPI: true),
            DisplayMode(id: 42, width: 1920, height: 1080, freq: 60, density: 2.0, isHiDPI: true),
            DisplayMode(id: 99, width: 1920, height: 1080, freq: 60, density: 1.0, isHiDPI: false)
        ]

        let catalog = ModeResolver.buildCatalog(rawModes: rawModes, currentModeID: 42)

        #expect(catalog.availableModes.count == 2)
        #expect(catalog.currentMode?.id == 42)
        #expect(catalog.hidpiModes.first?.id == 42)
    }

    @Test("Группировка по разрешениям схлопывает дубли 60/120/144Hz и выделяет список частот")
    func resolutionGroupingAndRefreshRates() {
        let rawModes = [
            DisplayMode(id: 1, width: 2560, height: 1440, freq: 144, density: 2.0, isHiDPI: true),
            DisplayMode(id: 2, width: 2560, height: 1440, freq: 120, density: 2.0, isHiDPI: true),
            DisplayMode(id: 3, width: 2560, height: 1440, freq: 60, density: 2.0, isHiDPI: true),
            DisplayMode(id: 4, width: 1920, height: 1080, freq: 144, density: 2.0, isHiDPI: true),
            DisplayMode(id: 5, width: 1920, height: 1080, freq: 120, density: 2.0, isHiDPI: true)
        ]

        let catalog = ModeResolver.buildCatalog(rawModes: rawModes, currentModeID: 2)

        #expect(catalog.hidpiModes.count == 2)
        #expect(catalog.hidpiModes[0].id == 2)
        #expect(catalog.hidpiModes[1].id == 5)
        #expect(catalog.availableRefreshRates.map(\.freq) == [144, 120, 60])
    }

    @Test("Частоты, которых нет у нативного сигнала панели, отбрасываются (иначе выводится обрезанная картинка)")
    func phantomRefreshRatesAreFilteredOut() {
        let rawModes = [
            DisplayMode(id: 1, width: 3440, height: 1440, freq: 100, density: 1.0, isHiDPI: false),
            DisplayMode(id: 2, width: 3440, height: 1440, freq: 60, density: 1.0, isHiDPI: false),
            DisplayMode(id: 3, width: 3440, height: 1440, freq: 100, density: 2.0, isHiDPI: true),
            DisplayMode(id: 4, width: 3440, height: 1440, freq: 75, density: 2.0, isHiDPI: true),
            DisplayMode(id: 5, width: 3440, height: 1440, freq: 60, density: 2.0, isHiDPI: true),
            DisplayMode(id: 6, width: 3440, height: 1440, freq: 56, density: 2.0, isHiDPI: true)
        ]

        let catalog = ModeResolver.buildCatalog(rawModes: rawModes, currentModeID: 3)

        #expect(catalog.availableRefreshRates.map(\.freq) == [100, 60])
        #expect(!catalog.availableModes.contains(where: { $0.freq == 75 || $0.freq == 56 }))
    }

    @Test("Вертикальные (портретные) мониторы 1080×1920 не отсекаются фильтром 1280px")
    func portraitDisplayModesAreIncluded() {
        let rawModes = [
            DisplayMode(id: 1, width: 1080, height: 1920, freq: 60, density: 2.0, isHiDPI: true),
            DisplayMode(id: 2, width: 1080, height: 1920, freq: 60, density: 1.0, isHiDPI: false),
            DisplayMode(id: 3, width: 800, height: 600, freq: 60, density: 1.0, isHiDPI: false)
        ]

        let catalog = ModeResolver.buildCatalog(rawModes: rawModes, currentModeID: 1)

        #expect(catalog.hidpiModes.count == 1)
        #expect(catalog.hidpiModes.first?.width == 1080)
        #expect(catalog.standardModes.count == 1)
        #expect(catalog.standardModes.first?.width == 1080)
    }

    @Test("Подбор режима: приоритет 1 — точное совпадение геометрии и частоты")
    func toggleTargetExactMatch() {
        let current = DisplayMode(id: 1, width: 2560, height: 1440, freq: 120, density: 1.0, isHiDPI: false)
        let modes = [
            current,
            DisplayMode(id: 2, width: 2560, height: 1440, freq: 60, density: 2.0, isHiDPI: true),
            DisplayMode(id: 3, width: 2560, height: 1440, freq: 120, density: 2.0, isHiDPI: true)
        ]

        let target = ModeResolver.findToggleTarget(from: current, in: modes)
        #expect(target?.id == 3)
    }

    @Test("Подбор режима: приоритет 3 — парный физический Retina 2x (3840×2160 1x -> 1920×1080 2x)")
    func toggleTargetScaledRetinaMatch() {
        let current = DisplayMode(id: 1, width: 3840, height: 2160, freq: 60, density: 1.0, isHiDPI: false)
        let modes = [
            current,
            DisplayMode(id: 2, width: 1920, height: 1080, freq: 60, density: 2.0, isHiDPI: true),
            DisplayMode(id: 3, width: 1600, height: 900, freq: 60, density: 2.0, isHiDPI: true)
        ]

        let target = ModeResolver.findToggleTarget(from: current, in: modes)
        #expect(target?.id == 2)
    }

    @Test("Генерация кастомных HiDPI разрешений и кодирование scale-resolutions для QHD и Ultrawide")
    func customHiDPISpecGenerationAndEncoding() {
        // 16:9 QHD (2560×1440)
        let qhd = CustomHiDPISpec.recommendedResolutions(nativeWidth: 2560, nativeHeight: 1440)
        #expect(qhd.contains(HiDPIResolutionPair(logicalWidth: 2560, logicalHeight: 1440)))
        #expect(qhd.contains(HiDPIResolutionPair(logicalWidth: 2048, logicalHeight: 1152)))
        #expect(qhd.contains(HiDPIResolutionPair(logicalWidth: 1920, logicalHeight: 1080)))

        // 21:9 Ultrawide (3440×1440)
        let ultrawide = CustomHiDPISpec.recommendedResolutions(nativeWidth: 3440, nativeHeight: 1440)
        #expect(ultrawide.contains(HiDPIResolutionPair(logicalWidth: 3440, logicalHeight: 1440)))
        #expect(ultrawide.contains(HiDPIResolutionPair(logicalWidth: 3008, logicalHeight: 1260)))
        #expect(ultrawide.contains(HiDPIResolutionPair(logicalWidth: 2560, logicalHeight: 1080)))

        // Проверка 16-байтной Big-Endian кодировки scale-resolutions
        let entry = CustomHiDPISpec.encodeScaleResolutionEntry(width: 5120, height: 2880)
        #expect(entry.count == 16)
        #expect(Array(entry.prefix(4)) == [0x00, 0x00, 0x14, 0x00]) // 5120 = 0x1400
        #expect(Array(entry[4..<8]) == [0x00, 0x00, 0x0B, 0x40])   // 2880 = 0x0B40

        // Проверка пути Override Plist
        let path = CustomHiDPISpec.overrideFilePath(vendorID: 0x1e6d, productID: 0x5b11)
        #expect(path.hasSuffix("/DisplayVendorID-1e6d/DisplayProductID-5b11"))
    }

    @Test("Виртуальный HiDPI-фреймбуфер (2K/Ultrawide) и системный Override переключаются через DisplayStore")
    @MainActor
    func virtualHiDPIAndSystemOverrideToggle() async {
        let mockClient = MockHardwareClient()
        let mockPrefs = MockPreferencesStore()
        let mockHotKeys = MockHotKeyService()
        let mockVirtual = MockVirtualHiDPIService()
        let mockOverride = MockOverrideInstaller()

        let store = DisplayStore(
            hardwareClient: mockClient,
            preferencesStore: mockPrefs,
            hotKeyService: mockHotKeys,
            virtualHiDPIService: mockVirtual,
            overrideInstaller: mockOverride,
            revertTimeoutSeconds: 0
        )

        #expect(store.isVirtualHiDPIActive == false)
        store.toggleVirtualHiDPI()
        #expect(store.isVirtualHiDPIActive == true)
        #expect(mockVirtual.activeIDs.contains(2))

        store.toggleVirtualHiDPI()
        #expect(store.isVirtualHiDPIActive == false)
        #expect(store.selectedDisplayID == 2)

        #expect(store.hasInstalledSystemOverride == false)
        await store.toggleSystemOverride()
        #expect(store.hasInstalledSystemOverride == true)
        await store.toggleSystemOverride()
        #expect(store.hasInstalledSystemOverride == false)
    }

    @Test("Таймер безопасного отката запускается для непроверенного режима и открывает/закрывает отдельный диалог")
    @MainActor
    func safetyRevertTimerConfirmAndRevert() {
        let mockClient = MockHardwareClient()
        let mockPrefs = MockPreferencesStore()
        let mockHotKeys = MockHotKeyService()
        let mockPresenter = MockRevertPresenter()
        let store = DisplayStore(
            hardwareClient: mockClient,
            preferencesStore: mockPrefs,
            hotKeyService: mockHotKeys,
            virtualHiDPIService: MockVirtualHiDPIService(),
            overrideInstaller: MockOverrideInstaller(),
            revertTimeoutSeconds: 10,
            revertPresenter: mockPresenter
        )

        #expect(store.currentMode?.id == 10)
        #expect(store.pendingRevertSeconds == nil)
        #expect(mockPresenter.showCallCount == 0)
        #expect(mockPresenter.dismissCallCount == 0)

        // Переключаем на непроверенный режим — должен показаться диалог
        store.toggleHiDPI()
        #expect(store.currentMode?.id == 20)
        #expect(store.pendingRevertSeconds == 10)
        #expect(store.previousSafeMode?.id == 10)
        #expect(mockPresenter.showCallCount == 1)
        #expect(mockPresenter.dismissCallCount == 0)

        // Откат по хоткею — диалог закрывается
        mockHotKeys.onAction?(.toggleHiDPIOrRevert)
        #expect(store.currentMode?.id == 10)
        #expect(store.pendingRevertSeconds == nil)
        #expect(mockPresenter.dismissCallCount == 1)

        // Снова переключаем — диалог открывается второй раз
        store.toggleHiDPI()
        #expect(store.pendingRevertSeconds == 10)
        #expect(mockPresenter.showCallCount == 2)

        // Подтверждение через диалог — режим сохраняется, диалог закрывается
        store.confirmPendingMode()
        #expect(store.pendingRevertSeconds == nil)
        #expect(mockPresenter.dismissCallCount == 2)

        // Теперь режим проверен — переключение обратно и снова на него не вызывает показ диалога
        store.toggleHiDPI()
        #expect(store.currentMode?.id == 10)
        #expect(store.pendingRevertSeconds == nil)
        #expect(mockPresenter.showCallCount == 2)

        store.toggleHiDPI()
        #expect(store.currentMode?.id == 20)
        #expect(store.pendingRevertSeconds == nil)
        #expect(mockPresenter.showCallCount == 2)
    }

    @Test("Переключение частоты обновления строго сохраняет геометрию и признак HiDPI")
    @MainActor
    func setRefreshRatePreservesGeometryAndHiDPI() {
        let mockClient = MockHardwareClient()
        let mockPrefs = MockPreferencesStore()
        let store = DisplayStore(
            hardwareClient: mockClient,
            preferencesStore: mockPrefs,
            hotKeyService: MockHotKeyService(),
            virtualHiDPIService: MockVirtualHiDPIService(),
            overrideInstaller: MockOverrideInstaller(),
            revertTimeoutSeconds: 0
        )

        #expect(store.currentMode?.id == 10)
        #expect(store.currentMode?.width == 1920)
        #expect(store.currentMode?.height == 1080)
        #expect(store.currentMode?.freq == 60)
        #expect(store.isHiDPIActive == false)

        // Переключаем частоту на 120Hz для текущего 1920x1080 Low-Res
        store.setRefreshRate(120)
        #expect(store.currentMode?.id == 11)
        #expect(store.currentMode?.width == 1920)
        #expect(store.currentMode?.height == 1080)
        #expect(store.currentMode?.freq == 120)
        #expect(store.isHiDPIActive == false)

        // Переключаемся в HiDPI (20: 1920x1080 @ 60Hz)
        store.setMode(DisplayMode(id: 20, width: 1920, height: 1080, freq: 60, density: 2.0, isHiDPI: true))
        #expect(store.currentMode?.id == 20)
        #expect(store.isHiDPIActive == true)

        // Переключаем частоту в HiDPI на 120Hz
        store.setRefreshRate(120)
        #expect(store.currentMode?.id == 21)
        #expect(store.currentMode?.width == 1920)
        #expect(store.currentMode?.height == 1080)
        #expect(store.currentMode?.freq == 120)
        #expect(store.isHiDPIActive == true)
    }

    @Test("При alwaysConfirmModeChanges диалог подтверждения появляется при любом переключении частоты или разрешения")
    @MainActor
    func alwaysConfirmModeChangesShowsDialogEveryTime() {
        let mockClient = MockHardwareClient()
        let mockPrefs = MockPreferencesStore()
        mockPrefs.alwaysConfirmModeChanges = true
        let mockPresenter = MockRevertPresenter()
        let store = DisplayStore(
            hardwareClient: mockClient,
            preferencesStore: mockPrefs,
            hotKeyService: MockHotKeyService(),
            virtualHiDPIService: MockVirtualHiDPIService(),
            overrideInstaller: MockOverrideInstaller(),
            revertTimeoutSeconds: 10,
            revertPresenter: mockPresenter
        )

        #expect(mockPresenter.showCallCount == 0)

        // 1. Переключение частоты
        store.setRefreshRate(120)
        #expect(store.currentMode?.freq == 120)
        #expect(store.pendingRevertSeconds == 10)
        #expect(mockPresenter.showCallCount == 1)

        // Подтверждаем
        store.confirmPendingMode()
        #expect(store.pendingRevertSeconds == nil)
        #expect(mockPresenter.dismissCallCount == 1)

        // 2. Переключение обратно на 60Hz — снова выводится диалог
        store.setRefreshRate(60)
        #expect(store.currentMode?.freq == 60)
        #expect(store.pendingRevertSeconds == 10)
        #expect(mockPresenter.showCallCount == 2)

        // Откатываем через revertPendingMode
        store.revertPendingMode()
        #expect(store.currentMode?.freq == 120)
        #expect(store.pendingRevertSeconds == nil)
        #expect(mockPresenter.dismissCallCount == 2)

        // 3. Переключение разрешения в HiDPI
        store.toggleHiDPI()
        #expect(store.isHiDPIActive == true)
        #expect(store.pendingRevertSeconds == 10)
        #expect(mockPresenter.showCallCount == 3)

        store.confirmPendingMode()
        #expect(mockPresenter.dismissCallCount == 3)
    }

    @Test("Избранные пресеты и циклическое переключение по хоткею ⌃⌥⌘F")
    @MainActor
    func favoriteModesAndCycling() {
        let mockClient = MockHardwareClient()
        let mockPrefs = MockPreferencesStore()
        let mockHotKeys = MockHotKeyService()
        let store = DisplayStore(
            hardwareClient: mockClient,
            preferencesStore: mockPrefs,
            hotKeyService: mockHotKeys,
            virtualHiDPIService: MockVirtualHiDPIService(),
            overrideInstaller: MockOverrideInstaller(),
            revertTimeoutSeconds: 0
        )

        store.toggleCurrentModeFavorite()
        #expect(store.isCurrentModeFavorite == true)
        #expect(store.favoriteModes.map(\.id) == [10])

        store.toggleHiDPI()
        store.toggleCurrentModeFavorite()
        #expect(store.favoriteModes.map(\.id) == [10, 20])

        mockHotKeys.onAction?(.cycleFavorites)
        #expect(store.currentMode?.id == 10)
        mockHotKeys.onAction?(.cycleFavorites)
        #expect(store.currentMode?.id == 20)
    }

    @Test("Автовосстановление сохранённого режима при старте приложения")
    @MainActor
    func autoRestoreSavedModeOnLaunch() {
        let mockClient = MockHardwareClient()
        let mockPrefs = MockPreferencesStore()
        let mockHotKeys = MockHotKeyService()

        let externalDevice = DisplayDevice(id: 2, name: "LG UltraFine 4K", isMain: true, isBuiltin: false)
        mockPrefs.setPreferredModeKey(
            ModeKey(width: 1920, height: 1080, freq: 60, isHiDPI: true),
            for: externalDevice
        )

        let store = DisplayStore(
            hardwareClient: mockClient,
            preferencesStore: mockPrefs,
            hotKeyService: mockHotKeys,
            virtualHiDPIService: MockVirtualHiDPIService(),
            overrideInstaller: MockOverrideInstaller(),
            revertTimeoutSeconds: 10
        )

        #expect(store.currentMode?.id == 20)
        #expect(store.isHiDPIActive == true)
        #expect(store.pendingRevertSeconds == nil)
    }

    @Test("Кэширование сырых режимов устраняет повторные вызовы allModes при переключении режима и фильтра")
    @MainActor
    func rawModesCacheAvoidsRedundantHardwareQueries() {
        let mockClient = MockHardwareClient()
        let store = DisplayStore(
            hardwareClient: mockClient,
            preferencesStore: MockPreferencesStore(),
            hotKeyService: MockHotKeyService(),
            virtualHiDPIService: MockVirtualHiDPIService(),
            overrideInstaller: MockOverrideInstaller(),
            revertTimeoutSeconds: 0
        )

        let initialCalls = mockClient.allModesCallCount
        #expect(initialCalls == 1)

        // Переключение режима и фильтра использует закэшированный список сырых режимов
        store.toggleHiDPI()
        store.setRefreshRate(120)
        store.showAllResolutions = true
        #expect(mockClient.allModesCallCount == initialCalls)

        // Полное обновление списка экранов сбрасывает кэш
        store.refreshDisplays()
        #expect(mockClient.allModesCallCount == initialCalls + 1)
    }
}

// MARK: - Тестовые дублёры (Mocks)

@MainActor
private final class MockHardwareClient: DisplayHardwareClientProtocol {
    var currentID: Int = 10
    var lastAppliedModeID: Int?
    var allModesCallCount: Int = 0

    func activeDisplays() -> [DisplayDevice] {
        [
            DisplayDevice(id: 1, name: "Built-in Retina", isMain: false, isBuiltin: true),
            DisplayDevice(id: 2, name: "LG UltraFine 4K", isMain: true, isBuiltin: false)
        ]
    }

    func currentModeID(for displayID: CGDirectDisplayID) -> Int {
        currentID
    }

    func allModes(for displayID: CGDirectDisplayID) -> [DisplayMode] {
        allModesCallCount += 1
        return [
            DisplayMode(id: 10, width: 1920, height: 1080, freq: 60, density: 1.0, isHiDPI: false),
            DisplayMode(id: 11, width: 1920, height: 1080, freq: 120, density: 1.0, isHiDPI: false),
            DisplayMode(id: 20, width: 1920, height: 1080, freq: 60, density: 2.0, isHiDPI: true),
            DisplayMode(id: 21, width: 1920, height: 1080, freq: 120, density: 2.0, isHiDPI: true)
        ]
    }

    func setDisplayMode(_ modeID: Int, for displayID: CGDirectDisplayID) -> Bool {
        currentID = modeID
        lastAppliedModeID = modeID
        return true
    }

    func reconfigurationEvents() -> AsyncStream<Void> {
        AsyncStream { _ in }
    }
}

@MainActor
private final class MockPreferencesStore: DisplayPreferencesStoreProtocol {
    var preferredDisplayID: CGDirectDisplayID? = 2
    var autoRestoreSavedMode: Bool = true
    var globalHotKeysEnabled: Bool = true
    var showAllResolutions: Bool = false
    var alwaysConfirmModeChanges: Bool = false

    private var preferredModes: [String: ModeKey] = [:]
    private var favoriteModes: [String: [ModeKey]] = [:]
    private var verifiedModes: [String: Set<ModeKey>] = [:]

    func preferredModeKey(for display: DisplayDevice) -> ModeKey? {
        preferredModes[display.persistentIdentifier]
    }

    func setPreferredModeKey(_ key: ModeKey?, for display: DisplayDevice) {
        preferredModes[display.persistentIdentifier] = key
    }

    func favoriteModeKeys(for display: DisplayDevice) -> [ModeKey] {
        favoriteModes[display.persistentIdentifier] ?? []
    }

    func setFavoriteModeKeys(_ keys: [ModeKey], for display: DisplayDevice) {
        favoriteModes[display.persistentIdentifier] = keys
    }

    func verifiedModeKeys(for display: DisplayDevice) -> Set<ModeKey> {
        verifiedModes[display.persistentIdentifier] ?? []
    }

    func addVerifiedModeKey(_ key: ModeKey, for display: DisplayDevice) {
        var set = verifiedModes[display.persistentIdentifier] ?? []
        set.insert(key)
        verifiedModes[display.persistentIdentifier] = set
    }
}

@MainActor
private final class MockHotKeyService: GlobalHotKeyServiceProtocol {
    var onAction: (@MainActor (HotKeyAction) -> Void)?
    var isEnabled: Bool = false

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }
}

@MainActor
private final class MockVirtualHiDPIService: VirtualHiDPIServiceProtocol {
    var activeIDs: Set<CGDirectDisplayID> = []

    func isVirtualHiDPIActive(for physicalDisplayID: CGDirectDisplayID) -> Bool {
        activeIDs.contains(physicalDisplayID)
    }

    func virtualDisplayID(for physicalDisplayID: CGDirectDisplayID) -> CGDirectDisplayID? {
        activeIDs.contains(physicalDisplayID) ? physicalDisplayID : nil
    }

    func enableVirtualHiDPI(
        for device: DisplayDevice,
        nativeWidth: Int,
        nativeHeight: Int,
        refreshRate: Double
    ) -> CGDirectDisplayID? {
        activeIDs.insert(device.id)
        return device.id
    }

    @discardableResult
    func disableVirtualHiDPI(for physicalDisplayID: CGDirectDisplayID) -> CGDirectDisplayID? {
        guard activeIDs.remove(physicalDisplayID) != nil else { return nil }
        return physicalDisplayID
    }

    func disableAll() {
        activeIDs.removeAll()
    }
}

@MainActor
private final class MockOverrideInstaller: DisplayOverrideInstallerProtocol {
    var installed: Set<String> = []

    func isOverrideInstalled(for device: DisplayDevice) -> Bool {
        installed.contains(device.persistentIdentifier)
    }

    func installOverride(for device: DisplayDevice, nativeWidth: Int, nativeHeight: Int) async throws {
        installed.insert(device.persistentIdentifier)
    }

    func removeOverride(for device: DisplayDevice) async throws {
        installed.remove(device.persistentIdentifier)
    }
}

@MainActor
private final class MockRevertPresenter: RevertDialogPresenter {
    var showCallCount = 0
    var dismissCallCount = 0

    func showRevertDialog(store: DisplayStore) {
        showCallCount += 1
    }

    func dismissRevertDialog() {
        dismissCallCount += 1
    }
}
