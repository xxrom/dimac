import AppKit
import CoreGraphics
import DimacCore
import Foundation

struct ConnectedDisplayRow: Identifiable, Equatable {
    let id: String
    let index: Int?
    let name: String
    let resolution: String
    let brightnessPercent: Int?
    let isBuiltIn: Bool
    let isExternal: Bool
    let canReadHardwareBrightness: Bool
}

final class ConnectedDisplayDiscovery {
    private let brightnessPathProvider: () -> String
    private let commandRunner: CommandRunning

    init(
        brightnessPathProvider: @escaping () -> String = { CommandLocator.brightnessDefaultPath },
        commandRunner: CommandRunning = ProcessCommandRunner()
    ) {
        self.brightnessPathProvider = brightnessPathProvider
        self.commandRunner = commandRunner
    }

    func displays() -> [ConnectedDisplayRow] {
        let screenRows = Self.displaysFromScreens()
        if let cliRows = externalDisplaysFromBrightnessCLI(screenRows: screenRows),
           !cliRows.isEmpty {
            return cliRows
        }

        return screenRows
    }

    private func externalDisplaysFromBrightnessCLI(
        screenRows: [ConnectedDisplayRow]
    ) -> [ConnectedDisplayRow]? {
        let path = brightnessPathProvider()
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }

        guard let result = try? commandRunner.run(path, arguments: ["-lv"], timeout: 3) else {
            return nil
        }

        let output = [result.stdout, result.stderr]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else {
            return nil
        }

        let parser = BrightnessVerboseDisplayParser()
        let screenRowsByID = Dictionary(uniqueKeysWithValues: screenRows.map { ($0.id, $0) })

        return parser.parse(output)
            .map { display in
                let screenRow = screenRowsByID[display.id]
                return ConnectedDisplayRow(
                    id: display.id,
                    index: display.index,
                    name: screenRow?.name ?? Self.fallbackDisplayName(for: display),
                    resolution: display.resolution ?? screenRow?.resolution ?? "",
                    brightnessPercent: display.brightnessPercent,
                    isBuiltIn: display.isBuiltIn,
                    isExternal: display.isExternal,
                    canReadHardwareBrightness: display.brightnessPercent != nil
                )
            }
    }

    private static func displaysFromScreens() -> [ConnectedDisplayRow] {
        NSScreen.screens.enumerated().compactMap { index, screen in
            guard let screenNumber = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else {
                return nil
            }

            let displayID = CGDirectDisplayID(screenNumber.uint32Value)
            let width = Int(screen.frame.width.rounded())
            let height = Int(screen.frame.height.rounded())
            let isBuiltIn = CGDisplayIsBuiltin(displayID) != 0

            return ConnectedDisplayRow(
                id: "\(displayID)",
                index: index,
                name: screen.localizedName,
                resolution: "\(width)x\(height)",
                brightnessPercent: nil,
                isBuiltIn: isBuiltIn,
                isExternal: !isBuiltIn,
                canReadHardwareBrightness: false
            )
        }
    }

    private static func fallbackDisplayName(for display: BrightnessVerboseDisplayParser.Display) -> String {
        display.isBuiltIn ? "Built-in display" : "External display \(display.index)"
    }
}

struct BrightnessVerboseDisplayParser {
    private static let headerPattern =
        #"^display\s+([0-9]+):\s+(.+),\s+ID\s+(0x[0-9a-fA-F]+)\s*$"#
    private static let brightnessPattern =
        #"^display\s+([0-9]+):\s+brightness\s+([0-9]*\.?[0-9]+)\s*$"#
    private static let resolutionPattern =
        #"^resolution\s+[0-9]+\s+x\s+[0-9]+\s+pt\s+\(([0-9]+)\s+x\s+([0-9]+)\s+px\)"#

    struct Display: Equatable {
        var index: Int
        var id: String
        var isBuiltIn: Bool
        var isExternal: Bool
        var resolution: String?
        var brightnessPercent: Int?
    }

    func parse(_ output: String) -> [Display] {
        var displays: [Display] = []
        var currentDisplayIndex: Int?
        var displayIndexesByNumber: [Int: Int] = [:]

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)

            if let header = parseHeader(line) {
                displays.append(header)
                let displayIndex = displays.index(before: displays.endIndex)
                currentDisplayIndex = displayIndex
                displayIndexesByNumber[header.index] = displayIndex
                continue
            }

            if let brightness = parseBrightness(line) {
                if let displayIndex = displayIndexesByNumber[brightness.index] {
                    displays[displayIndex].brightnessPercent = brightness.percent
                }
                continue
            }

            if let currentDisplayIndex, let resolution = parseResolution(line) {
                displays[currentDisplayIndex].resolution = resolution
            }
        }

        return displays
    }

    private func parseHeader(_ line: String) -> Display? {
        guard let match = firstMatch(pattern: Self.headerPattern, in: line),
              let index = Int(match[1]) else {
            return nil
        }

        let flags = match[2].lowercased()
        let displayID = Self.decimalID(fromHexString: match[3]) ?? match[3]

        return Display(
            index: index,
            id: displayID,
            isBuiltIn: flags.contains("built-in"),
            isExternal: flags.contains("external"),
            resolution: nil,
            brightnessPercent: nil
        )
    }

    private func parseBrightness(_ line: String) -> (index: Int, percent: Int)? {
        guard let match = firstMatch(pattern: Self.brightnessPattern, in: line),
              let index = Int(match[1]),
              let value = Double(match[2]) else {
            return nil
        }

        return (index, DimmerSettings.clampedPercent(Int((value * 100).rounded())))
    }

    private func parseResolution(_ line: String) -> String? {
        guard let match = firstMatch(pattern: Self.resolutionPattern, in: line) else {
            return nil
        }

        return "\(match[1])x\(match[2])"
    }

    private func firstMatch(pattern: String, in line: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range) else {
            return nil
        }

        return (0..<match.numberOfRanges).compactMap { rangeIndex in
            guard let matchRange = Range(match.range(at: rangeIndex), in: line) else {
                return nil
            }
            return String(line[matchRange])
        }
    }

    private static func decimalID(fromHexString value: String) -> String? {
        let normalized = value.replacingOccurrences(of: "0x", with: "")
        guard let intValue = UInt32(normalized, radix: 16) else {
            return nil
        }

        return "\(intValue)"
    }
}
