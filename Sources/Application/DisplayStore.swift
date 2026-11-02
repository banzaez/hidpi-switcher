import AppKit
import CoreGraphics
import Foundation
import Observation
import os

private let log = Logger(subsystem: "com.local.HiDpiSwitcher", category: "DisplayStore")

/// Презентер системного диалогового окна подтверждения смены режима.
@MainActor
public protocol RevertDialogPresenter: AnyObject {
    func showRevertDialog(store: DisplayStore)
    func dismissRevertDialog()
}

/// Реактивное хранилище состояния дисплеев, частот, избранных пресетов, виртуального 2K/Ultrawide HiDPI и безопасного отката (Swift 6 / 2026).
@Observable
@MainActor
public final class DisplayStore {
    public private(set) var connectedDisplays: [DisplayDevice] = []
    public private(set) var selectedDisplayID: CGDirectDisplayID
    public private(set) var availableModes: [DisplayMode] = []
    public private(set) var hidpiModes: [DisplayMode] = []
    public private(set) var standardModes: [DisplayMode] = []
    public private(set) var availableRefreshRates: [DisplayMode] = []
    public private(set) var favoriteModes: [DisplayMode] = []
    public private(set) var currentMode: DisplayMode?
    public private(set) var isHiDPIActive: Bool = false
    public private(set) var isVirtualHiDPIActive: Bool = false
    public private(set) var hasInstalledSystemOverride: Bool = false
    public private(set) var isInstallingOverride: Bool = false

    /// Оставшееся время (в секундах) до автоматического отката непроверенного видеорежима.
    public private(set) var pendingRevertSeconds: Int?
    public private(set) var previousSafeMode: DisplayMode?
    public let revertTimeoutSeconds: Int

    @ObservationIgnored
    public var revertPresenter: (any RevertDialogPresenter)?

    public var autoRestoreSavedMode: Bool {
        didSet {
            preferencesStore.autoRestoreSavedMode = autoRestoreSavedMode
        }
    }

    public var globalHotKeysEnabled: Bool {
        didSet {
            preferencesStore.globalHotKeysEnabled = globalHotKeysEnabled
            hotKeyService.setEnabled(globalHotKeysEnabled)
        }
    }

    public var showAllResolutions: Bool {
        didSet {
            preferencesStore.showAllResolutions = showAllResolutions
            refreshModes()
        }
    }

    public var alwaysConfirmModeChanges: Bool {
        didSet {
            preferencesStore.alwaysConfirmModeChanges = alwaysConfirmModeChanges
        }
    }

    public var lastError: String?
    public var statusMessage: String?

    public var selectedDevice: DisplayDevice? {
        connectedDisplays.first(where: { $0.id == selectedDisplayID })
    }

    public var isCurrentModeFavorite: Bool {
        guard let currentMode else { return false }
        let key = ModeKey(mode: currentMode)
        return favoriteModes.contains { ModeKey(mode: $0) == key }
    }

    @ObservationIgnored
    private let hardwareClient: DisplayHardwareClientProtocol
    @ObservationIgnored
    private let preferencesStore: DisplayPreferencesStoreProtocol
    @ObservationIgnored
    private let hotKeyService: GlobalHotKeyServiceProtocol
    @ObservationIgnored
    private let virtualHiDPIService: VirtualHiDPIServiceProtocol
    @ObservationIgnored
    private let overrideInstaller: DisplayOverrideInstallerProtocol
    @ObservationIgnored
    private var monitorTask: Task<Void, Never>?
    @ObservationIgnored
    private var debounceTask: Task<Void, Never>?
    @ObservationIgnored
    private var revertTimerTask: Task<Void, Never>?
    @ObservationIgnored
    private var restoredDisplayIDs: Set<String> = []
    /// Частота, явно выбранная пользователем; применяется при смене разрешения, если она доступна.
    @ObservationIgnored
    private var preferredRefreshRate: Int?
    /// Кэш сырых видеорежимов текущего монитора для устранения повторных CGS-вызовов при переключении режима/фильтра.
    @ObservationIgnored
    private var cachedRawModes: (displayID: CGDirectDisplayID, modes: [DisplayMode])?

