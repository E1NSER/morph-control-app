import Foundation
import MorphCore
@testable import MorphServices

@MainActor
func sampleCredentials() -> LampCredentials {
    LampCredentials(serial: "TEST-EU-12345678", accountID: "12345678-90ab-cdef-1234-567890abcdef",
                    longTermKey: String(repeating: "ab", count: 32), name: "Schreibtisch")
}

@MainActor
final class FakeTransport: LampTransport {
    enum Event: Equatable {
        case connect, apply(LampAction), completed(LampAction), refresh(Bool), disconnect, abort
    }
    var onStateChange: ((LampState) -> Void)?
    var onDisconnect: (() -> Void)?
    var connectCalls = 0
    var disconnectCalls = 0
    var abortCalls = 0
    var actions: [LampAction] = []
    var events: [Event] = []
    var applyStarts: [ContinuousClock.Instant] = []
    var applyCompletions: [ContinuousClock.Instant] = []
    var activeApplies = 0
    var maximumActiveApplies = 0
    var applyDelay: UInt64 = 0
    var connectDelay: UInt64 = 0
    var connectError: Error?
    var applyError: Error?
    var applyHandler: ((LampAction) throws -> Void)?
    var refreshCalls: [Bool] = []
    var refreshStarts: [ContinuousClock.Instant] = []
    var refreshDelay: UInt64 = 0
    var refreshError: Error?
    var refreshedState: LampState?
    var blockDisconnect = false
    private var disconnectContinuation: CheckedContinuation<Void, Never>?
    var blockConnect = false
    private var connectContinuation: CheckedContinuation<Void, Never>?
    var state = LampState(power: false, lumens: 200, brightness: 11, kelvin: 3000,
                          autoBrightness: false, movement: true, daylight: false, preset: nil)

    func connect(_ credentials: LampCredentials) async throws -> LampState {
        connectCalls += 1
        events.append(.connect)
        if blockConnect { await withCheckedContinuation { connectContinuation = $0 } }
        if connectDelay > 0 { try await Task.sleep(nanoseconds: connectDelay) }
        if let connectError { throw connectError }
        return state
    }
    func apply(_ action: LampAction) async throws {
        actions.append(action)
        events.append(.apply(action))
        applyStarts.append(.now)
        activeApplies += 1
        maximumActiveApplies = max(maximumActiveApplies, activeApplies)
        defer { activeApplies -= 1 }
        if applyDelay > 0 { try await Task.sleep(nanoseconds: applyDelay) }
        if let applyError { throw applyError }
        try applyHandler?(action)
        events.append(.completed(action))
        applyCompletions.append(.now)
        onStateChange?(state)
    }
    func applyEffectFrame(_ frame: LightEffectFrame, ifAllowed: @escaping () -> Bool) async throws {
        guard ifAllowed() else { return }
        try await apply(.effectFrame(frame))
    }
    func refresh(requireModes: Bool) async throws -> LampState {
        refreshCalls.append(requireModes)
        refreshStarts.append(.now)
        events.append(.refresh(requireModes))
        if refreshDelay > 0 { try await Task.sleep(nanoseconds: refreshDelay) }
        if let refreshError { throw refreshError }
        return refreshedState ?? state
    }
    func disconnect() async {
        disconnectCalls += 1
        events.append(.disconnect)
        onStateChange = nil
        onDisconnect = nil
        if blockDisconnect {
            await withCheckedContinuation { disconnectContinuation = $0 }
        }
    }
    func unblockDisconnect() {
        blockDisconnect = false
        let continuation = disconnectContinuation
        disconnectContinuation = nil
        continuation?.resume()
    }
    func abort() async {
        abortCalls += 1
        events.append(.abort)
        onStateChange = nil
        onDisconnect = nil
        blockConnect = false
        let connecting = connectContinuation
        connectContinuation = nil
        connecting?.resume()
        unblockDisconnect()
    }
}

@MainActor
final class FakeCloud: PairingCloudClient {
    var beginError: Error?
    var verifyError: Error?
    var manifestError: Error?
    var keyError: Error?
    var returnedKey = String(repeating: "ab", count: 32)
    var keyErrorsBySerial: [String: Error] = [:]
    var delay: UInt64 = 0
    var beginCalls = 0
    var verifyCalls = 0
    var fetchedSerials: [String] = []
    var receivedEmail = ""
    var lights: [DysonCloud.Device] = [
        .init(serial: "TEST-EU-12345678", name: "Schreibtisch", category: "light", connectionCategory: "bluetoothOnly")
    ]
    func beginLogin(email: String) async throws -> String {
        beginCalls += 1
        receivedEmail = email
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if let beginError { throw beginError }
        return "temporary-challenge"
    }
    func completeLogin(email: String, password: String, challengeId: String, otpCode: String) async throws -> (token: String, accountId: String) {
        verifyCalls += 1
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if let verifyError { throw verifyError }
        return ("temporary-bearer-secret", sampleCredentials().accountID)
    }
    func devices(token: String) async throws -> [DysonCloud.Device] {
        if let manifestError { throw manifestError }
        return lights
    }
    func fetchLtk(serial: String, token: String) async throws -> String {
        fetchedSerials.append(serial)
        if let error = keyErrorsBySerial[serial] { throw error }
        if let keyError { throw keyError }
        return returnedKey
    }
}
