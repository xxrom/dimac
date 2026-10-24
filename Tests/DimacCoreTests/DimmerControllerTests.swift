import DimacCore
import XCTest

@MainActor
final class DimmerControllerTests: XCTestCase {
    func testFileSnapshotRetainsUUIDRecoveryAcrossDisconnectAndRestart() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("snapshot.json")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let uuid = "11111111-1111-1111-1111-111111111111"
        let original = ExternalDisplayReference(selector: "1", name: "Monitor", uuid: uuid)
        let external = MultiExternalBrightnessController(displays: [original], luminanceBySelector: ["1": 65])
        let internalController = MockInternalBrightnessController()
        let store = FileSnapshotStore(fileURL: fileURL)
        let controller = DimmerController(settingsProvider: { DimmerSettings(dimPercent: 10) }, internalBrightness: internalController, externalBrightness: external, snapshotStore: store)
        controller.dimNow()
        external.connectedSelectors = []
        controller.handleUserActivity()
        XCTAssertEqual(try store.load()?.externalDisplays.first?.luminance, 65)

        let reopenedStore = FileSnapshotStore(fileURL: fileURL)
        let restarted = DimmerController(settingsProvider: { DimmerSettings(dimPercent: 10) }, internalBrightness: internalController, externalBrightness: external, snapshotStore: reopenedStore)
        restarted.restorePersistedSnapshotIfNeeded()
        external.displays = [ExternalDisplayReference(selector: "7", name: "Renamed", uuid: uuid)]
        external.connectedSelectors = ["7"]
        external.luminanceBySelector["7"] = 10
        restarted.refreshExternalDisplays()

