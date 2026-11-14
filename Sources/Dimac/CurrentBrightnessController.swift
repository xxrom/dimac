import DimacCore
import Foundation

protocol CurrentBrightnessManaging {
    func read(_ row: DisplayControlRow) throws -> Int
    func set(_ percent: Int, for row: DisplayControlRow) throws
}

final class CurrentBrightnessController: CurrentBrightnessManaging {
    /// How long a discovered display list is reused, so repeated reads do not each spawn
    /// `m1ddc display list`. Writes always discover afresh.
    static let defaultDiscoveryCacheLifetime: TimeInterval = 5

    private let internalBrightness: InternalBrightnessManaging
    private let externalBrightness: ExternalBrightnessManaging
    private var cachedDisplays: [ExternalDisplayReference] = []
    private var cachedAt: TimeInterval?
    private let discoveryCacheLifetime: TimeInterval

    init(
        internalBrightness: InternalBrightnessManaging,
        externalBrightness: ExternalBrightnessManaging,
        discoveryCacheLifetime: TimeInterval = CurrentBrightnessController.defaultDiscoveryCacheLifetime
    ) {
        self.internalBrightness = internalBrightness
        self.externalBrightness = externalBrightness
        self.discoveryCacheLifetime = discoveryCacheLifetime
    }

    func read(_ row: DisplayControlRow) throws -> Int {
        switch row.mode {
        case .ddc(let saved):
            let (display, cached) = try resolve(saved, failure: .readFailed(saved.name))
            let snapshot: ExternalDisplaySnapshot?
            do {
                snapshot = try externalBrightness.currentSnapshot(for: [display]).first
            } catch {
                if cached { invalidateDiscoveryCache() }
                throw error
            }
            guard let snapshot else {
                throw BrightnessError.readFailed(row.name)
            }
            return snapshot.luminance
        case .brightnessCLI:
            let id = try displayID(for: row, failure: .readFailed(row.name))
            guard let snapshot = try internalBrightness.currentSnapshot().first(where: { $0.displayID == id }) else {
                throw BrightnessError.readFailed(row.name)
            }
            return Int((snapshot.brightness * 100).rounded())
        case .unsupported:
            throw BrightnessError.readFailed(row.name)
        }
    }

    func set(_ percent: Int, for row: DisplayControlRow) throws {
        let percent = min(100, max(0, percent))
        switch row.mode {
        case .ddc(let saved):
            // Writes never trust the cache: a monitor swapped since the last discovery must be rejected.
            let (display, _) = try resolve(saved, failure: .writeFailed(saved.name), allowCached: false)
            do {
                try externalBrightness.restore([ExternalDisplaySnapshot(display: display, luminance: percent)])
            } catch {
                invalidateDiscoveryCache()
                throw error
            }
        case .brightnessCLI:
            let id = try displayID(for: row, failure: .writeFailed(row.name))
            try internalBrightness.restore([InternalDisplaySnapshot(displayID: id, brightness: Float(percent) / 100)])
        case .unsupported:
            throw BrightnessError.writeFailed(row.name)
        }
    }

    /// Returns the single connected display matching `saved`, and whether it came from the cache.
    /// A cached entry is reused only when it carries a UUID: commands then address the monitor by UUID,
    /// so a stale list cannot redirect a write to a different monitor that took over its selector.
    private func resolve(
        _ saved: ExternalDisplayReference,
        failure: BrightnessError,
        allowCached: Bool = true
    ) throws -> (display: ExternalDisplayReference, cached: Bool) {
        guard saved.hasReliableIdentity else {
            throw failure
        }

        if allowCached, let cachedAt, ProcessInfo.processInfo.systemUptime - cachedAt < discoveryCacheLifetime {
            let matches = cachedDisplays.filter { $0.matchesRecoveryIdentity(of: saved) }
            if matches.count == 1, let display = matches.first, display.uuid != nil {
                return (display, true)
            }
        }

        let discovered = try externalBrightness.discoverDisplays()
        cachedDisplays = discovered
        cachedAt = ProcessInfo.processInfo.systemUptime
        let matches = discovered.filter { $0.matchesRecoveryIdentity(of: saved) }
        guard matches.count == 1, let display = matches.first else {
            throw failure
        }
        return (display, false)
    }

    private func invalidateDiscoveryCache() {
        cachedDisplays = []
        cachedAt = nil
    }

    private func displayID(for row: DisplayControlRow, failure: BrightnessError) throws -> UInt32 {
        guard let id = UInt32(row.preferenceKey.replacingOccurrences(of: "display:", with: "")) else {
            throw failure
        }
        return id
    }
}
