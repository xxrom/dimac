import DimacCore
import XCTest

final class InternalBrightnessControllerTests: XCTestCase {
    func testCLISnapshotPreservesEveryReadableDisplayID() throws {
        let runner = StubCommandRunner(results: [
            .init(status: 0, stdout: Self.twoDisplayList, stderr: "")
        ])
        let controller = BrightnessCLIBrightnessController(
            executablePathProvider: { "/usr/local/bin/brightness" },
            commandRunner: runner
        )

        let snapshots = try controller.currentSnapshot()

        XCTAssertEqual(
            snapshots,
            [
                InternalDisplaySnapshot(displayID: 0x1b56353c, brightness: 0.5),
                InternalDisplaySnapshot(displayID: 0x003f003f, brightness: 0.75)
            ]
        )
        XCTAssertEqual(runner.calls.map(\.arguments), [["-lv"]])
    }

    func testCLISetTargetsOnlyDisplaysCapturedBySnapshot() throws {
        let runner = StubCommandRunner(results: [
            .init(status: 0, stdout: Self.oneDisplayList(id: 0x1b56353c, index: 0, brightness: 0.5), stderr: ""),
            .init(status: 0, stdout: Self.twoDisplayList, stderr: ""),
            .init(status: 0, stdout: "", stderr: "")
        ])
        let controller = BrightnessCLIBrightnessController(
            executablePathProvider: { "/usr/local/bin/brightness" },
            commandRunner: runner
        )

        _ = try controller.currentSnapshot()
        try controller.setBrightness(percent: 20)

        XCTAssertEqual(
            runner.calls.map(\.arguments),
            [["-lv"], ["-lv"], ["-d", "0", "0.2000"]]
        )
    }

    func testCLIRestoreResolvesCurrentIndexesFromStableDisplayIDs() throws {
        let reorderedList = """
        display 0: main, active, awake, online, external, ID 0x3f003f
        display 0: brightness 0.100000
        display 1: active, awake, online, built-in, ID 0x1b56353c
        display 1: brightness 0.100000
        """
        let runner = StubCommandRunner(results: [
            .init(status: 0, stdout: reorderedList, stderr: ""),
            .init(status: 0, stdout: "", stderr: ""),
            .init(status: 0, stdout: "", stderr: "")
        ])
        let controller = BrightnessCLIBrightnessController(
            executablePathProvider: { "/usr/local/bin/brightness" },
            commandRunner: runner
        )

        try controller.restore([
            InternalDisplaySnapshot(displayID: 0x1b56353c, brightness: 0.5),
            InternalDisplaySnapshot(displayID: 0x003f003f, brightness: 0.75)
        ])

        XCTAssertEqual(
            runner.calls.map(\.arguments),
            [
                ["-lv"],
                ["-d", "1", "0.5000"],
                ["-d", "0", "0.7500"]
            ]
        )
    }

    func testCLIRestoreReportsDisconnectedAndLegacySentinelDisplaysWithoutWritingThem() throws {
        let runner = StubCommandRunner(results: [
            .init(status: 0, stdout: Self.oneDisplayList(id: 0x1b56353c, index: 0, brightness: 0.2), stderr: ""),
            .init(status: 0, stdout: "", stderr: "")
        ])
        let controller = BrightnessCLIBrightnessController(
            executablePathProvider: { "/usr/local/bin/brightness" },
            commandRunner: runner
        )

        XCTAssertThrowsError(try controller.restore([
            InternalDisplaySnapshot(displayID: 0x1b56353c, brightness: 0.5),
            InternalDisplaySnapshot(displayID: 0x00abcdef, brightness: 0.6),
            InternalDisplaySnapshot(
                displayID: BrightnessCLIBrightnessController.snapshotDisplayID,
                brightness: 0.7
            )
        ]))

        XCTAssertEqual(
            runner.calls.map(\.arguments),
            [["-lv"], ["-d", "0", "0.5000"]]
        )
    }

    func testFallbackSnapshotMergesCLIOnlyDisplaysAndPrefersPrimaryValue() throws {
        let primary = StubInternalBrightnessController(snapshot: [
            InternalDisplaySnapshot(displayID: 10, brightness: 0.6)
        ])
        let fallback = StubInternalBrightnessController(snapshot: [
            InternalDisplaySnapshot(displayID: 10, brightness: 0.4),
            InternalDisplaySnapshot(displayID: 20, brightness: 0.8)
        ])
        let controller = FallbackInternalBrightnessController(primary: primary, fallback: fallback)

        let snapshots = try controller.currentSnapshot()

        XCTAssertEqual(snapshots, [
            InternalDisplaySnapshot(displayID: 10, brightness: 0.6),
            InternalDisplaySnapshot(displayID: 20, brightness: 0.8)
        ])
    }

    func testFallbackRestoreRoutesCurrentPrimaryAndCLIOnlyDisplaysSeparately() throws {
        let primary = StubInternalBrightnessController(snapshot: [
            InternalDisplaySnapshot(displayID: 10, brightness: 0.1)
        ])
        let fallback = StubInternalBrightnessController(snapshot: [])
        let controller = FallbackInternalBrightnessController(primary: primary, fallback: fallback)
        let saved = [
            InternalDisplaySnapshot(displayID: 10, brightness: 0.6),
            InternalDisplaySnapshot(displayID: 20, brightness: 0.8)
        ]

        try controller.restore(saved)

        XCTAssertEqual(primary.restoredSnapshots, [[saved[0]]])
        XCTAssertEqual(fallback.restoredSnapshots, [[saved[1]]])
    }

    private static let twoDisplayList = """
    display 0: main, active, awake, online, built-in, ID 0x1b56353c
        resolution 1512 x 982 pt (3024 x 1964 px), origin (0, 0)
    display 0: brightness 0.500000
    display 1: active, awake, online, external, ID 0x3f003f
        resolution 2560 x 1440 pt (5120 x 2880 px), origin (1512, 0)
    display 1: brightness 0.750000
    """

    private static func oneDisplayList(id: UInt32, index: Int, brightness: Float) -> String {
        """
        display \(index): main, active, awake, online, built-in, ID 0x\(String(id, radix: 16))
        display \(index): brightness \(brightness)
        """
    }
}

private final class StubCommandRunner: CommandRunning {
    struct Call: Equatable {
        var path: String
        var arguments: [String]
        var timeout: TimeInterval
    }

    private var results: [CommandResult]
    private(set) var calls: [Call] = []

    init(results: [CommandResult]) {
        self.results = results
    }

    func run(_ path: String, arguments: [String], timeout: TimeInterval) throws -> CommandResult {
        calls.append(Call(path: path, arguments: arguments, timeout: timeout))
        return results.removeFirst()
    }
}

private final class StubInternalBrightnessController: InternalBrightnessManaging {
    var snapshot: [InternalDisplaySnapshot]
    private(set) var restoredSnapshots: [[InternalDisplaySnapshot]] = []

    init(snapshot: [InternalDisplaySnapshot]) {
        self.snapshot = snapshot
    }

    func currentSnapshot() throws -> [InternalDisplaySnapshot] {
        snapshot
    }

    func setBrightness(percent: Int) throws {}

    func restore(_ snapshots: [InternalDisplaySnapshot]) throws {
        restoredSnapshots.append(snapshots)
    }
}
