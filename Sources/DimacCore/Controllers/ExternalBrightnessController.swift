import Foundation

public protocol ExternalBrightnessManaging {
    func discoverDisplays() throws -> [ExternalDisplayReference]
    func currentSnapshot(for displays: [ExternalDisplayReference]) throws -> [ExternalDisplaySnapshot]
    func setBrightness(percent: Int, for displays: [ExternalDisplayReference]) throws
    func restore(_ snapshots: [ExternalDisplaySnapshot]) throws
}

public struct M1DDCDisplayListParser {
    public init() {}

    public func parse(_ output: String) -> [ExternalDisplayReference] {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { rawLine in
                let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else {
                    return nil
                }

                let patterns = [
                    #"^\s*\[([0-9]+)\]\s*(.*?)\s*(?:\([0-9A-Fa-f-]+\))?\s*$"#,
                    #"^\s*Display\s+([0-9]+)\b[:.)\-\s]*(.*)$"#,
                    #"^\s*([0-9]+)\b[:.)\-\s]*(.*)$"#
                ]

                for pattern in patterns {
                    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                        continue
                    }

                    let range = NSRange(line.startIndex..<line.endIndex, in: line)
                    guard let match = regex.firstMatch(in: line, range: range), match.numberOfRanges >= 2 else {
                        continue
                    }

                    guard let selectorRange = Range(match.range(at: 1), in: line) else {
                        continue
                    }

                    let selector = String(line[selectorRange])
                    var name = "Display \(selector)"
                    if match.numberOfRanges >= 3, let nameRange = Range(match.range(at: 2), in: line) {
                        let candidate = String(line[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !candidate.isEmpty, candidate != "(null)" {
                            name = candidate
                        }
                    }

                    return ExternalDisplayReference(selector: selector, name: name)
                }

                return nil
            }
    }
}

public final class M1DDCBrightnessController: ExternalBrightnessManaging {
    private let executablePathProvider: () -> String
    private let commandRunner: CommandRunning
    private let parser: M1DDCDisplayListParser

    public init(
        executablePathProvider: @escaping () -> String,
        commandRunner: CommandRunning = ProcessCommandRunner(),
        parser: M1DDCDisplayListParser = M1DDCDisplayListParser()
    ) {
        self.executablePathProvider = executablePathProvider
        self.commandRunner = commandRunner
        self.parser = parser
    }

    public func discoverDisplays() throws -> [ExternalDisplayReference] {
        let path = executablePathProvider()
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw BrightnessError.commandNotFound(path)
        }

        let result = try? commandRunner.run(path, arguments: ["display", "list"], timeout: 3)

        if let result, result.status == 0 {
            let displays = parser.parse(result.stdout)
            if !displays.isEmpty {
                return displays
            }
        }

        if let luminance = try? readLuminance(display: nil), luminance >= 0 {
            return [
                ExternalDisplayReference(
                    selector: nil,
                    name: "Default external display",
                    isDefaultFallback: true
                )
            ]
        }

        if let result {
            if result.status == 0 {
                return []
            }

            throw BrightnessError.commandFailed(
                path: path,
                arguments: ["display", "list"],
                status: result.status,
                stderr: result.stderr
            )
        }

        return []
    }

    public func currentSnapshot(for displays: [ExternalDisplayReference]) throws -> [ExternalDisplaySnapshot] {
        var snapshots: [ExternalDisplaySnapshot] = []
        var errors: [Error] = []

        for display in displays {
            do {
                let luminance = try readLuminance(display: display)
                snapshots.append(ExternalDisplaySnapshot(display: display, luminance: luminance))
            } catch {
                errors.append(error)
            }
        }

        if snapshots.isEmpty, let firstError = errors.first {
            throw firstError
        }

        return snapshots
    }

    public func setBrightness(percent: Int, for displays: [ExternalDisplayReference]) throws {
        let value = DimmerSettings.clampedPercent(percent)
        var errors: [Error] = []

        for display in displays {
            do {
                try writeLuminance(value, display: display)
            } catch {
                errors.append(error)
            }
        }

        if errors.count == displays.count, let firstError = errors.first {
            throw firstError
        }
    }

    public func restore(_ snapshots: [ExternalDisplaySnapshot]) throws {
        var errors: [Error] = []

        for snapshot in snapshots {
            do {
                try writeLuminance(snapshot.luminance, display: snapshot.display)
            } catch {
                errors.append(error)
            }
        }

        if errors.count == snapshots.count, let firstError = errors.first {
            throw firstError
        }
    }

    private func readLuminance(display: ExternalDisplayReference?) throws -> Int {
        let arguments = commandArguments(display: display, action: ["get", "luminance"])
        let result = try commandRunner.run(executablePathProvider(), arguments: arguments, timeout: 3)
        guard result.status == 0 else {
            throw BrightnessError.commandFailed(
                path: executablePathProvider(),
                arguments: arguments,
                status: result.status,
                stderr: result.stderr
            )
        }

        guard let value = firstInteger(in: result.stdout) else {
            throw BrightnessError.invalidOutput(
                command: ([executablePathProvider()] + arguments).joined(separator: " "),
                output: result.stdout
            )
        }

        return min(100, max(0, value))
    }

    private func writeLuminance(_ value: Int, display: ExternalDisplayReference?) throws {
        let arguments = commandArguments(
            display: display,
            action: ["set", "luminance", "\(min(100, max(0, value)))"]
        )
        let result = try commandRunner.run(executablePathProvider(), arguments: arguments, timeout: 3)
        guard result.status == 0 else {
            throw BrightnessError.commandFailed(
                path: executablePathProvider(),
                arguments: arguments,
                status: result.status,
                stderr: result.stderr
            )
        }
    }

    private func commandArguments(display: ExternalDisplayReference?, action: [String]) -> [String] {
        guard let selector = display?.selector else {
            return action
        }

        return ["display", selector] + action
    }

    private func firstInteger(in output: String) -> Int? {
        let pattern = #"[-+]?[0-9]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = regex.firstMatch(in: output, range: range),
              let valueRange = Range(match.range, in: output) else {
            return nil
        }

        return Int(output[valueRange])
    }
}
