import CoreGraphics
import Foundation

final class InputWakeMonitor {
    private final class Context {
        let onActivity: () -> Void

        init(onActivity: @escaping () -> Void) {
            self.onActivity = onActivity
        }
    }

    private let onActivity: () -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var context: Unmanaged<Context>?

    init(onActivity: @escaping () -> Void) {
        self.onActivity = onActivity
    }

    var isRunning: Bool {
        eventTap != nil
    }

    @discardableResult
    func start() -> Bool {
        stop()

        guard EventListeningPermission.isTrusted else {
            return false
        }

        let mask = eventMask([
            .mouseMoved,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .keyDown,
            .flagsChanged,
            .scrollWheel
        ])

        let retainedContext = Unmanaged.passRetained(Context(onActivity: onActivity))
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    return Unmanaged.passUnretained(event)
                }

                if let userInfo {
                    let context = Unmanaged<Context>.fromOpaque(userInfo).takeUnretainedValue()
                    context.onActivity()
                }

                return Unmanaged.passUnretained(event)
            },
            userInfo: retainedContext.toOpaque()
        ) else {
            retainedContext.release()
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.context = retainedContext
        self.eventTap = tap
        self.runLoopSource = source
        return true
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }

        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }

        context?.release()
        context = nil
        runLoopSource = nil
        eventTap = nil
    }

    deinit {
        stop()
    }

    private func eventMask(_ types: [CGEventType]) -> CGEventMask {
        types.reduce(CGEventMask(0)) { partial, type in
            partial | (CGEventMask(1) << CGEventMask(type.rawValue))
        }
    }
}
