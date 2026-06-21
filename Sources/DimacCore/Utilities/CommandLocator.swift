import Foundation

public enum CommandLocator {
    public static let brightnessCandidates = [
        "/opt/homebrew/bin/brightness",
        "/usr/local/bin/brightness"
    ]

    public static let m1ddcCandidates = [
        "/opt/homebrew/bin/m1ddc",
        "/usr/local/bin/m1ddc"
    ]

    public static var brightnessDefaultPath: String {
        resolve(candidates: brightnessCandidates)
    }

    public static var m1ddcDefaultPath: String {
        resolve(candidates: m1ddcCandidates)
    }

    public static func resolve(
        candidates: [String],
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String {
        candidates.first(where: isExecutable) ?? candidates.first ?? ""
    }
}
