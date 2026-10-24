import DimacCore
import Dispatch
import Foundation
import XCTest

final class DiagnosticLoggerTests: XCTestCase {
    func testFiveHourCutoffRemovesExpiredRecordsWhileKeepingRecentOnes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("diagnostics.jsonl")
        var now = Date(timeIntervalSince1970: 10_000)
        let logger = DiagnosticLogger(fileURL: url, now: { now })
        logger.record("first")
        now.addTimeInterval(5 * 60 * 60 - 1)
        logger.record("recent")
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("first"))
        now.addTimeInterval(1)
        logger.record("cutoff")
        let events = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        XCTAssertEqual(events.compactMap { $0["event"] as? String }, ["recent", "cutoff"])
    }

    func testRelaunchPrunesAllRotatedFilesByRecordTimestampRatherThanFileAge() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("diagnostics.jsonl")
        let now = Date(timeIntervalSince1970: 100_000)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func line(_ event: String, age: TimeInterval) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: ["event": event,
                "timestamp": formatter.string(from: now.addingTimeInterval(-age))])
            return String(decoding: data, as: UTF8.self) + "\n"
        }
        try Data((line("expired-current", age: 18_001) + line("recent-current", age: 60)).utf8).write(to: url)
        try Data((line("expired-backup", age: 20_000) + line("recent-backup", age: 120)).utf8)
            .write(to: url.appendingPathExtension("1"))
        try Data(line("expired-oldest", age: 30_000).utf8).write(to: url.appendingPathExtension("2"))
        let logger = DiagnosticLogger(fileURL: url, now: { now })
        logger.record("relaunch")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("2").path))
        let current = try String(contentsOf: url, encoding: .utf8)
        let backup = try String(contentsOf: url.appendingPathExtension("1"), encoding: .utf8)
        XCTAssertFalse(current.contains("expired"))
        XCTAssertFalse(backup.contains("expired"))
        XCTAssertTrue(current.contains("recent-current"))
        XCTAssertTrue(backup.contains("recent-backup"))
    }

    func testFullyExpiredCurrentLogStartsFreshAfterLongPause() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("diagnostics.jsonl")
        var now = Date(timeIntervalSince1970: 10_000)
        let logger = DiagnosticLogger(fileURL: url, now: { now })
        logger.record("before-sleep")
        now.addTimeInterval(6 * 60 * 60)
        logger.record("after-wake")
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(contents.contains("before-sleep"))
        XCTAssertTrue(contents.contains("after-wake"))
    }

    func testJSONLinesPreserveValuesAndRotateWithSessionContinuity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("diagnostics.jsonl")
        let logger = DiagnosticLogger(fileURL: url, maximumFileSize: 1_024)
        for index in 0..<16 {
            logger.record("brightness", ["requested": 70, "reported": 1, "index": index,
                                          "raw": "line one\nline two"])
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { ["diagnostics.jsonl", "diagnostics.jsonl.1", "diagnostics.jsonl.2"].contains($0.lastPathComponent) }
        XCTAssertEqual(files.count, 3)
        var events: [[String: Any]] = []
        for file in files {
            for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n") {
                events.append(try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]))
            }
        }
        XCTAssertEqual(Set(events.compactMap { $0["session"] as? String }).count, 1)
        XCTAssertTrue(events.allSatisfy { $0["requested"] as? Int == 70 && $0["reported"] as? Int == 1 })
        XCTAssertTrue(events.allSatisfy { $0["raw"] as? String == "line one\nline two" })
        XCTAssertEqual(events.compactMap { $0["sequence"] as? Int }.max(), 16)
        let reader = DiagnosticLogger(fileURL: url)
        reader.record("relaunch")
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        let last = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(lines.last).utf8)) as? [String: Any])
        XCTAssertFalse(last["session"] as? String == events.first?["session"] as? String)
    }

    func testIndependentInstancesSerializeConcurrentWritesToOneFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("diagnostics.jsonl")
        let logPath = url.path
        let now = Date(timeIntervalSince1970: 200_000)
        let writerCount = 6
        let recordsPerWriter = 20

        DispatchQueue.concurrentPerform(iterations: writerCount) { writer in
            let logger = DiagnosticLogger(fileURL: URL(fileURLWithPath: logPath), maximumFileSize: 20_000, now: { now })
            for index in 0..<recordsPerWriter {
                logger.record("parallel", ["id": "\(writer)-\(index)"])
            }
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("1").path))
        let events = try [url, url.appendingPathExtension("1"), url.appendingPathExtension("2")].filter {
            FileManager.default.fileExists(atPath: $0.path)
        }.flatMap { file in
            try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map {
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
            }
        }
        let identifiers = events.compactMap { $0["id"] as? String }
        XCTAssertEqual(events.count, writerCount * recordsPerWriter)
        XCTAssertEqual(Set(identifiers).count, writerCount * recordsPerWriter)
    }

    func testOversizedEventIsBoundedAndKeepsMetadataAndReason() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("diagnostics.jsonl")
        let logger = DiagnosticLogger(fileURL: url, maximumFileSize: 1_024,
                                      now: { Date(timeIntervalSince1970: 300_000) })
        logger.record("command.finished", [
            "raw": "stdout-prefix-" + String(repeating: "output;", count: 50_000),
            "reason": "restore readback was stale"
        ])

        let data = try Data(contentsOf: url)
        XCTAssertLessThanOrEqual(data.count, 1_024)
        let line = try XCTUnwrap(String(data: data, encoding: .utf8)?.split(separator: "\n").first)
        let entry = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(entry["event"] as? String, "command.finished")
        XCTAssertEqual(entry["reason"] as? String, "restore readback was stale")
        XCTAssertNotNil(entry["timestamp"] as? String)
        XCTAssertNotNil(entry["session"] as? String)
        XCTAssertNotNil(entry["sequence"] as? Int)
        XCTAssertNotNil(entry["pid"] as? Int)
        XCTAssertNotNil(entry["uptimeSeconds"] as? Double)
        XCTAssertEqual(entry["loggerTruncated"] as? Bool, true)
        XCTAssertGreaterThan(entry["originalByteCount"] as? Int ?? 0, data.count)
        XCTAssertEqual(entry["loggerTruncationReason"] as? String,
                       "record exceeded the configured maximum log size")
        XCTAssertNil(entry["raw"])
        logger.record(String(repeating: "\u{01}", count: 5_000), ["reason": String(repeating: "\u{02}", count: 5_000)])
        let escapedData = try Data(contentsOf: url)
        XCTAssertLessThanOrEqual(escapedData.count, 1_024)
        let escapedLine = try XCTUnwrap(escapedData.split(separator: 0x0a).last)
        let escaped = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(escapedLine)) as? [String: Any])
        XCTAssertEqual(escaped["loggerTruncated"] as? Bool, true)
    }

    func testCommandTraceIncludesRawOutputExitStatusAndFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("diagnostics.jsonl")
        let logger = DiagnosticLogger(fileURL: url)
        let runner = ProcessCommandRunner(diagnostics: logger)
        let result = try runner.run("/usr/bin/printf", arguments: ["70\n"], timeout: 1)
        XCTAssertEqual(result.stdout, "70\n")
        XCTAssertThrowsError(try runner.run("/missing/brightness-helper", arguments: [], timeout: 1))
        let events = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        XCTAssertEqual(events.compactMap { $0["event"] as? String },
                       ["command.started", "command.finished", "command.started", "command.failed"])
        XCTAssertEqual(events[1]["stdout"] as? String, "70\n")
        XCTAssertEqual(events[1]["status"] as? Int, 0)
        XCTAssertEqual(events[0]["commandID"] as? String, events[1]["commandID"] as? String)
        XCTAssertNotNil(events[3]["error"])
    }

    func testUnwritableLogDoesNotThrowIntoBrightnessCode() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("parent-is-file")
        try Data().write(to: file)
        let logger = DiagnosticLogger(fileURL: file.appendingPathComponent("diagnostics.jsonl"))
        logger.record("failure")
        XCTAssertEqual(try Data(contentsOf: file).count, 0)
    }
}
