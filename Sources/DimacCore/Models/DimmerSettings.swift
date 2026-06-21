import Foundation

public struct DimmerSettings: Equatable, Sendable {
    public var isEnabled: Bool
    public var idleTimeoutSeconds: Int
    public var dimPercent: Int
    public var m1ddcPath: String
    public var externalBrightnessByDisplay: [String: Int]

    public init(
        isEnabled: Bool = true,
        idleTimeoutSeconds: Int = 600,
        dimPercent: Int = 10,
        m1ddcPath: String = CommandLocator.m1ddcDefaultPath,
        externalBrightnessByDisplay: [String: Int] = [:]
    ) {
        self.isEnabled = isEnabled
        self.idleTimeoutSeconds = max(1, idleTimeoutSeconds)
        self.dimPercent = Self.clampedPercent(dimPercent)
        self.m1ddcPath = m1ddcPath
        self.externalBrightnessByDisplay = externalBrightnessByDisplay.mapValues(Self.clampedPercent)
    }

    public static func clampedPercent(_ value: Int) -> Int {
        min(100, max(1, value))
    }
}
