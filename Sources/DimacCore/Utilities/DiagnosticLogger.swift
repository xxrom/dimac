import Foundation
import Darwin

public final class DiagnosticLogger {
    public static let shared = DiagnosticLogger(fileURL: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Dimac/diagnostics.jsonl"))

    private static let minimumFileSize = 1_024
    private static let truncationReason = "record exceeded the configured maximum log size"

    public let fileURL: URL
    private let maximumFileSize: Int
    private let now: () -> Date
    private let maximumAge: TimeInterval = 5 * 60 * 60
    private let session = UUID().uuidString
    private let lock = NSLock()
    private var sequence = 0
    private var reportedFailure = false
    private var nextExpiration = Date.distantPast

    public init(fileURL: URL, maximumFileSize: Int = 5_000_000, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.maximumFileSize = max(Self.minimumFileSize, maximumFileSize)
        self.now = now
    }

    public static func encoded<T: Encodable>(_ value: T) -> Any {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value),
              let json = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else {
            return ["encodingError": String(describing: value)]
        }
        return json
    }

    public func record(_ event: String, _ fields: [String: Any] = [:]) {
        lock.lock()
        defer { lock.unlock() }
        sequence += 1
        var entry = fields
        entry["event"] = event
        entry["session"] = session
        entry["sequence"] = sequence
        entry["pid"] = ProcessInfo.processInfo.processIdentifier
        entry["uptimeSeconds"] = ProcessInfo.processInfo.systemUptime
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            let lockDescriptor = try acquireFileLock()
            defer {
                _ = flock(lockDescriptor, LOCK_UN)
                _ = Darwin.close(lockDescriptor)
            }

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let date = now()
            entry["timestamp"] = formatter.string(from: date)
            if date >= nextExpiration {
                try removeExpiredRecords(at: date, formatter: formatter)
            }
            let data = try encodedLine(for: entry)
            let size = (try? manager.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue ?? 0
            if size + data.count > maximumFileSize {
                let previous = fileURL.appendingPathExtension("1")
                let oldest = fileURL.appendingPathExtension("2")
                if manager.fileExists(atPath: oldest.path) { try manager.removeItem(at: oldest) }
                if manager.fileExists(atPath: previous.path) { try manager.moveItem(at: previous, to: oldest) }
                if manager.fileExists(atPath: fileURL.path) { try manager.moveItem(at: fileURL, to: previous) }
            }
            let descriptor = open(fileURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            nextExpiration = min(nextExpiration, date.addingTimeInterval(maximumAge))
        } catch {
            if !reportedFailure {
                reportedFailure = true
                NSLog("Dimac diagnostic logging failed at %@: %@", fileURL.path, error.localizedDescription)
            }
        }
    }

    private func acquireFileLock() throws -> Int32 {
        let lockURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            _ = Darwin.close(descriptor)
            throw error
        }
        return descriptor
    }

    private func encodedLine(for entry: [String: Any]) throws -> Data {
        let encoded = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
        guard encoded.count + 1 > maximumFileSize else {
            var line = encoded
            line.append(0x0a)
            return line
        }

        var fallback: [String: Any] = [
            "event": String((entry["event"] as? String ?? "unknown").unicodeScalars.prefix(32)),
            "loggerTruncated": true,
            "originalByteCount": encoded.count,
            "loggerTruncationReason": Self.truncationReason
        ]
        for key in ["timestamp", "session", "sequence", "pid", "uptimeSeconds"] {
            fallback[key] = entry[key]
        }
        if let reason = entry["reason"] as? String {
            fallback["reason"] = String(reason.unicodeScalars.prefix(32))
        }
        var line = try JSONSerialization.data(withJSONObject: fallback, options: [.sortedKeys])
        line.append(0x0a)
        return line
    }

    private func removeExpiredRecords(at date: Date, formatter: ISO8601DateFormatter) throws {
        let manager = FileManager.default
        let cutoff = date.addingTimeInterval(-maximumAge)
        var earliestExpiration = Date.distantFuture
        for url in [fileURL, fileURL.appendingPathExtension("1"), fileURL.appendingPathExtension("2")] {
            guard manager.fileExists(atPath: url.path) else { continue }
            let contents = try String(contentsOf: url, encoding: .utf8)
            let lines = contents.split(separator: "\n")
            let retained = lines.filter { line in
                guard let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let timestamp = entry["timestamp"] as? String,
                      let recordedAt = formatter.date(from: timestamp), recordedAt > cutoff else {
                    return false
                }
                earliestExpiration = min(earliestExpiration, recordedAt.addingTimeInterval(maximumAge))
                return true
            }
            if retained.isEmpty {
                try manager.removeItem(at: url)
            } else if retained.count != lines.count {
                try Data((retained.joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        }
        nextExpiration = earliestExpiration
    }
}
