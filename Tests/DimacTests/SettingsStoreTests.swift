@testable import Dimac
import XCTest

@MainActor
final class SettingsStoreTests: XCTestCase {
    func testLoweringBrightPercentAlsoLowersDimPercent() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)
        let key = "display:built-in"

        _ = store.seedDisplayControl(
            key: key,
            displayName: "Built-in Retina Display",
            currentPercent: 80,
            defaultDimPercent: 30
        )
        _ = store.setDisplayDimPercent(60, key: key, displayName: "Built-in Retina Display")

        let updated = store.setDisplayNormalPercent(
            50,
            key: key,
            displayName: "Built-in Retina Display"
        )

        XCTAssertEqual(updated.normalPercent, 50)
        XCTAssertEqual(updated.dimPercent, 50)
        XCTAssertEqual(store.displayControlPreferences[key]?.dimPercent, 50)
    }

    func testDimPercentIsClampedToBrightPercent() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)
        let key = "display:external"

        _ = store.seedDisplayControl(
            key: key,
            displayName: "MSI PS341WU",
            currentPercent: 70,
            defaultDimPercent: 20
        )

        let updated = store.setDisplayDimPercent(95, key: key, displayName: "MSI PS341WU")

        XCTAssertEqual(updated.normalPercent, 70)
        XCTAssertEqual(updated.dimPercent, 70)
    }

    func testInvalidLoadedPreferenceIsNormalized() throws {
        let suiteName = "dimac.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let key = "display:external"
        let invalidPreference = DisplayControlPreference(
            id: key,
            displayName: "MSI PS341WU",
            normalPercent: 40,
            dimPercent: 90,
            updatedAt: Date()
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        defaults.set(
            try encoder.encode([key: invalidPreference]),
            forKey: "displayControlPreferences"
        )

        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(store.displayControlPreferences[key]?.normalPercent, 40)
        XCTAssertEqual(store.displayControlPreferences[key]?.dimPercent, 40)
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
