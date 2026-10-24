import Foundation

public struct DimmerSettings: Encodable, Equatable, Sendable {
    public var isEnabled: Bool
    public var idleTimeoutSeconds: Int
    public var dimPercent: Int
    public var m1ddcPath: String
    public var externalBrightnessByDisplay: [String: Int]
    public var internalDimPercentByDisplay: [UInt32: Int]
    public var externalDimPercentByDisplay: [String: Int]
    public var excludedInternalDisplayIDs: Set<UInt32>

    public init(
        isEnabled: Bool = true,
        idleTimeoutSeconds: Int = 600,
        dimPercent: Int = 10,
        m1ddcPath: String = CommandLocator.m1ddcDefaultPath,
        externalBrightnessByDisplay: [String: Int] = [:],
        internalDimPercentByDisplay: [UInt32: Int] = [:],
        externalDimPercentByDisplay: [String: Int] = [:],
        excludedInternalDisplayIDs: Set<UInt32> = []
    ) {
        self.isEnabled = isEnabled
        self.idleTimeoutSeconds = max(1, idleTimeoutSeconds)
        self.dimPercent = Self.clampedPercent(dimPercent)
        self.m1ddcPath = m1ddcPath
        self.externalBrightnessByDisplay = externalBrightnessByDisplay.mapValues(Self.clampedPercent)
        self.internalDimPercentByDisplay = internalDimPercentByDisplay.mapValues(Self.clampedPercent)
        self.externalDimPercentByDisplay = externalDimPercentByDisplay.mapValues(Self.clampedPercent)
        self.excludedInternalDisplayIDs = excludedInternalDisplayIDs
    }

    public static func clampedPercent(_ value: Int) -> Int {
        min(100, max(1, value))
    }
}
