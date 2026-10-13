import SwiftUI

/// Подменю со списком режимов (общее для HiDPI и 1x).
private struct ModeMenu: View {
    let title: String
    let modes: [ModeEntry]
    let currentID: Int?
    let onSelect: (ModeEntry) -> Void

    var body: some View {
        if !modes.isEmpty {
            Menu(title) {
                ForEach(modes) { res in
                    Button {
                        onSelect(res)
                    } label: {
                        Text((currentID == res.id ? "✓ " : "   ") + res.title)
                    }
                }
            }
        }
    }
}

@main
struct HiDpiApp: App {
    @StateObject private var displayManager = DisplayManager()
    @StateObject private var launchManager = LaunchAtLoginManager()

    private var selectedDevice: DisplayDevice? {
        displayManager.connectedDisplays.first(where: { $0.id == displayManager.selectedDisplayID })
    }

    var statusIcon: String {
        return displayManager.isHiDPIActive ? "sparkles.tv" : "display"
    }

    var body: some Scene {
        MenuBarExtra("HiDPI Switcher", systemImage: statusIcon) {
            // Выбор монитора, если их несколько
            if displayManager.connectedDisplays.count > 1 {
                Menu("Выбор экрана: \(selectedDevice?.name ?? "Экран")") {
                    ForEach(displayManager.connectedDisplays) { device in
                        Button {
                            displayManager.selectDisplay(device.id)
                        } label: {
                            Text((device.id == displayManager.selectedDisplayID ? "✓ " : "   ") + device.title)
                        }
                    }
                }
                Divider()
            }

            // Текущее состояние экрана
            if let current = displayManager.currentMode {
                VStack(alignment: .leading, spacing: 2) {
                    if let curDevice = selectedDevice {
                        Text(curDevice.name)
                            .font(.headline)
                    }
                    Text("Разрешение: \(current.width) × \(current.height)")
                        .font(.subheadline)
                    Text(current.isHiDPI
                         ? "✓ Retina 2x HiDPI (@ \(current.freq)Hz)"
                         : "○ Стандартный 1x (@ \(current.freq)Hz)")
                        .font(.caption)
                        .foregroundColor(current.isHiDPI ? .green : .secondary)
                }
            } else {
                Text("Определение экрана...")
            }

            if let error = displayManager.lastError ?? launchManager.lastError {
                Text("⚠️ \(error)")
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Divider()

            // Главный тумблер HiDPI для выбранного монитора
            Toggle("Режим HiDPI (Retina)", isOn: Binding(
                get: { displayManager.isHiDPIActive },
                set: { _ in displayManager.toggleHiDPI() }
            ))
            .disabled(displayManager.currentMode == nil)

            Divider()

            ModeMenu(
                title: "Все разрешения HiDPI (2x)",
                modes: displayManager.hidpiModes,
                currentID: displayManager.currentMode?.id,
                onSelect: displayManager.setMode
            )
            ModeMenu(
                title: "Все разрешения Low-Res (1x)",
                modes: displayManager.standardModes,
                currentID: displayManager.currentMode?.id,
                onSelect: displayManager.setMode
            )

            Divider()

            Toggle("Запускать при входе в систему", isOn: Binding(
                get: { launchManager.isEnabled },
                set: { launchManager.setEnabled($0) }
            ))

            Divider()

            Button("Обновить список") {
                displayManager.refreshDisplays()
            }

            Button("Завершить") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
