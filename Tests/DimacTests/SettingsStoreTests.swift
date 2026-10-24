@testable import Dimac
import XCTest

@MainActor
final class SettingsStoreTests: XCTestCase {
    func testDisplayDimPercentPersistsAcrossStoreInstances() {
        let defaults = makeDefaults()
        let key = "display:external"
        let store = SettingsStore(defaults: defaults)

        _ = store.seedDisplayControl(
            key: key,
            displayName: "MSI PS341WU",
            defaultDimPercent: 20
        )
        let updated = store.setDisplayDimPercent(95, key: key, displayName: "MSI PS341WU")

        XCTAssertEqual(updated.dimPercent, 95)
        XCTAssertEqual(SettingsStore(defaults: defaults).displayControlPreferences[key]?.dimPercent, 95)
    }

    func testSeedingExistingDisplayKeepsDimTargetAndRefreshesName() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)
        let key = "display:built-in"

        _ = store.seedDisplayControl(
            key: key,
            displayName: "Built-in Retina Display",
            defaultDimPercent: 30
        )
        _ = store.setDisplayDimPercent(45, key: key, displayName: "Built-in Retina Display")

        let reseeded = store.seedDisplayControl(
            key: key,
            displayName: "Renamed display",
            defaultDimPercent: 15
        )

        XCTAssertEqual(reseeded.displayName, "Renamed display")
        XCTAssertEqual(reseeded.dimPercent, 45)
    }

    func testSettingDimPercentUpdatesDisconnectedDisplayPreferences() {
        let defaults = makeDefaults()
        let key = "display:disconnected"
        let store = SettingsStore(defaults: defaults)
        _ = store.seedDisplayControl(key: key, displayName: "Offline monitor", defaultDimPercent: 10)
        _ = store.setDisplayDimPercent(35, key: key, displayName: "Offline monitor")

        store.setDimPercent(20)

        let reloadedStore = SettingsStore(defaults: defaults)
        let reconnected = reloadedStore.seedDisplayControl(
            key: key,
            displayName: "Offline monitor",
            defaultDimPercent: reloadedStore.dimPercent
        )
        XCTAssertEqual(reconnected.dimPercent, 20)
    }

    func testLegacyBrightPercentDoesNotCapMigratedDimPercent() throws {
        let defaults = makeDefaults()
        let key = "display:external"
        let legacyPreference = LegacyDisplayControlPreference(
            id: key,
            displayName: "MSI PS341WU",
            normalPercent: 40,
            dimPercent: 90,
            updatedAt: Date()
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        defaults.set(
            try encoder.encode([key: legacyPreference]),
            forKey: "displayControlPreferences"
        )

        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(store.displayControlPreferences[key]?.dimPercent, 90)
    }

    func testTimeoutAcceptsCompoundValuesAndFormatsWithoutLosingSeconds() {
        let store = SettingsStore(defaults: makeDefaults())

        store.setTimeoutFromText("1h 30m 5s")

        XCTAssertEqual(store.idleTimeoutSeconds, 5_405)
        XCTAssertEqual(store.timeoutText, "1h 30m 5s")
    }

    func testInvalidOrOverflowingTimeoutDoesNotChangeSetting() {
        let store = SettingsStore(defaults: makeDefaults())
        store.setIdleTimeoutSeconds(75)

        store.setTimeoutFromText("1hour")
        XCTAssertEqual(store.idleTimeoutSeconds, 75)
        store.setTimeoutFromText("999999999999999999999999h")
        XCTAssertEqual(store.idleTimeoutSeconds, 75)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "dimac.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}

private struct LegacyDisplayControlPreference: Codable {
    let id: String
    var displayName: String
    var normalPercent: Int
    var dimPercent: Int
    var updatedAt: Date
}
