import DimacCore
import Foundation

final class DisplayHardwareBrightnessController {
    private let brightnessPathProvider: () -> String
    private let commandRunner: CommandRunning

    init(
        brightnessPathProvider: @escaping () -> String = { CommandLocator.brightnessDefaultPath },
        commandRunner: CommandRunning = ProcessCommandRunner()
    ) {
        self.brightnessPathProvider = brightnessPathProvider
        self.commandRunner = commandRunner
    }

    func setBrightness(percent: Int, displayIndex: Int) throws {
        let path = brightnessPathProvider()
        let value = String(format: "%.4f", Float(DimmerSettings.clampedPercent(percent)) / 100.0)
        let result = try commandRunner.run(
            path,
            arguments: ["-d", "\(displayIndex)", value],
            timeout: 3
        )

        guard result.status == 0 else {
            throw BrightnessError.commandFailed(
                path: path,
                arguments: ["-d", "\(displayIndex)", value],
                status: result.status,
                stderr: result.stderr
            )
        }
    }
}
