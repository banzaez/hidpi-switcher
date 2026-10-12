import SwiftUI

@main
struct HiDpiApp: App {
    @StateObject private var displayManager = DisplayManager()
    @StateObject private var launchManager = LaunchAtLoginManager()

    var statusIcon: String {
        return displayManager.isHiDPIActive ? "sparkles.tv" : "display"
    }

    var body: some Scene {
        MenuBarExtra("HiDPI Switcher", systemImage: statusIcon) {
            // Выбор монитора, если их несколько
            if displayManager.connectedDisplays.count > 1 {
                Menu("Выбор экрана: \(displayManager.connectedDisplays.first(where: { $0.id == displayManager.selectedDisplayID })?.name ?? "Экран")") {
                    ForEach(displayManager.connectedDisplays) { device in
                        Button(action: {
                            displayManager.selectDisplay(device.id)
                        }) {
                            if device.id == displayManager.selectedDisplayID {
                                Text("✓ " + device.title)
                            } else {
                                Text("   " + device.title)
                            }
                        }
                    }
                }
                Divider()
            }

            // Текущее состояние экрана
            if let current = displayManager.currentMode {
                VStack(alignment: .leading, spacing: 2) {
                    if let curDevice = displayManager.connectedDisplays.first(where: { $0.id == displayManager.selectedDisplayID }) {
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

            Divider()

            // Главный тумблер HiDPI для выбранного монитора
            Toggle("Режим HiDPI (Retina)", isOn: Binding(
                get: { displayManager.isHiDPIActive },
                set: { _ in displayManager.toggleHiDPI() }
            ))

            Divider()

            // Списки других режимов для выбранного монитора
            let hidpiModes = displayManager.availableModes.filter { $0.isHiDPI && $0.width >= 1280 }
            if !hidpiModes.isEmpty {
                Menu("Все разрешения HiDPI (2x)") {
                    ForEach(hidpiModes) { res in
                        Button(action: {
                            displayManager.setMode(res)
                        }) {
                            if displayManager.currentMode?.id == res.id {
                                Text("✓ " + res.title)
                            } else {
                                Text("   " + res.title)
                            }
                        }
                    }
                }
            }

            let standardModes = displayManager.availableModes.filter { !$0.isHiDPI && $0.width >= 1280 }
            if !standardModes.isEmpty {
                Menu("Все разрешения Low-Res (1x)") {
                    ForEach(standardModes) { res in
                        Button(action: {
                            displayManager.setMode(res)
                        }) {
                            if displayManager.currentMode?.id == res.id {
                                Text("✓ " + res.title)
                            } else {
                                Text("   " + res.title)
                            }
                        }
                    }
                }
            }

            Divider()

            Toggle("Запускать при входе в систему", isOn: Binding(
                get: { launchManager.isEnabled },
                set: { _ in launchManager.toggle() }
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
