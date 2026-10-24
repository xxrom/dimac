import CoreGraphics
import Darwin
import Foundation

public protocol InternalBrightnessManaging {
    func currentSnapshot() throws -> [InternalDisplaySnapshot]
    func setBrightness(percent: Int) throws
    func restore(_ snapshots: [InternalDisplaySnapshot]) throws
}

public final class DisplayServicesBrightnessController: InternalBrightnessManaging {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private let getBrightness: GetBrightness
    private let setBrightness: SetBrightness

    public init() throws {
        let frameworkPath = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(frameworkPath, RTLD_NOW) else {
            throw BrightnessError.displayServicesUnavailable
        }

        guard let getSymbol = dlsym(handle, "DisplayServicesGetBrightness") else {
            throw BrightnessError.displayServicesSymbolMissing("DisplayServicesGetBrightness")
        }

        guard let setSymbol = dlsym(handle, "DisplayServicesSetBrightness") else {
            throw BrightnessError.displayServicesSymbolMissing("DisplayServicesSetBrightness")
        }

        self.getBrightness = unsafeBitCast(getSymbol, to: GetBrightness.self)
        self.setBrightness = unsafeBitCast(setSymbol, to: SetBrightness.self)
    }

    public func currentSnapshot() throws -> [InternalDisplaySnapshot] {
        let displayIDs = builtinDisplayIDs()
        guard !displayIDs.isEmpty else {
            throw BrightnessError.noBuiltinDisplayFound
        }

        return displayIDs.compactMap { displayID in
            var value: Float = 0
            guard getBrightness(displayID, &value) == 0 else {
                return nil
            }
            return InternalDisplaySnapshot(displayID: displayID, brightness: value)
        }
    }

    public func setBrightness(percent: Int) throws {
        let value = Float(DimmerSettings.clampedPercent(percent)) / 100.0
        let displayIDs = builtinDisplayIDs()
        guard !displayIDs.isEmpty else {
            throw BrightnessError.noBuiltinDisplayFound
        }

        for displayID in displayIDs {
            guard setBrightness(displayID, value) == 0 else {
                throw BrightnessError.writeFailed("built-in display \(displayID)")
            }
        }
    }

    public func restore(_ snapshots: [InternalDisplaySnapshot]) throws {
        for snapshot in snapshots {
            guard setBrightness(CGDirectDisplayID(snapshot.displayID), snapshot.brightness) == 0 else {
                throw BrightnessError.writeFailed("built-in display \(snapshot.displayID)")
            }
        }
    }

    private func builtinDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return []
        }

        var displays = Array(repeating: CGDirectDisplayID(0), count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else {
            return []
        }

        return displays.filter { CGDisplayIsBuiltin($0) != 0 }
    }
}

public final class BrightnessCLIBrightnessController: InternalBrightnessManaging {
    public static let snapshotDisplayID = UInt32.max

    private let executablePathProvider: () -> String
    private let commandRunner: CommandRunning
    private var snapshotDisplayIDs: Set<UInt32> = []

    public init(
        executablePathProvider: @escaping () -> String = { CommandLocator.brightnessDefaultPath },
        commandRunner: CommandRunning = ProcessCommandRunner()
    ) {
        self.executablePathProvider = executablePathProvider
        self.commandRunner = commandRunner
    }

    public func currentSnapshot() throws -> [InternalDisplaySnapshot] {
        let path = executablePathProvider()
        let displays = try loadDisplayList(path: path)
        let snapshots = displays.compactMap { display -> InternalDisplaySnapshot? in
            guard let brightness = display.brightness else {
                return nil
            }
            return InternalDisplaySnapshot(displayID: display.id, brightness: brightness)
        }
        guard !snapshots.isEmpty else {
            throw BrightnessError.invalidOutput(command: "\(path) -lv", output: displays.description)
        }

        snapshotDisplayIDs = Set(snapshots.map(\.displayID))
        return snapshots
    }

    public func setBrightness(percent: Int) throws {
        let path = executablePathProvider()
        let value = String(format: "%.4f", Float(DimmerSettings.clampedPercent(percent)) / 100.0)
        let displays = try loadDisplayList(path: path)

        for display in displays where snapshotDisplayIDs.contains(display.id) {
            try setBrightness(path: path, displayIndex: display.index, value: value)
        }
    }

