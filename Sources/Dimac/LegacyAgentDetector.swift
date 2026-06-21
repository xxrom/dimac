import Foundation

enum LegacyAgentDetector {
    static var isDetected: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let launchAgent = home
            .appendingPathComponent("Library/LaunchAgents/com.user.idledim.plist")
        let script = home
            .appendingPathComponent(".local/bin/idle-dim.sh")

        return FileManager.default.fileExists(atPath: launchAgent.path)
            || FileManager.default.fileExists(atPath: script.path)
    }
}
