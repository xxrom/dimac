@testable import Dimac
import DimacCore
import XCTest

@MainActor
final class AppModelPresentationTests: XCTestCase {
    func testSettingsPresentationCountIsIdempotentPerPresentation() throws {
        let suite = "dimac.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(settings: SettingsStore(defaults: defaults), dimmer: makeDimmer(), startAutomatically: false)

        XCTAssertFalse(model.isShowingSettings)
        model.setSettingsPresentation(.popover, visible: true)
        model.setSettingsPresentation(.popover, visible: true)
        model.setSettingsPresentation(.window, visible: true)
        XCTAssertTrue(model.isShowingSettings)

        model.setSettingsPresentation(.popover, visible: false)
        XCTAssertTrue(model.isShowingSettings)
        model.setSettingsPresentation(.window, visible: false)
        XCTAssertFalse(model.isShowingSettings)

        // Extra close notifications must not leave the count negative or stuck.
        model.setSettingsPresentation(.window, visible: false)
        model.setSettingsPresentation(.popover, visible: false)
        XCTAssertFalse(model.isShowingSettings)
        model.setSettingsPresentation(.popover, visible: true)
        XCTAssertTrue(model.isShowingSettings)
        model.setSettingsPresentation(.popover, visible: false)
        XCTAssertFalse(model.isShowingSettings)
    }

    func testReopenIsIgnoredDuringLaunchGracePeriod() {
        let launch = Date(timeIntervalSinceReferenceDate: 1_000)
        XCTAssertFalse(AppModel.shouldHandleReopen(launchedAt: launch, now: launch))
        XCTAssertFalse(AppModel.shouldHandleReopen(launchedAt: launch, now: launch.addingTimeInterval(1.5)))
        XCTAssertTrue(AppModel.shouldHandleReopen(launchedAt: launch, now: launch.addingTimeInterval(2)))
        XCTAssertTrue(AppModel.shouldHandleReopen(launchedAt: launch, now: launch.addingTimeInterval(60)))
    }

    func testActivityHandlingIsThrottledButFirstEventIsImmediate() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        XCTAssertTrue(AppModel.shouldHandleActivity(lastHandledAt: .distantPast, now: now))
        XCTAssertFalse(AppModel.shouldHandleActivity(lastHandledAt: now, now: now))
        XCTAssertFalse(AppModel.shouldHandleActivity(lastHandledAt: now, now: now.addingTimeInterval(0.1)))
        XCTAssertTrue(AppModel.shouldHandleActivity(lastHandledAt: now, now: now.addingTimeInterval(0.3)))
        // A clock that moved backwards must not block activity handling.
        XCTAssertTrue(AppModel.shouldHandleActivity(lastHandledAt: now, now: now.addingTimeInterval(-10)))
    }

    func testZeroBrightnessFromSliderIsNotRecordedAsNormalLevel() throws {
        let suite = "dimac.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let monitor = ExternalDisplayReference(selector: "1", name: "Monitor")
        let external = PresentationTestExternalBrightness()
        external.displays = [monitor]
        let dimmer = DimmerController(
            settingsProvider: { DimmerSettings(dimPercent: 10) },
            internalBrightness: PresentationTestInternalBrightness(),
            externalBrightness: external,
            snapshotStore: PresentationTestSnapshotStore()
        )
        let model = AppModel(
            settings: SettingsStore(defaults: defaults), dimmer: dimmer, startAutomatically: false,
            brightnessControls: WriteOnlyBrightnessControls(),
            displayProvider: {
                [ConnectedDisplayRow(id: "2", index: 0, name: "Monitor", resolution: "", brightnessPercent: nil,
                                     isBuiltIn: false, isExternal: true, canReadHardwareBrightness: false)]
            }
        )
        model.refreshExternalDisplays()
        XCTAssertEqual(model.displayControlRows.first?.mode, .ddc(monitor))

        model.setCurrentBrightness(50, for: "display:2")
        XCTAssertEqual(dimmer.lastKnownExternalBrightness(for: monitor), 50)

        model.setCurrentBrightness(0, for: "display:2")
        XCTAssertEqual(dimmer.lastKnownExternalBrightness(for: monitor), 50)
    }

    private func makeDimmer() -> DimmerController {
        DimmerController(
            settingsProvider: { DimmerSettings(dimPercent: 10) },
            internalBrightness: PresentationTestInternalBrightness(),
            externalBrightness: PresentationTestExternalBrightness(),
            snapshotStore: PresentationTestSnapshotStore()
        )
    }
}

/// A monitor that accepts writes but cannot report its level.
private final class WriteOnlyBrightnessControls: CurrentBrightnessManaging {
    func read(_ row: DisplayControlRow) throws -> Int { throw BrightnessError.readFailed(row.name) }
    func set(_ percent: Int, for row: DisplayControlRow) throws {}
}

private final class PresentationTestInternalBrightness: InternalBrightnessManaging {
    func currentSnapshot() throws -> [InternalDisplaySnapshot] { [] }
    func setBrightness(percent: Int) throws {}
    func restore(_ snapshots: [InternalDisplaySnapshot]) throws {}
}

private final class PresentationTestExternalBrightness: ExternalBrightnessManaging {
    var displays: [ExternalDisplayReference] = []
    func discoverDisplays() throws -> [ExternalDisplayReference] { displays }
    func currentSnapshot(for displays: [ExternalDisplayReference]) throws -> [ExternalDisplaySnapshot] { [] }
    func setBrightness(percent: Int, for displays: [ExternalDisplayReference]) throws {}
    func restore(_ snapshots: [ExternalDisplaySnapshot]) throws {}
}

private final class PresentationTestSnapshotStore: SnapshotPersisting {
    func load() throws -> BrightnessSnapshot? { nil }
    func save(_ snapshot: BrightnessSnapshot) throws {}
    func clear() throws {}
}
