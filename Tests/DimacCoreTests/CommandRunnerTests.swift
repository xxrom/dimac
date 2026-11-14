import Darwin
import DimacCore
import Foundation
import XCTest

final class CommandRunnerTests: XCTestCase {
    func testDrainsLargeStandardOutputAndStandardErrorConcurrently() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let diagnostics = DiagnosticLogger(fileURL: directory.appendingPathComponent("diagnostics.jsonl"))
        let runner = ProcessCommandRunner(diagnostics: diagnostics)
        let chunk = "0123456789"
        let repetitions = 10_000
        let script = "i=0; while [ \"$i\" -lt \(repetitions) ]; do printf \(chunk); printf \(chunk) >&2; i=$((i + 1)); done"

        let result = try runner.run("/bin/sh", arguments: ["-c", script], timeout: 5)

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, String(repeating: chunk, count: repetitions))
        XCTAssertEqual(result.stderr, String(repeating: chunk, count: repetitions))

        let events = try String(contentsOf: diagnostics.fileURL, encoding: .utf8)
            .split(separator: "\n")
            .map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        let finished = try XCTUnwrap(events.first { $0["event"] as? String == "command.finished" })
        XCTAssertEqual((finished["stdout"] as? String)?.count, 8192)
        XCTAssertEqual((finished["stderr"] as? String)?.count, 8192)
    }

    func testTimeoutKillsAndReapsHelperThatIgnoresTermination() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("ignore-term")
        let pidFile = directory.appendingPathComponent("helper.pid")
        let script = "#!/bin/sh\ntrap '' TERM\nprintf '%s' \"$$\" > '\(pidFile.path)'\nwhile :; do :; done\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let diagnostics = DiagnosticLogger(fileURL: directory.appendingPathComponent("diagnostics.jsonl"))
        let runner = ProcessCommandRunner(diagnostics: diagnostics)
        XCTAssertThrowsError(try runner.run(executable.path, arguments: [], timeout: 1)) { error in
            XCTAssertEqual(error as? BrightnessError, .commandTimedOut(path: executable.path, arguments: []))
        }

        let pid = try XCTUnwrap(Int(String(contentsOf: pidFile, encoding: .utf8)))
        let helperPID = pid_t(pid)
        defer {
            if kill(helperPID, 0) == 0 {
                _ = kill(helperPID, SIGKILL)
            }
        }

        let deadline = Date().addingTimeInterval(2)
        while kill(helperPID, 0) == 0, Date() < deadline {
            usleep(10_000)
        }
        let result = kill(helperPID, 0)
        let resultError = errno
        XCTAssertEqual(result, -1)
        XCTAssertEqual(resultError, ESRCH)
    }

    func testExitedCommandReturnsPromptlyWhileGrandchildHoldsOutputPipe() throws {
        let runner = ProcessCommandRunner(diagnostics: DiagnosticLogger(fileURL: Self.scratchLogURL(), isEnabled: false))
        let started = Date()
        let result = try runner.run("/bin/sh", arguments: ["-c", "sleep 30 & echo $!; echo hi"], timeout: 5)
        let elapsed = Date().timeIntervalSince(started)
        let lines = result.stdout.split(separator: "\n")
        if let grandchild = lines.first.flatMap({ pid_t(String($0)) }) {
            _ = kill(grandchild, SIGKILL)
        }

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(lines.last, "hi")
        XCTAssertLessThanOrEqual(elapsed, 2)
    }

    func testTimeoutIsBoundedAndKillsGrandchildHoldingOutputPipe() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("grandchild.pid")

        let runner = ProcessCommandRunner(diagnostics: DiagnosticLogger(fileURL: Self.scratchLogURL(), isEnabled: false))
        let started = Date()
        XCTAssertThrowsError(try runner.run(
            "/bin/sh", arguments: ["-c", "sleep 30 & printf '%s' \"$!\" > '\(pidFile.path)'; echo hi; sleep 30"], timeout: 0.5
        )) { error in
            XCTAssertEqual(error as? BrightnessError, .commandTimedOut(path: "/bin/sh", arguments: [
                "-c", "sleep 30 & printf '%s' \"$!\" > '\(pidFile.path)'; echo hi; sleep 30"
            ]))
        }
        XCTAssertLessThanOrEqual(Date().timeIntervalSince(started), 3)

        let grandchild = pid_t(try XCTUnwrap(Int(String(contentsOf: pidFile, encoding: .utf8))))
        defer { if kill(grandchild, 0) == 0 { _ = kill(grandchild, SIGKILL) } }
        let deadline = Date().addingTimeInterval(2)
        while kill(grandchild, 0) == 0, Date() < deadline {
            usleep(10_000)
        }
        XCTAssertEqual(kill(grandchild, 0), -1)
    }

    private static func scratchLogURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("dimac-runner-\(UUID().uuidString).jsonl")
    }
}