        XCTAssertEqual(external.luminanceBySelector["7"], 65)
        XCTAssertFalse(restarted.isDimmed)
        XCTAssertNil(try reopenedStore.load())
    }

    func testDifferentUUIDWithSameNameDoesNotReceiveSavedBrightness() {
        let original = ExternalDisplayReference(selector: "1", name: "Monitor", uuid: "11111111-1111-1111-1111-111111111111")
        let external = MultiExternalBrightnessController(displays: [original], luminanceBySelector: ["1": 65])
        let store = MemorySnapshotStore()
        let controller = DimmerController(settingsProvider: { DimmerSettings(dimPercent: 10) }, internalBrightness: MockInternalBrightnessController(), externalBrightness: external, snapshotStore: store)
        controller.dimNow()
        external.connectedSelectors = []
        controller.handleUserActivity()

        external.displays = [ExternalDisplayReference(selector: "7", name: "Monitor", uuid: "22222222-2222-2222-2222-222222222222")]
        external.connectedSelectors = ["7"]
        external.luminanceBySelector["7"] = 40
        controller.refreshExternalDisplays()

        XCTAssertEqual(external.luminanceBySelector["7"], 40)
        XCTAssertEqual(external.restoreSelectors, ["1"])
        XCTAssertEqual(store.snapshot?.externalDisplays.first?.luminance, 65)
    }

    func testSameNameDisplaysWithDistinctUUIDsHaveIndependentRestoreValues() {
        let first = ExternalDisplayReference(selector: "1", name: "Monitor", uuid: "11111111-1111-1111-1111-111111111111")
        let second = ExternalDisplayReference(selector: "2", name: "Monitor", uuid: "22222222-2222-2222-2222-222222222222")
        let external = MultiExternalBrightnessController(displays: [first, second], luminanceBySelector: ["1": 60, "2": 80])
        let store = MemorySnapshotStore()
        let controller = DimmerController(settingsProvider: { DimmerSettings(dimPercent: 10) }, internalBrightness: MockInternalBrightnessController(), externalBrightness: external, snapshotStore: store)
        controller.dimNow()
        XCTAssertEqual(external.luminanceBySelector["1"], 10)
        XCTAssertEqual(external.luminanceBySelector["2"], 10)
        controller.handleUserActivity()

        XCTAssertEqual(external.luminanceBySelector["1"], 60)
        XCTAssertEqual(external.luminanceBySelector["2"], 80)
        XCTAssertNil(store.snapshot)
    }

    func testSameNameMixedIdentityDisplaysDimOnlyUniquelyIdentifiedUUIDDisplay() {
        let identified = ExternalDisplayReference(selector: "1", name: "Monitor", uuid: "11111111-1111-1111-1111-111111111111")
        let ambiguous = ExternalDisplayReference(selector: "2", name: "Monitor")
        let external = MultiExternalBrightnessController(displays: [identified, ambiguous], luminanceBySelector: ["1": 60, "2": 80])
        let store = MemorySnapshotStore()
        let controller = DimmerController(settingsProvider: { DimmerSettings(dimPercent: 10) }, internalBrightness: MockInternalBrightnessController(), externalBrightness: external, snapshotStore: store)

        controller.dimNow()

        XCTAssertEqual(external.luminanceBySelector["1"], 10)
        XCTAssertEqual(external.luminanceBySelector["2"], 80)
        XCTAssertEqual(external.restoreSelectors, ["1"])
        XCTAssertEqual(controller.statusMessage, "Dimmed with warnings")
        let dimError = controller.lastError
        XCTAssertNotNil(dimError)
        controller.refreshExternalDisplays()
        XCTAssertEqual(controller.statusMessage, "Dimmed with warnings")
        XCTAssertEqual(controller.lastError, dimError)

        controller.handleUserActivity()
        XCTAssertEqual(external.luminanceBySelector["1"], 60)
        XCTAssertEqual(external.luminanceBySelector["2"], 80)
        XCTAssertNil(store.snapshot)
    }

    func testLegacyNameSnapshotRetainsManualAdjustmentGuardWhenUUIDBecomesAvailable() {
        let legacy = ExternalDisplayReference(selector: "1", name: "Monitor")
        let current = ExternalDisplayReference(selector: "7", name: "Monitor", uuid: "11111111-1111-1111-1111-111111111111")
        let external = MultiExternalBrightnessController(displays: [current], luminanceBySelector: ["7": 47])
        let store = MemorySnapshotStore()
        store.snapshot = BrightnessSnapshot(internalDisplays: [], externalDisplays: [ExternalDisplaySnapshot(display: legacy, luminance: 65)], appliedExternalDisplays: [ExternalDisplaySnapshot(display: legacy, luminance: 10)])
        let controller = DimmerController(settingsProvider: { DimmerSettings(dimPercent: 10) }, internalBrightness: MockInternalBrightnessController(), externalBrightness: external, snapshotStore: store)

        controller.restorePersistedSnapshotIfNeeded()

        XCTAssertEqual(external.luminanceBySelector["7"], 47)
        XCTAssertTrue(external.restoreSelectors.isEmpty)
        XCTAssertNil(store.snapshot)
    }

    func testQuantizedExternalDimReadbackRestoresOriginalBrightness() {
        let external = MockExternalBrightnessController()
        external.dimReadback = 9
        let store = MemorySnapshotStore()
        let controller = makeController(internalController: MockInternalBrightnessController(), externalController: external, store: store)

        controller.dimNow()
        XCTAssertEqual(external.currentLuminance, 9)
        XCTAssertEqual(store.snapshot?.appliedExternalDisplays?.first?.luminance, 9)
        controller.handleUserActivity()

        XCTAssertEqual(external.currentLuminance, 65)
        XCTAssertFalse(controller.isDimmed)
        XCTAssertNil(store.snapshot)
    }

    func testManualAdjustmentAfterQuantizedDimIsPreserved() {
        let external = MockExternalBrightnessController()
        external.dimReadback = 9
        let store = MemorySnapshotStore()
        let controller = makeController(internalController: MockInternalBrightnessController(), externalController: external, store: store)

        controller.dimNow()
        external.currentLuminance = 11
        controller.handleUserActivity()

        XCTAssertEqual(external.currentLuminance, 11)
        XCTAssertEqual(controller.lastKnownExternalBrightness(for: external.display), 11)
        XCTAssertNil(store.snapshot)
    }

    func testUnavailableDimReadbackDoesNotTurnRequestedTargetIntoManualChangeBaseline() {
        let external = MockExternalBrightnessController()
        external.dimReadback = 9
        external.failReadbackAfterWrite = true
        let store = MemorySnapshotStore()
        let controller = makeController(internalController: MockInternalBrightnessController(), externalController: external, store: store)

        controller.dimNow()
        external.failReadbackAfterWrite = false
        controller.handleUserActivity()

        XCTAssertEqual(external.currentLuminance, 65)
        XCTAssertNil(store.snapshot)
    }

    func testStaleUnchangedReadbackDoesNotSuppressLaterRestore() {
        let external = MockExternalBrightnessController()
        external.dimReadback = 65
        let store = MemorySnapshotStore()
        let controller = makeController(internalController: MockInternalBrightnessController(), externalController: external, store: store)

        controller.dimNow()
        external.currentLuminance = 9
        controller.handleUserActivity()

        XCTAssertEqual(external.currentLuminance, 65)
        XCTAssertNil(store.snapshot)
    }

    func testQuantizedDimBaselineSurvivesControllerRestart() {
        let external = MockExternalBrightnessController()
        external.dimReadback = 9
        let internalController = MockInternalBrightnessController()
        let store = MemorySnapshotStore()
        let controller = makeController(internalController: internalController, externalController: external, store: store)
        controller.dimNow()

        let restarted = makeController(internalController: internalController, externalController: external, store: store)
        restarted.restorePersistedSnapshotIfNeeded()

        XCTAssertEqual(external.currentLuminance, 65)
        XCTAssertFalse(restarted.isDimmed)
        XCTAssertNil(store.snapshot)
    }

    func testDisconnectedExternalRestoresOnRefreshWithNewSelectorAfterWake() {
        let original = ExternalDisplayReference(selector: "1", name: "Monitor")
        let external = MultiExternalBrightnessController(displays: [original], luminanceBySelector: ["1": 65])
        let internalController = MockInternalBrightnessController()
        let store = MemorySnapshotStore()
        let controller = DimmerController(settingsProvider: { DimmerSettings(dimPercent: 10) }, internalBrightness: internalController, externalBrightness: external, snapshotStore: store)

        controller.dimNow()
        external.connectedSelectors = []
        controller.handleUserActivity()

        XCTAssertEqual(internalController.currentBrightness, 0.7, accuracy: 0.0001)
        XCTAssertEqual(store.snapshot?.externalDisplays.first?.luminance, 65)
        XCTAssertTrue(store.snapshot?.internalDisplays.isEmpty == true)

        external.displays = [ExternalDisplayReference(selector: "7", name: "Monitor")]
        external.connectedSelectors = ["7"]
        external.luminanceBySelector["7"] = 10
        controller.refreshExternalDisplays()

        XCTAssertEqual(external.luminanceBySelector["7"], 65)
        XCTAssertEqual(external.restoreSelectors.last, "7")
        XCTAssertFalse(controller.isDimmed)
        XCTAssertNil(store.snapshot)
    }

    func testDisplayRefreshBeforeWakeDoesNotRestoreDimmedDisplay() {
        let external = MockExternalBrightnessController()
        let store = MemorySnapshotStore()
        let controller = makeController(internalController: MockInternalBrightnessController(), externalController: external, store: store)

        controller.dimNow()
        controller.refreshExternalDisplays()

        XCTAssertEqual(external.currentLuminance, 10)
        XCTAssertTrue(controller.isDimmed)
        XCTAssertNotNil(store.snapshot)
    }

    func testPendingDisconnectedExternalSurvivesRestartAndRestoresOnReconnect() {
        let original = ExternalDisplayReference(selector: "1", name: "Monitor")
        let external = MultiExternalBrightnessController(displays: [original], luminanceBySelector: ["1": 65])
        let internalController = MockInternalBrightnessController()
        let store = MemorySnapshotStore()
        let controller = DimmerController(settingsProvider: { DimmerSettings(dimPercent: 10) }, internalBrightness: internalController, externalBrightness: external, snapshotStore: store)
        controller.dimNow()
        external.connectedSelectors = []
        controller.handleUserActivity()

        let restarted = DimmerController(settingsProvider: { DimmerSettings(dimPercent: 10) }, internalBrightness: internalController, externalBrightness: external, snapshotStore: store)
        restarted.restorePersistedSnapshotIfNeeded()
        XCTAssertNotNil(store.snapshot)
        external.displays = [ExternalDisplayReference(selector: "7", name: "Monitor")]
        external.connectedSelectors = ["7"]
        external.luminanceBySelector["7"] = 10
        restarted.refreshExternalDisplays()

        XCTAssertEqual(external.luminanceBySelector["7"], 65)
        XCTAssertFalse(restarted.isDimmed)
        XCTAssertNil(store.snapshot)
    }

    func testIdleTimerRetriesPendingExternalRestoreEvenAfterIdleThreshold() {
        let external = MockExternalBrightnessController()
        let store = MemorySnapshotStore()
        var now = Date(timeIntervalSince1970: 1_000)
        let controller = DimmerController(settingsProvider: { DimmerSettings(idleTimeoutSeconds: 10, dimPercent: 10) }, internalBrightness: MockInternalBrightnessController(), externalBrightness: external, snapshotStore: store, now: { now })
        controller.dimNow()
        external.restoreError = TestError.failed
        controller.handleUserActivity()
        XCTAssertNotNil(store.snapshot)

        external.restoreError = nil
        controller.handleIdleTime(20)
        XCTAssertEqual(external.currentLuminance, 10)
        now.addTimeInterval(5)
        controller.handleIdleTime(20)

        XCTAssertEqual(external.currentLuminance, 65)
        XCTAssertFalse(controller.isDimmed)
        XCTAssertNil(store.snapshot)
    }

    func testPendingExternalDoesNotPreventNewInternalDimCycleOrReplaceExternalBaseline() {
        let display = ExternalDisplayReference(selector: "1", name: "Monitor")
        let external = MultiExternalBrightnessController(displays: [display], luminanceBySelector: ["1": 65])
        let internalController = MockInternalBrightnessController()
        let store = MemorySnapshotStore()
        var now = Date(timeIntervalSince1970: 1_000)
        let controller = DimmerController(settingsProvider: { DimmerSettings(idleTimeoutSeconds: 10, dimPercent: 10) }, internalBrightness: internalController, externalBrightness: external, snapshotStore: store, now: { now })
        controller.dimNow()
        external.connectedSelectors = []
        controller.handleUserActivity()
        XCTAssertEqual(internalController.currentBrightness, 0.7, accuracy: 0.0001)

        internalController.currentBrightness = 0.8
        now.addTimeInterval(10)
        controller.handleIdleTime(20)
        XCTAssertEqual(internalController.currentBrightness, 0.1, accuracy: 0.0001)
        XCTAssertEqual(store.snapshot?.externalDisplays.first?.luminance, 65)
        controller.handleUserActivity()
        XCTAssertEqual(internalController.currentBrightness, 0.8, accuracy: 0.0001)

        external.connectedSelectors = ["1"]
        controller.refreshExternalDisplays()
        XCTAssertEqual(external.luminanceBySelector["1"], 65)
        XCTAssertNil(store.snapshot)
    }

    func testObservedDisconnectInvalidatesLegacyNameOnlyManualFallback() {
        let display = ExternalDisplayReference(selector: "1", name: "Monitor")
        let external = MultiExternalBrightnessController(displays: [display], luminanceBySelector: [:])
        let controller = DimmerController(settingsProvider: { DimmerSettings(dimPercent: 10) }, internalBrightness: MockInternalBrightnessController(), externalBrightness: external, snapshotStore: MemorySnapshotStore())
        controller.recordManualExternalBrightness(43, for: display)
        external.connectedSelectors = []
        controller.refreshExternalDisplays()
        external.connectedSelectors = ["1"]
        controller.dimNow()
        XCTAssertTrue(external.restoreSelectors.isEmpty)
    }

    func testInternalReadFailureDoesNotPreventExternalCycle() {
        let internalController = MockInternalBrightnessController()
        internalController.snapshotError = TestError.failed
        let external = MockExternalBrightnessController()
        let controller = DimmerController(settingsProvider: { DimmerSettings(dimPercent: 10) }, internalBrightness: internalController, externalBrightness: external, snapshotStore: MemorySnapshotStore())
        controller.dimNow()
        XCTAssertEqual(external.currentLuminance, 10)
        XCTAssertEqual(internalController.currentBrightness, 0.7, accuracy: 0.0001)
        controller.handleUserActivity()
        XCTAssertEqual(external.currentLuminance, 65)
        XCTAssertFalse(controller.isDimmed)
    }

    func testMixedReadableAndUnreadableExternalsHaveIndependentBaselines() {
        let first = ExternalDisplayReference(selector: "1", name: "Readable")
        let second = ExternalDisplayReference(selector: "2", name: "Write only")
        let external = MultiExternalBrightnessController(displays: [first, second], luminanceBySelector: ["1": 80])
        let internalController = MockInternalBrightnessController()
        let controller = DimmerController(settingsProvider: { DimmerSettings(dimPercent: 10, externalDimPercentByDisplay: [second.brightnessPreferenceKey: 20]) }, internalBrightness: internalController, externalBrightness: external, snapshotStore: MemorySnapshotStore())
        controller.recordManualExternalBrightness(55, for: second)
        controller.dimNow()
        XCTAssertEqual(external.luminanceBySelector["1"], 10)
        XCTAssertEqual(external.luminanceBySelector["2"], 20)
        controller.handleUserActivity()
        XCTAssertEqual(external.luminanceBySelector["1"], 80)
        XCTAssertEqual(external.luminanceBySelector["2"], 55)
        XCTAssertEqual(internalController.currentBrightness, 0.7, accuracy: 0.0001)
    }

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

    func testRestoresExternalDisplayToBrightnessCapturedImmediatelyBeforeDim() {
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
        XCTAssertEqual(externalController.currentLuminance, 65)
    }

    func testUsesPerDisplayDimTargetsWithoutIncreasingBrightness() {
        let internalController = MockInternalBrightnessController()
        internalController.currentBrightness = 0.05
        let externalController = MockExternalBrightnessController()
        let store = MemorySnapshotStore()

        let controller = DimmerController(
            settingsProvider: {
                DimmerSettings(
                    isEnabled: true,
                    idleTimeoutSeconds: 10,
                    dimPercent: 20,
                    internalDimPercentByDisplay: [1: 15],
                    externalDimPercentByDisplay: [
                        externalController.display.brightnessPreferenceKey: 35
                    ]
                )
            },
            internalBrightness: internalController,
            externalBrightness: externalController,
            snapshotStore: store
        )

        controller.dimNow()

        XCTAssertEqual(internalController.currentBrightness, 0.05, accuracy: 0.0001)
        XCTAssertEqual(externalController.currentLuminance, 35)
    }

    func testManualBrightnessChangesWhileDimmedArePreservedOnActivity() {
        let internalController = MockInternalBrightnessController()
        let externalController = MockExternalBrightnessController()
        let store = MemorySnapshotStore()
        let controller = makeController(
            internalController: internalController,
            externalController: externalController,
            store: store
        )

        controller.dimNow()
        internalController.currentBrightness = 0.42
        externalController.currentLuminance = 47

        controller.handleUserActivity()

        XCTAssertFalse(controller.isDimmed)
        XCTAssertEqual(internalController.currentBrightness, 0.42, accuracy: 0.0001)
        XCTAssertEqual(externalController.currentLuminance, 47)
        XCTAssertNil(store.snapshot)
    }

    func testManualBrightnessChangesArePreservedAfterControllerRestart() {
        let internalController = MockInternalBrightnessController()
        let externalController = MockExternalBrightnessController()
        let store = MemorySnapshotStore()
        let firstController = makeController(
            internalController: internalController,
            externalController: externalController,
            store: store
        )
        firstController.dimNow()

        internalController.currentBrightness = 0.42
        externalController.currentLuminance = 47
        let restartedController = makeController(
            internalController: internalController,
            externalController: externalController,
            store: store
        )
        restartedController.restorePersistedSnapshotIfNeeded()

        XCTAssertFalse(restartedController.isDimmed)
        XCTAssertEqual(internalController.currentBrightness, 0.42, accuracy: 0.0001)
        XCTAssertEqual(externalController.currentLuminance, 47)
        XCTAssertNil(store.snapshot)
    }

    func testFailedRestoreKeepsOriginalSnapshotAndCanRetry() {
        let internalController = MockInternalBrightnessController()
        let externalController = MockExternalBrightnessController()
        let store = MemorySnapshotStore()
        var now = Date(timeIntervalSince1970: 1_000)
        let controller = makeController(
            internalController: internalController,
            externalController: externalController,
            store: store,
            now: { now }
        )

        controller.dimNow()
        internalController.restoreError = TestError.failed
        controller.handleUserActivity()

        XCTAssertTrue(controller.isDimmed)
        XCTAssertNotNil(store.snapshot)
        XCTAssertEqual(internalController.currentBrightness, 0.1, accuracy: 0.0001)
        XCTAssertEqual(controller.statusMessage, "Restore failed; will retry")

        internalController.restoreError = nil
        now.addTimeInterval(5)
        controller.handleUserActivity()

        XCTAssertFalse(controller.isDimmed)
        XCTAssertNil(store.snapshot)
        XCTAssertEqual(internalController.currentBrightness, 0.7, accuracy: 0.0001)
    }

    func testDoesNotDimExternalDisplayWhenItsBrightnessCouldNotBeCaptured() {
        let internalController = MockInternalBrightnessController()
        let externalController = MockExternalBrightnessController()
        externalController.snapshotError = TestError.failed
        let store = MemorySnapshotStore()
        let controller = makeController(
            internalController: internalController,
            externalController: externalController,
            store: store
        )

        controller.dimNow()

        XCTAssertTrue(controller.isDimmed)
        XCTAssertEqual(internalController.currentBrightness, 0.1, accuracy: 0.0001)
        XCTAssertEqual(externalController.currentLuminance, 65)
        XCTAssertEqual(externalController.restoreCallCount, 0)
        XCTAssertEqual(controller.statusMessage, "Dimmed with warnings")
    }

    func testDoesNotDimReadableDisplayWhenAnotherConnectedDisplayHasSameName() {
        let internalController = MockInternalBrightnessController()
        let externalController = MultiExternalBrightnessController(
            displays: [
                ExternalDisplayReference(selector: "1", name: "Studio Display"),
                ExternalDisplayReference(selector: "2", name: "Studio Display")
            ],
            luminanceBySelector: ["1": 60]
        )
        let store = MemorySnapshotStore()
        let controller = DimmerController(
            settingsProvider: { DimmerSettings(dimPercent: 10) },
            internalBrightness: internalController,
            externalBrightness: externalController,
            snapshotStore: store
        )

        controller.dimNow()

        XCTAssertEqual(externalController.luminanceBySelector["1"], 60)
        XCTAssertEqual(externalController.restoreSelectors, [])
        XCTAssertEqual(controller.statusMessage, "Dimmed with warnings")
    }

    func testRestoresConnectedExternalDisplayAndKeepsDisconnectedDisplayPending() {
        let internalController = MockInternalBrightnessController()
        let first = ExternalDisplayReference(selector: "1", name: "Left")
        let second = ExternalDisplayReference(selector: "2", name: "Right")
        let externalController = MultiExternalBrightnessController(
            displays: [first, second],
            luminanceBySelector: ["1": 60, "2": 70]
        )
        let store = MemorySnapshotStore()
        let controller = DimmerController(
            settingsProvider: { DimmerSettings(dimPercent: 10) },
            internalBrightness: internalController,
            externalBrightness: externalController,
            snapshotStore: store
        )

        controller.dimNow()
        externalController.connectedSelectors = ["1"]
        controller.handleUserActivity()

        XCTAssertTrue(controller.isDimmed)
        XCTAssertEqual(externalController.luminanceBySelector["1"], 60)
        XCTAssertEqual(store.snapshot?.externalDisplays.map(\.display.name), ["Right"])

        externalController.connectedSelectors = ["1", "2"]
        controller.refreshExternalDisplays()

        XCTAssertFalse(controller.isDimmed)
        XCTAssertEqual(externalController.luminanceBySelector["2"], 70)
        XCTAssertNil(store.snapshot)
    }

    func testRepeatedDimDoesNotReplaceOriginalSnapshot() {
        let internalController = MockInternalBrightnessController()
        let externalController = MockExternalBrightnessController()
        let store = MemorySnapshotStore()
        let controller = makeController(
            internalController: internalController,
            externalController: externalController,
            store: store
        )

        controller.dimNow()
        let originalSnapshot = store.snapshot
        controller.dimNow()

        XCTAssertEqual(store.snapshot, originalSnapshot)
        controller.handleUserActivity()
        XCTAssertEqual(internalController.currentBrightness, 0.7, accuracy: 0.0001)
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

    private func makeController(
        internalController: MockInternalBrightnessController,
        externalController: MockExternalBrightnessController,
        store: MemorySnapshotStore,
        now: @escaping () -> Date = Date.init
    ) -> DimmerController {
        DimmerController(
            settingsProvider: {
                DimmerSettings(isEnabled: true, idleTimeoutSeconds: 10, dimPercent: 10)
            },
            internalBrightness: internalController,
            externalBrightness: externalController,
            snapshotStore: store,
            now: now
        )
    }
}

