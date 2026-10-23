@testable import Dimac
import DimacCore
import XCTest

@MainActor
final class CurrentBrightnessTests: XCTestCase {
    func testLiveControlBecomesNextRestoreLevelWithoutSavingBrightPreference() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.model.refreshExternalDisplays()
        XCTAssertEqual(fixture.model.displayControlRows.first?.currentPercent, 65)
        XCTAssertEqual(fixture.external.writes.count, 0)
        let preferences = fixture.settings.displayControlPreferences

        fixture.model.setCurrentBrightness(43, for: "display:1")
        XCTAssertEqual(fixture.external.value, 43)
        XCTAssertEqual(fixture.settings.displayControlPreferences, preferences)
        fixture.model.dimNow()
        XCTAssertEqual(fixture.external.value, 10)
        fixture.model.restoreNow()
        XCTAssertEqual(fixture.external.value, 43)
    }

    func testAdjustmentWhileDimmedEndsCycleEvenWhenValueEqualsDimTarget() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.model.refreshExternalDisplays()
        fixture.model.dimNow()
        fixture.model.setCurrentBrightness(10, for: "display:1")
        XCTAssertFalse(fixture.dimmer.isDimmed)
        fixture.dimmer.handleUserActivity()
        XCTAssertEqual(fixture.external.value, 10)
        XCTAssertNil(fixture.store.snapshot)
    }

    func testFailedWriteReadsActualBrightnessAndReportsError() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.model.refreshExternalDisplays()
        fixture.external.failWrites = true
        fixture.model.setCurrentBrightness(43, for: "display:1")
        XCTAssertEqual(fixture.model.displayControlRows.first?.currentPercent, 65)
        XCTAssertNotNil(fixture.dimmer.lastError)
    }

    func testMonitorWithUnavailableReadingStillAcceptsManualBrightness() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.external.failReads = true
        fixture.model.refreshExternalDisplays()
        XCTAssertTrue(fixture.model.displayControlRows[0].isControllable)
        XCTAssertNil(fixture.model.displayControlRows[0].currentPercent)
        fixture.model.setCurrentBrightness(43, for: "display:1")
        XCTAssertEqual(fixture.external.value, 43)
        XCTAssertEqual(fixture.model.displayControlRows[0].requestedPercent, 43)
        XCTAssertNil(fixture.model.displayControlRows[0].currentPercent)
        XCTAssertNil(fixture.dimmer.lastError)
    }

    func testUnreadableExternalDimsAlongsideInternalAndRestoresManualLevel() {
        for level in [0, 5, 43, 100] {
            let fixture = Fixture()
            defer { fixture.cleanUp() }
            fixture.external.failReads = true
            fixture.model.refreshExternalDisplays()
            fixture.model.setCurrentBrightness(level, for: "display:1")
            fixture.dimmer.handleIdleTime(1000)
            XCTAssertEqual(fixture.external.value, min(level, 10))
            XCTAssertEqual(fixture.internalBrightness.value, 0.1, accuracy: 0.0001)
            fixture.dimmer.handleUserActivity()
            XCTAssertEqual(fixture.external.value, level)
            XCTAssertEqual(fixture.internalBrightness.value, 0.7, accuracy: 0.0001)
            XCTAssertFalse(fixture.dimmer.isDimmed)
        }
    }

    func testUnreadableExternalWithoutSuccessfulSettingIsSkipped() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.external.failReads = true
        fixture.external.failWrites = true
        fixture.model.refreshExternalDisplays()
        fixture.model.setCurrentBrightness(43, for: "display:1")
        fixture.external.failWrites = false
        fixture.model.dimNow()
        XCTAssertEqual(fixture.external.value, 65)
        XCTAssertEqual(fixture.internalBrightness.value, 0.1, accuracy: 0.0001)
    }

    func testLiveExternalReadingOverridesEarlierManualSetting() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.model.refreshExternalDisplays()
        fixture.model.setCurrentBrightness(43, for: "display:1")
        fixture.external.value = 72
        fixture.model.dimNow()
        fixture.model.restoreNow()
        XCTAssertEqual(fixture.external.value, 72)
    }

    func testUnreadableExternalRestoreRetriesWithoutRedimmingInternal() {
        var now = Date(timeIntervalSince1970: 1_000)
        let fixture = Fixture(now: { now })
        defer { fixture.cleanUp() }
        fixture.external.failReads = true
        fixture.model.refreshExternalDisplays()
        fixture.model.setCurrentBrightness(43, for: "display:1")
        fixture.model.dimNow()
        fixture.external.failWrites = true
        fixture.dimmer.handleUserActivity()
        XCTAssertTrue(fixture.dimmer.isDimmed)
        XCTAssertEqual(fixture.internalBrightness.value, 0.7, accuracy: 0.0001)
        XCTAssertEqual(fixture.store.snapshot?.externalDisplays.first?.luminance, 43)
        fixture.external.failWrites = false
        now.addTimeInterval(5)
        fixture.dimmer.handleUserActivity()
        XCTAssertEqual(fixture.external.value, 43)
        XCTAssertFalse(fixture.dimmer.isDimmed)
    }

    func testUnreadableExternalRestoresSavedCycleAfterRestart() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.external.failReads = true
        fixture.model.refreshExternalDisplays()
        fixture.model.setCurrentBrightness(43, for: "display:1")
        fixture.model.dimNow()
        let restarted = DimmerController(settingsProvider: { DimmerSettings(dimPercent: 10) }, internalBrightness: fixture.internalBrightness, externalBrightness: fixture.external, snapshotStore: fixture.store)
        restarted.restorePersistedSnapshotIfNeeded()
        XCTAssertEqual(fixture.external.value, 43)
        XCTAssertFalse(restarted.isDimmed)
        // A completed recovery does not establish a fresh session's manual baseline.
        restarted.dimNow()
        XCTAssertEqual(fixture.external.value, 43)
        XCTAssertEqual(fixture.internalBrightness.value, 0.1, accuracy: 0.0001)
    }

    func testUnreadableAdjustmentDuringDimSurvivesMouseActivity() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.external.failReads = true
        fixture.model.refreshExternalDisplays()
        fixture.model.setCurrentBrightness(43, for: "display:1")
        fixture.model.dimNow()
        fixture.model.setCurrentBrightness(10, for: "display:1")
        fixture.dimmer.handleUserActivity()
        XCTAssertEqual(fixture.external.value, 10)
        XCTAssertFalse(fixture.dimmer.isDimmed)
    }

    func testFailedManualWriteDoesNotReplaceSuccessfulBaseline() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.external.failReads = true
        fixture.model.refreshExternalDisplays()
        fixture.model.setCurrentBrightness(43, for: "display:1")
        fixture.external.failWrites = true
        fixture.model.setCurrentBrightness(80, for: "display:1")
        fixture.external.failWrites = false
        fixture.model.dimNow()
        fixture.model.restoreNow()
        XCTAssertEqual(fixture.external.value, 43)
    }

    func testManualControlResolvesNewSelectorAndRejectsAmbiguousDisplay() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.model.refreshExternalDisplays()
        let row = try XCTUnwrap(fixture.model.displayControlRows.first)
        fixture.external.displays[0].selector = "2"
        try fixture.controls.set(40, for: row)
        XCTAssertEqual(fixture.external.writes.last?.display.selector, "2")
        fixture.external.displays.append(ExternalDisplayReference(selector: "3", name: "Monitor"))
        XCTAssertThrowsError(try fixture.controls.set(60, for: row))
        XCTAssertEqual(fixture.external.value, 40)
    }

    func testManualControlResolvesUUIDAfterSelectorAndNameChange() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let uuid = "37D8832A-2D66-02CA-B9F7-8F30A301B230"
        fixture.external.displays[0].uuid = uuid
        fixture.model.refreshExternalDisplays()
        let row = try XCTUnwrap(fixture.model.displayControlRows.first)

        fixture.external.displays = [
            ExternalDisplayReference(selector: "2", name: "Renamed Monitor", uuid: uuid),
            ExternalDisplayReference(selector: "3", name: "Monitor", uuid: "37D8832A-2D66-02CA-B9F7-8F30A301B231")
        ]
        try fixture.controls.set(40, for: row)

        XCTAssertEqual(fixture.external.writes.last?.display.selector, "2")
        XCTAssertEqual(fixture.external.writes.last?.display.uuid, uuid)
        XCTAssertEqual(try fixture.controls.read(row), 40)
    }

    func testManualControlRejectsSameNameReplacementWithDifferentUUID() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.external.displays[0].uuid = "37D8832A-2D66-02CA-B9F7-8F30A301B230"
        fixture.model.refreshExternalDisplays()
        let row = try XCTUnwrap(fixture.model.displayControlRows.first)
        fixture.external.displays[0].uuid = "37D8832A-2D66-02CA-B9F7-8F30A301B231"

        XCTAssertThrowsError(try fixture.controls.set(40, for: row))
        XCTAssertThrowsError(try fixture.controls.read(row))
        XCTAssertTrue(fixture.external.writes.isEmpty)
        XCTAssertEqual(fixture.external.value, 65)
    }
}

