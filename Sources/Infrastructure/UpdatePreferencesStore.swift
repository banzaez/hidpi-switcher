import Foundation

public protocol UpdatePreferencesStore: Sendable {
    var automaticallyCheckForUpdates: Bool { get }
    func setAutomaticallyCheckForUpdates(_ enabled: Bool)

    var lastCheckDate: Date? { get }
    func setLastCheckDate(_ date: Date?)

    var skippedVersion: String? { get }
    func setSkippedVersion(_ version: String?)
}

public final class UserDefaultsUpdatePreferencesStore: UpdatePreferencesStore, Sendable {
    private nonisolated(unsafe) let defaults: UserDefaults

    private enum Keys {
        static let autoCheck = "UpdateStore.automaticallyCheckForUpdates"
        static let lastCheckDate = "UpdateStore.lastCheckDate"
        static let skippedVersion = "UpdateStore.skippedVersion"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.autoCheck: true
        ])
    }

    public var automaticallyCheckForUpdates: Bool {
        defaults.bool(forKey: Keys.autoCheck)
    }

    public func setAutomaticallyCheckForUpdates(_ enabled: Bool) {
        defaults.set(enabled, forKey: Keys.autoCheck)
    }

    public var lastCheckDate: Date? {
        defaults.object(forKey: Keys.lastCheckDate) as? Date
    }

    public func setLastCheckDate(_ date: Date?) {
        if let date {
            defaults.set(date, forKey: Keys.lastCheckDate)
        } else {
            defaults.removeObject(forKey: Keys.lastCheckDate)
        }
    }

    public var skippedVersion: String? {
        defaults.string(forKey: Keys.skippedVersion)
    }

    public func setSkippedVersion(_ version: String?) {
        if let version {
            defaults.set(version, forKey: Keys.skippedVersion)
        } else {
            defaults.removeObject(forKey: Keys.skippedVersion)
        }
    }
}
