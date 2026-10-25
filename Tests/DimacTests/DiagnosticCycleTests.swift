@testable import Dimac
import DimacCore
import Foundation
import XCTest

@MainActor
final class DiagnosticCycleTests: XCTestCase {
    func testFullSeventyOneDisconnectWakeReconnectCycleLogsBothCycles() throws {
        let result = try emulate(staleAfterReconnect: false)
        XCTAssertEqual(result.physical, 70)
        XCTAssertEqual(result.restoreLevels, [70, 70])
        XCTAssertTrue(result.events.contains { $0["event"] as? String == "restore.pending" })
        XCTAssertTrue(result.events.contains { $0["event"] as? String == "snapshot.file.loaded" })
    }

    func testWriteOnlyMonitorKeepsNormalLevelAcrossReconnectRestartAndFurtherCycles() throws {
        let result = try emulate(staleAfterReconnect: false, unreadable: true)
        XCTAssertEqual(result.physical, 70)
        XCTAssertEqual(result.restoreLevels, [70, 70, 70])
        XCTAssertTrue(result.events.contains { $0["event"] as? String == "ddc.readRejected" && $0["raw"] as? String == "-55\n" })
    }

    func testStaleReadAfterReconnectDoesNotReplaceSavedSeventyBaseline() throws {
        let result = try emulate(staleAfterReconnect: true)
        XCTAssertEqual(result.restoreLevels, [70, 70])
        let captures = result.events.filter { $0["event"] as? String == "dim.external.captured" }
        let readings = captures.compactMap { ($0["reading"] as? [String: Any])?["luminance"] as? Int }
        XCTAssertEqual(readings, [70])
        XCTAssertTrue(captures.contains { $0["source"] as? String == "saved level" && $0["percent"] as? Int == 70 })
        let reads = result.events.filter { $0["event"] as? String == "ddc.read" }
        XCTAssertTrue(reads.contains { $0["raw"] as? String == "1\n" && $0["percent"] as? Int == 1 })
        XCTAssertTrue(result.events.contains { $0["event"] as? String == "ui.brightnessWriteAccepted" && $0["requested"] as? Int == 70 })
    }

