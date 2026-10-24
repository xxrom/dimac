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

    func testReconnectRetriesPendingRestoreAndClearsStaleError() throws {
        let suite = "dimac.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let hardware = TestInternalBrightness()
        let external = TestExternalBrightness()
        external.displays = [ExternalDisplayReference(selector: "1", name: "Monitor")]
        let store = TestSnapshotStore()
        let dimmer = DimmerController(
            settingsProvider: { DimmerSettings(dimPercent: 10) },
            internalBrightness: hardware,
            externalBrightness: external,
            snapshotStore: store
        )
        let model = AppModel(
            settings: settings, dimmer: dimmer, startAutomatically: false,
            brightnessControls: CurrentBrightnessController(internalBrightness: hardware, externalBrightness: external),
            displayProvider: {
                [ConnectedDisplayRow(id: "1", index: 0, name: "Built-in", resolution: "", brightnessPercent: nil,
                                     isBuiltIn: true, isExternal: false, canReadHardwareBrightness: true),
                 ConnectedDisplayRow(id: "2", index: 1, name: "Monitor", resolution: "", brightnessPercent: nil,
                                     isBuiltIn: false, isExternal: true, canReadHardwareBrightness: false)]
            }
        )

        model.dimNow()
        external.displays = []
        dimmer.handleUserActivity()
        XCTAssertEqual(hardware.value, 0.7, accuracy: 0.0001)
        XCTAssertTrue(dimmer.isDimmed)
        XCTAssertEqual(hardware.writeCount, 2)

        model.refreshExternalDisplays()
        model.setCurrentBrightness(45, for: "display:1")
        XCTAssertEqual(hardware.value, 0.45, accuracy: 0.0001)
        XCTAssertTrue(dimmer.isDimmed)

        external.displays = [ExternalDisplayReference(selector: "2", name: "Monitor")]
        external.failWrites = true
        model.refreshExternalDisplays()
        XCTAssertTrue(dimmer.isDimmed)
        XCTAssertEqual(dimmer.statusMessage, "Restore failed; will retry")
        XCTAssertNotNil(dimmer.lastError)

        external.failWrites = false
        model.refreshExternalDisplays()
        XCTAssertFalse(dimmer.isDimmed)
        XCTAssertNil(dimmer.lastError)
        XCTAssertNil(store.snapshot)
        XCTAssertEqual(external.value, 65)
        XCTAssertEqual(external.writes.last?.display.selector, "2")
        XCTAssertEqual(hardware.value, 0.45, accuracy: 0.0001)
        XCTAssertEqual(hardware.writeCount, 3)
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
    var displays: [ExternalDisplayReference] = []
    var value = 65
    var failWrites = false
    var writes: [ExternalDisplaySnapshot] = []
    func discoverDisplays() throws -> [ExternalDisplayReference] { displays }
    func currentSnapshot(for displays: [ExternalDisplayReference]) throws -> [ExternalDisplaySnapshot] {
        displays.map { ExternalDisplaySnapshot(display: $0, luminance: value) }
    }
    func setBrightness(percent: Int, for displays: [ExternalDisplayReference]) throws {}
    func restore(_ snapshots: [ExternalDisplaySnapshot]) throws {
        if failWrites { throw BrightnessError.writeFailed("Monitor") }
        for snapshot in snapshots {
            writes.append(snapshot)
            value = snapshot.luminance
        }
    }
}

private final class TestSnapshotStore: SnapshotPersisting {
    var snapshot: BrightnessSnapshot?
    func load() throws -> BrightnessSnapshot? { snapshot }
    func save(_ snapshot: BrightnessSnapshot) throws { self.snapshot = snapshot }
    func clear() throws { snapshot = nil }
}
