import Darwin
import Foundation
import IOKit

public protocol IdleTimeReading {
    func idleTime() -> TimeInterval
}

public final class IOKitIdleTimeReader: IdleTimeReading {
    private let diagnostics: DiagnosticLogger
    private let clock: () -> TimeInterval
    private let rawReader: () -> Result<TimeInterval, IdleTimeReadFailure>
    private let lock = NSLock()
    private var lastGood: (idle: TimeInterval, readAt: TimeInterval)?
    private var consecutiveFailures = 0

    public enum IdleTimeReadFailure: String, Error {
        case serviceUnavailable
        case propertyMissing
        case unexpectedPropertyType
    }

    public convenience init(diagnostics: DiagnosticLogger = .shared) {
        self.init(diagnostics: diagnostics, clock: IOKitIdleTimeReader.monotonicSeconds, rawReader: IOKitIdleTimeReader.readHIDIdleTime)
    }

    /// Test seam: `rawReader` stands in for the IOKit query and `clock` for monotonic elapsed time.
    public init(
        diagnostics: DiagnosticLogger,
        clock: @escaping () -> TimeInterval,
        rawReader: @escaping () -> Result<TimeInterval, IdleTimeReadFailure>
    ) {
        self.diagnostics = diagnostics
        self.clock = clock
        self.rawReader = rawReader
    }

    /// Seconds since the last user input, never negative.
    ///
    /// A failed read must not look like activity (0 would block dimming forever and wake a dimmed screen
    /// on one missed read), so it returns the last good value advanced by the time since it was taken:
    /// exactly what the idle time would be if the user is still away. Until a first read succeeds it
    /// returns 0, because without any evidence of idleness dimming would be a guess.
    public func idleTime() -> TimeInterval {
        let result = rawReader()
        let now = clock()
        lock.lock()
        defer { lock.unlock() }

        switch result {
        case .success(let value):
            let idle = value.isFinite ? max(0, value) : 0
            if consecutiveFailures > 0 {
                diagnostics.record("idle.readRecovered", ["consecutiveFailures": consecutiveFailures, "idleSeconds": idle])
            }
            consecutiveFailures = 0
            lastGood = (idle, now)
            return idle
        case .failure(let failure):
            consecutiveFailures += 1
            let estimate = lastGood.map { $0.idle + max(0, now - $0.readAt) } ?? 0
            // Log the first failure and then at exponentially spaced counts so a persistent fault stays visible
            // without writing one record per poll.
            if consecutiveFailures & (consecutiveFailures - 1) == 0 {
                diagnostics.record("idle.readFailed", [
                    "reason": failure.rawValue,
                    "consecutiveFailures": consecutiveFailures,
                    "estimatedIdleSeconds": estimate,
                    "hasPreviousReading": lastGood != nil
                ])
            }
            return estimate
        }
    }

    /// Monotonic clock that keeps counting during sleep, like HIDIdleTime.
    private static func monotonicSeconds() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }

    private static func readHIDIdleTime() -> Result<TimeInterval, IdleTimeReadFailure> {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOHIDSystem")
        )

        guard service != 0 else {
            return .failure(.serviceUnavailable)
        }

        defer {
            IOObjectRelease(service)
        }

        guard let property = IORegistryEntryCreateCFProperty(
            service,
            "HIDIdleTime" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else {
            return .failure(.propertyMissing)
        }

        // Read as signed and clamp: a negative value must not wrap to a huge idle time and dim at once.
        if let number = property as? NSNumber {
            return .success(TimeInterval(max(0, number.int64Value)) / 1_000_000_000)
        }

        if let data = property as? Data, data.count >= MemoryLayout<Int64>.size {
            var nanos: Int64 = 0
            _ = withUnsafeMutableBytes(of: &nanos) { destination in
                data.copyBytes(to: destination)
            }
            return .success(TimeInterval(max(0, nanos)) / 1_000_000_000)
        }

        return .failure(.unexpectedPropertyType)
    }
}
