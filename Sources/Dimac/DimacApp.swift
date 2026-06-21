import AppKit
import SwiftUI

@main
struct DimacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Settings {
            EmptyView()
                .environmentObject(model)
                .environmentObject(model.dimmer)
                .environmentObject(model.settings)
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppRuntime.model?.handleReopen()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppRuntime.model?.restoreNow()
        return .terminateNow
    }
}
