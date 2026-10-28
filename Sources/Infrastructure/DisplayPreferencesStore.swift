import CoreGraphics
import Foundation

/// Протокол хранения пользовательских предпочтений мониторов, избранных пресетов и подтверждённых режимов.
@MainActor
public protocol DisplayPreferencesStoreProtocol: AnyObject {
    var preferredDisplayID: CGDirectDisplayID? { get set }
    var autoRestoreSavedMode: Bool { get set }
    var globalHotKeysEnabled: Bool { get set }
    var showAllResolutions: Bool { get set }
    var alwaysConfirmModeChanges: Bool { get set }

    func preferredModeKey(for display: DisplayDevice) -> ModeKey?
    func setPreferredModeKey(_ key: ModeKey?, for display: DisplayDevice)

    func favoriteModeKeys(for display: DisplayDevice) -> [ModeKey]
    func setFavoriteModeKeys(_ keys: [ModeKey], for display: DisplayDevice)

    func verifiedModeKeys(for display: DisplayDevice) -> Set<ModeKey>
    func addVerifiedModeKey(_ key: ModeKey, for display: DisplayDevice)
}

/// Реализация хранилища поверх `UserDefaults`.
@MainActor
public final class UserDefaultsDisplayPreferencesStore: DisplayPreferencesStoreProtocol {
    private enum Keys {
        static let preferredDisplayID = "HiDpiSwitcher.preferredDisplayID"
        static let autoRestoreSavedMode = "HiDpiSwitcher.autoRestoreSavedMode"
        static let globalHotKeysEnabled = "HiDpiSwitcher.globalHotKeysEnabled"
        static let showAllResolutions = "HiDpiSwitcher.showAllResolutions"
        static let alwaysConfirmModeChanges = "HiDpiSwitcher.alwaysConfirmModeChanges"
        static let preferredModesPrefix = "HiDpiSwitcher.preferredMode."
        static let favoriteModesPrefix = "HiDpiSwitcher.favoriteModes."
        static let verifiedModesPrefix = "HiDpiSwitcher.verifiedModes."
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var preferredDisplayID: CGDirectDisplayID? {
        get {
            guard defaults.object(forKey: Keys.preferredDisplayID) != nil else { return nil }
            let raw = defaults.integer(forKey: Keys.preferredDisplayID)
            return raw > 0 ? CGDirectDisplayID(raw) : nil
        }
        set {
            if let newValue {
                defaults.set(Int(newValue), forKey: Keys.preferredDisplayID)
            } else {
                defaults.removeObject(forKey: Keys.preferredDisplayID)
            }
        }
    }

    public var autoRestoreSavedMode: Bool {
        get {
            guard defaults.object(forKey: Keys.autoRestoreSavedMode) != nil else { return true }
            return defaults.bool(forKey: Keys.autoRestoreSavedMode)
        }
        set {
            defaults.set(newValue, forKey: Keys.autoRestoreSavedMode)
        }
    }

    public var globalHotKeysEnabled: Bool {
        get {
            guard defaults.object(forKey: Keys.globalHotKeysEnabled) != nil else { return true }
            return defaults.bool(forKey: Keys.globalHotKeysEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.globalHotKeysEnabled)
        }
    }

    public var showAllResolutions: Bool {
        get {
            defaults.bool(forKey: Keys.showAllResolutions)
        }
        set {
            defaults.set(newValue, forKey: Keys.showAllResolutions)
        }
    }

    public var alwaysConfirmModeChanges: Bool {
        get {
            guard defaults.object(forKey: Keys.alwaysConfirmModeChanges) != nil else { return true }
            return defaults.bool(forKey: Keys.alwaysConfirmModeChanges)
        }
        set {
            defaults.set(newValue, forKey: Keys.alwaysConfirmModeChanges)
        }
    }

    public func preferredModeKey(for display: DisplayDevice) -> ModeKey? {
        let storageKey = Keys.preferredModesPrefix + display.persistentIdentifier
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try? decoder.decode(ModeKey.self, from: data)
    }

    public func setPreferredModeKey(_ key: ModeKey?, for display: DisplayDevice) {
        let storageKey = Keys.preferredModesPrefix + display.persistentIdentifier
        if let key, let data = try? encoder.encode(key) {
            defaults.set(data, forKey: storageKey)
        } else {
            defaults.removeObject(forKey: storageKey)
        }
    }

    public func favoriteModeKeys(for display: DisplayDevice) -> [ModeKey] {
        let storageKey = Keys.favoriteModesPrefix + display.persistentIdentifier
        guard let data = defaults.data(forKey: storageKey),
              let keys = try? decoder.decode([ModeKey].self, from: data) else {
            return []
        }
        return keys
    }

    public func setFavoriteModeKeys(_ keys: [ModeKey], for display: DisplayDevice) {
        let storageKey = Keys.favoriteModesPrefix + display.persistentIdentifier
        if let data = try? encoder.encode(keys) {
            defaults.set(data, forKey: storageKey)
        }
    }

    public func verifiedModeKeys(for display: DisplayDevice) -> Set<ModeKey> {
        let storageKey = Keys.verifiedModesPrefix + display.persistentIdentifier
        guard let data = defaults.data(forKey: storageKey),
              let keys = try? decoder.decode([ModeKey].self, from: data) else {
            return []
        }
        return Set(keys)
    }

    public func addVerifiedModeKey(_ key: ModeKey, for display: DisplayDevice) {
        var current = verifiedModeKeys(for: display)
        guard current.insert(key).inserted else { return }
        let storageKey = Keys.verifiedModesPrefix + display.persistentIdentifier
        if let data = try? encoder.encode(Array(current)) {
            defaults.set(data, forKey: storageKey)
        }
    }
}
