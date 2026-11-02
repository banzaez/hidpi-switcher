import AppKit
import SwiftUI

/// Всплывающее диалоговое окно подтверждения нового видеорежима с таймером автоотката.
struct RevertConfirmationView: View {
    @Bindable var store: DisplayStore

    var body: some View {
        VStack(spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "display.trianglebadge.exclamationmark")
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 42))
                    .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Сохранить новые параметры экрана?")
                        .font(.headline)

                    if let current = store.currentMode {
                        VStack(alignment: .leading, spacing: 4) {
                            if let device = store.selectedDevice {
                                Text(device.name)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            HStack(spacing: 8) {
                                Text("\(current.width) × \(current.height)")
                                    .font(.body.weight(.semibold))

                                Text("@ \(current.refreshRateTitle)")
                                    .font(.body)
                                    .foregroundStyle(.secondary)

                                Text(current.isHiDPI ? "HiDPI (2x)" : "Low-Res (1x)")
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(
                                        current.isHiDPI
                                            ? Color.green.opacity(0.18)
                                            : Color.secondary.opacity(0.18)
                                    )
                                    .foregroundStyle(current.isHiDPI ? .green : .primary)
                                    .clipShape(Capsule())
                            }
                        }
                    }

                    if let seconds = store.pendingRevertSeconds {
                        Text("Если вы не подтвердите выбор, прежний режим автоматически восстановится через \(seconds) сек.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let seconds = store.pendingRevertSeconds {
                VStack(alignment: .trailing, spacing: 4) {
                    ProgressView(
                        value: Double(seconds),
                        total: Double(max(1, store.revertTimeoutSeconds))
                    )
                    .tint(seconds <= 3 ? .red : .accentColor)
                    .animation(.linear(duration: 1.0), value: seconds)

                    Text("\(seconds) с")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(seconds <= 3 ? .red : .secondary)
                }
            }

            HStack(spacing: 14) {
                Button("Вернуть прежний (Esc)") {
                    store.revertPendingMode()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Сохранить (Enter)") {
                    store.confirmPendingMode()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 440)
    }
}

/// Специальная панель с гарантированной поддержкой фокуса ввода и шорткатов клавиатуры.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Контроллер отдельного системного диалога подтверждения разрешения (macOS Floating NSPanel).
@MainActor
public final class RevertConfirmationPresenter: NSObject, RevertDialogPresenter, NSWindowDelegate {
    private var panel: NSPanel?
    private weak var currentStore: DisplayStore?

    public override init() {
        super.init()
    }

    public func showRevertDialog(store: DisplayStore) {
        self.currentStore = store

        if let existing = panel, existing.isVisible {
            updatePanelPosition(for: store.selectedDisplayID)
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = RevertConfirmationView(store: store)
        let hostingController = NSHostingController(rootView: contentView)
        let fittingSize = hostingController.view.fittingSize

        let newPanel = KeyPanel(
            contentRect: NSRect(origin: .zero, size: fittingSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        newPanel.title = "Проверка параметров экрана"
        newPanel.titlebarAppearsTransparent = true
        newPanel.titleVisibility = .hidden
        newPanel.isFloatingPanel = true
        newPanel.level = .modalPanel
        newPanel.isMovableByWindowBackground = true
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.contentViewController = hostingController
        newPanel.setContentSize(fittingSize)
        newPanel.isReleasedWhenClosed = false
        newPanel.delegate = self

        self.panel = newPanel
        updatePanelPosition(for: store.selectedDisplayID)

        newPanel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func dismissRevertDialog() {
        guard let panel else { return }
        panel.orderOut(nil)
        self.panel = nil
        self.currentStore = nil
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        // При нажатии крестика закрытия окна — безопасный откат (который сам закроет панель через dismissRevertDialog)
        currentStore?.revertPendingMode()
        return false
    }

    private func updatePanelPosition(for displayID: CGDirectDisplayID) {
        guard let panel else { return }

        // Центрируем диалог на целевом экране, на котором тестируется разрешение
        let screenKey = NSDeviceDescriptionKey("NSScreenNumber")
        let targetScreen = NSScreen.screens.first { screen in
            guard let screenNumber = (screen.deviceDescription[screenKey] as? NSNumber)?.uint32Value else {
                return false
            }
            return screenNumber == displayID
        } ?? NSScreen.main

        if let targetScreen {
            let visibleFrame = targetScreen.visibleFrame
            let x = visibleFrame.midX - (panel.frame.width / 2)
            let y = visibleFrame.midY - (panel.frame.height / 2)
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            panel.center()
        }
    }
}
