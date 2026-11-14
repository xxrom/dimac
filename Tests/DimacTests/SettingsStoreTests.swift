@testable import Dimac
import DimacCore
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

    // MARK: Timeout stepper

    func testIncrementStepsBySecondsBelowAMinuteAndByMinutesFromAMinute() {
        let store = SettingsStore(defaults: makeDefaults())

        store.setIdleTimeoutSeconds(58)
        store.incrementTimeout()
        XCTAssertEqual(store.idleTimeoutSeconds, 59)
        store.incrementTimeout()
        XCTAssertEqual(store.idleTimeoutSeconds, 60)
        store.incrementTimeout()
        XCTAssertEqual(store.idleTimeoutSeconds, 120)

        store.setIdleTimeoutSeconds(SettingsStore.maxTimeoutSeconds)
        store.incrementTimeout()
        XCTAssertEqual(store.idleTimeoutSeconds, SettingsStore.maxTimeoutSeconds)
    }

    func testDecrementNeverJumpsFromMinutesToSeconds() {
        let store = SettingsStore(defaults: makeDefaults())

        store.setIdleTimeoutSeconds(180)
        store.decrementTimeout()
        XCTAssertEqual(store.idleTimeoutSeconds, 120)
        store.decrementTimeout()
        XCTAssertEqual(store.idleTimeoutSeconds, 60)
        store.decrementTimeout()
        XCTAssertEqual(store.idleTimeoutSeconds, 59)
        store.decrementTimeout()
        XCTAssertEqual(store.idleTimeoutSeconds, 58)

        for start in [61, 90, 119, 120] {
            store.setIdleTimeoutSeconds(start)
            store.decrementTimeout()
            XCTAssertEqual(store.idleTimeoutSeconds, 60)
        }

        store.setIdleTimeoutSeconds(125)
        store.decrementTimeout()
        XCTAssertEqual(store.idleTimeoutSeconds, 65)

        store.setIdleTimeoutSeconds(1)
        store.decrementTimeout()
        XCTAssertEqual(store.idleTimeoutSeconds, 1)
    }

    // MARK: Timeout text

    func testTimeoutTextParsing() {
        let store = SettingsStore(defaults: makeDefaults())

        store.setTimeoutFromText("30s")
        XCTAssertEqual(store.idleTimeoutSeconds, 30)
        store.setTimeoutFromText("5m")
        XCTAssertEqual(store.idleTimeoutSeconds, 300)
        store.setTimeoutFromText("2h")
        XCTAssertEqual(store.idleTimeoutSeconds, 7_200)
        store.setTimeoutFromText("  1H 30M 5S ")
        XCTAssertEqual(store.idleTimeoutSeconds, 5_405)
        store.setTimeoutFromText("7")
        XCTAssertEqual(store.idleTimeoutSeconds, 420)
        store.setTimeoutFromText("0m30s")
        XCTAssertEqual(store.idleTimeoutSeconds, 30)
        store.setTimeoutFromText("9999h")
        XCTAssertEqual(store.idleTimeoutSeconds, SettingsStore.maxTimeoutSeconds)
    }

    func testEmptyZeroNegativeAndOverflowingTimeoutTextIsRejected() {
        let store = SettingsStore(defaults: makeDefaults())
        store.setIdleTimeoutSeconds(75)

        for text in ["", "   ", "0", "-5", "0s", "0m", "0h 0m", "-5m", "5x", "m", "200000000000000000"] {
            store.setTimeoutFromText(text)
            XCTAssertEqual(store.idleTimeoutSeconds, 75)
        }
    }

    // MARK: Init

    func testInitClampsAndDefaultsStoredValues() {
        let defaults = makeDefaults()
        defaults.set(999_999, forKey: "idleTimeoutSeconds")
        defaults.set(250, forKey: "dimPercent")
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.idleTimeoutSeconds, SettingsStore.maxTimeoutSeconds)
        XCTAssertEqual(store.dimPercent, 100)
        XCTAssertTrue(store.isEnabled)

        let negative = makeDefaults()
        negative.set(-5, forKey: "idleTimeoutSeconds")
        negative.set(-5, forKey: "dimPercent")
        let negativeStore = SettingsStore(defaults: negative)
        XCTAssertEqual(negativeStore.idleTimeoutSeconds, 600)
        XCTAssertEqual(negativeStore.dimPercent, 10)

        let empty = SettingsStore(defaults: makeDefaults())
        XCTAssertEqual(empty.idleTimeoutSeconds, 600)
        XCTAssertEqual(empty.dimPercent, 10)
        XCTAssertTrue(empty.displayControlPreferences.isEmpty)
    }

    // MARK: Helper paths

    func testStoredPathsAreTrimmedAndFallBackToDefaultsAtLaunch() {
        let defaults = makeDefaults()
        defaults.set("  /opt/tools/m1ddc \n", forKey: "m1ddcPath")
        defaults.set("   ", forKey: "brightnessPath")

        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(store.m1ddcPath, "/opt/tools/m1ddc")
        XCTAssertEqual(store.brightnessPath, CommandLocator.brightnessDefaultPath)
    }

    func testEditedPathsResolveAndPersistNormalised() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)

        store.m1ddcPath = "/opt/My Tools/m1ddc "
        // The raw text is kept as typed so the field stays editable...
        XCTAssertEqual(store.m1ddcPath, "/opt/My Tools/m1ddc ")
        // ...but everything that uses the path sees the normalised value.
        XCTAssertEqual(store.resolvedM1ddcPath, "/opt/My Tools/m1ddc")
        XCTAssertEqual(store.currentSettings(externalBrightnessByDisplay: [:]).m1ddcPath, "/opt/My Tools/m1ddc")
        XCTAssertEqual(defaults.string(forKey: "m1ddcPath"), "/opt/My Tools/m1ddc")

        store.brightnessPath = "  "
        XCTAssertEqual(store.resolvedBrightnessPath, CommandLocator.brightnessDefaultPath)
        XCTAssertEqual(defaults.string(forKey: "brightnessPath"), CommandLocator.brightnessDefaultPath)

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.m1ddcPath, "/opt/My Tools/m1ddc")
        XCTAssertEqual(reloaded.brightnessPath, CommandLocator.brightnessDefaultPath)
    }

    // MARK: Redundant writes

    func testSettingAnUnchangedValueDoesNotWriteDefaults() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)
        store.setIdleTimeoutSeconds(90)
        store.setDimPercent(30)
        store.isEnabled = false
        let key = "display:external"
        _ = store.setDisplayDimPercent(30, key: key, displayName: "Monitor")

        defaults.removeObject(forKey: "idleTimeoutSeconds")
        defaults.removeObject(forKey: "dimPercent")
        defaults.removeObject(forKey: "isEnabled")
        defaults.removeObject(forKey: "displayControlPreferences")

        store.setIdleTimeoutSeconds(90)
        store.setTimeoutFromText("90s")
        store.setDimPercent(30)
        store.isEnabled = false
        let unchanged = store.setDisplayDimPercent(30, key: key, displayName: "Monitor")

        XCTAssertEqual(unchanged.dimPercent, 30)
        XCTAssertNil(defaults.object(forKey: "idleTimeoutSeconds"))
        XCTAssertNil(defaults.object(forKey: "dimPercent"))
        XCTAssertNil(defaults.object(forKey: "isEnabled"))
        XCTAssertNil(defaults.object(forKey: "displayControlPreferences"))

        store.setIdleTimeoutSeconds(91)
        XCTAssertEqual(defaults.integer(forKey: "idleTimeoutSeconds"), 91)
    }

    // MARK: Per-display preferences

    func testPartiallyCorruptDisplayPreferencesKeepValidEntriesAndPreserveBadOnes() throws {
        let defaults = makeDefaults()
        let blob = """
        {
          "display:good": {"id": "display:good", "displayName": "Good", "dimPercent": 40, "updatedAt": "2026-01-01T00:00:00Z"},
          "display:bad": {"id": "display:bad", "displayName": "Bad", "dimPercent": "forty"},
          "display:weird": 42
        }
        """
        defaults.set(Data(blob.utf8), forKey: "displayControlPreferences")

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.displayControlPreferences.count, 1)
        XCTAssertEqual(store.displayControlPreferences["display:good"]?.dimPercent, 40)

        _ = store.setDisplayDimPercent(55, key: "display:good", displayName: "Good")
        _ = store.seedDisplayControl(key: "display:new", displayName: "New", defaultDimPercent: 20)

        let storedData = try XCTUnwrap(defaults.data(forKey: "displayControlPreferences"))
        let stored = try XCTUnwrap(try JSONSerialization.jsonObject(with: storedData) as? [String: Any])
        XCTAssertNotNil(stored["display:bad"])
        XCTAssertEqual(stored["display:weird"] as? Int, 42)

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.displayControlPreferences["display:good"]?.dimPercent, 55)
        XCTAssertEqual(reloaded.displayControlPreferences["display:new"]?.dimPercent, 20)
        XCTAssertNil(reloaded.displayControlPreferences["display:bad"])
    }

    func testReplacingABadDisplayEntryDropsTheBadCopy() throws {
        let defaults = makeDefaults()
        let blob = #"{"display:bad": {"id": "display:bad", "dimPercent": "forty"}}"#
        defaults.set(Data(blob.utf8), forKey: "displayControlPreferences")

        let store = SettingsStore(defaults: defaults)
        _ = store.seedDisplayControl(key: "display:bad", displayName: "Fixed", defaultDimPercent: 25)

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.displayControlPreferences["display:bad"]?.dimPercent, 25)
        XCTAssertEqual(reloaded.displayControlPreferences["display:bad"]?.displayName, "Fixed")
    }

    func testUnreadableDisplayPreferencesBlobIsBackedUp() {
        let defaults = makeDefaults()
        let garbage = Data("not json".utf8)
        defaults.set(garbage, forKey: "displayControlPreferences")

        let store = SettingsStore(defaults: defaults)

        XCTAssertTrue(store.displayControlPreferences.isEmpty)
        XCTAssertEqual(defaults.data(forKey: "displayControlPreferences.unreadableBackup"), garbage)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "dimac.tests.\(UUID().uuidString)"
        // Never fall back to `.standard`: that would write into the real app's settings.
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Could not create isolated UserDefaults suite \(suiteName)")
        }
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
