import Foundation

public protocol UpdatePreferencesStore: Sendable {
    var automaticallyCheckForUpdates: Bool { get }
    func setAutomaticallyCheckForUpdates(_ enabled: Bool)

    var lastCheckDate: Date? { get }
    func setLastCheckDate(_ date: Date?)

    var skippedVersion: String? { get }
    func setSkippedVersion(_ version: String?)
}

public final class UserDefaultsUpdatePreferencesStore: UpdatePreferencesStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "com.hidpiswitcher.update.preferences", qos: .utility)

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
        queue.sync { defaults.bool(forKey: Keys.autoCheck) }
    }

    public func setAutomaticallyCheckForUpdates(_ enabled: Bool) {
        queue.sync { defaults.set(enabled, forKey: Keys.autoCheck) }
    }

    public var lastCheckDate: Date? {
        queue.sync { defaults.object(forKey: Keys.lastCheckDate) as? Date }
    }

    public func setLastCheckDate(_ date: Date?) {
        queue.sync {
            if let date {
                defaults.set(date, forKey: Keys.lastCheckDate)
            } else {
                defaults.removeObject(forKey: Keys.lastCheckDate)
            }
        }
    }

    public var skippedVersion: String? {
        queue.sync { defaults.string(forKey: Keys.skippedVersion) }
    }

    public func setSkippedVersion(_ version: String?) {
        queue.sync {
            if let version {
                defaults.set(version, forKey: Keys.skippedVersion)
            } else {
                defaults.removeObject(forKey: Keys.skippedVersion)
            }
        }
    }
}
