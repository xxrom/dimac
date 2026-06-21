import Foundation

public struct BrightnessSnapshot: Codable, Equatable, Sendable {
    public var internalDisplays: [InternalDisplaySnapshot]
    public var externalDisplays: [ExternalDisplaySnapshot]
    public var createdAt: Date
    public var appVersion: String

    public init(
        internalDisplays: [InternalDisplaySnapshot],
        externalDisplays: [ExternalDisplaySnapshot],
        createdAt: Date = Date(),
        appVersion: String = "0.1.0"
    ) {
        self.internalDisplays = internalDisplays
        self.externalDisplays = externalDisplays
        self.createdAt = createdAt
        self.appVersion = appVersion
    }

    public var isEmpty: Bool {
        internalDisplays.isEmpty && externalDisplays.isEmpty
    }
}

public struct InternalDisplaySnapshot: Codable, Equatable, Sendable {
    public var displayID: UInt32
    public var brightness: Float

    public init(displayID: UInt32, brightness: Float) {
        self.displayID = displayID
        self.brightness = min(1.0, max(0.0, brightness))
    }
}

public struct ExternalDisplayReference: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var selector: String?
    public var name: String
    public var isDefaultFallback: Bool

    public init(selector: String?, name: String, isDefaultFallback: Bool = false) {
        self.selector = selector
        self.name = name
        self.isDefaultFallback = isDefaultFallback
    }

    public var id: String {
        selector ?? "default"
    }

    public var brightnessPreferenceKey: String {
        if isDefaultFallback {
            return "default"
        }

        let normalizedName = Self.normalizedDisplayName(name)
        if let selector, normalizedName == "display \(selector)" {
            return "selector:\(selector)"
        }

        if !normalizedName.isEmpty {
            return "name:\(normalizedName)"
        }

        if let selector {
            return "selector:\(selector)"
        }

        return "default"
    }

    private static func normalizedDisplayName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

public struct ExternalDisplaySnapshot: Codable, Equatable, Sendable {
    public var display: ExternalDisplayReference
    public var luminance: Int

    public init(display: ExternalDisplayReference, luminance: Int) {
        self.display = display
        self.luminance = min(100, max(0, luminance))
    }
}
