import Foundation

public protocol SnapshotPersisting {
    func load() throws -> BrightnessSnapshot?
    func save(_ snapshot: BrightnessSnapshot) throws
    func clear() throws
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

        do {
            let data = try Data(contentsOf: fileURL)
            let snapshot = try decoder.decode(BrightnessSnapshot.self, from: data)
            diagnostics.record("snapshot.file.loaded", ["path": fileURL.path, "snapshot": DiagnosticLogger.encoded(snapshot)])
            return snapshot
        } catch {
            diagnostics.record("snapshot.file.loadFailed", ["path": fileURL.path, "error": error.localizedDescription])
            throw error
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
