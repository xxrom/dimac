import DimacCore
import XCTest

final class ExternalBrightnessControllerTests: XCTestCase {
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
}

private final class PartialFailureRunner: CommandRunning {
    var arguments: [[String]] = []
    func run(_ path: String, arguments: [String], timeout: TimeInterval) throws -> CommandResult {
        self.arguments.append(arguments)
        return CommandResult(status: arguments[1] == "1" ? 1 : 0, stdout: "", stderr: "Display unavailable")
    }
}
