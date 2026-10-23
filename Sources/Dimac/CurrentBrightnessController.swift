import DimacCore
import Foundation

protocol CurrentBrightnessManaging {
    func read(_ row: DisplayControlRow) throws -> Int
    func set(_ percent: Int, for row: DisplayControlRow) throws
}

/// Live display controls never persist a normal/restore brightness preference.
final class CurrentBrightnessController: CurrentBrightnessManaging {
    private let internalBrightness: InternalBrightnessManaging
    private let externalBrightness: ExternalBrightnessManaging

    init(internalBrightness: InternalBrightnessManaging, externalBrightness: ExternalBrightnessManaging) {
        self.internalBrightness = internalBrightness
        self.externalBrightness = externalBrightness
    }

    func read(_ row: DisplayControlRow) throws -> Int {
        switch row.mode {
        case .ddc(let saved):
            let display = try resolve(saved)
            guard let snapshot = try externalBrightness.currentSnapshot(for: [display]).first else {
                throw BrightnessError.readFailed(row.name)
            }
            return snapshot.luminance
        case .brightnessCLI:
            let id = try displayID(for: row)
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
            let display = try resolve(saved)
            try externalBrightness.restore([ExternalDisplaySnapshot(display: display, luminance: percent)])
        case .brightnessCLI:
            let id = try displayID(for: row)
            // The controller resolves this ID to the current hardware index before writing.
            try internalBrightness.restore([InternalDisplaySnapshot(displayID: id, brightness: Float(percent) / 100)])
        case .unsupported:
            throw BrightnessError.writeFailed(row.name)
        }
    }

    private func resolve(_ saved: ExternalDisplayReference) throws -> ExternalDisplayReference {
        let matches = try externalBrightness.discoverDisplays().filter { $0.matchesRecoveryIdentity(of: saved) }
        guard saved.hasReliableIdentity, matches.count == 1, let display = matches.first else {
            throw BrightnessError.readFailed(saved.name)
        }
        return display
    }

    private func displayID(for row: DisplayControlRow) throws -> UInt32 {
        guard let id = UInt32(row.preferenceKey.replacingOccurrences(of: "display:", with: "")) else {
            throw BrightnessError.readFailed(row.name)
        }
        return id
    }
}
