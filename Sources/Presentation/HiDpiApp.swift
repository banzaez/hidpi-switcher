import AppKit
import SwiftUI

/// Содержимое меню в строке состояния (Menu Bar).
struct MenuBarContentView: View {
    @Bindable var displayStore: DisplayStore
    let launchStore: LaunchAtLoginStore
    @Bindable var updateStore: UpdateStore

    private var displaySelectionBinding: Binding<CGDirectDisplayID> {
        Binding(
            get: { displayStore.selectedDisplayID },
            set: { displayStore.selectDisplay($0) }
        )
    }

    var body: some View {
        // 0. Баннер доступного обновления (если найдено)
        if let update = updateStore.availableUpdate {
            Button("⚡️ Доступно обновление (\(update.version.description))...") {
                updateStore.presentUpdateDialog()
            }
            Divider()
        }

        // 1. Выбор монитора (если подключено более одного)
        if displayStore.connectedDisplays.count > 1 {
            Menu("Выбор экрана: \(displayStore.selectedDevice?.name ?? "Экран")") {
                Picker("Экран", selection: displaySelectionBinding) {
                    ForEach(displayStore.connectedDisplays) { device in
                        Text(device.menuTitle)
                            .tag(device.id)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Divider()
        }

        // 2. Текущее состояние выбранного монитора
        if let current = displayStore.currentMode {
            VStack(alignment: .leading, spacing: 2) {
                if let curDevice = displayStore.effectivePhysicalDevice ?? displayStore.selectedDevice {
                    let cleanName = curDevice.name.replacingOccurrences(of: " (HiDPI)", with: "")
                    Text(displayStore.isVirtualHiDPIActive ? "\(cleanName) • Виртуальный HiDPI" : cleanName)
                        .font(.headline)
                }
                Text("Разрешение: \(current.width) × \(current.height)")
                    .font(.subheadline)
                Text(current.statusSubtitle)
                    .font(.caption)
                    .foregroundStyle(current.isHiDPI ? .green : .secondary)
            }
        } else {
            Text("Определение экрана...")
        }

        if let statusMessage = displayStore.statusMessage {
            Text(statusMessage)
                .font(.caption)
                .foregroundStyle(.green)
        }

        if displayStore.hidpiModes.isEmpty, displayStore.currentMode != nil {
            Text("ℹ️ Нет родных HiDPI ≥ 1280px — включите «2K / Ultrawide HiDPI» ниже")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        // 4. Вывод ошибок каждого слоя отдельно
        if let displayError = displayStore.lastError {
            Text("⚠️ \(displayError)")
                .font(.caption)
                .foregroundStyle(.red)
        }
        if let launchError = launchStore.lastError {
            Text("⚠️ \(launchError)")
                .font(.caption)
                .foregroundStyle(.red)
            if launchStore.requiresApproval {
                Button("Открыть настройки «Объекты входа»...") {
                    launchStore.openSystemSettingsLoginItems()
                }
            }
        }

        Divider()

        // 5. Главный тумблер HiDPI для выбранного монитора
        Toggle("Режим HiDPI (Retina)  ⌃⌥⌘H", isOn: Binding(
            get: { displayStore.isHiDPIActive },
            set: { _ in displayStore.toggleHiDPI() }
        ))
        .disabled(displayStore.currentMode == nil)

        // 6. Отдельный переключатель частоты обновления (Hz) для текущего разрешения
        if displayStore.availableRefreshRates.count > 1,
           let current = displayStore.currentMode {
            Menu("Частота обновления: \(current.refreshRateTitle)") {
                ForEach(displayStore.availableRefreshRates) { mode in
                    Button {
                        displayStore.setRefreshRate(mode.freq)
                    } label: {
                        if mode.freq == current.freq {
                            Text("✓ \(mode.refreshRateTitle)")
                        } else {
                            Text(mode.refreshRateTitle)
                        }
                    }
                }
            }
        }

        Divider()

        // 7. Избранные пресеты (быстрое переключение в 1 клик или по ⌃⌥⌘F)
        if !displayStore.favoriteModes.isEmpty {
            ForEach(displayStore.favoriteModes) { fav in
                Button {
                    displayStore.selectFavorite(fav)
                } label: {
                    Text(fav.id == displayStore.currentMode?.id ? "✓ \(fav.favoriteTitle)" : fav.favoriteTitle)
                }
            }
        }

        if displayStore.currentMode != nil {
            Button(displayStore.isCurrentModeFavorite
                   ? "☆ Убрать текущий режим из Избранного"
                   : "★ Добавить текущий режим в Избранное") {
                displayStore.toggleCurrentModeFavorite()
            }
        }

        Divider()

        // 8. Сгруппированные по геометрии списки разрешений (без дублей герцовки)
        ModeMenu(
            title: "Все разрешения HiDPI (2x)",
            modes: displayStore.hidpiModes,
            currentID: displayStore.currentMode?.id,
            onSelect: displayStore.setMode
        )

        ModeMenu(
            title: "Все разрешения Low-Res (1x)",
            modes: displayStore.standardModes,
            currentID: displayStore.currentMode?.id,
            onSelect: displayStore.setMode
        )

        // 9. Разблокировка 2K / QHD (2560×1440) и Ultrawide (3440×1440) на Apple Silicon
        if displayStore.isBuiltinSelected {
            Text("ℹ️ Встроенный дисплей MacBook уже работает в нативном Retina HiDPI")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Button(displayStore.isVirtualHiDPIActive
                   ? "✓ Виртуальный HiDPI-буфер (2K / Ultrawide)"
                   : "Виртуальный HiDPI-буфер (2K / Ultrawide)") {
                // Выполняем асинхронно после закрытия меню macOS, чтобы WindowServer
                // вышел из модального Menu Tracking Loop и не отклонял реконфигурацию экранов
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    displayStore.toggleVirtualHiDPI()
                }
            }
            .disabled(!displayStore.canManageVirtualHiDPI)

            Menu("Системный профиль Override") {
                Button(displayStore.isVirtualHiDPIActive
                       ? "✓ Виртуальный HiDPI-буфер активен (отключить)"
                       : "Включить виртуальный HiDPI-буфер (мгновенно)") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        displayStore.toggleVirtualHiDPI()
                    }
                }

                Divider()

                Button(displayStore.hasInstalledSystemOverride
                       ? "Удалить системный профиль Override..."
                       : "Установить системный профиль Override...") {
                    Task {
                        await displayStore.toggleSystemOverride()
                    }
                }
                .disabled(displayStore.isInstallingOverride || !displayStore.canManageSystemOverride)
            }
        }

        Divider()

        // 10. Настройки поведения и автозапуска
        Menu("Параметры") {
            Toggle("Запускать при входе в систему", isOn: Binding(
                get: { launchStore.isEnabled },
                set: { launchStore.setEnabled($0) }
            ))

            Toggle("Восстанавливать режим при подключении", isOn: $displayStore.autoRestoreSavedMode)

            Toggle("Глобальные хоткеи (⌃⌥⌘H / ⌃⌥⌘F)", isOn: $displayStore.globalHotKeysEnabled)

            Toggle("Показывать разрешения < 1280px", isOn: $displayStore.showAllResolutions)

            Toggle("Подтверждать смену режима диалогом", isOn: $displayStore.alwaysConfirmModeChanges)

            Divider()

            Toggle("Автоматически проверять обновления", isOn: Binding(
                get: { updateStore.automaticallyCheckForUpdates },
                set: { updateStore.automaticallyCheckForUpdates = $0 }
            ))

            Button(updateStore.state == .checking ? "Проверка обновлений..." : "Проверить обновления...") {
                Task {
                    await updateStore.checkForUpdates(manual: true)
                }
            }
            .disabled(updateStore.state == .checking)
        }

        Divider()

        Button("Обновить список") {
            displayStore.refreshDisplays()
            launchStore.refresh()
        }
        .keyboardShortcut("r", modifiers: .command)

        Button("Завершить") {
            displayStore.cleanupOnTerminate()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}

@main
struct HiDpiApp: App {
    @State private var displayStore: DisplayStore
    @State private var launchStore = LaunchAtLoginStore()
    @State private var updateStore: UpdateStore
    private let revertPresenter: RevertConfirmationPresenter
    private let updatePresenter: UpdatePresenter

    init() {
        let rPresenter = RevertConfirmationPresenter()
        self.revertPresenter = rPresenter
        let dStore = DisplayStore(revertPresenter: rPresenter)
        _displayStore = State(initialValue: dStore)

        let uPresenter = UpdatePresenter()
        self.updatePresenter = uPresenter
        let uStore = UpdateStore(presenter: uPresenter)
        _updateStore = State(initialValue: uStore)

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                dStore.cleanupOnTerminate()
            }
        }

        Task {
            await uStore.performStartupCheckIfNeeded()
        }
    }

    private var statusIcon: String {
        if displayStore.pendingRevertSeconds != nil {
            return "clock.arrow.circlepath"
        }
        return displayStore.isHiDPIActive ? "sparkles.tv" : "display"
    }

    var body: some Scene {
        MenuBarExtra("HiDPI Switcher", systemImage: statusIcon) {
            MenuBarContentView(
                displayStore: displayStore,
                launchStore: launchStore,
                updateStore: updateStore
            )
        }
    }
}