@MainActor
private final class Fixture {
    let suite = "dimac.tests.\(UUID().uuidString)"
    let settings: SettingsStore
    let external = LiveExternal()
    let internalBrightness = NoInternal()
    let store = LiveStore()
    let controls: CurrentBrightnessController
    let dimmer: DimmerController
    let model: AppModel

    init(now: @escaping () -> Date = Date.init) {
        let defaults = UserDefaults(suiteName: suite)!
        settings = SettingsStore(defaults: defaults)
        controls = CurrentBrightnessController(internalBrightness: internalBrightness, externalBrightness: external)
        dimmer = DimmerController(settingsProvider: { DimmerSettings(dimPercent: 10) }, internalBrightness: internalBrightness, externalBrightness: external, snapshotStore: store, now: now)
        model = AppModel(settings: settings, dimmer: dimmer, startAutomatically: false, brightnessControls: controls, displayProvider: {
            [ConnectedDisplayRow(id: "1", index: 0, name: "Monitor", resolution: "", brightnessPercent: nil, isBuiltIn: false, isExternal: true, canReadHardwareBrightness: false)]
        })
    }
    func cleanUp() { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
}

private final class LiveExternal: ExternalBrightnessManaging {
    var displays = [ExternalDisplayReference(selector: "1", name: "Monitor")]
    var value = 65
    var failWrites = false
    var failReads = false
    var writes: [ExternalDisplaySnapshot] = []
    func discoverDisplays() throws -> [ExternalDisplayReference] { displays }
    func currentSnapshot(for displays: [ExternalDisplayReference]) throws -> [ExternalDisplaySnapshot] {
        if failReads { throw BrightnessError.readFailed("Monitor") }
        return displays.map { ExternalDisplaySnapshot(display: $0, luminance: value) }
    }
    func setBrightness(percent: Int, for displays: [ExternalDisplayReference]) throws { value = percent }
    func restore(_ snapshots: [ExternalDisplaySnapshot]) throws {
        if failWrites { throw BrightnessError.writeFailed("Monitor") }
        for snapshot in snapshots { writes.append(snapshot); value = snapshot.luminance }
    }
}
private final class NoInternal: InternalBrightnessManaging {
    var value: Float = 0.7
    func currentSnapshot() throws -> [InternalDisplaySnapshot] { [InternalDisplaySnapshot(displayID: 99, brightness: value)] }
    func setBrightness(percent: Int) throws {}
    func restore(_ snapshots: [InternalDisplaySnapshot]) throws { value = snapshots.first?.brightness ?? value }
}
private final class LiveStore: SnapshotPersisting {
    var snapshot: BrightnessSnapshot?
    func load() throws -> BrightnessSnapshot? { snapshot }
    func save(_ snapshot: BrightnessSnapshot) throws { self.snapshot = snapshot }
    func clear() throws { snapshot = nil }
}
