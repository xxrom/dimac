import Combine
import DimacCore
import Foundation

struct DisplayControlPreference: Codable, Equatable, Identifiable {
    let id: String
    var displayName: String
    var normalPercent: Int
    var dimPercent: Int
    var updatedAt: Date
}

@MainActor
final class SettingsStore: ObservableObject {
    static let minTimeoutSeconds = 1
    static let maxTimeoutSeconds = 180 * 60

    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Keys.isEnabled) }
    }

    @Published var idleTimeoutSeconds: Int {
        didSet {
            defaults.set(idleTimeoutSeconds, forKey: Keys.idleTimeoutSeconds)
        }
    }

    @Published var dimPercent: Int {
        didSet {
            defaults.set(dimPercent, forKey: Keys.dimPercent)
        }
    }

    @Published var m1ddcPath: String {
        didSet { defaults.set(m1ddcPath, forKey: Keys.m1ddcPath) }
    }

    @Published var brightnessPath: String {
        didSet { defaults.set(brightnessPath, forKey: Keys.brightnessPath) }
    }

    @Published var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Keys.launchAtLogin) }
    }

    @Published var hideMenuBarIcon: Bool {
        didSet { defaults.set(hideMenuBarIcon, forKey: Keys.hideMenuBarIcon) }
    }

    @Published private(set) var displayControlPreferences: [String: DisplayControlPreference] {
        didSet { saveDisplayControlPreferences() }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if defaults.object(forKey: Keys.isEnabled) == nil {
            self.isEnabled = true
        } else {
            self.isEnabled = defaults.bool(forKey: Keys.isEnabled)
        }

        let savedSeconds = defaults.integer(forKey: Keys.idleTimeoutSeconds)
        self.idleTimeoutSeconds = Self.clampedSeconds(savedSeconds > 0 ? savedSeconds : 600)

        let savedPercent = defaults.integer(forKey: Keys.dimPercent)
        self.dimPercent = savedPercent > 0 ? DimmerSettings.clampedPercent(savedPercent) : 10

        self.m1ddcPath = Self.storedString(
            forKey: Keys.m1ddcPath,
            in: defaults,
            fallback: CommandLocator.m1ddcDefaultPath
        )
        self.brightnessPath = Self.storedString(
            forKey: Keys.brightnessPath,
            in: defaults,
            fallback: CommandLocator.brightnessDefaultPath
        )

        self.launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        self.hideMenuBarIcon = defaults.bool(forKey: Keys.hideMenuBarIcon)
        self.displayControlPreferences = Self.loadDisplayControlPreferences(from: defaults)
    }

    func currentSettings(externalBrightnessByDisplay: [String: Int]) -> DimmerSettings {
        DimmerSettings(
            isEnabled: isEnabled,
            idleTimeoutSeconds: Self.clampedSeconds(idleTimeoutSeconds),
            dimPercent: dimPercent,
            m1ddcPath: m1ddcPath,
            externalBrightnessByDisplay: externalBrightnessByDisplay
        )
    }

    func setIdleTimeoutSeconds(_ value: Int) {
        idleTimeoutSeconds = Self.clampedSeconds(value)
    }

    func setTimeoutSliderValue(_ value: Double) {
        setIdleTimeoutSeconds(Self.seconds(fromSliderValue: value))
    }

    func incrementTimeout() {
        setIdleTimeoutSeconds(idleTimeoutSeconds + timeoutStep)
    }

    func decrementTimeout() {
        setIdleTimeoutSeconds(idleTimeoutSeconds - timeoutStep)
    }

    func setDimPercent(_ value: Int) {
        dimPercent = DimmerSettings.clampedPercent(value)
    }

    func seedDisplayControl(
        key: String,
        displayName: String,
        currentPercent: Int?,
        defaultDimPercent: Int
    ) -> DisplayControlPreference {
        if let preference = displayControlPreferences[key] {
            let normalizedPreference = Self.normalizedDisplayControlPreference(
                id: preference.id,
                displayName: displayName,
                normalPercent: preference.normalPercent,
                dimPercent: preference.dimPercent,
                updatedAt: preference.updatedAt
            )

            if normalizedPreference != preference {
                displayControlPreferences[key] = normalizedPreference
            }

            return normalizedPreference
        }

        let preference = upsertDisplayControlPreference(
            for: key,
            displayName: displayName,
            normalPercent: DimmerSettings.clampedPercent(currentPercent ?? 100),
            dimPercent: DimmerSettings.clampedPercent(defaultDimPercent),
            existing: nil
        )
        return preference
    }

    @discardableResult
    func setDisplayNormalPercent(_ value: Int, key: String, displayName: String) -> DisplayControlPreference {
        upsertDisplayControlPreference(
            for: key,
            displayName: displayName,
            normalPercent: DimmerSettings.clampedPercent(value),
            dimPercent: displayControlPreferences[key]?.dimPercent ?? DimmerSettings.clampedPercent(dimPercent),
            existing: displayControlPreferences[key]
        )
    }

    @discardableResult
    func setDisplayDimPercent(_ value: Int, key: String, displayName: String) -> DisplayControlPreference {
        upsertDisplayControlPreference(
            for: key,
            displayName: displayName,
            normalPercent: displayControlPreferences[key]?.normalPercent ?? 100,
            dimPercent: DimmerSettings.clampedPercent(value),
            existing: displayControlPreferences[key]
        )
    }

    func setTimeoutFromText(_ text: String) {
        guard let seconds = Self.parseTimeout(text) else {
            return
        }

        setIdleTimeoutSeconds(seconds)
    }

    var timeoutSliderValue: Double {
        Self.sliderValue(forSeconds: idleTimeoutSeconds)
    }

    var timeoutText: String {
        Self.formatTimeout(idleTimeoutSeconds)
    }

    private var timeoutStep: Int {
        idleTimeoutSeconds < 60 ? 1 : 60
    }

    private static func clampedSeconds(_ value: Int) -> Int {
        min(maxTimeoutSeconds, max(minTimeoutSeconds, value))
    }

    private static func sliderValue(forSeconds seconds: Int) -> Double {
        let clamped = clampedSeconds(seconds)
        if clamped <= 60 {
            return Double(clamped - 1) / 59.0 * 20.0
        }

        return 20.0 + (Double(clamped - 60) / Double(maxTimeoutSeconds - 60) * 80.0)
    }

    private static func seconds(fromSliderValue value: Double) -> Int {
        let clamped = min(100.0, max(0.0, value))
        if clamped <= 20.0 {
            return clampedSeconds(1 + Int((clamped / 20.0 * 59.0).rounded()))
        }

        let rawSeconds = 60.0 + ((clamped - 20.0) / 80.0 * Double(maxTimeoutSeconds - 60))
        return clampedSeconds(Int((rawSeconds / 60.0).rounded()) * 60)
    }

    private static func formatTimeout(_ seconds: Int) -> String {
        let clamped = clampedSeconds(seconds)
        if clamped < 60 {
            return "\(clamped)s"
        }

        let minutes = clamped / 60
        if minutes < 60 {
            return "\(minutes)m"
        }

        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
    }

    private static func parseTimeout(_ text: String) -> Int? {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")

        guard !normalized.isEmpty else {
            return nil
        }

        let numberString = normalized
            .trimmingCharacters(in: CharacterSet(charactersIn: "0123456789").inverted)
        guard let value = Int(numberString) else {
            return nil
        }

        if normalized.contains("h") {
            return value * 60 * 60
        }

        if normalized.contains("s") {
            return value
        }

        return value * 60
    }

    private static func storedString(forKey key: String, in defaults: UserDefaults, fallback: String) -> String {
        guard let value = defaults.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return fallback
        }

        return value
    }

    @discardableResult
    private func upsertDisplayControlPreference(
        for key: String,
        displayName: String,
        normalPercent: Int,
        dimPercent: Int,
        existing: DisplayControlPreference?
    ) -> DisplayControlPreference {
        let preference = Self.normalizedDisplayControlPreference(
            id: existing?.id ?? key,
            displayName: displayName,
            normalPercent: normalPercent,
            dimPercent: dimPercent,
            updatedAt: Date()
        )
        displayControlPreferences[key] = preference
        return preference
    }

    private func saveDisplayControlPreferences() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(displayControlPreferences) else {
            return
        }

        defaults.set(data, forKey: Keys.displayControlPreferences)
    }

    private static func loadDisplayControlPreferences(
        from defaults: UserDefaults
    ) -> [String: DisplayControlPreference] {
        guard let data = defaults.data(forKey: Keys.displayControlPreferences) else {
            return [:]
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let preferences = (
            try? decoder.decode([String: DisplayControlPreference].self, from: data)
        ) ?? [:]
        return preferences.mapValues { preference in
            normalizedDisplayControlPreference(
                id: preference.id,
                displayName: preference.displayName,
                normalPercent: preference.normalPercent,
                dimPercent: preference.dimPercent,
                updatedAt: preference.updatedAt
            )
        }
    }

    private static func normalizedDisplayControlPreference(
        id: String,
        displayName: String,
        normalPercent: Int,
        dimPercent: Int,
        updatedAt: Date
    ) -> DisplayControlPreference {
        let normalizedNormalPercent = DimmerSettings.clampedPercent(normalPercent)
        let normalizedDimPercent = min(
            normalizedNormalPercent,
            DimmerSettings.clampedPercent(dimPercent)
        )

        return DisplayControlPreference(
            id: id,
            displayName: displayName,
            normalPercent: normalizedNormalPercent,
            dimPercent: normalizedDimPercent,
            updatedAt: updatedAt
        )
    }

    private enum Keys {
        static let isEnabled = "isEnabled"
        static let idleTimeoutSeconds = "idleTimeoutSeconds"
        static let dimPercent = "dimPercent"
        static let m1ddcPath = "m1ddcPath"
        static let brightnessPath = "brightnessPath"
        static let launchAtLogin = "launchAtLogin"
        static let hideMenuBarIcon = "hideMenuBarIcon"
        static let displayControlPreferences = "displayControlPreferences"
    }
}
