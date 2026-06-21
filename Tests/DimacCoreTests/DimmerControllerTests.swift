import DimacCore
import XCTest

@MainActor
final class DimmerControllerTests: XCTestCase {
    func testDimsAfterTimeoutAndRestoresOnActivity() {
        let internalController = MockInternalBrightnessController()
        let externalController = MockExternalBrightnessController()
        let store = MemorySnapshotStore()

        let controller = DimmerController(
            settingsProvider: {
                DimmerSettings(isEnabled: true, idleTimeoutSeconds: 10, dimPercent: 10)
            },
            internalBrightness: internalController,
            externalBrightness: externalController,
            snapshotStore: store
        )

        controller.handleIdleTime(11)

        XCTAssertTrue(controller.isDimmed)
        XCTAssertEqual(internalController.currentBrightness, 0.1, accuracy: 0.0001)
        XCTAssertEqual(externalController.currentLuminance, 10)
        XCTAssertNotNil(store.snapshot)

        controller.handleUserActivity()

        XCTAssertFalse(controller.isDimmed)
        XCTAssertEqual(internalController.currentBrightness, 0.7, accuracy: 0.0001)
        XCTAssertEqual(externalController.currentLuminance, 65)
        XCTAssertNil(store.snapshot)
    }

    func testDisabledSettingsRestoreActiveDimState() {
        let internalController = MockInternalBrightnessController()
        let externalController = MockExternalBrightnessController()
        let store = MemorySnapshotStore()
        var enabled = true

        let controller = DimmerController(
            settingsProvider: {
                DimmerSettings(isEnabled: enabled, idleTimeoutSeconds: 10, dimPercent: 10)
            },
            internalBrightness: internalController,
            externalBrightness: externalController,
            snapshotStore: store
        )

        controller.handleIdleTime(11)
        enabled = false
        controller.handleIdleTime(11)

        XCTAssertFalse(controller.isDimmed)
        XCTAssertEqual(internalController.currentBrightness, 0.7, accuracy: 0.0001)
    }

    func testRestoresExternalDisplayToSavedPreference() {
        let internalController = MockInternalBrightnessController()
        let externalController = MockExternalBrightnessController()
        let store = MemorySnapshotStore()
        let preferenceKey = externalController.display.brightnessPreferenceKey

        let controller = DimmerController(
            settingsProvider: {
                DimmerSettings(
                    isEnabled: true,
                    idleTimeoutSeconds: 10,
                    dimPercent: 10,
                    externalBrightnessByDisplay: [preferenceKey: 78]
                )
            },
            internalBrightness: internalController,
            externalBrightness: externalController,
            snapshotStore: store
        )

        controller.handleIdleTime(11)
        XCTAssertEqual(externalController.currentLuminance, 10)

        controller.handleUserActivity()

        XCTAssertFalse(controller.isDimmed)
        XCTAssertEqual(externalController.currentLuminance, 78)
    }

    func testDisplayControlledFlowCanSkipHardwareWrites() {
        let internalController = MockInternalBrightnessController()
        let externalController = MockExternalBrightnessController()
        let store = MemorySnapshotStore()

        let controller = DimmerController(
            settingsProvider: {
                DimmerSettings(isEnabled: true, idleTimeoutSeconds: 10, dimPercent: 10)
            },
            internalBrightness: internalController,
            externalBrightness: externalController,
            snapshotStore: store
        )

        controller.handleIdleTime(11, applyHardware: false)

        XCTAssertTrue(controller.isDimmed)
        XCTAssertEqual(internalController.currentBrightness, 0.7, accuracy: 0.0001)
        XCTAssertEqual(externalController.currentLuminance, 65)
        XCTAssertNotNil(store.snapshot)

        controller.handleUserActivity(applyHardware: false)

        XCTAssertFalse(controller.isDimmed)
        XCTAssertEqual(internalController.currentBrightness, 0.7, accuracy: 0.0001)
        XCTAssertEqual(externalController.currentLuminance, 65)
        XCTAssertNil(store.snapshot)
    }
}

private final class MockInternalBrightnessController: InternalBrightnessManaging {
    var currentBrightness: Float = 0.7

    func currentSnapshot() throws -> [InternalDisplaySnapshot] {
        [InternalDisplaySnapshot(displayID: 1, brightness: currentBrightness)]
    }

    func setBrightness(percent: Int) throws {
        currentBrightness = Float(percent) / 100.0
    }

    func restore(_ snapshots: [InternalDisplaySnapshot]) throws {
        currentBrightness = snapshots.first?.brightness ?? currentBrightness
    }
}

private final class MockExternalBrightnessController: ExternalBrightnessManaging {
    var currentLuminance = 65
    let display = ExternalDisplayReference(selector: "1", name: "Mock")

    func discoverDisplays() throws -> [ExternalDisplayReference] {
        [display]
    }

    func currentSnapshot(for displays: [ExternalDisplayReference]) throws -> [ExternalDisplaySnapshot] {
        displays.map { ExternalDisplaySnapshot(display: $0, luminance: currentLuminance) }
    }

    func setBrightness(percent: Int, for displays: [ExternalDisplayReference]) throws {
        currentLuminance = percent
    }

    func restore(_ snapshots: [ExternalDisplaySnapshot]) throws {
        currentLuminance = snapshots.first?.luminance ?? currentLuminance
    }
}

private final class MemorySnapshotStore: SnapshotPersisting {
    var snapshot: BrightnessSnapshot?

    func load() throws -> BrightnessSnapshot? {
        snapshot
    }

    func save(_ snapshot: BrightnessSnapshot) throws {
        self.snapshot = snapshot
    }

    func clear() throws {
        snapshot = nil
    }
}
