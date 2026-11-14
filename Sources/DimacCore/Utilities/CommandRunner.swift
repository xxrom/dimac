import Foundation
import Darwin

/// Drains one pipe on a dispatch source so the caller can stop waiting for EOF at any time.
/// The source owns a duplicate of the read descriptor and closes it in its cancel handler, which
/// dispatch serialises after any in-flight read, so cancelling never races a read on a closed descriptor.
private final class CommandOutputReader {
    private let lock = NSLock()
    private var storage = Data()
    private let source: DispatchSourceRead

    init?(handle: FileHandle, group: DispatchGroup) {
        let descriptor = dup(handle.fileDescriptor)
        guard descriptor >= 0 else { return nil }
        try? handle.close()
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)

        let queue = DispatchQueue(label: "dimac.command-output", qos: .utility)
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        group.enter()
        // Strong capture is released by dispatch once the source is cancelled.
        source.setEventHandler { [self] in
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
                if count > 0 {
                    lock.lock()
                    storage.append(contentsOf: buffer[0..<count])
                    lock.unlock()
                    continue
                }
                if count < 0, errno == EINTR { continue }
                if count < 0, errno == EAGAIN { return }
                source.cancel()
                return
            }
        }
        source.setCancelHandler {
            _ = Darwin.close(descriptor)
            group.leave()
        }
        source.resume()
    }

    func cancel() {
        source.cancel()
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
    /// How long to wait for EOF once the command has exited before abandoning its pipes.
    private static let outputGracePeriod: TimeInterval = 0.25
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
        let pid = process.processIdentifier
        // Foundation.Process starts the child as the leader of its own process group; only signal the
        // group when that holds, so a helper that shares our group can never take Dimac down with it.
        let childGroup = getpgid(pid)
        let canSignalGroup = childGroup == pid && childGroup != getpgrp()

        let outputGroup = DispatchGroup()
        let readers = [stdout, stderr].map { CommandOutputReader(handle: $0.fileHandleForReading, group: outputGroup) }

        func signal(_ signal: Int32) {
            if canSignalGroup {
                _ = killpg(childGroup, signal)
            } else {
                _ = kill(pid, signal)
            }
        }

        /// Waits briefly for EOF, then stops reading: a descendant that inherited the pipes must not
        /// keep the caller (usually the main thread) waiting after the command itself has exited.
        func finishReading() -> (stdout: String, stderr: String) {
            if outputGroup.wait(timeout: .now() + Self.outputGracePeriod) == .timedOut {
                readers.forEach { $0?.cancel() }
                _ = outputGroup.wait(timeout: .now() + Self.outputGracePeriod)
            }
            return (
                readers[0].flatMap { String(data: $0.data(), encoding: .utf8) } ?? "",
                readers[1].flatMap { String(data: $0.data(), encoding: .utf8) } ?? ""
            )
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            signal(SIGTERM)
            if semaphore.wait(timeout: .now() + Self.terminationGracePeriod) == .timedOut {
                signal(SIGKILL)
                _ = semaphore.wait(timeout: .now() + Self.terminationGracePeriod)
            }
            _ = finishReading()
            throw BrightnessError.commandTimedOut(path: path, arguments: arguments)
        }

        let output = finishReading()
        return CommandResult(status: process.terminationStatus, stdout: output.stdout, stderr: output.stderr)
    }
}
