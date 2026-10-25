import Foundation

/// Persists the user's normal (undimmed) external brightness per display so it survives
/// display reconnects, sleep/wake and app restarts. Keys are `ExternalDisplayReference.recoveryKey`.
public protocol ExternalLevelPersisting {
    func loadLevels() -> [String: Int]
    func saveLevels(_ levels: [String: Int])
}

public final class UserDefaultsExternalLevelStore: ExternalLevelPersisting {
    public static let defaultsKey = "externalNormalBrightnessByDisplay"

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = UserDefaultsExternalLevelStore.defaultsKey) {
        self.defaults = defaults
        self.key = key
    }

    public func loadLevels() -> [String: Int] {
        guard let stored = defaults.dictionary(forKey: key) else {
            return [:]
        }
        return stored.reduce(into: [String: Int]()) { result, entry in
            if let value = entry.value as? Int {
                result[entry.key] = min(100, max(0, value))
            }
        }
    }

    public func saveLevels(_ levels: [String: Int]) {
        if levels.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(levels, forKey: key)
        }
    }
}