    public init(
        hardwareClient: DisplayHardwareClientProtocol = LiveDisplayHardwareClient(),
        preferencesStore: DisplayPreferencesStoreProtocol = UserDefaultsDisplayPreferencesStore(),
        hotKeyService: GlobalHotKeyServiceProtocol = CarbonGlobalHotKeyService(),
        virtualHiDPIService: VirtualHiDPIServiceProtocol = LiveVirtualHiDPIService(),
        overrideInstaller: DisplayOverrideInstallerProtocol = SystemDisplayOverrideInstaller(),
        revertTimeoutSeconds: Int = 10,
        revertPresenter: (any RevertDialogPresenter)? = nil
    ) {
        self.hardwareClient = hardwareClient
        self.preferencesStore = preferencesStore
        self.hotKeyService = hotKeyService
        self.virtualHiDPIService = virtualHiDPIService
        self.overrideInstaller = overrideInstaller
        self.revertTimeoutSeconds = revertTimeoutSeconds
        self.revertPresenter = revertPresenter
        self.selectedDisplayID = preferencesStore.preferredDisplayID ?? CGMainDisplayID()
        self.autoRestoreSavedMode = preferencesStore.autoRestoreSavedMode
        self.globalHotKeysEnabled = preferencesStore.globalHotKeysEnabled
        self.showAllResolutions = preferencesStore.showAllResolutions
        self.alwaysConfirmModeChanges = preferencesStore.alwaysConfirmModeChanges

        setupHotKeys()
        refreshDisplays()
        startMonitoringReconfiguration()
    }

    deinit {
        monitorTask?.cancel()
        debounceTask?.cancel()
        revertTimerTask?.cancel()
    }