private final class MockInternalBrightnessController: InternalBrightnessManaging {
    var currentBrightness: Float = 0.7
    var snapshotError: Error?
    var restoreError: Error?

    func currentSnapshot() throws -> [InternalDisplaySnapshot] {
        if let snapshotError { throw snapshotError }
        return [InternalDisplaySnapshot(displayID: 1, brightness: currentBrightness)]
    }

    func setBrightness(percent: Int) throws {
        currentBrightness = Float(percent) / 100.0
    }

    func restore(_ snapshots: [InternalDisplaySnapshot]) throws {
        if let restoreError {
            throw restoreError
        }
        currentBrightness = snapshots.first?.brightness ?? currentBrightness
    }
}

private final class MockExternalBrightnessController: ExternalBrightnessManaging {
    var currentLuminance = 65
    let display = ExternalDisplayReference(selector: "1", name: "Mock")
    var snapshotError: Error?
    var restoreError: Error?
    var restoreCallCount = 0
    var dimReadback: Int?
    var failReadbackAfterWrite = false

    func discoverDisplays() throws -> [ExternalDisplayReference] {
        [display]
    }

    func currentSnapshot(for displays: [ExternalDisplayReference]) throws -> [ExternalDisplaySnapshot] {
        if failReadbackAfterWrite, restoreCallCount > 0 {
            throw TestError.failed
        }
        if let snapshotError {
            throw snapshotError
        }
        return displays.map { ExternalDisplaySnapshot(display: $0, luminance: currentLuminance) }
    }

