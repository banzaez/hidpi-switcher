import Carbon.HIToolbox
import Foundation

/// Действия глобальных сочетаний клавиш.
public enum HotKeyAction: UInt32, Sendable {
    /// `⌃⌥⌘H` — переключить HiDPI (или откатить режим во время таймера подтверждения).
    case toggleHiDPIOrRevert = 1
    /// `⌃⌥⌘F` — переключить следующий избранный режим по кругу.
    case cycleFavorites = 2
}

/// Протокол сервиса глобальных хоткеев.
@MainActor
public protocol GlobalHotKeyServiceProtocol: AnyObject {
    var onAction: (@MainActor (HotKeyAction) -> Void)? { get set }
    func setEnabled(_ enabled: Bool)
}

/// Нативный сервис глобальных сочетаний клавиш через `RegisterEventHotKey` (не требует прав Accessibility).
@MainActor
public final class CarbonGlobalHotKeyService: GlobalHotKeyServiceProtocol {
    public var onAction: (@MainActor (HotKeyAction) -> Void)?

    private nonisolated(unsafe) var eventHandlerRef: EventHandlerRef?
    private nonisolated(unsafe) var toggleHotKeyRef: EventHotKeyRef?
    private nonisolated(unsafe) var favoritesHotKeyRef: EventHotKeyRef?
    private var isRegistered = false

    private nonisolated static let signature: OSType = 0x4844_5049 // 'HDPI'

    public init() {}

    deinit {
        if let ref = toggleHotKeyRef {
            UnregisterEventHotKey(ref)
        }
        if let ref = favoritesHotKeyRef {
            UnregisterEventHotKey(ref)
        }
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
        }
    }

    public func setEnabled(_ enabled: Bool) {
        if enabled {
            registerIfNeeded()
        } else {
            unregisterAll()
        }
    }

    private func registerIfNeeded() {
        guard !isRegistered else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.hotKeyEventHandler,
            1,
            &eventType,
            selfPtr,
            &eventHandlerRef
        )
        guard status == noErr else { return }

        let modifiers = UInt32(cmdKey | optionKey | controlKey)

        // ⌃⌥⌘H (kVK_ANSI_H = 0x04)
        let toggleID = EventHotKeyID(signature: Self.signature, id: HotKeyAction.toggleHiDPIOrRevert.rawValue)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_H),
            modifiers,
            toggleID,
            GetApplicationEventTarget(),
            0,
            &toggleHotKeyRef
        )

        // ⌃⌥⌘F (kVK_ANSI_F = 0x03)
        let favID = EventHotKeyID(signature: Self.signature, id: HotKeyAction.cycleFavorites.rawValue)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_F),
            modifiers,
            favID,
            GetApplicationEventTarget(),
            0,
            &favoritesHotKeyRef
        )

        isRegistered = true
    }

    private func unregisterAll() {
        if let ref = toggleHotKeyRef {
            UnregisterEventHotKey(ref)
            toggleHotKeyRef = nil
        }
        if let ref = favoritesHotKeyRef {
            UnregisterEventHotKey(ref)
            favoritesHotKeyRef = nil
        }
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
        isRegistered = false
    }

    private nonisolated static let hotKeyEventHandler: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }

        var hotKeyID = EventHotKeyID()
        let err = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard err == noErr,
              hotKeyID.signature == CarbonGlobalHotKeyService.signature,
              let action = HotKeyAction(rawValue: hotKeyID.id) else {
            return OSStatus(eventNotHandledErr)
        }

        nonisolated(unsafe) let rawUserData = userData
        MainActor.assumeIsolated {
            let service = Unmanaged<CarbonGlobalHotKeyService>.fromOpaque(rawUserData).takeUnretainedValue()
            service.onAction?(action)
        }
        return noErr
    }
}
