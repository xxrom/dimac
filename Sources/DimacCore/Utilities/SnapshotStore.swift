import Foundation

public protocol SnapshotPersisting {
    func load() throws -> BrightnessSnapshot?
    func save(_ snapshot: BrightnessSnapshot) throws
    func clear() throws
}

public enum SnapshotStoreError: LocalizedError, Equatable {
    /// The saved dim snapshot could not be decoded; it was renamed to `quarantinedAt` when that succeeded.
    case corruptSnapshot(quarantinedAt: URL?)

    public var errorDescription: String? {
        switch self {
        case .corruptSnapshot(let url):
            let location = url.map { " It was moved to \($0.lastPathComponent)." } ?? ""
            return "The saved dim snapshot was unreadable, so original brightness could not be restored; "
                + "set brightness manually if a display is still dim.\(location)"
        }
    }
}

public final class FileSnapshotStore: SnapshotPersisting {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let diagnostics: DiagnosticLogger

    public init(fileURL: URL? = nil, diagnostics: DiagnosticLogger = .shared) {
        self.diagnostics = diagnostics
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.fileURL = base
                .appendingPathComponent("Dimac", isDirectory: true)
                .appendingPathComponent("active-snapshot.json", isDirectory: false)
        }

        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func load() throws -> BrightnessSnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            diagnostics.record("snapshot.file.missing", ["path": fileURL.path])
            return nil
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            diagnostics.record("snapshot.file.loadFailed", ["path": fileURL.path, "error": error.localizedDescription])
            throw error
        }

        do {
            let snapshot = try decoder.decode(BrightnessSnapshot.self, from: data)
            diagnostics.record("snapshot.file.loaded", ["path": fileURL.path, "snapshot": DiagnosticLogger.encoded(snapshot)])
            return snapshot
        } catch {
            // Move the unreadable file aside so it is kept for inspection but no longer blocks saving a new
            // snapshot, and tell the caller the saved brightness was lost rather than "no snapshot".
            let quarantined = quarantineCorruptFile()
            diagnostics.record("snapshot.file.corrupt", ["path": fileURL.path, "error": error.localizedDescription,
                                                         "quarantinedAt": quarantined?.path ?? NSNull()])
            throw SnapshotStoreError.corruptSnapshot(quarantinedAt: quarantined)
        }
    }

    private func quarantineCorruptFile() -> URL? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = fileURL.deletingPathExtension().lastPathComponent
        let directory = fileURL.deletingLastPathComponent()
        var destination = directory.appendingPathComponent("\(base).corrupt-\(formatter.string(from: Date())).json")
        var suffix = 1
        while FileManager.default.fileExists(atPath: destination.path) {
            suffix += 1
            destination = directory.appendingPathComponent("\(base).corrupt-\(formatter.string(from: Date()))-\(suffix).json")
        }
        do {
            try FileManager.default.moveItem(at: fileURL, to: destination)
            return destination
        } catch {
            diagnostics.record("snapshot.file.quarantineFailed", ["path": fileURL.path, "error": error.localizedDescription])
            return nil
        }
    }

    public func save(_ snapshot: BrightnessSnapshot) throws {
        diagnostics.record("snapshot.file.saveRequested", ["path": fileURL.path, "snapshot": DiagnosticLogger.encoded(snapshot)])
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
            diagnostics.record("snapshot.file.saved", ["path": fileURL.path])
        } catch {
            diagnostics.record("snapshot.file.saveFailed", ["path": fileURL.path, "error": error.localizedDescription])
            throw error
        }
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }

        do {
            try FileManager.default.removeItem(at: fileURL)
            diagnostics.record("snapshot.file.cleared", ["path": fileURL.path])
        } catch {
            diagnostics.record("snapshot.file.clearFailed", ["path": fileURL.path, "error": error.localizedDescription])
            throw error
        }
    }
}
