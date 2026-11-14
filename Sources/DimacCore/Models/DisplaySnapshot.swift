import Foundation

public struct BrightnessSnapshot: Codable, Equatable, Sendable {
    public var internalDisplays: [InternalDisplaySnapshot]
    public var externalDisplays: [ExternalDisplaySnapshot]
    public var appliedInternalDisplays: [InternalDisplaySnapshot]?
    public var appliedExternalDisplays: [ExternalDisplaySnapshot]?
    public var createdAt: Date
    public var appVersion: String

    /// The running app's marketing version, or "unknown" outside an app bundle (tests, `swift run`).
    public static var currentAppVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let trimmed = version?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "unknown" : trimmed
    }

    public init(
        internalDisplays: [InternalDisplaySnapshot],
        externalDisplays: [ExternalDisplaySnapshot],
        appliedInternalDisplays: [InternalDisplaySnapshot]? = nil,
        appliedExternalDisplays: [ExternalDisplaySnapshot]? = nil,
        createdAt: Date = Date(),
        appVersion: String = BrightnessSnapshot.currentAppVersion
    ) {
        self.internalDisplays = internalDisplays
        self.externalDisplays = externalDisplays
        self.appliedInternalDisplays = appliedInternalDisplays
        self.appliedExternalDisplays = appliedExternalDisplays
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

    private enum CodingKeys: String, CodingKey {
        case displayID, brightness
    }

    public init(displayID: UInt32, brightness: Float) {
        self.displayID = displayID
        self.brightness = min(1.0, max(0.0, brightness))
    }

    /// Decodes through the clamping initializer so an edited or corrupted snapshot cannot carry
    /// out-of-range values.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            displayID: try container.decode(UInt32.self, forKey: .displayID),
            brightness: try container.decode(Float.self, forKey: .brightness)
        )
    }
}

public struct ExternalDisplayReference: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var selector: String?
    public var name: String
    public var isDefaultFallback: Bool
    public var uuid: String?

    private enum CodingKeys: String, CodingKey {
        case selector, name, isDefaultFallback, uuid
    }

    public init(selector: String?, name: String, isDefaultFallback: Bool = false, uuid: String? = nil) {
        self.selector = selector
        self.name = name
        self.isDefaultFallback = isDefaultFallback
        self.uuid = uuid.flatMap { UUID(uuidString: $0)?.uuidString }
    }

    /// Decodes through the normalising initializer so a stored UUID is canonical (or dropped when invalid).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            selector: try container.decodeIfPresent(String.self, forKey: .selector),
            name: try container.decode(String.self, forKey: .name),
            isDefaultFallback: try container.decodeIfPresent(Bool.self, forKey: .isDefaultFallback) ?? false,
            uuid: try container.decodeIfPresent(String.self, forKey: .uuid)
        )
    }

    public var id: String {
        selector ?? "default"
    }

    /// Name/selector based key; identical monitors share it. Kept unchanged because it also backs the
    /// legacy (pre-UUID) recovery identity. Per-display settings should prefer `dimPreferenceKey`.
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

    /// Per-display settings key that tells identical monitors apart by UUID when one is known. Lookups
    /// fall back to `brightnessPreferenceKey`, so entries stored under the old key keep working.
    public var dimPreferenceKey: String {
        guard !isDefaultFallback, let uuid else {
            return brightnessPreferenceKey
        }
        return "\(brightnessPreferenceKey)|uuid:\(uuid.lowercased())"
    }

    public var recoveryKey: String {
        uuid.map { "uuid:\($0.lowercased())" } ?? brightnessPreferenceKey
    }

    public var hasReliableIdentity: Bool {
        uuid != nil || brightnessPreferenceKey.hasPrefix("name:")
    }

    public func matchesRecoveryIdentity(of saved: ExternalDisplayReference) -> Bool {
        if saved.uuid != nil {
            return uuid != nil && recoveryKey == saved.recoveryKey
        }
        return saved.hasReliableIdentity && brightnessPreferenceKey == saved.brightnessPreferenceKey
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

    private enum CodingKeys: String, CodingKey {
        case display, luminance
    }

    public init(display: ExternalDisplayReference, luminance: Int) {
        self.display = display
        self.luminance = min(100, max(0, luminance))
    }

    /// Decodes through the clamping initializer.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            display: try container.decode(ExternalDisplayReference.self, forKey: .display),
            luminance: try container.decode(Int.self, forKey: .luminance)
        )
    }
}
