import DimacCore
import XCTest

final class ExternalBrightnessControllerTests: XCTestCase {
    func testRecoveryIdentitySurvivesSelectorAndNameChanges() {
        let saved = ExternalDisplayReference(selector: "1", name: "Dell", uuid: "37D8832A-2D66-02CA-B9F7-8F30A301B230")
        let connected = ExternalDisplayReference(selector: "3", name: "Renamed Dell", uuid: "37d8832a-2d66-02ca-b9f7-8f30a301b230")
        let replacement = ExternalDisplayReference(selector: "1", name: "Dell", uuid: "37D8832A-2D66-02CA-B9F7-8F30A301B231")

        XCTAssertTrue(connected.matchesRecoveryIdentity(of: saved))
        XCTAssertEqual(connected.recoveryKey, saved.recoveryKey)
        XCTAssertFalse(replacement.matchesRecoveryIdentity(of: saved))
        XCTAssertFalse(ExternalDisplayReference(selector: "1", name: "Dell").matchesRecoveryIdentity(of: saved))
        XCTAssertEqual(saved.brightnessPreferenceKey, "name:dell")
    }

    func testLegacyRecoveryIdentityUsesMeaningfulNameWithoutSelector() throws {
        let legacyJSON = Data(#"{"selector":"1","name":" Dell ","isDefaultFallback":false}"#.utf8)
        let saved = try JSONDecoder().decode(ExternalDisplayReference.self, from: legacyJSON)
        let connected = ExternalDisplayReference(selector: "2", name: "DELL", uuid: "37D8832A-2D66-02CA-B9F7-8F30A301B230")

        XCTAssertNil(saved.uuid)
        XCTAssertTrue(saved.hasReliableIdentity)
        XCTAssertTrue(connected.matchesRecoveryIdentity(of: saved))
        XCTAssertFalse(ExternalDisplayReference(selector: "1", name: "Display 1").hasReliableIdentity)
        XCTAssertFalse(ExternalDisplayReference(selector: nil, name: "Default external display", isDefaultFallback: true).hasReliableIdentity)
        XCTAssertEqual(try JSONDecoder().decode(ExternalDisplayReference.self, from: JSONEncoder().encode(connected)), connected)
        let lowercaseJSON = Data(#"{"selector":"3","name":"Dell","isDefaultFallback":false,"uuid":"37d8832a-2d66-02ca-b9f7-8f30a301b230"}"#.utf8)
        let decoded = try JSONDecoder().decode(ExternalDisplayReference.self, from: lowercaseJSON)
        XCTAssertEqual(decoded.recoveryKey, connected.recoveryKey)
    }

    func testCommandsUseUUIDWhenAvailableAndSelectorAsFallback() throws {
        let uuid = "37D8832A-2D66-02CA-B9F7-8F30A301B230"
        let displays = [
            ExternalDisplayReference(selector: "3", name: "Dell", uuid: uuid),
            ExternalDisplayReference(selector: "7", name: "Legacy Dell")
        ]
        let runner = SuccessfulCommandRunner()
        let diagnosticsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dimac-ddc-test-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: diagnosticsURL) }
        let controller = M1DDCBrightnessController(
            executablePathProvider: { "/mock/m1ddc" },
            commandRunner: runner,
            diagnostics: DiagnosticLogger(fileURL: diagnosticsURL)
        )

        XCTAssertEqual(try controller.currentSnapshot(for: displays).map(\.luminance), [65, 65])
        try controller.restore([
            ExternalDisplaySnapshot(display: displays[0], luminance: 40),
            ExternalDisplaySnapshot(display: displays[1], luminance: 50)
        ])

        XCTAssertEqual(runner.arguments, [
            ["display", uuid, "get", "luminance"],
            ["display", "7", "get", "luminance"],
            ["display", uuid, "set", "luminance", "40"],
            ["display", "7", "set", "luminance", "50"]
        ])
    }

    func testPartialRestoreFailureIsReportedAndOtherDisplaysAreAttempted() {
        let runner = PartialFailureRunner()
        let controller = M1DDCBrightnessController(executablePathProvider: { "/mock/m1ddc" }, commandRunner: runner)
        let snapshots = [
            ExternalDisplaySnapshot(display: ExternalDisplayReference(selector: "1", name: "First"), luminance: 40),
            ExternalDisplaySnapshot(display: ExternalDisplayReference(selector: "2", name: "Second"), luminance: 70)
        ]

        XCTAssertThrowsError(try controller.restore(snapshots))
        XCTAssertEqual(runner.arguments, [
            ["display", "1", "set", "luminance", "40"],
            ["display", "2", "set", "luminance", "70"]
        ])
    }

    func testLuminanceRejectsInvalidReadingsInsteadOfClampingOrExtractingNumbers() throws {
        let runner = SuccessfulCommandRunner()
        let controller = M1DDCBrightnessController(executablePathProvider: { "/mock/m1ddc" }, commandRunner: runner)
        let display = ExternalDisplayReference(selector: "1", name: "Monitor")
        for output in ["-55\n", "101", "error 1", "70 1", "", "999999999999999999999"] {
            runner.stdout = output
            XCTAssertThrowsError(try controller.currentSnapshot(for: [display]))
        }
        for level in [0, 1, 70, 100] {
            runner.stdout = " \(level)\n"
            XCTAssertEqual(try controller.currentSnapshot(for: [display]).first?.luminance, level)
        }
    }
}

private final class PartialFailureRunner: CommandRunning {
    var arguments: [[String]] = []
    func run(_ path: String, arguments: [String], timeout: TimeInterval) throws -> CommandResult {
        self.arguments.append(arguments)
        return CommandResult(status: arguments[1] == "1" ? 1 : 0, stdout: "", stderr: "Display unavailable")
    }
}

private final class SuccessfulCommandRunner: CommandRunning {
    var arguments: [[String]] = []
    var stdout = "65"

    func run(_ path: String, arguments: [String], timeout: TimeInterval) throws -> CommandResult {
        self.arguments.append(arguments)
        return CommandResult(status: 0, stdout: stdout, stderr: "")
    }
}
