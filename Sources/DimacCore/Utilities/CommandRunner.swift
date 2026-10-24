import Foundation
import Darwin

private final class CommandOutputBuffer {
    private let lock = NSLock()
    private var storage = Data()

    func store(_ data: Data) {
        lock.lock()
        storage = data
        lock.unlock()
    }

    func data() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

public struct CommandResult: Equatable, Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol CommandRunning {
    func run(_ path: String, arguments: [String], timeout: TimeInterval) throws -> CommandResult
}

public final class ProcessCommandRunner: CommandRunning {
    private static let terminationGracePeriod: TimeInterval = 0.25
    private let diagnostics: DiagnosticLogger

    public init(diagnostics: DiagnosticLogger = .shared) {
        self.diagnostics = diagnostics
    }

    public func run(_ path: String, arguments: [String], timeout: TimeInterval = 3) throws -> CommandResult {
        let started = ProcessInfo.processInfo.systemUptime
        let id = UUID().uuidString
        let fields: [String: Any] = ["commandID": id, "path": path, "arguments": arguments, "timeoutSeconds": timeout]
        diagnostics.record("command.started", fields)
        do {
            let result = try runProcess(path, arguments: arguments, timeout: timeout)
            diagnostics.record("command.finished", fields.merging([
                "durationMs": (ProcessInfo.processInfo.systemUptime - started) * 1_000,
                "status": result.status, "stdout": String(result.stdout.prefix(8192)),
                "stderr": String(result.stderr.prefix(8192))
            ]) { _, new in new })
            return result
        } catch {
            diagnostics.record("command.failed", fields.merging([
                "durationMs": (ProcessInfo.processInfo.systemUptime - started) * 1_000,
                "error": error.localizedDescription
            ]) { _, new in new })
            throw error
        }
    }

    private func runProcess(_ path: String, arguments: [String], timeout: TimeInterval) throws -> CommandResult {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw BrightnessError.commandNotFound(path)
        }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()

        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            semaphore.signal()
        }

        try process.run()

        let outputGroup = DispatchGroup()
        let stdoutBuffer = CommandOutputBuffer()
        let stderrBuffer = CommandOutputBuffer()
        outputGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutBuffer.store(stdout.fileHandleForReading.readDataToEndOfFile())
            outputGroup.leave()
        }
        outputGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrBuffer.store(stderr.fileHandleForReading.readDataToEndOfFile())
            outputGroup.leave()
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if semaphore.wait(timeout: .now() + Self.terminationGracePeriod) == .timedOut {
                _ = kill(process.processIdentifier, SIGKILL)
                semaphore.wait()
            }
            outputGroup.wait()
            throw BrightnessError.commandTimedOut(path: path, arguments: arguments)
        }

        outputGroup.wait()

        return CommandResult(
            status: process.terminationStatus,
            stdout: String(data: stdoutBuffer.data(), encoding: .utf8) ?? "",
            stderr: String(data: stderrBuffer.data(), encoding: .utf8) ?? ""
        )
    }
}