    func setBrightness(percent: Int, for displays: [ExternalDisplayReference]) throws {
        currentLuminance = percent
    }

    func restore(_ snapshots: [ExternalDisplaySnapshot]) throws {
        restoreCallCount += 1
        if let restoreError {
            throw restoreError
        }
        if let luminance = snapshots.first?.luminance {
            currentLuminance = luminance == 10 ? (dimReadback ?? luminance) : luminance
        }
    }
}

private enum TestError: Error {
    case failed
}

private final class MultiExternalBrightnessController: ExternalBrightnessManaging {
    var displays: [ExternalDisplayReference]
    var connectedSelectors: Set<String>
    var luminanceBySelector: [String: Int]
    var restoreSelectors: [String] = []

    init(displays: [ExternalDisplayReference], luminanceBySelector: [String: Int]) {
        self.displays = displays
        self.connectedSelectors = Set(displays.compactMap(\.selector))
        self.luminanceBySelector = luminanceBySelector
    }

    func discoverDisplays() throws -> [ExternalDisplayReference] {
        displays.filter { display in
            display.selector.map(connectedSelectors.contains) ?? false
        }
    }

    func currentSnapshot(for displays: [ExternalDisplayReference]) throws -> [ExternalDisplaySnapshot] {
        displays.compactMap { display in
            guard let selector = display.selector,
                  connectedSelectors.contains(selector),
                  let luminance = luminanceBySelector[selector] else {
                return nil
            }
            return ExternalDisplaySnapshot(display: display, luminance: luminance)
        }
    }

    func setBrightness(percent: Int, for displays: [ExternalDisplayReference]) throws {
        try restore(displays.map { ExternalDisplaySnapshot(display: $0, luminance: percent) })
    }

    func restore(_ snapshots: [ExternalDisplaySnapshot]) throws {
        for snapshot in snapshots {
            guard let selector = snapshot.display.selector,
                  connectedSelectors.contains(selector) else {
                throw TestError.failed
            }
            restoreSelectors.append(selector)
            luminanceBySelector[selector] = snapshot.luminance
        }
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
