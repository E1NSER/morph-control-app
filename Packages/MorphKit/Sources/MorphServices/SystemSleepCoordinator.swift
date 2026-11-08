import CoreFoundation
import Foundation
import IOKit
import IOKit.pwr_mgt
import OSLog

/// Uses Apple's public power-change acknowledgement API. The Mac may sleep
/// after at most six seconds of local cleanup; sleep is never vetoed.
/// NSWorkspace notifications remain the fallback when registration is denied.
@MainActor
public final class SystemSleepCoordinator {
    // Public IOMessage.h macros use a C function-like macro that Swift cannot
    // import. These are their values (sys_iokit | sub_iokit_common | message).
    private enum PowerMessage {
        static let canSleep: natural_t = 0xe0000270
        static let willSleep: natural_t = 0xe0000280
        static let willPowerOn: natural_t = 0xe0000320
        static let hasPoweredOn: natural_t = 0xe0000300
    }
    private static let diagnostics = Logger(subsystem: "at.einser.morphcontrol", category: "Bluetooth")
    private final class CallbackContext: @unchecked Sendable {
        weak var owner: SystemSleepCoordinator?
        init(owner: SystemSleepCoordinator) { self.owner = owner }
    }

    /// C owns no Swift references. Keep an independent callback context alive
    /// until deregistration, even if the public coordinator is released early.
    private final class Registration: @unchecked Sendable {
        /// These raw handles are transferred once to the main queue solely for
        /// destruction; no mutable registration remains accessible afterwards.
        private struct Cleanup: @unchecked Sendable {
            let port: io_connect_t
            let notifications: IONotificationPortRef?
            let object: io_object_t
            let source: CFRunLoopSource?
            let context: UnsafeMutableRawPointer?
            func perform() { Registration.destroy(port, notifications, object, source, context) }
        }
        var rootPort: io_connect_t = 0
        var notificationPort: IONotificationPortRef?
        var notifier: io_object_t = 0
        var source: CFRunLoopSource?
        var context: UnsafeMutableRawPointer?

        func close() {
            Self.destroy(rootPort, notificationPort, notifier, source, context)
            rootPort = 0; notificationPort = nil; notifier = 0; source = nil; context = nil
        }

        deinit {
            let cleanup = Cleanup(port: rootPort, notifications: notificationPort,
                                  object: notifier, source: source, context: context)
            // Teardown on the callback's main run loop prevents racing a C
            // callback with release of its retained weak-owner context.
            DispatchQueue.main.async {
                cleanup.perform()
            }
        }

        private static func destroy(_ port: io_connect_t, _ notifications: IONotificationPortRef?,
                                    _ object: io_object_t, _ source: CFRunLoopSource?,
                                    _ context: UnsafeMutableRawPointer?) {
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            var object = object
            if object != 0 { IODeregisterForSystemPower(&object) }
            if port != 0 { IOServiceClose(port) }
            if let notifications { IONotificationPortDestroy(notifications) }
            if let context { Unmanaged<CallbackContext>.fromOpaque(context).release() }
        }
    }

    private var registration: Registration?
    private let preparation: SleepPreparation
    public private(set) var isRegistered = false

    public init(prepare: @escaping () async -> Void, force: @escaping () async -> Void) {
        preparation = SleepPreparation(prepare: prepare, force: force)
    }

    public func start() -> Bool {
        guard !isRegistered else { return true }
        let registration = Registration()
        self.registration = registration
        let context = Unmanaged.passRetained(CallbackContext(owner: self)).toOpaque()
        registration.context = context
        registration.rootPort = IORegisterForSystemPower(context, &registration.notificationPort, { context, _, message, argument in
            guard let context else { return }
            // The notification source is attached only to the main run loop.
            // Forwarding to the main actor also serializes lifecycle intents.
            let token = Int(bitPattern: argument)
            let callback = Unmanaged<CallbackContext>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor [callback] in
                callback.owner?.receive(message: message, token: token)
            }
        }, &registration.notifier)
        guard registration.rootPort != 0, let notificationPort = registration.notificationPort,
              let source = IONotificationPortGetRunLoopSource(notificationPort)?.takeUnretainedValue() else {
            stop()
            Self.diagnostics.notice("Power-change acknowledgement unavailable; using workspace sleep notifications")
            return false
        }
        registration.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        isRegistered = true
        Self.diagnostics.notice("Bounded pre-sleep Bluetooth cleanup registered")
        return true
    }

    public func cancelPendingForWake() { preparation.cancelPendingForWake() }

    public func stop() {
        preparation.cancelPendingForWake()
        registration?.close()
        registration = nil
        isRegistered = false
    }

    private func receive(message: natural_t, token: Int) {
        guard isRegistered, let registration, registration.rootPort != 0 else { return }
        switch message {
        case PowerMessage.canSleep:
            // Idle sleep is always permitted immediately. Cleanup happens at
            // SystemWillSleep for both idle and user-requested sleep.
            IOAllowPowerChange(registration.rootPort, token)
        case PowerMessage.willSleep:
            preparation.begin { [weak registration] in
                Self.diagnostics.notice("Pre-sleep Bluetooth cleanup window ended; allowing sleep")
                if let port = registration?.rootPort, port != 0 { IOAllowPowerChange(port, token) }
            }
        case PowerMessage.willPowerOn, PowerMessage.hasPoweredOn:
            cancelPendingForWake()
        default: break
        }
    }
}
