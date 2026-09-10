@testable import Dimac
import DimacCore
import XCTest

@MainActor
final class AppModelBrightnessTests: XCTestCase {
    func testManualCycleUsesHardwareSnapshotInsteadOfSavedConfiguration() throws {
        let suite = "dimac.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let hardware = TestInternalBrightness()
        let dimmer = DimmerController(
            settingsProvider: { DimmerSettings(dimPercent: 10) },
            internalBrightness: hardware,
            externalBrightness: TestExternalBrightness(),
            snapshotStore: TestSnapshotStore()
        )
        let model = AppModel(settings: settings, dimmer: dimmer, startAutomatically: false)

        hardware.value = 0.43
        model.dimNow()
        XCTAssertTrue(dimmer.isDimmed)
        XCTAssertEqual(hardware.value, 0.1, accuracy: 0.0001)

        model.restoreNow()
        XCTAssertFalse(dimmer.isDimmed)
        XCTAssertEqual(hardware.value, 0.43, accuracy: 0.0001)
    }

    func testChangingDimConfigurationDoesNotWriteActiveBrightness() throws {
        let suite = "dimac.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let hardware = TestInternalBrightness()
        let dimmer = DimmerController(
            settingsProvider: { DimmerSettings(dimPercent: settings.dimPercent) },
            internalBrightness: hardware,
            externalBrightness: TestExternalBrightness(),
            snapshotStore: TestSnapshotStore()
        )
        let model = AppModel(settings: settings, dimmer: dimmer, startAutomatically: false)

        model.setDimPercent(20)
        XCTAssertEqual(hardware.value, 0.7, accuracy: 0.0001)
        XCTAssertEqual(hardware.writeCount, 0)
        model.dimNow()
        XCTAssertEqual(hardware.value, 0.2, accuracy: 0.0001)
        model.setDimPercent(30)
        XCTAssertEqual(hardware.value, 0.2, accuracy: 0.0001)
        model.restoreNow()
        XCTAssertEqual(hardware.value, 0.7, accuracy: 0.0001)
    }
}

private final class TestInternalBrightness: InternalBrightnessManaging {
    var value: Float = 0.7
    var writeCount = 0
    func currentSnapshot() throws -> [InternalDisplaySnapshot] {
        [InternalDisplaySnapshot(displayID: 1, brightness: value)]
    }
    func setBrightness(percent: Int) throws {
        value = Float(percent) / 100
        writeCount += 1
    }
    func restore(_ snapshots: [InternalDisplaySnapshot]) throws {
        for snapshot in snapshots {
            value = snapshot.brightness
            writeCount += 1
        }
    }
}

private final class TestExternalBrightness: ExternalBrightnessManaging {
    func discoverDisplays() throws -> [ExternalDisplayReference] { [] }
    func currentSnapshot(for displays: [ExternalDisplayReference]) throws -> [ExternalDisplaySnapshot] { [] }
    func setBrightness(percent: Int, for displays: [ExternalDisplayReference]) throws {}
    func restore(_ snapshots: [ExternalDisplaySnapshot]) throws {}
}

private final class TestSnapshotStore: SnapshotPersisting {
    var snapshot: BrightnessSnapshot?
    func load() throws -> BrightnessSnapshot? { snapshot }
    func save(_ snapshot: BrightnessSnapshot) throws { self.snapshot = snapshot }
    func clear() throws { snapshot = nil }
}
