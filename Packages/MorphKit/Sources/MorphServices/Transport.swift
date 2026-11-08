import Foundation
import MorphCore
import OSLog

@MainActor
protocol LampTransport: AnyObject {
    var onStateChange: ((LampState) -> Void)? { get set }
    var onDisconnect: (() -> Void)? { get set }
    func connect(_ credentials: LampCredentials) async throws -> LampState
    func apply(_ action: LampAction) async throws
    func applyEffectFrame(_ frame: LightEffectFrame, ifAllowed: @escaping () -> Bool) async throws
    func refresh(requireModes: Bool) async throws -> LampState
    func disconnect() async
    /// Cancels this transport's local Bluetooth session without waiting for
    /// peripheral unsubscribe/disconnect acknowledgements.
    func abort() async
}

extension LampTransport {
    func refresh() async throws -> LampState { try await refresh(requireModes: false) }
}

@MainActor
final class BluetoothLampTransport: LampTransport {
    private static let diagnostics = Logger(subsystem: "at.einser.morphcontrol", category: "Bluetooth")
    // A successful session can be found again without waiting for advertising.
    // This is only a discovery hint, scoped to one lamp and this app process;
    // every connection still authenticates with the stored lamp credentials.
    private static var rememberedPeripheral: (serial: String, id: UUID)?
    var onStateChange: ((LampState) -> Void)?
    var onDisconnect: (() -> Void)?
    private let lamp = Lamp()
    private var lastState: LampState?
    private let frameWriter = EffectFrameWriter()

    init() {
        lamp.onStateChange = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.lastState = state
                self?.onStateChange?(state)
            }
        }
        lamp.onDisconnect = { [weak self] in
            Task { @MainActor [weak self] in self?.onDisconnect?() }
        }
    }

    func connect(_ credentials: LampCredentials) async throws -> LampState {
        let serial = credentials.serial.uppercased()
        let remembered = Self.rememberedPeripheral.flatMap { $0.serial == serial ? $0 : nil }
        do {
            guard credentials.isValid else { throw ServiceError.invalidCredentials }
            // Recover the complete initialization, including notifications and
            // initial reads. An ATT error there does not prove stuck firmware.
            let (identifier, state) = try await retryOnceWithFreshBluetoothSession(attempt: { [self] in
                var phase = "bluetooth"
                do {
                    try await lamp.powerOn()
                    phase = "connection-and-authentication"
                    let identifier = try await lamp.connect(serial: credentials.serial, accountId: credentials.accountID,
                                                            ltkHex: credentials.longTermKey, cachedId: remembered?.id)
                    phase = "live-state-initialization"
                    try await lamp.enableLiveState()
                    try Task.checkCancellation()
                    phase = "state-snapshot"
                    let state = try await lamp.state(attributes: true, fresh: false)
                    return (identifier, state)
                } catch {
                    // Fixed phase/category only: never account data, lamp IDs,
                    // credentials, protocol bytes or raw error descriptions.
                    let kind = Self.diagnosticKind(for: error)
                    Self.diagnostics.error("Connection failed: phase=\(phase, privacy: .public) kind=\(kind, privacy: .public)")
                    throw error
                }
            }, reset: { [lamp] in
                Self.diagnostics.notice("Recreating the Bluetooth session once after an ATT failure")
                await lamp.resetAfterATTFailure()
            })
            lastState = state
            Self.rememberedPeripheral = (serial, identifier)
            Self.diagnostics.notice("Authenticated Bluetooth connection and live state are ready")
            return state
        } catch {
            // A failed/cancelled attempt does not invalidate a previously
            // authenticated discovery hint. Every new link still authenticates.
            await lamp.abort()
            throw error
        }
    }

    private static func diagnosticKind(for error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let error = error as? MorphError {
            switch error {
            case .lampStuck: return "att"
            case .timeout: return "timeout"
            case .protocolError: return "protocol"
            case .bluetoothState: return "bluetooth-state"
            default: return "bluetooth"
            }
        }
        if let error = error as? ServiceError, case .deadline = error { return "deadline" }
        return "other"
    }

    func apply(_ action: LampAction) async throws {
        switch action {
        case .effectFrame(let frame):
            try await applyEffectFrame(frame, ifAllowed: { true })
            return
        case .power(let value): try await lamp.setPower(value)
        case .brightness(let value):
            if lastState?.power != true { try await lamp.setPower(true) }
            try await lamp.setLumens(percentToLumens(value))
        case .kelvin(let value):
            if lastState?.power != true { try await lamp.setPower(true) }
            try await lamp.setKelvin(value)
        case .daylight(let value): try await lamp.setDaylight(value)
        case .autoBrightness(let value): try await lamp.setAutoBrightness(value)
        case .movement(let value): try await lamp.setMovement(value)
        case .preset(let value): try await lamp.setPreset(value)
        case .refresh:
            _ = try await refresh()
            return
        }
        frameWriter.reset()
        try Task.checkCancellation()
        switch action {
        case .brightness, .kelvin, .preset, .daylight:
            try await Task.sleep(nanoseconds: 400_000_000)
        default: break
        }
        // Some firmware does not notify its own writes. Read the actual values
        // once after the ramp without treating automation-driven drift as failure.
        let includesMode: Bool
        switch action {
        case .daylight, .preset: includesMode = true
        default: includesMode = false
        }
        let actual = try await lamp.state(attributes: includesMode, fresh: true)
        lastState = actual
        onStateChange?(actual)
    }

    func refresh(requireModes: Bool) async throws -> LampState {
        let state = try await lamp.state(attributes: true, fresh: true, requireAttributes: requireModes)
        try Task.checkCancellation()
        lastState = state
        frameWriter.reset()
        onStateChange?(state)
        return state
    }

    func applyEffectFrame(_ frame: LightEffectFrame, ifAllowed: @escaping () -> Bool) async throws {
        let baseline = lastState.map { LightEffectFrame(brightness: $0.brightness, kelvin: $0.kelvin) }
        try await frameWriter.write(frame, baseline: baseline,
            ifAllowed: { [weak self] in ifAllowed() && self?.lastState?.power == true },
            setBrightness: { [lamp] value in try await lamp.setLumens(percentToLumens(value)) },
            setKelvin: { [lamp] value in try await lamp.setKelvin(value) })
    }

    func disconnect() async {
        onStateChange = nil
        onDisconnect = nil
        await lamp.disconnect()
        await lamp.abort()
    }

    func abort() async {
        onStateChange = nil
        onDisconnect = nil
        await lamp.abort()
    }
}