    private func emulate(staleAfterReconnect: Bool, unreadable: Bool = false) throws -> (physical: Int, restoreLevels: [Int], events: [[String: Any]]) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logger = DiagnosticLogger(fileURL: directory.appendingPathComponent("diagnostics.jsonl"))
        let runner = CycleCommandRunner()
        runner.failReads = unreadable
        let external = M1DDCBrightnessController(executablePathProvider: { "/usr/bin/true" }, commandRunner: runner, diagnostics: logger)
        let internalBrightness = CycleInternalBrightness()
        let storeURL = directory.appendingPathComponent("active-snapshot.json")
        let store = FileSnapshotStore(fileURL: storeURL, diagnostics: logger)
        var now = Date(timeIntervalSince1970: 1_000)
        let dimmer = DimmerController(settingsProvider: { DimmerSettings(idleTimeoutSeconds: 10, dimPercent: 1) },
            internalBrightness: internalBrightness, externalBrightness: external, snapshotStore: store,
            now: { now }, diagnostics: logger)
        let suite = "dimac.diagnostics.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.setDimPercent(1)
        func makeModel(_ controller: DimmerController) -> AppModel {
            AppModel(settings: settings, dimmer: controller, startAutomatically: false,
                brightnessControls: CurrentBrightnessController(internalBrightness: internalBrightness, externalBrightness: external),
                displayProvider: {
                    runner.connected ? [ConnectedDisplayRow(id: "2", index: 1, name: "Monitor", resolution: "",
                        brightnessPercent: nil, isBuiltIn: false, isExternal: true, canReadHardwareBrightness: false)] : []
                }, diagnostics: logger)
        }
        let model = makeModel(dimmer)
        model.refreshExternalDisplays()
        model.setCurrentBrightness(70, for: "display:2")
        dimmer.handleIdleTime(11)
        XCTAssertEqual(runner.physical, 1)
        runner.connected = false
        model.refreshExternalDisplays()
        dimmer.restoreNow(reason: "sleep")
        now.addTimeInterval(20)
        dimmer.handleIdleTime(30)
        dimmer.restoreNow(reason: "wake")
        XCTAssertEqual(internalBrightness.brightness, 0.7, accuracy: 0.0001)
        let restarted = DimmerController(settingsProvider: { DimmerSettings(idleTimeoutSeconds: 10, dimPercent: 1) },
            internalBrightness: internalBrightness, externalBrightness: external,
            snapshotStore: FileSnapshotStore(fileURL: storeURL, diagnostics: logger), now: { now }, diagnostics: logger)
        restarted.restorePersistedSnapshotIfNeeded()
        runner.connected = true
        runner.selector = "7"
        runner.stale = staleAfterReconnect
        let reconnectedModel = makeModel(restarted)
        reconnectedModel.refreshExternalDisplays()
        XCTAssertEqual(runner.physical, 70)
        if unreadable {
            XCTAssertNil(reconnectedModel.displayControlRows.first?.currentPercent)
            XCTAssertEqual(reconnectedModel.displayControlRows.first?.requestedPercent, 70)
        }
        now.addTimeInterval(20)
        restarted.handleIdleTime(11)
        XCTAssertEqual(runner.physical, 1)
        restarted.handleUserActivity()
        XCTAssertEqual(internalBrightness.brightness, 0.7, accuracy: 0.0001)
        if unreadable {
            runner.connected = false
            reconnectedModel.refreshExternalDisplays()
            now.addTimeInterval(20)
            restarted.handleIdleTime(11)
            restarted.handleUserActivity()
            runner.connected = true
            runner.selector = "9"
            runner.invalidReading = true
            reconnectedModel.refreshExternalDisplays()
            XCTAssertEqual(reconnectedModel.displayControlRows.first?.requestedPercent, 70)
            now.addTimeInterval(20)
            restarted.handleIdleTime(11)
            XCTAssertEqual(runner.physical, 1)
            restarted.handleUserActivity()
            XCTAssertEqual(internalBrightness.brightness, 0.7, accuracy: 0.0001)
        }
        let events = try String(contentsOf: logger.fileURL, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        let restoreLevels = events.filter { $0["event"] as? String == "restore.external.sent" }.compactMap {
            ($0["target"] as? [String: Any])?["luminance"] as? Int
        }
        return (runner.physical, restoreLevels, events)
    }
}

private final class CycleCommandRunner: CommandRunning {
    var connected = true
    var selector = "1"
    var physical = 50
    var stale = false
    var failReads = false
    var invalidReading = false

    func run(_ path: String, arguments: [String], timeout: TimeInterval) throws -> CommandResult {
        if arguments == ["display", "list"] {
            return CommandResult(status: 0, stdout: connected ? "[\(selector)] Monitor (11111111-1111-1111-1111-111111111111)\n" : "", stderr: "")
        }
        guard connected else { return CommandResult(status: 1, stdout: "", stderr: "Display disconnected") }
        guard arguments.count > 1, arguments[0] == "display", arguments[1] == "11111111-1111-1111-1111-111111111111" else {
            return CommandResult(status: 1, stdout: "", stderr: "Wrong display identity")
        }
        if Array(arguments.suffix(2)) == ["get", "luminance"] {
            if invalidReading { return CommandResult(status: 0, stdout: "-55\n", stderr: "") }
            if failReads { return CommandResult(status: 1, stdout: "", stderr: "") }
            return CommandResult(status: 0, stdout: "\(stale ? 1 : physical)\n", stderr: "")
        }
        if arguments.count >= 3, arguments[arguments.count - 3] == "set", let value = Int(arguments.last ?? "") {
            physical = value
            return CommandResult(status: 0, stdout: "", stderr: "")
        }
        return CommandResult(status: 1, stdout: "", stderr: "Unexpected emulated command")
    }
}

private final class CycleInternalBrightness: InternalBrightnessManaging {
    var brightness: Float = 0.7
    func currentSnapshot() throws -> [InternalDisplaySnapshot] { [InternalDisplaySnapshot(displayID: 1, brightness: brightness)] }
    func setBrightness(percent: Int) throws { brightness = Float(percent) / 100 }
    func restore(_ snapshots: [InternalDisplaySnapshot]) throws {
        for snapshot in snapshots { brightness = snapshot.brightness }
    }
}
