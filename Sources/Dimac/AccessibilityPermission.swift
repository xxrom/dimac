import CoreGraphics

enum EventListeningPermission {
    static var isTrusted: Bool {
        CGPreflightListenEventAccess()
    }
}
