import Combine
import DimacCore
import Foundation

struct DisplayControlPreference: Codable, Equatable, Identifiable {
    let id: String
    var displayName: String
    var dimPercent: Int
    var updatedAt: Date
}

@MainActor
final class SettingsStore: ObservableObject {
    static let minTimeoutSeconds = 1
    static let maxTimeoutSeconds = 180 * 60

    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Keys.isEnabled)
        }
    }

    @Published var idleTimeoutSeconds: Int {
        didSet {
            guard idleTimeoutSeconds != oldValue else { return }
            defaults.set(idleTimeoutSeconds, forKey: Keys.idleTimeoutSeconds)
        }
    }

    @Published var dimPercent: Int {
        didSet {
            guard dimPercent != oldValue else { return }
            defaults.set(dimPercent, forKey: Keys.dimPercent)
        }
    }

    /// Raw text of the m1ddc path field. It is bound directly to a text field, so it is
    /// deliberately not rewritten while the user types (that would make it impossible to
    /// type a space inside a path, or to clear the field before typing a new one).
    /// The persisted value is normalised; code that runs the tool should read
    /// `resolvedM1ddcPath`.
    @Published var m1ddcPath: String {
        didSet {
            guard m1ddcPath != oldValue else { return }
            defaults.set(resolvedM1ddcPath, forKey: Keys.m1ddcPath)
        }
    }

    /// Raw text of the brightness path field; see `m1ddcPath`. Read `resolvedBrightnessPath`.
    @Published var brightnessPath: String {
        didSet {
            guard brightnessPath != oldValue else { return }
            defaults.set(resolvedBrightnessPath, forKey: Keys.brightnessPath)
        }
    }

    /// `m1ddcPath` trimmed of whitespace, or the default path when empty — the same
    /// normalisation that is applied when the setting is loaded at launch.
    var resolvedM1ddcPath: String {
        Self.normalizedPath(m1ddcPath, fallback: CommandLocator.m1ddcDefaultPath)
    }

    /// `brightnessPath` trimmed of whitespace, or the default path when empty.
    var resolvedBrightnessPath: String {
        Self.normalizedPath(brightnessPath, fallback: CommandLocator.brightnessDefaultPath)
    }

    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
        }
    }

    @Published var hideMenuBarIcon: Bool {
        didSet {
            guard hideMenuBarIcon != oldValue else { return }
            defaults.set(hideMenuBarIcon, forKey: Keys.hideMenuBarIcon)
        }
    }

    @Published var diagnosticLoggingEnabled: Bool {
        didSet {
            guard diagnosticLoggingEnabled != oldValue else { return }
            defaults.set(diagnosticLoggingEnabled, forKey: Keys.diagnosticLoggingEnabled)
        }
    }

    @Published private(set) var displayControlPreferences: [String: DisplayControlPreference] {
        didSet {
            guard displayControlPreferences != oldValue else { return }
            saveDisplayControlPreferences()
        }
    }

    let defaults: UserDefaults

    /// Raw JSON values of stored per-display entries that could not be decoded. They are
    /// written back unchanged on every save, so one bad entry never erases the others.
    private var undecodableDisplayControlEntries: [String: Any]

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
        self.diagnosticLoggingEnabled = defaults.bool(forKey: Keys.diagnosticLoggingEnabled)

        let loaded = Self.loadDisplayControlPreferences(from: defaults)
        self.undecodableDisplayControlEntries = loaded.undecodableEntries
        self.displayControlPreferences = loaded.preferences

        if let unreadableData = loaded.unreadableData,
           defaults.object(forKey: Keys.displayControlPreferencesBackup) == nil {
            // The whole blob is unreadable and the next save will replace it, so keep a copy.
            defaults.set(unreadableData, forKey: Keys.displayControlPreferencesBackup)
        }
    }

    func currentSettings(externalBrightnessByDisplay: [String: Int]) -> DimmerSettings {
        DimmerSettings(
            isEnabled: isEnabled,
            idleTimeoutSeconds: Self.clampedSeconds(idleTimeoutSeconds),
            dimPercent: dimPercent,
            m1ddcPath: resolvedM1ddcPath,
            externalBrightnessByDisplay: externalBrightnessByDisplay
        )
    }

    func setIdleTimeoutSeconds(_ value: Int) {
        let seconds = Self.clampedSeconds(value)
        guard seconds != idleTimeoutSeconds else { return }
        idleTimeoutSeconds = seconds
    }

    func setTimeoutSliderValue(_ value: Double) {
        setIdleTimeoutSeconds(Self.seconds(fromSliderValue: value))
    }

    /// Below a minute the stepper moves in 1 s steps, from a minute up in 60 s steps:
    /// 59 s -> 60 s, 60 s -> 120 s.
    func incrementTimeout() {
        let current = Self.clampedSeconds(idleTimeoutSeconds)
        setIdleTimeoutSeconds(current < 60 ? current + 1 : current + 60)
    }

    /// Mirror of `incrementTimeout`. Stepping down from above a minute never lands below
    /// 60 s (61-120 s -> 60 s); from exactly 60 s it goes to 59 s, then in 1 s steps.
    func decrementTimeout() {
        let current = Self.clampedSeconds(idleTimeoutSeconds)
        setIdleTimeoutSeconds(current > 60 ? max(60, current - 60) : current - 1)
    }

    func setDimPercent(_ value: Int) {
        let percent = DimmerSettings.clampedPercent(value)
        if percent != dimPercent {
            dimPercent = percent
        }

        guard displayControlPreferences.values.contains(where: { $0.dimPercent != percent }) else {
            return
        }

        let updatedAt = Date()
        displayControlPreferences = displayControlPreferences.mapValues { preference in
            guard preference.dimPercent != percent else {
                return preference
            }
            return Self.normalizedDisplayControlPreference(
                id: preference.id,
                displayName: preference.displayName,
                dimPercent: percent,
                updatedAt: updatedAt
            )
        }
    }

    func seedDisplayControl(
        key: String,
        displayName: String,
        defaultDimPercent: Int
    ) -> DisplayControlPreference {
        if let preference = displayControlPreferences[key] {
            let normalizedPreference = Self.normalizedDisplayControlPreference(
                id: preference.id,
                displayName: displayName,
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
            dimPercent: DimmerSettings.clampedPercent(defaultDimPercent),
            existing: nil
        )
        return preference
    }

    @discardableResult
    func setDisplayDimPercent(_ value: Int, key: String, displayName: String) -> DisplayControlPreference {
        upsertDisplayControlPreference(
            for: key,
            displayName: displayName,
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

        let hours = clamped / 3_600
        let minutes = (clamped % 3_600) / 60
        let remainderSeconds = clamped % 60
        var components: [String] = []
        if hours > 0 {
            components.append("\(hours)h")
        }
        if minutes > 0 {
            components.append("\(minutes)m")
        }
        if remainderSeconds > 0 {
            components.append("\(remainderSeconds)s")
        }
        return components.joined(separator: " ")
    }

    /// Parses "5" (minutes), "30s", "5m", "2h" or combinations such as "1h 30m 5s".
    /// Returns nil for empty, malformed, overflowing or non-positive input, so "0" or "-5"
    /// are refused instead of being clamped up to a 1-second timeout.
    private static func parseTimeout(_ text: String) -> Int? {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")

        guard !normalized.isEmpty else {
            return nil
        }

        if let minutes = Int(normalized) {
            let (seconds, overflow) = minutes.multipliedReportingOverflow(by: 60)
            return overflow || seconds <= 0 ? nil : seconds
        }

        let characters = Array(normalized)
        var offset = 0
        var totalSeconds = 0
        while offset < characters.count {
            let numberStart = offset
            while offset < characters.count, characters[offset].wholeNumberValue != nil {
                offset += 1
            }
            guard numberStart < offset,
                  let value = Int(String(characters[numberStart..<offset])),
                  offset < characters.count else {
                return nil
            }

            let multiplier: Int
            switch characters[offset] {
            case "h": multiplier = 3_600
            case "m": multiplier = 60
            case "s": multiplier = 1
            default: return nil
            }
            offset += 1

            let (componentSeconds, multiplicationOverflow) = value.multipliedReportingOverflow(by: multiplier)
            let (newTotal, additionOverflow) = totalSeconds.addingReportingOverflow(componentSeconds)
            guard !multiplicationOverflow, !additionOverflow else {
                return nil
            }
            totalSeconds = newTotal
        }

        return totalSeconds > 0 ? totalSeconds : nil
    }

    private static func storedString(forKey key: String, in defaults: UserDefaults, fallback: String) -> String {
        normalizedPath(defaults.string(forKey: key) ?? "", fallback: fallback)
    }

    private static func normalizedPath(_ path: String, fallback: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    @discardableResult
    private func upsertDisplayControlPreference(
        for key: String,
        displayName: String,
        dimPercent: Int,
        existing: DisplayControlPreference?
    ) -> DisplayControlPreference {
        if let existing,
           existing.displayName == displayName,
           existing.dimPercent == DimmerSettings.clampedPercent(dimPercent) {
            return existing
        }

        let preference = Self.normalizedDisplayControlPreference(
            id: existing?.id ?? key,
            displayName: displayName,
            dimPercent: dimPercent,
            updatedAt: Date()
        )
        displayControlPreferences[key] = preference
        return preference
    }

    private func saveDisplayControlPreferences() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var data = try? encoder.encode(displayControlPreferences) else {
            return
        }

        let preserved = undecodableDisplayControlEntries.filter { displayControlPreferences[$0.key] == nil }
        if !preserved.isEmpty {
            // Never replace the stored blob with less data than it holds: merge the entries
            // that could not be decoded back in, and skip the write if that fails.
            guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return
            }
            for (key, value) in preserved {
                object[key] = value
            }
            guard JSONSerialization.isValidJSONObject(object),
                  let merged = try? JSONSerialization.data(withJSONObject: object) else {
                return
            }
            data = merged
        }

        defaults.set(data, forKey: Keys.displayControlPreferences)
    }

    private struct LoadedDisplayControlPreferences {
        var preferences: [String: DisplayControlPreference] = [:]
        /// Entries that are present in the stored dictionary but do not decode as a preference.
        var undecodableEntries: [String: Any] = [:]
        /// The stored blob, when it is not a JSON dictionary at all.
        var unreadableData: Data?
    }

    /// Decodes stored preferences entry by entry so one malformed entry does not discard the rest.
    private static func loadDisplayControlPreferences(
        from defaults: UserDefaults
    ) -> LoadedDisplayControlPreferences {
        var result = LoadedDisplayControlPreferences()
        guard let data = defaults.data(forKey: Keys.displayControlPreferences) else {
            return result
        }

        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            result.unreadableData = data
            return result
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for (key, value) in object {
            guard JSONSerialization.isValidJSONObject(value),
                  let entryData = try? JSONSerialization.data(withJSONObject: value),
                  let preference = try? decoder.decode(DisplayControlPreference.self, from: entryData) else {
                result.undecodableEntries[key] = value
                continue
            }

            result.preferences[key] = normalizedDisplayControlPreference(
                id: preference.id,
                displayName: preference.displayName,
                dimPercent: preference.dimPercent,
                updatedAt: preference.updatedAt
            )
        }

        return result
    }

    private static func normalizedDisplayControlPreference(
        id: String,
        displayName: String,
        dimPercent: Int,
        updatedAt: Date
    ) -> DisplayControlPreference {
        return DisplayControlPreference(
            id: id,
            displayName: displayName,
            dimPercent: DimmerSettings.clampedPercent(dimPercent),
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
        static let diagnosticLoggingEnabled = DiagnosticLogger.enabledDefaultsKey
        static let displayControlPreferences = "displayControlPreferences"
        static let displayControlPreferencesBackup = "displayControlPreferences.unreadableBackup"
    }
}
