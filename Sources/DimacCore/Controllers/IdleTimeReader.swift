import Foundation
import IOKit

public protocol IdleTimeReading {
    func idleTime() -> TimeInterval
}

public final class IOKitIdleTimeReader: IdleTimeReading {
    public init() {}

    public func idleTime() -> TimeInterval {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOHIDSystem")
        )

        guard service != 0 else {
            return 0
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
            return 0
        }

        if let number = property as? NSNumber {
            return TimeInterval(number.uint64Value) / 1_000_000_000
        }

        if let data = property as? Data, data.count >= MemoryLayout<UInt64>.size {
            var nanos: UInt64 = 0
            _ = withUnsafeMutableBytes(of: &nanos) { destination in
                data.copyBytes(to: destination)
            }
            return TimeInterval(nanos) / 1_000_000_000
        }

        return 0
    }
}