@MainActor
final class DemoLampTransport: LampTransport {
    var onStateChange: ((LampState) -> Void)?
    var onDisconnect: (() -> Void)?
    var state = LampState(power: true, lumens: percentToLumens(68), brightness: 68, kelvin: 3800,
                          autoBrightness: false, movement: true, daylight: false, preset: nil)

    func connect(_ credentials: LampCredentials) async throws -> LampState { state }
    func refresh(requireModes: Bool) async throws -> LampState { state }
    func disconnect() async { onStateChange = nil; onDisconnect = nil }
    func abort() async { onStateChange = nil; onDisconnect = nil }

    func apply(_ action: LampAction) async throws {
        try Task.checkCancellation()
        switch action {
        case .power(let value): state.power = value
        case .brightness(let value):
            state.power = true
            state.brightness = min(100, max(0, value))
            state.lumens = percentToLumens(state.brightness)
            state.daylight = false
            state.preset = nil
        case .kelvin(let value):
            state.power = true
            state.kelvin = min(6500, max(2700, value))
            state.daylight = false
            state.preset = nil
        case .daylight(let value): state.daylight = value
        case .autoBrightness(let value): state.autoBrightness = value
        case .movement(let value): state.movement = value
        case .preset(let value):
            state.preset = value
            if let value {
                state.power = true
                state.kelvin = value == .relax ? 2700 : (value == .study ? 4500 : 6500)
                state.brightness = value == .relax ? 30 : (value == .study ? 70 : 100)
                state.lumens = percentToLumens(state.brightness)
            }
        case .effectFrame(let frame):
            state.brightness = frame.brightness
            state.lumens = percentToLumens(frame.brightness)
            state.kelvin = frame.kelvin
        case .refresh: break
        }
        onStateChange?(state)
    }

    func applyEffectFrame(_ frame: LightEffectFrame, ifAllowed: @escaping () -> Bool) async throws {
        guard ifAllowed(), state.power else { return }
        try await apply(.effectFrame(frame))
    }
}

func withConnectionDeadline<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(0.001, seconds) * 1_000_000_000))
            throw ServiceError.deadline
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw CancellationError() }
        return result
    }
}
