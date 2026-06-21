import CoreGraphics
import Darwin
import Foundation

public protocol InternalBrightnessManaging {
    func currentSnapshot() throws -> [InternalDisplaySnapshot]
    func setBrightness(percent: Int) throws
    func restore(_ snapshots: [InternalDisplaySnapshot]) throws
}

public final class DisplayServicesBrightnessController: InternalBrightnessManaging {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Bool
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Bool

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
            guard getBrightness(displayID, &value) else {
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
            guard setBrightness(displayID, value) else {
                throw BrightnessError.writeFailed("built-in display \(displayID)")
            }
        }
    }

    public func restore(_ snapshots: [InternalDisplaySnapshot]) throws {
        for snapshot in snapshots {
            guard setBrightness(CGDirectDisplayID(snapshot.displayID), snapshot.brightness) else {
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

    public init(
        executablePathProvider: @escaping () -> String = { CommandLocator.brightnessDefaultPath },
        commandRunner: CommandRunning = ProcessCommandRunner()
    ) {
        self.executablePathProvider = executablePathProvider
        self.commandRunner = commandRunner
    }

    public func currentSnapshot() throws -> [InternalDisplaySnapshot] {
        let path = executablePathProvider()
        let result = try commandRunner.run(path, arguments: ["-l"], timeout: 3)
        guard result.status == 0 else {
            throw BrightnessError.commandFailed(
                path: path,
                arguments: ["-l"],
                status: result.status,
                stderr: result.stderr
            )
        }

        guard let brightness = parseBrightness(result.stdout) else {
            throw BrightnessError.invalidOutput(command: "\(path) -l", output: result.stdout)
        }

        return [
            InternalDisplaySnapshot(
                displayID: Self.snapshotDisplayID,
                brightness: brightness
            )
        ]
    }

    public func setBrightness(percent: Int) throws {
        let path = executablePathProvider()
        let value = String(format: "%.4f", Float(DimmerSettings.clampedPercent(percent)) / 100.0)
        let result = try commandRunner.run(path, arguments: [value], timeout: 3)
        guard result.status == 0 else {
            throw BrightnessError.commandFailed(
                path: path,
                arguments: [value],
                status: result.status,
                stderr: result.stderr
            )
        }
    }

    public func restore(_ snapshots: [InternalDisplaySnapshot]) throws {
        guard let brightness = snapshots.first?.brightness else {
            return
        }

        let path = executablePathProvider()
        let value = String(format: "%.4f", min(1.0, max(0.0, brightness)))
        let result = try commandRunner.run(path, arguments: [value], timeout: 3)
        guard result.status == 0 else {
            throw BrightnessError.commandFailed(
                path: path,
                arguments: [value],
                status: result.status,
                stderr: result.stderr
            )
        }
    }

    private func parseBrightness(_ output: String) -> Float? {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map(String.init)

        for line in lines where line.localizedCaseInsensitiveContains("brightness") {
            if let value = lastFloat(in: line) {
                return min(1.0, max(0.0, value))
            }
        }

        return lastFloat(in: output).map { min(1.0, max(0.0, $0)) }
    }

    private func lastFloat(in string: String) -> Float? {
        let pattern = #"[-+]?(?:[0-9]*\.[0-9]+|[0-9]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        let matches = regex.matches(in: string, range: range)
        guard let match = matches.last,
              let matchRange = Range(match.range, in: string) else {
            return nil
        }

        return Float(string[matchRange])
    }
}

public final class FallbackInternalBrightnessController: InternalBrightnessManaging {
    private let primary: InternalBrightnessManaging
    private let fallback: InternalBrightnessManaging
    private var lastSnapshotUsedFallback = false

    public init(primary: InternalBrightnessManaging, fallback: InternalBrightnessManaging) {
        self.primary = primary
        self.fallback = fallback
    }

    public func currentSnapshot() throws -> [InternalDisplaySnapshot] {
        do {
            let snapshot = try primary.currentSnapshot()
            if !snapshot.isEmpty {
                lastSnapshotUsedFallback = false
                return snapshot
            }
        } catch {
            // Fall through to the proven CLI path.
        }

        let snapshot = try fallback.currentSnapshot()
        lastSnapshotUsedFallback = true
        return snapshot
    }

    public func setBrightness(percent: Int) throws {
        if lastSnapshotUsedFallback {
            try fallback.setBrightness(percent: percent)
            return
        }

        do {
            try primary.setBrightness(percent: percent)
        } catch {
            try fallback.setBrightness(percent: percent)
        }
    }

    public func restore(_ snapshots: [InternalDisplaySnapshot]) throws {
        if snapshots.contains(where: { $0.displayID == BrightnessCLIBrightnessController.snapshotDisplayID }) {
            try fallback.restore(snapshots)
            return
        }

        do {
            try primary.restore(snapshots)
        } catch {
            try fallback.restore(snapshots)
        }
    }
}
