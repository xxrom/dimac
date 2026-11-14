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
                    #"^\s*\[([0-9]+)\]\s*(.*?)\s*$"#,
                    #"^\s*Display\s+([0-9]+)\b[:.)\-\s]*(.*)$"#,
                    // A bare number needs an explicit list separator ("1: Name", "1) Name", "1. Name",
                    // "1 - Name") so that lines such as "60 Hz" or "2560x1440" are not read as displays.
                    #"^\s*([0-9]+)(?:\s*[:)]|\.(?=\s|$)|\s+-(?=\s|$))\s*(.*)$"#
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
                    var uuid: String?
                    if match.numberOfRanges >= 3, let nameRange = Range(match.range(at: 2), in: line) {
                        var candidate = String(line[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if let start = Self.trailingGroupStart(in: candidate) {
                            let value = String(candidate[candidate.index(after: start)..<candidate.index(before: candidate.endIndex)])
                                .trimmingCharacters(in: .whitespaces)
                            if let identity = UUID(uuidString: value) {
                                uuid = identity.uuidString
                                candidate = String(candidate[..<start]).trimmingCharacters(in: .whitespacesAndNewlines)
                            } else if Self.isNullPlaceholder(value) {
                                candidate = String(candidate[..<start]).trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        }
                        if !candidate.isEmpty, !Self.isNullPlaceholder(candidate) {
                            name = candidate
                        }
                    }

                    return ExternalDisplayReference(selector: selector, name: name, uuid: uuid)
                }

                return nil
            }
    }

    /// Index of the "(" that opens the parenthesised group ending the string, honouring nesting so that
    /// "Dell ((null))" yields "(null)" rather than "null)".
    private static func trailingGroupStart(in value: String) -> String.Index? {
        guard value.hasSuffix(")") else { return nil }
        var depth = 0
        var index = value.endIndex
        while index > value.startIndex {
            index = value.index(before: index)
            switch value[index] {
            case ")": depth += 1
            case "(":
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
        }
        return nil
    }

    /// m1ddc prints a missing UUID or name as "(null)" (Objective-C nil formatting).
    private static func isNullPlaceholder(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespaces).lowercased()
        return normalized == "null" || normalized == "(null)" || normalized.isEmpty
    }
}

public final class M1DDCBrightnessController: ExternalBrightnessManaging {
    private let executablePathProvider: () -> String
    private let commandRunner: CommandRunning
    private let parser: M1DDCDisplayListParser
    private let diagnostics: DiagnosticLogger

    public init(
        executablePathProvider: @escaping () -> String,
        commandRunner: CommandRunning = ProcessCommandRunner(),
        parser: M1DDCDisplayListParser = M1DDCDisplayListParser(),
        diagnostics: DiagnosticLogger = .shared
    ) {
        self.executablePathProvider = executablePathProvider
        self.commandRunner = commandRunner
        self.parser = parser
        self.diagnostics = diagnostics
    }

    public func discoverDisplays() throws -> [ExternalDisplayReference] {
        let path = executablePathProvider()
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw BrightnessError.commandNotFound(path)
        }

        // A timed-out or failed list call is an error, never "no displays": reading it as empty would fall
        // back to a single selector-less display and silently leave every other monitor untouched.
        let arguments = ["display", "list"]
        let result: CommandResult
        do {
            result = try commandRunner.run(path, arguments: arguments, timeout: 3)
        } catch {
            diagnostics.record("ddc.discoveryFailed", ["error": error.localizedDescription])
            throw error
        }
        guard result.status == 0 else {
            diagnostics.record("ddc.discoveryFailed", ["status": result.status, "stderr": result.stderr])
            throw BrightnessError.commandFailed(path: path, arguments: arguments, status: result.status, stderr: result.stderr)
        }

        let displays = parser.parse(result.stdout)
        diagnostics.record("ddc.discovery", ["raw": result.stdout, "displays": DiagnosticLogger.encoded(displays)])
        if !displays.isEmpty {
            return displays
        }

        // The list succeeded but printed nothing parseable: probe m1ddc's default display.
        if let luminance = try? readLuminance(display: nil), luminance >= 0 {
            return [
                ExternalDisplayReference(
                    selector: nil,
                    name: "Default external display",
                    isDefaultFallback: true
                )
            ]
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

        if let firstError = errors.first {
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

        if let firstError = errors.first {
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

        guard let value = Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)),
              (0...100).contains(value) else {
            diagnostics.record("ddc.readRejected", ["display": display.map { DiagnosticLogger.encoded($0) } ?? NSNull(),
                                                    "raw": result.stdout, "reason": "expected brightness from 0 to 100"])
            throw BrightnessError.invalidOutput(
                command: ([executablePathProvider()] + arguments).joined(separator: " "),
                output: result.stdout
            )
        }

        diagnostics.record("ddc.read", ["display": display.map { DiagnosticLogger.encoded($0) } ?? NSNull(),
                                        "raw": result.stdout, "parsed": value, "percent": value])
        return value
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
        diagnostics.record("ddc.writeAccepted", ["display": display.map { DiagnosticLogger.encoded($0) } ?? NSNull(),
                                                 "requested": value, "status": result.status])
    }

    private func commandArguments(display: ExternalDisplayReference?, action: [String]) -> [String] {
        guard let selector = display?.uuid ?? display?.selector else {
            return action
        }

        return ["display", selector] + action
    }
}