    public func restore(_ snapshots: [InternalDisplaySnapshot]) throws {
        guard !snapshots.isEmpty else {
            return
        }

        let path = executablePathProvider()
        let displayIndexesByID = Dictionary(
            uniqueKeysWithValues: try loadDisplayList(path: path).map { ($0.id, $0.index) }
        )

        var firstError: Error?
        for snapshot in snapshots {
            guard snapshot.displayID != Self.snapshotDisplayID,
                  let displayIndex = displayIndexesByID[snapshot.displayID] else {
                firstError = firstError ?? BrightnessError.readFailed("saved display \(snapshot.displayID)")
                continue
            }

            let value = String(format: "%.4f", min(1.0, max(0.0, snapshot.brightness)))
            do {
                try setBrightness(path: path, displayIndex: displayIndex, value: value)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }

    private func loadDisplayList(path: String) throws -> [CLIDisplay] {
        let arguments = ["-lv"]
        let result = try commandRunner.run(path, arguments: arguments, timeout: 3)
        guard result.status == 0 else {
            throw BrightnessError.commandFailed(
                path: path,
                arguments: arguments,
                status: result.status,
                stderr: result.stderr
            )
        }

        let output = [result.stdout, result.stderr].joined(separator: "\n")
        let displays = parseDisplayList(output)
        guard !displays.isEmpty else {
            throw BrightnessError.invalidOutput(command: "\(path) -lv", output: output)
        }
        return displays
    }

    private func setBrightness(path: String, displayIndex: Int, value: String) throws {
        let arguments = ["-d", "\(displayIndex)", value]
        let result = try commandRunner.run(path, arguments: arguments, timeout: 3)
        guard result.status == 0 else {
            throw BrightnessError.commandFailed(
                path: path,
                arguments: arguments,
                status: result.status,
                stderr: result.stderr
            )
        }
    }

    private func parseDisplayList(_ output: String) -> [CLIDisplay] {
        var displays: [CLIDisplay] = []
        var displayOffsetsByIndex: [Int: Int] = [:]

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if let header = parseDisplayHeader(line) {
                displayOffsetsByIndex[header.index] = displays.count
                displays.append(header)
                continue
            }

            if let (index, brightness) = parseDisplayBrightness(line),
               let offset = displayOffsetsByIndex[index] {
                displays[offset].brightness = brightness
            }
        }

        return displays
    }

    private func parseDisplayHeader(_ line: String) -> CLIDisplay? {
        let pattern = #"^display\s+([0-9]+):.*\bID\s+0x([0-9a-fA-F]+)\s*$"#
        guard let fields = captureGroups(pattern: pattern, in: line),
              let index = Int(fields[0]),
              let id = UInt32(fields[1], radix: 16) else {
            return nil
        }
        return CLIDisplay(index: index, id: id, brightness: nil)
    }

    private func parseDisplayBrightness(_ line: String) -> (Int, Float)? {
        let pattern = #"^display\s+([0-9]+):\s+brightness\s+([0-9]*\.?[0-9]+)\s*$"#
        guard let fields = captureGroups(pattern: pattern, in: line),
              let index = Int(fields[0]),
              let brightness = Float(fields[1]) else {
            return nil
        }
        return (index, min(1.0, max(0.0, brightness)))
    }

    private func captureGroups(pattern: String, in string: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        guard let match = regex.firstMatch(in: string, range: range) else {
            return nil
        }
        return (1..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: string) else {
                return nil
            }
            return String(string[range])
        }
    }

    private struct CLIDisplay: CustomStringConvertible {
        var index: Int
        var id: UInt32
        var brightness: Float?

        var description: String {
            let brightnessDescription = brightness.map { String($0) } ?? "unavailable"
            return "display \(index) (ID \(id), brightness \(brightnessDescription))"
        }
    }
}

public final class FallbackInternalBrightnessController: InternalBrightnessManaging {
    private let primary: InternalBrightnessManaging
    private let fallback: InternalBrightnessManaging
    private var lastPrimaryDisplayIDs: Set<UInt32> = []
    private var lastFallbackDisplayIDs: Set<UInt32> = []

    public init(primary: InternalBrightnessManaging, fallback: InternalBrightnessManaging) {
        self.primary = primary
        self.fallback = fallback
    }

    public func currentSnapshot() throws -> [InternalDisplaySnapshot] {
        var primarySnapshots: [InternalDisplaySnapshot] = []
        var primaryError: Error?
        do {
            primarySnapshots = try primary.currentSnapshot()
        } catch {
            primaryError = error
        }

        var fallbackSnapshots: [InternalDisplaySnapshot] = []
        var fallbackError: Error?
        do {
            fallbackSnapshots = try fallback.currentSnapshot()
        } catch {
            fallbackError = error
        }

        var snapshotsByID = Dictionary(
            uniqueKeysWithValues: fallbackSnapshots.map { ($0.displayID, $0) }
        )
        for snapshot in primarySnapshots {
            snapshotsByID[snapshot.displayID] = snapshot
        }

        let snapshots = snapshotsByID.values.sorted { $0.displayID < $1.displayID }
        guard !snapshots.isEmpty else {
            throw fallbackError ?? primaryError ?? BrightnessError.noBuiltinDisplayFound
        }

        lastPrimaryDisplayIDs = Set(primarySnapshots.map(\.displayID))
        lastFallbackDisplayIDs = Set(fallbackSnapshots.map(\.displayID))
        return snapshots
    }

    public func setBrightness(percent: Int) throws {
        if lastPrimaryDisplayIDs.isEmpty {
            try fallback.setBrightness(percent: percent)
            return
        }

        do {
            try primary.setBrightness(percent: percent)
        } catch {
            try fallback.setBrightness(percent: percent)
            if !lastPrimaryDisplayIDs.isSubset(of: lastFallbackDisplayIDs) {
                throw error
            }
            return
        }

        if !lastFallbackDisplayIDs.subtracting(lastPrimaryDisplayIDs).isEmpty {
            try fallback.setBrightness(percent: percent)
        }
    }

    public func restore(_ snapshots: [InternalDisplaySnapshot]) throws {
        guard !snapshots.isEmpty else {
            return
        }

        let currentPrimaryIDs: Set<UInt32>
        do {
            currentPrimaryIDs = Set(try primary.currentSnapshot().map(\.displayID))
        } catch {
            try fallback.restore(snapshots)
            return
        }

        let primarySnapshots = snapshots.filter { currentPrimaryIDs.contains($0.displayID) }
        let fallbackSnapshots = snapshots.filter { !currentPrimaryIDs.contains($0.displayID) }

        do {
            try primary.restore(primarySnapshots)
        } catch {
            try fallback.restore(snapshots)
            return
        }

        if !fallbackSnapshots.isEmpty {
            try fallback.restore(fallbackSnapshots)
        }
    }
}
