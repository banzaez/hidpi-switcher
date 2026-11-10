import AppKit
import SwiftUI

/// Протокол презентера диалогов обновления.
@MainActor
public protocol UpdateDialogPresenter: AnyObject {
    func showUpdateDialog(store: UpdateStore)
    func dismissUpdateDialog()
    func showUpToDateAlert(version: SemanticVersion)
    func showErrorAlert(message: String, releaseURL: URL?)
}

/// Нативный SwiftUI интерфейс окна обновления приложения (Sparkle-стиль).
struct UpdateDialogView: View {
    @Bindable var store: UpdateStore

    var body: some View {
        VStack(spacing: 16) {
            // 1. Верхний блок: иконка приложения и заголовок
            HStack(alignment: .top, spacing: 16) {
                if let appIcon = NSApp.applicationIconImage {
                    Image(nsImage: appIcon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 64, height: 64)
                } else {
                    Image(systemName: "sparkles.tv")
                        .font(.system(size: 48))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 64, height: 64)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Доступна новая версия HiDpiSwitcher!")
                        .font(.headline)

                    if let update = store.availableUpdate {
                        HStack(spacing: 8) {
                            Text("Установлена: \(store.currentVersion.description)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            Image(systemName: "arrow.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Text("Новая: \(update.version.description)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                        }

                        if let size = update.formattedSize {
                            Text("Размер загрузки: \(size)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
            }

            Divider()

            // 2. Список изменений (Release Notes)
            if let update = store.availableUpdate {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Что нового:")
                        .font(.subheadline.weight(.medium))

                    ScrollView(.vertical) {
                        Text(update.releaseNotes)
                            .font(.system(.body, design: .default))
                            .lineSpacing(3)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 180)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                }
            }

            // 3. Индикатор загрузки (когда скачивается архив)
            if case .downloading(let progress) = store.state {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Загрузка обновления...")
                            .font(.caption)
                        Spacer()
                        Text("\(Int(progress * 100))%")
                            .font(.caption.monospacedDigit())
                    }
                    ProgressView(value: progress, total: 1.0)
                        .progressViewStyle(.linear)
                }
                .padding(.vertical, 4)
            }

            if let error = store.lastErrorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Divider()

            // 4. Панель кнопок
            HStack(spacing: 12) {
                Button("Страница релиза...") {
                    store.openReleaseWebPage()
                }
                .buttonStyle(.link)
                .font(.callout)

                Spacer()

                if case .downloading = store.state {
                    Button("Отмена") {
                        store.dismiss()
                    }
                } else {
                    if let update = store.availableUpdate {
                        Button("Пропустить версию") {
                            store.skipVersion(update.version)
                        }
                        .keyboardShortcut(.cancelAction)
                    }

                    Button("Позже") {
                        store.dismiss()
                    }

                    Button("Обновить и перезапустить") {
                        Task {
                            await store.downloadAndInstall()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(store.availableUpdate?.downloadURL == nil && store.availableUpdate == nil)
                }
            }
        }
        .padding(20)
        .frame(width: 500)
    }
}

/// Специальная панель с гарантированной поддержкой фокуса ввода.
private final class UpdateKeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Нативный macOS-контроллер плавающего модального окна обновления (NSPanel).
@MainActor
public final class UpdatePresenter: NSObject, UpdateDialogPresenter, NSWindowDelegate {
    private var panel: NSPanel?
    private weak var currentStore: UpdateStore?

    public override init() {
        super.init()
    }

    public func showUpdateDialog(store: UpdateStore) {
        self.currentStore = store

        if let existing = panel, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = UpdateDialogView(store: store)
        let hostingController = NSHostingController(rootView: contentView)
        let fittingSize = hostingController.view.fittingSize

        let newPanel = UpdateKeyPanel(
            contentRect: NSRect(origin: .zero, size: fittingSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        newPanel.title = "Обновление HiDpiSwitcher"
        newPanel.titlebarAppearsTransparent = true
        newPanel.titleVisibility = .hidden
        newPanel.isFloatingPanel = true
        newPanel.level = .floating
        newPanel.isMovableByWindowBackground = true
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.contentViewController = hostingController
        newPanel.setContentSize(fittingSize)
        newPanel.isReleasedWhenClosed = false
        newPanel.delegate = self

        self.panel = newPanel
        newPanel.center()
        newPanel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func dismissUpdateDialog() {
        guard let panel else { return }
        panel.orderOut(nil)
        self.panel = nil
        self.currentStore = nil
    }

    public func showUpToDateAlert(version: SemanticVersion) {
        let alert = NSAlert()
        alert.messageText = "У вас установлена актуальная версия"
        alert.informativeText = "HiDpiSwitcher \(version.description) — новейшая доступная версия приложения."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    public func showErrorAlert(message: String, releaseURL: URL?) {
        let alert = NSAlert()
        alert.messageText = "Не удалось проверить обновления"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if releaseURL != nil {
            alert.addButton(withTitle: "Открыть GitHub...")
        }
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertSecondButtonReturn, let url = releaseURL {
            NSWorkspace.shared.open(url)
        }
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismissUpdateDialog()
        return true
    }
}