    private func setupHotKeys() {
        hotKeyService.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .toggleHiDPIOrRevert:
                if self.pendingRevertSeconds != nil {
                    self.revertPendingMode()
                } else {
                    self.toggleHiDPI()
                }
            case .cycleFavorites:
                self.cycleFavoriteModes()
            }
        }
        hotKeyService.setEnabled(globalHotKeysEnabled)
    }

    private func startMonitoringReconfiguration() {
        let events = hardwareClient.reconfigurationEvents()
        monitorTask = Task { [weak self] in
            for await _ in events {
                guard !Task.isCancelled, let self else { break }
                self.scheduleDebouncedRefresh()
            }
        }
    }

    /// Коалесценция множественных системных уведомлений CoreGraphics в единое обновление UI.
    private func scheduleDebouncedRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled, let self else { return }
            self.refreshDisplays()
        }
    }

    public func selectDisplay(_ id: CGDirectDisplayID) {
        guard selectedDisplayID != id else { return }
        cancelRevertTimer(confirm: true)
        preferredRefreshRate = nil
        cachedRawModes = nil
        selectedDisplayID = id
        preferencesStore.preferredDisplayID = id
        lastError = nil
        statusMessage = nil
        refreshModes()
    }

    public func refreshDisplays() {
        let devices = hardwareClient.activeDisplays()
        guard !devices.isEmpty else { return }

        let activePersistentIDs = Set(devices.map(\.persistentIdentifier))
        restoredDisplayIDs.formIntersection(activePersistentIDs)

        if devices != connectedDisplays {
            connectedDisplays = devices
        }

        if !devices.contains(where: { $0.id == selectedDisplayID }) {
            let savedID = preferencesStore.preferredDisplayID
            let preferred = devices.first(where: { $0.id == savedID })
                ?? devices.first(where: { !$0.isBuiltin })
                ?? devices.first(where: { $0.isMain })
                ?? devices.first
            if let newID = preferred?.id {
                selectedDisplayID = newID
            }
        }

        refreshModes(invalidateCache: true)
        restoreSavedModesIfNeeded(for: devices)
    }

    public func refreshModes(invalidateCache: Bool = false) {
        if invalidateCache {
            cachedRawModes = nil
        }
        let currentID = hardwareClient.currentModeID(for: selectedDisplayID)
        let rawModes: [DisplayMode]
        if let cached = cachedRawModes, cached.displayID == selectedDisplayID {
            rawModes = cached.modes
        } else {
            let fetched = hardwareClient.allModes(for: selectedDisplayID)
            cachedRawModes = (selectedDisplayID, fetched)
            rawModes = fetched
        }
        let minEdge = showAllResolutions ? 0 : ModeResolver.defaultMinimumLongEdge

        let catalog = ModeResolver.buildCatalog(
            rawModes: rawModes,
            currentModeID: currentID,
            minimumLongEdge: minEdge,
            preferredFrequency: preferredRefreshRate
        )
        if preferredRefreshRate == nil {
            preferredRefreshRate = catalog.currentMode?.freq
        }

        if availableModes != catalog.availableModes {
            availableModes = catalog.availableModes
        }
        if hidpiModes != catalog.hidpiModes {
            hidpiModes = catalog.hidpiModes
        }
        if standardModes != catalog.standardModes {
            standardModes = catalog.standardModes
        }
        if availableRefreshRates != catalog.availableRefreshRates {
            availableRefreshRates = catalog.availableRefreshRates
        }
        if currentMode != catalog.currentMode {
            currentMode = catalog.currentMode
        }
        let active = catalog.currentMode?.isHiDPI ?? false
        if isHiDPIActive != active {
            isHiDPIActive = active
        }

        isVirtualHiDPIActive = virtualHiDPIService.isVirtualHiDPIActive(for: selectedDisplayID)
        if let device = selectedDevice {
            hasInstalledSystemOverride = overrideInstaller.isOverrideInstalled(for: device)
        } else {
            hasInstalledSystemOverride = false
        }

        if pendingRevertSeconds == nil,
           let current = catalog.currentMode,
           let device = selectedDevice {
            preferencesStore.addVerifiedModeKey(ModeKey(mode: current), for: device)
        }

        refreshFavoritesList()
    }

    private func refreshFavoritesList() {
        guard let device = selectedDevice else {
            favoriteModes = []
            return
        }
        let favKeys = preferencesStore.favoriteModeKeys(for: device)
        let resolved = favKeys.compactMap { ModeResolver.findMode(matching: $0, in: availableModes) }
        if favoriteModes != resolved {
            favoriteModes = resolved
        }
    }

    /// Автоматическое применение сохранённого режима при старте приложения или подключении монитора.
    private func restoreSavedModesIfNeeded(for devices: [DisplayDevice]) {
        guard autoRestoreSavedMode, pendingRevertSeconds == nil else { return }

        for device in devices {
            let pid = device.persistentIdentifier
            guard !restoredDisplayIDs.contains(pid) else { continue }
            restoredDisplayIDs.insert(pid)

            guard let savedKey = preferencesStore.preferredModeKey(for: device) else { continue }
            let modes = device.id == selectedDisplayID
                ? availableModes
                : ModeResolver.buildCatalog(
                    rawModes: hardwareClient.allModes(for: device.id),
                    currentModeID: hardwareClient.currentModeID(for: device.id),
                    minimumLongEdge: 0
                ).availableModes

            guard let targetMode = ModeResolver.findMode(matching: savedKey, in: modes) else { continue }
            let currentID = hardwareClient.currentModeID(for: device.id)
            guard targetMode.id != currentID else { continue }

            if hardwareClient.setDisplayMode(targetMode.id, for: device.id) {
                preferencesStore.addVerifiedModeKey(ModeKey(mode: targetMode), for: device)
                if device.id == selectedDisplayID {
                    refreshModes()
                }
            }
        }
    }

    // MARK: - Переключение режимов и безопасный откат (Revert Timer)

    public func toggleHiDPI() {
        guard let current = currentMode,
              let target = ModeResolver.findToggleTarget(from: current, in: availableModes) else {
            return
        }
        setMode(target)
    }

    /// Переключает частоту обновления (Hz) строго для ТЕКУЩЕГО разрешения и типа (HiDPI / Low-Res).
    public func setRefreshRate(_ targetFreq: Int) {
        guard let current = currentMode else { return }
        guard current.freq != targetFreq else { return }

        // Ищем режим строго с такой же геометрией и плотностью (HiDPI / 1x)
        guard let targetMode = availableModes.first(where: {
            $0.width == current.width &&
            $0.height == current.height &&
            $0.isHiDPI == current.isHiDPI &&
            $0.freq == targetFreq
        }) else {
            lastError = "Частота \(targetFreq) Hz недоступна для разрешения \(current.width)×\(current.height)"
            log.error("setRefreshRate: frequency \(targetFreq)Hz not found for \(current.width)x\(current.height) (HiDPI: \(current.isHiDPI))")
            return
        }

        preferredRefreshRate = targetFreq
        setMode(targetMode)
    }

    /// Применяет избранный пресет; его частота становится предпочтительной.
    public func selectFavorite(_ mode: DisplayMode) {
        preferredRefreshRate = mode.freq
        setMode(mode)
    }

    public func setMode(_ mode: DisplayMode) {
        guard mode.id != currentMode?.id else { return }
        let previous = currentMode

        guard hardwareClient.setDisplayMode(mode.id, for: selectedDisplayID) else {
            lastError = "Не удалось применить режим \(mode.width)×\(mode.height)"
            log.error("setDisplayMode failed for mode ID \(mode.id) (\(mode.width)x\(mode.height))")
            return
        }

        lastError = nil
        statusMessage = nil
        currentMode = mode
        isHiDPIActive = mode.isHiDPI

        if let device = selectedDevice {
            let modeKey = ModeKey(mode: mode)
            let isVerified = preferencesStore.verifiedModeKeys(for: device).contains(modeKey)
            let shouldConfirm = alwaysConfirmModeChanges || !isVerified

            if shouldConfirm && revertTimeoutSeconds > 0, let previous {
                startRevertTimer(from: previous, to: mode, on: device)
            } else {
                cancelRevertTimer(confirm: false)
                preferencesStore.setPreferredModeKey(modeKey, for: device)
                preferencesStore.addVerifiedModeKey(modeKey, for: device)
            }
        }

        refreshModes()
    }

    public func confirmPendingMode() {
        cancelRevertTimer(confirm: true)
    }

    public func revertPendingMode() {
        guard let safeMode = previousSafeMode else {
            cancelRevertTimer(confirm: false)
            return
        }
        cancelRevertTimer(confirm: false)
        preferredRefreshRate = safeMode.freq
        _ = hardwareClient.setDisplayMode(safeMode.id, for: selectedDisplayID)
        refreshModes()
    }

    private func startRevertTimer(from safeMode: DisplayMode, to newMode: DisplayMode, on device: DisplayDevice) {
        revertTimerTask?.cancel()
        if previousSafeMode == nil {
            previousSafeMode = safeMode
        }
        pendingRevertSeconds = revertTimeoutSeconds
        revertPresenter?.showRevertDialog(store: self)

        let seconds = revertTimeoutSeconds
        revertTimerTask = Task { [weak self] in
            for remaining in stride(from: seconds - 1, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                if remaining > 0 {
                    self.pendingRevertSeconds = remaining
                } else {
                    log.notice("Таймер подтверждения истёк, откат к режиму \(safeMode.width)x\(safeMode.height)")
                    self.revertPendingMode()
                }
            }
        }
    }

    private func cancelRevertTimer(confirm: Bool) {
        revertTimerTask?.cancel()
        revertTimerTask = nil
        if confirm, let currentMode, let device = selectedDevice {
            let key = ModeKey(mode: currentMode)
            preferencesStore.addVerifiedModeKey(key, for: device)
            preferencesStore.setPreferredModeKey(key, for: device)
        }
        pendingRevertSeconds = nil
        previousSafeMode = nil
        revertPresenter?.dismissRevertDialog()
    }

    // MARK: - Избранные пресеты (Favorites)

    public func toggleCurrentModeFavorite() {
        guard let currentMode, let device = selectedDevice else { return }
        let key = ModeKey(mode: currentMode)
        var keys = preferencesStore.favoriteModeKeys(for: device)
        if let idx = keys.firstIndex(of: key) {
            keys.remove(at: idx)
        } else {
            keys.append(key)
            preferencesStore.addVerifiedModeKey(key, for: device)
        }
        preferencesStore.setFavoriteModeKeys(keys, for: device)
        refreshFavoritesList()
    }

    public func cycleFavoriteModes() {
        guard let device = selectedDevice else { return }
        let favKeys = preferencesStore.favoriteModeKeys(for: device)
        guard let next = ModeResolver.nextFavoriteMode(from: currentMode, favorites: favKeys, in: availableModes) else {
            return
        }
        selectFavorite(next)
    }

    // MARK: - Разблокировка 2K / QHD (2560×1440) и Ultrawide (3440×1440) на Apple Silicon

    /// Определяет нативное физическое разрешение выбранного монитора.
    private func nativeResolutionForSelectedDisplay() -> (width: Int, height: Int, freq: Double) {
        let best1x = availableModes.filter { !$0.isHiDPI }.max(by: { $0.area < $1.area }) ?? currentMode
        let width = best1x?.width ?? 2560
        let height = best1x?.height ?? 1440
        let freq = Double(currentMode?.freq ?? best1x?.freq ?? 60)
        return (width, height, freq > 0 ? freq : 60.0)
    }

    /// Мгновенно включает или выключает виртуальный HiDPI-фреймбуфер (`CGVirtualDisplay` + аппаратный Mirroring).
    public func toggleVirtualHiDPI() {
        guard let device = selectedDevice else { return }
        lastError = nil
        statusMessage = nil

        if virtualHiDPIService.isVirtualHiDPIActive(for: selectedDisplayID) {
            if let physicalID = virtualHiDPIService.disableVirtualHiDPI(for: selectedDisplayID) {
                selectedDisplayID = physicalID
            }
            isVirtualHiDPIActive = false
            statusMessage = "Виртуальный HiDPI-буфер отключён"
            refreshDisplays()
            return
        }

        let native = nativeResolutionForSelectedDisplay()
        if let vDisplayID = virtualHiDPIService.enableVirtualHiDPI(
            for: device,
            nativeWidth: native.width,
            nativeHeight: native.height,
            refreshRate: native.freq
        ) {
            selectedDisplayID = vDisplayID
            isVirtualHiDPIActive = true
            statusMessage = "✓ Виртуальный 2K/Ultrawide HiDPI активирован"
            refreshDisplays()
        } else {
            lastError = "Не удалось создать виртуальный HiDPI-буфер"
        }
    }

    /// Устанавливает или удаляет системный профиль `scale-resolutions` в `/Library/Displays/Contents/Resources/Overrides`.
    public func toggleSystemOverride() async {
        guard let device = selectedDevice, !isInstallingOverride else { return }
        isInstallingOverride = true
        defer { isInstallingOverride = false }
        lastError = nil
        statusMessage = nil

        do {
            if overrideInstaller.isOverrideInstalled(for: device) {
                try await overrideInstaller.removeOverride(for: device)
                hasInstalledSystemOverride = false
                statusMessage = "✓ Системный профиль удалён (переподключите экран)"
            } else {
                let native = nativeResolutionForSelectedDisplay()
                try await overrideInstaller.installOverride(
                    for: device,
                    nativeWidth: native.width,
                    nativeHeight: native.height
                )
                hasInstalledSystemOverride = true
                statusMessage = "✓ Профиль HiDPI установлен (переподключите экран)"
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func cleanupOnTerminate() {
        virtualHiDPIService.disableAll()
    }
}
