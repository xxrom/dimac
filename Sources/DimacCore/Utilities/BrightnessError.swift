import Foundation

public enum BrightnessError: LocalizedError, Equatable {
    case displayServicesUnavailable
    case displayServicesSymbolMissing(String)
    case noBuiltinDisplayFound
    case readFailed(String)
    case writeFailed(String)
    case commandNotFound(String)
    case commandFailed(path: String, arguments: [String], status: Int32, stderr: String)
    case commandTimedOut(path: String, arguments: [String])
    case invalidOutput(command: String, output: String)

    public var errorDescription: String? {
        switch self {
        case .displayServicesUnavailable:
            return "DisplayServices.framework could not be loaded."
        case .displayServicesSymbolMissing(let symbol):
            return "DisplayServices symbol is missing: \(symbol)."
        case .noBuiltinDisplayFound:
            return "No built-in display was found."
        case .readFailed(let target):
            return "Could not read brightness for \(target)."
        case .writeFailed(let target):
            return "Could not write brightness for \(target)."
        case .commandNotFound(let path):
            return "Command not found: \(path)."
        case .commandFailed(let path, let arguments, let status, let stderr):
            let command = ([path] + arguments).joined(separator: " ")
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "\(command) exited with status \(status)." : "\(command) failed: \(detail)"
        case .commandTimedOut(let path, let arguments):
            return "Command timed out: \(([path] + arguments).joined(separator: " "))"
        case .invalidOutput(let command, let output):
            return "Invalid output from \(command): \(output)"
        }
    }
}
