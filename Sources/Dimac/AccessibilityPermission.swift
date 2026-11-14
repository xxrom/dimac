import CoreGraphics

/// Input Monitoring permission (System Settings > Privacy & Security > Input Monitoring), which the
/// listen-only event tap in `InputWakeMonitor` needs. This is not the Accessibility permission,
/// despite the file name, which is kept so existing references and project layout stay unchanged.
enum EventListeningPermission {
    /// Whether listen-event (Input Monitoring) access is granted. Does not prompt the user.
    static var isTrusted: Bool {
        CGPreflightListenEventAccess()
    }
}
