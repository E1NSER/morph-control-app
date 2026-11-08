import Combine
import Foundation
import MorphCore

public enum ConnectionState: Equatable {
    case unpaired, disconnected, connecting, connected, failed
}

@MainActor
public final class LampController: ObservableObject {
    /// A demo owns only an in-memory credential store and simulated transport.
    public let isDemo: Bool
    @Published public private(set) var connection: ConnectionState = .unpaired
    @Published public private(set) var state: LampState?
    @Published public private(set) var lampName = ServiceLocalization.text("Meine Lampe")
    @Published public private(set) var serial = ""
    @Published public private(set) var hasCredentials = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var isBusy = false
    @Published public private(set) var keepConnectionAlive: Bool
    @Published public private(set) var syncPowerWithMac: Bool
    @Published public private(set) var isConnectionPaused = false
    @Published public private(set) var isRestoringAutomaticLighting = false
    @Published public private(set) var activeLightEffect: LightEffect?
    @Published public private(set) var isStartingLightEffect = false
    private var localizedErrorKey: String?

    private let credentialStore: CredentialStore
    private let transportFactory: () -> LampTransport
    private let connectionTimeout: TimeInterval
    private let idleSeconds: TimeInterval
    private let powerTransitionTimeout: TimeInterval
    private let commandMinimumGap: Duration
    private let effectTickSeconds: TimeInterval
    private let recoveryRetrySeconds: TimeInterval
    private let recoveryDropDelay: TimeInterval
    private let recoveryStableSeconds: TimeInterval
    private let inactivityProbeSeconds: TimeInterval
    private let inactivityProbeTimeout: TimeInterval
    private var credentials: LampCredentials?
    private var transport: LampTransport?
    private var connectionTask: Task<Void, Never>?
    private var teardownTask: Task<Void, Never>?
    private var teardownID: UUID?
    // A teardown moves the active transport into its task. Retain a separate
    // handle so a lifecycle deadline can still abort that exact old session.
    private var teardownTransports: [ObjectIdentifier: LampTransport] = [:]
    private var forceAbortTask: Task<Void, Never>?
    private var forceAbortID: UUID?
    private var terminationTask: Task<Void, Never>?
    private var isTerminating = false
    private var credentialMutationID: UUID?
    private var idleTask: Task<Void, Never>?
    private var generation = UUID()
    private var panelIsOpen = false
    private var commandBusy = false
    private var isSleeping = false
    private var automaticRequest = UUID()
    private var automaticConnectionTask: Task<Void, Never>?
    private var recoveryPhaseStarted = false
    private var recoveryAttemptsRemaining = 0
    private var connectionEstablishedAt: ContinuousClock.Instant?
    private var stableConnectionMayResetRecovery = false
    private var lastContactAt: ContinuousClock.Instant?
    private var inactivityProbeID: UUID?
    private var failedInactivityProbeSession: UUID?
    private var lastConnectionFailureIsRetryable = false
    private var lastFailureWasPowerOff = false
    private var pendingPowerOn = false
    private var powerPolicy = UUID()
    private var wakeRequested = false
    private var powerOffTask: Task<Void, Never>?
    private var powerOffID: UUID?
    private var automaticLightingRestoreID: UUID?
    private var lightEffectID: UUID?
    private var requestedLightEffect: LightEffect?
    private var lightEffectTask: Task<Void, Never>?
    private var effectPowerWasOn = false
    private var lastQueuedEffectFrame: LightEffectFrame?
    private var sessionIsActive = true

    private lazy var commands = CommandQueue(minimumGap: commandMinimumGap, execute: { [weak self] action in
        guard let self, self.connection == .connected, let transport = self.transport else {
            throw ServiceError.notPaired
        }
        if case .effectFrame(let frame) = action {
            let effectID = self.lightEffectID
            let session = self.generation
            try await transport.applyEffectFrame(frame, ifAllowed: { [weak self] in
                guard let self else { return false }
                return self.lightEffectID == effectID && effectID != nil && self.generation == session &&
                    self.activeLightEffect != nil && !self.isSleeping && self.state?.power == true
            })
        } else if action == .refresh {
            let session = self.generation
            let isProbe = self.inactivityProbeID != nil
            let requireModes = self.isRestoringAutomaticLighting || self.isStartingLightEffect
            let value: LampState
            do {
                if isProbe {
                    value = try await withConnectionDeadline(seconds: self.inactivityProbeTimeout) {
                        try await transport.refresh(requireModes: requireModes)
                    }
                } else {
                    value = try await transport.refresh(requireModes: requireModes)
                }
            } catch {
                if isProbe, self.generation == session { self.failedInactivityProbeSession = session }
                throw error
            }
            try Task.checkCancellation()
            guard self.generation == session, self.connection == .connected else { throw CancellationError() }
            if isProbe { self.inactivityProbeID = nil }
            self.receiveLampState(value, refreshOnEffectStop: false)
        } else {
            if self.isStartingLightEffect && action == .power(true) && self.state?.power == true { return }
            try await transport.apply(action)
        }
    }, onError: { [weak self] error in
        self?.commandFailed(error)
    }, onBusy: { [weak self] busy in
        self?.commandBusy = busy
        self?.updateBusy()
        if !busy { self?.scheduleIdleRelease() }
    })

    public convenience init(demo: Bool = false, keepConnectionAlive: Bool = false,
                            syncPowerWithMac: Bool = false) {
        if demo {
            let credential = LampCredentials(serial: "DEMO", accountID: "00000000-0000-0000-0000-000000000000",
                longTermKey: String(repeating: "0", count: 64), name: ServiceLocalization.text("Schreibtisch"))
            let demoTransport = DemoLampTransport()
            self.init(store: MemoryCredentialStore(credential), transportFactory: { demoTransport }, connectionTimeout: 40, idleSeconds: 60, keepConnectionAlive: true, syncPowerWithMac: false, isDemo: true)
        } else {
            self.init(store: KeychainCredentialStore(), transportFactory: { BluetoothLampTransport() }, connectionTimeout: 40, idleSeconds: 60, keepConnectionAlive: keepConnectionAlive, syncPowerWithMac: syncPowerWithMac)
        }
    }

    #if DEBUG
    /// Dependency-injected setup fixture; never constructs a Keychain store or
    /// Bluetooth transport, even when returning from the public demo.
    public static func isolatedSetupPreview() -> LampController {
        let simulated = DemoLampTransport()
        return LampController(store: MemoryCredentialStore(), transportFactory: { simulated })
    }

    /// Native screenshot fixture: the real control view rendered against an
    /// entirely in-memory lamp. This API is absent from Release/Store builds.
    public static func isolatedControlPreview() -> LampController {
        let simulated = DemoLampTransport()
        simulated.state.daylight = true
        simulated.state.autoBrightness = true
        let credentials = LampCredentials(serial: "DEMO", accountID: "00000000-0000-0000-0000-000000000000",
            longTermKey: String(repeating: "0", count: 64), name: ServiceLocalization.text("Schreibtisch"))
        return LampController(store: MemoryCredentialStore(credentials), transportFactory: { simulated },
                              keepConnectionAlive: true, syncPowerWithMac: false)
    }
    #endif

    init(store: CredentialStore, transportFactory: @escaping () -> LampTransport,
         connectionTimeout: TimeInterval = 40, idleSeconds: TimeInterval = 60,
         keepConnectionAlive: Bool = false, syncPowerWithMac: Bool = false,
         powerTransitionTimeout: TimeInterval = 2,
         commandMinimumGap: Duration = .milliseconds(150), effectTickSeconds: TimeInterval = 0.4,
         recoveryRetrySeconds: TimeInterval = 3, recoveryDropDelay: TimeInterval = 1,
         recoveryStableSeconds: TimeInterval = 30, inactivityProbeSeconds: TimeInterval = 60,
         inactivityProbeTimeout: TimeInterval = 8, isDemo: Bool = false) {
        self.isDemo = isDemo
        self.credentialStore = store
        self.transportFactory = transportFactory
        self.connectionTimeout = connectionTimeout
        self.idleSeconds = idleSeconds
        self.keepConnectionAlive = keepConnectionAlive
        self.syncPowerWithMac = isDemo ? false : syncPowerWithMac
        self.powerTransitionTimeout = powerTransitionTimeout
        self.commandMinimumGap = commandMinimumGap
        self.effectTickSeconds = effectTickSeconds
        self.recoveryRetrySeconds = recoveryRetrySeconds
        self.recoveryDropDelay = recoveryDropDelay
        self.recoveryStableSeconds = recoveryStableSeconds
        self.inactivityProbeSeconds = inactivityProbeSeconds
        self.inactivityProbeTimeout = inactivityProbeTimeout
        do {
            if let saved = try store.load() {
                guard saved.isValid else { throw ServiceError.invalidCredentials }
                assign(saved)
                connection = .disconnected
            }
        } catch {
            setError(key: UserFacingError.key(for: error))
            connection = .failed
        }
    }

    public func start() {
        guard sessionIsActive else { return }
        requestAutomaticConnection(powerOn: syncPowerWithMac)
    }

    public func setSyncPowerWithMac(_ enabled: Bool) {
        guard sessionIsActive, !isDemo else { return }
        if syncPowerWithMac != enabled { powerPolicy = UUID() }
        syncPowerWithMac = enabled
        if !enabled { pendingPowerOn = false }
    }

    public func setKeepConnectionAlive(_ enabled: Bool) {
        guard sessionIsActive else { return }
        keepConnectionAlive = enabled
        let keepPendingPowerOn = pendingPowerOn
        invalidateAutomaticConnection()
        if enabled {
            idleTask?.cancel()
            isConnectionPaused = false
            requestAutomaticConnection(allowFailure: true, powerOn: keepPendingPowerOn,
                                       recovery: true, resetRecoveryBudget: true)
        } else {
            scheduleIdleRelease()
            if keepPendingPowerOn && syncPowerWithMac { requestAutomaticConnection(powerOn: true) }
        }
    }

    public func connect() async {
        guard sessionIsActive, !isSleeping, powerOffTask == nil, credentialMutationID == nil else { return }
        isConnectionPaused = false
        invalidateAutomaticConnection()
        recoveryPhaseStarted = false
        connectionEstablishedAt = nil
        await connect(automatically: false)
    }

    private func connect(automatically: Bool, request: UUID? = nil) async {
        idleTask?.cancel()
        guard sessionIsActive, !isSleeping, powerOffTask == nil, credentialMutationID == nil,
              !automatically || (request == automaticRequest && !isConnectionPaused && (keepConnectionAlive || panelIsOpen || pendingPowerOn)) else { return }
        let requestedGeneration = generation
        if let teardownTask {
            await teardownTask.value
            guard generation == requestedGeneration, credentialMutationID == nil,
                  !isSleeping, powerOffTask == nil, !Task.isCancelled,
                  !automatically || (request == automaticRequest && !isConnectionPaused && (keepConnectionAlive || panelIsOpen || pendingPowerOn)) else { return }
        }
        guard !Task.isCancelled else { return }
        if let connectionTask { await connectionTask.value; return }
        guard connection != .connected else { return }
        guard let credentials else {
            connection = .unpaired
            return
        }
        generation = UUID()
        let session = generation
        let currentTransport = transportFactory()
        transport = currentTransport
        currentTransport.onStateChange = { [weak self] value in
            guard let self, self.generation == session, self.connection == .connected else { return }
            self.receiveLampState(value)
        }
        currentTransport.onDisconnect = { [weak self] in
            guard let self, self.generation == session, self.connection == .connected else { return }
            self.setError(key: "Die Verbindung zur Lampe wurde unterbrochen. Verbinde sie erneut.")
            _ = self.beginTeardown(nextState: .disconnected)
            self.lastConnectionFailureIsRetryable = true
            self.requestAutomaticConnection(allowFailure: true, recovery: true,
                                            initialDelay: self.recoveryDropDelay)
        }
        connection = .connecting
        lastConnectionFailureIsRetryable = false
        lastFailureWasPowerOff = false
        clearLocalizedError()
        updateBusy()
        let timeout = connectionTimeout
        let task = Task { [weak self] in
            do {
                let value = try await withConnectionDeadline(seconds: timeout) {
                    try await currentTransport.connect(credentials)
                }
                try Task.checkCancellation()
                guard let self, self.generation == session else { return }
                self.state = value
                self.connection = .connected
                self.connectionEstablishedAt = .now
                self.lastContactAt = .now
            } catch {
                guard let self, self.generation == session else { return }
                // This task cannot be part of the barrier it is about to await.
                // A concurrent release has already invalidated the session and
                // owns cancellation/cleanup instead of entering this branch.
                self.connectionTask = nil
                let nextState: ConnectionState
                if error is CancellationError || Task.isCancelled {
                    nextState = .disconnected
                } else {
                    nextState = .failed
                    self.lastConnectionFailureIsRetryable = self.canRetryConnection(error)
                    self.setError(key: UserFacingError.key(for: error))
                }
                let requestToPreserve = self.automaticConnectionTask == nil ? nil : self.automaticRequest
                let cleanup = self.beginTeardown(nextState: nextState, preservingAutomaticRequest: requestToPreserve)
                await cleanup.value
                return
            }
            guard let self, self.generation == session else { return }
            self.connectionTask = nil
            self.updateBusy()
            self.scheduleIdleRelease()
        }
        connectionTask = task
        await task.value
    }

    public func releaseConnection() async {
        isConnectionPaused = true
        wakeRequested = false
        let cleanup = beginTeardown(nextState: hasCredentials ? .disconnected : .unpaired)
        await cleanup.value
    }

    /// A retained physical controller is inert for the whole demo session,
    /// including late view callbacks and Mac lifecycle notifications.
    func deactivateSession() async {
        sessionIsActive = false
        panelIsOpen = false
        credentialMutationID = nil
        pendingPowerOn = false
        powerOffTask?.cancel()
        powerOffTask = nil
        powerOffID = nil
        await releaseConnection()
    }

    func activateSession() {
        guard !isTerminating else { return }
        sessionIsActive = true
        isSleeping = false
        // Keep the released state until an explicit connect action.
    }

    /// Terminal intent is synchronous so queued wake, panel and demo callbacks
    /// cannot start another connection while the app awaits graceful cleanup.
    public func beginTermination() {
        guard !isTerminating else { return }
        isTerminating = true
        sessionIsActive = false
        isSleeping = true
        panelIsOpen = false
        credentialMutationID = nil
        wakeRequested = false
        pendingPowerOn = false
        powerPolicy = UUID()
        invalidateAutomaticConnection()
        stopLightEffect(refreshAfterStop: false)
        cancelAutomaticLightingRestore()
        idleTask?.cancel()
        idleTask = nil
        connectionTask?.cancel()
    }

    /// Both normal Quit and system shutdown await one shared cleanup. A normal
    /// Quit releases Bluetooth; only a system shutdown may request lamp power-off.
    public func prepareForTermination(powerOff: Bool) async {
        beginTermination()
        if let terminationTask { await terminationTask.value; return }
        let task = Task { [self] in
            if powerOff, !isDemo { await powerOffAndRelease() }
            else {
                await powerOffTask?.value
                await releaseConnection()
            }
        }
        terminationTask = task
        await task.value
    }

    /// The bounded OS lifecycle coordinator uses this only after its graceful
    /// window expires. Keep the teardown barrier: a late completion must finish
    /// before any subsequent wake creates another authenticated connection.
    public func forceAbortConnections() async {
        _ = beginTeardown(nextState: hasCredentials ? .disconnected : .unpaired)
        if let forceAbortTask { await forceAbortTask.value; return }
        let oldTransports = Array(teardownTransports.values)
        let id = UUID()
        let task = Task {
            for transport in oldTransports { await transport.abort() }
        }
        forceAbortID = id
        forceAbortTask = task
        await task.value
        guard forceAbortID == id else { return }
        forceAbortTask = nil
        forceAbortID = nil
    }

    public func suspendForSleep() async {
        guard sessionIsActive, !isDemo else { return }
        isSleeping = true
        stopLightEffect(refreshAfterStop: false)
        cancelAutomaticLightingRestore()
        wakeRequested = false
        invalidateAutomaticConnection()
        pendingPowerOn = false
        await powerOffAndRelease()
    }

    public func prepareForPowerOff() async {
        guard sessionIsActive, !isDemo else { return }
        isSleeping = true
        stopLightEffect(refreshAfterStop: false)
        cancelAutomaticLightingRestore()
        wakeRequested = false
        invalidateAutomaticConnection()
        pendingPowerOn = false
        await powerOffAndRelease()
    }

    public func resumeAfterWake() {
        guard sessionIsActive, !isDemo else { return }
        isSleeping = false
        if connection == .connected, powerOffTask == nil, !isConnectionPaused {
            // A missed sleep notification must not keep an obsolete BLE session
            // looking connected after a real system wake.
            _ = beginTeardown(nextState: .disconnected)
        }
        wakeRequested = true
        resumeConnectionAfterPowerOff()
    }

    private func resumeConnectionAfterPowerOff() {
        guard sessionIsActive, !isSleeping, powerOffTask == nil, wakeRequested else { return }
        wakeRequested = false
        guard connection != .failed || (lastConnectionFailureIsRetryable && !lastFailureWasPowerOff) else { return }
        requestAutomaticConnection(allowFailure: true, powerOn: syncPowerWithMac,
                                   recovery: true, resetRecoveryBudget: true)
    }

    private func powerOffAndRelease() async {
        if let powerOffTask { await powerOffTask.value; return }
        guard syncPowerWithMac, !isConnectionPaused, connection == .connected else {
            await beginTeardown(nextState: hasCredentials ? .disconnected : .unpaired).value
            return
        }
        idleTask?.cancel()
        commands.replacePending(with: .power(false))
        let session = generation
        let id = UUID()
        let timeout = powerTransitionTimeout
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await withConnectionDeadline(seconds: timeout) {
                    await self.commands.waitUntilIdle()
                    try Task.checkCancellation()
                }
                guard self.generation == session else { return }
                await self.beginTeardown(nextState: self.hasCredentials ? .disconnected : .unpaired).value
            } catch {
                guard self.generation == session else { return }
                self.setError(key: "Die Lampe konnte vor dem Ruhezustand oder Ausschalten nicht rechtzeitig ausgeschaltet werden.")
                self.lastFailureWasPowerOff = true
                await self.beginTeardown(nextState: .failed).value
            }
        }
        powerOffID = id
        powerOffTask = task
        updateBusy()
        await task.value
        guard powerOffID == id else { return }
        powerOffTask = nil
        powerOffID = nil
        updateBusy()
        resumeConnectionAfterPowerOff()
    }

    /// A single barrier owns every transport shutdown. New connect requests wait
    /// for it; later release/forget intents invalidate requests already waiting.
    @discardableResult
    private func beginTeardown(nextState: ConnectionState, preservingAutomaticRequest request: UUID? = nil) -> Task<Void, Never> {
        // Mark shutdown synchronously before cancelling commands, whose busy
        // callback can otherwise briefly publish an idle controller.
        if teardownID == nil { teardownID = UUID() }
        if connection == .connected, let connectionEstablishedAt,
           connectionEstablishedAt.duration(to: .now) >= .seconds(recoveryStableSeconds) {
            stableConnectionMayResetRecovery = true
        }
        connectionEstablishedAt = nil
        lastContactAt = nil
        if request != automaticRequest || automaticConnectionTask == nil { invalidateAutomaticConnection() }
        inactivityProbeID = nil
        failedInactivityProbeSession = nil
        generation = UUID()
        stopLightEffect(refreshAfterStop: false)
        cancelAutomaticLightingRestore()
        idleTask?.cancel()
        idleTask = nil
        commands.cancel()
        let connecting = connectionTask
        connectionTask = nil
        connecting?.cancel()
        let oldTransport = transport
        transport = nil
        if let oldTransport { teardownTransports[ObjectIdentifier(oldTransport)] = oldTransport }
        oldTransport?.onStateChange = nil
        oldTransport?.onDisconnect = nil
        state = nil
        connection = nextState
        if oldTransport == nil, connecting == nil, let teardownTask {
            updateBusy()
            return teardownTask
        }
        let previousCleanup = teardownTask
        let id = UUID()
        let cleanup = Task { [weak self] in
            await previousCleanup?.value
            // Cancelling a connection resolves its CoreBluetooth waiters. Wait
            // for that connect operation before the one graceful disconnect.
            await connecting?.value
            await oldTransport?.disconnect()
            if let oldTransport { self?.teardownTransports.removeValue(forKey: ObjectIdentifier(oldTransport)) }
            guard let self, self.teardownID == id else { return }
            self.teardownTask = nil
            self.teardownID = nil
            self.updateBusy()
        }
        teardownID = id
        teardownTask = cleanup
        updateBusy()
        return cleanup
    }

    public func refresh() async {
        guard sessionIsActive, !isSleeping, powerOffTask == nil, !isRestoringAutomaticLighting, !isStartingLightEffect,
              connection == .connected else { return }
        idleTask?.cancel()
        commands.enqueue(.refresh)
        await commands.waitUntilIdle()
    }

    public func restoreAutomaticLighting() async {
        guard sessionIsActive, !Task.isCancelled, !isRestoringAutomaticLighting, !isSleeping, powerOffTask == nil,
              !isConnectionPaused, credentialMutationID == nil,
              connection == .connected else { return }
        stopLightEffect(refreshAfterStop: false)
        inactivityProbeID = nil
        let id = UUID()
        let session = generation
        automaticLightingRestoreID = id
        isRestoringAutomaticLighting = true
        clearLocalizedError()
        invalidateAutomaticConnection()
        idleTask?.cancel()
        updateBusy()
        defer {
            if automaticLightingRestoreID == id {
                cancelAutomaticLightingRestore()
                scheduleIdleRelease()
            }
        }
        commands.replacePending(with: [.preset(nil), .autoBrightness(true), .daylight(true), .refresh], ifAllowed: { [weak self] in
            guard let self else { return false }
            return self.automaticLightingRestoreID == id && self.generation == session &&
                !self.isSleeping && !self.isConnectionPaused && self.connection == .connected
        })
        await commands.waitUntilIdle()
        guard automaticLightingRestoreID == id, generation == session,
              connection == .connected else { return }
        if Task.isCancelled {
            await beginTeardown(nextState: .disconnected).value
            return
        }
        guard state?.daylight == true, state?.autoBrightness == true, state?.preset == nil else {
            setError(key: "Die Lampe hat Tageslicht und automatische Helligkeit noch nicht bestätigt. Aktualisiere den Status oder versuche es erneut.")
            return
        }
    }

    public func startLightEffect(_ effect: LightEffect) async {
        guard sessionIsActive, !Task.isCancelled, !isSleeping, powerOffTask == nil, !isConnectionPaused,
              !isRestoringAutomaticLighting, credentialMutationID == nil,
              connection == .connected else { return }
        if requestedLightEffect == effect && (isStartingLightEffect || activeLightEffect == effect) { return }
        stopLightEffect(refreshAfterStop: false)
        inactivityProbeID = nil
        let id = UUID()
        let session = generation
        lightEffectID = id
        requestedLightEffect = effect
        isStartingLightEffect = true
        effectPowerWasOn = false
        clearLocalizedError()
        invalidateAutomaticConnection()
        idleTask?.cancel()
        updateBusy()
        commands.replacePending(with: [.refresh, .preset(nil), .daylight(false), .autoBrightness(false), .power(true), .refresh], ifAllowed: { [weak self] in
            guard let self else { return false }
            return self.lightEffectID == id && self.generation == session &&
                !self.isSleeping && !self.isConnectionPaused && self.connection == .connected
        })
        await commands.waitUntilIdle()
        guard lightEffectID == id, generation == session, connection == .connected else { return }
        guard !Task.isCancelled else { stopLightEffect(); return }
        guard state?.power == true, state?.daylight == false,
              state?.autoBrightness == false, state?.preset == nil else {
            stopLightEffect(refreshAfterStop: false)
            setError(key: "Die Lampe hat die manuelle Effektsteuerung noch nicht bestätigt. Aktualisiere den Status oder versuche es erneut.")
            return
        }
        isStartingLightEffect = false
        activeLightEffect = effect
        updateBusy()
        let started = ContinuousClock.now
        let tickNanoseconds = UInt64(max(0.001, effectTickSeconds) * 1_000_000_000)
        lightEffectTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.lightEffectID == id, self.activeLightEffect == effect,
                      self.connection == .connected, !self.isSleeping, self.state?.power == true else { return }
                let duration = started.duration(to: .now).components
                let elapsed = Double(duration.seconds) + Double(duration.attoseconds) / 1_000_000_000_000_000_000
                let frame = effect.frame(at: elapsed)
                if frame != self.lastQueuedEffectFrame {
                    self.lastQueuedEffectFrame = frame
                    self.commands.enqueue(.effectFrame(frame), ifAllowed: { [weak self] in
                        guard let self else { return false }
                        return self.lightEffectID == id && self.activeLightEffect == effect &&
                            self.generation == session && !self.isSleeping && self.state?.power == true
                    })
                }
                do { try await Task.sleep(nanoseconds: tickNanoseconds) }
                catch { return }
            }
        }
    }

    public func stopLightEffect() { stopLightEffect(refreshAfterStop: true) }

    private func stopLightEffect(refreshAfterStop: Bool) {
        guard lightEffectID != nil || isStartingLightEffect || activeLightEffect != nil else { return }
        let wasStarting = isStartingLightEffect
        lightEffectID = nil
        requestedLightEffect = nil
        lightEffectTask?.cancel()
        lightEffectTask = nil
        activeLightEffect = nil
        isStartingLightEffect = false
        lastQueuedEffectFrame = nil
        effectPowerWasOn = false
        commands.discardPending { action in
            if wasStarting { if case .movement = action { return false }; return true }
            if case .effectFrame = action { return true }
            return false
        }
        updateBusy()
        if refreshAfterStop, !isSleeping, powerOffTask == nil, connection == .connected {
            idleTask?.cancel()
            commands.enqueue(.refresh)
        } else { scheduleIdleRelease() }
    }

    public func setPower(_ value: Bool) { enqueue(.power(value)) }
    public func setBrightness(_ value: Int) { enqueue(.brightness(min(100, max(0, value)))) }
    public func setKelvin(_ value: Int) { enqueue(.kelvin(min(6500, max(2700, value)))) }
    public func setDaylight(_ value: Bool) { enqueue(.daylight(value)) }
    public func setAutoBrightness(_ value: Bool) { enqueue(.autoBrightness(value)) }
    public func setMovement(_ value: Bool) { enqueue(.movement(value)) }
    public func setPreset(_ value: Preset?) { enqueue(.preset(value)) }

    public func panelOpened() {
        guard sessionIsActive else { return }
        panelIsOpen = true
        idleTask?.cancel()
        if connection == .connected { recoverAfterInactivity() }
        else {
            guard automaticConnectionTask == nil else { return }
            requestAutomaticConnection(allowFailure: true, recovery: true, resetRecoveryBudget: true)
        }
    }

    /// Unlock/display wake is a connection health check, never a power-on intent.
    public func recoverAfterInactivity() {
        guard sessionIsActive, !isDemo else { return }
        guard !isSleeping, !isConnectionPaused, powerOffTask == nil,
              credentialMutationID == nil, hasCredentials else { return }
        if connection == .connected {
            guard !commandBusy, !isRestoringAutomaticLighting, !isStartingLightEffect,
                  activeLightEffect == nil, inactivityProbeID == nil,
                  let lastContactAt,
                  lastContactAt.duration(to: .now) >= .seconds(inactivityProbeSeconds) else { return }
            let id = UUID()
            let session = generation
            inactivityProbeID = id
            Task { [weak self] in
                guard let self else { return }
                defer { if self.inactivityProbeID == id { self.inactivityProbeID = nil } }
                guard self.inactivityProbeID == id, self.generation == session,
                      !self.commandBusy, !self.isSleeping, !self.isConnectionPaused,
                      !self.isRestoringAutomaticLighting, !self.isStartingLightEffect,
                      self.activeLightEffect == nil else { return }
                await self.refresh()
            }
        } else if connection == .disconnected || connection == .failed {
            guard automaticConnectionTask == nil,
                  connection != .failed || lastConnectionFailureIsRetryable else { return }
            requestAutomaticConnection(allowFailure: true, recovery: true)
        }
    }

    public func panelClosed() {
        panelIsOpen = false
        scheduleIdleRelease()
    }

    public func renameLamp(_ name: String) {
        guard sessionIsActive, credentialMutationID == nil, var credentials else { return }
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        guard !trimmed.isEmpty else { return }
        credentials.name = trimmed
        do {
            try credentialStore.save(credentials)
            assign(credentials)
        } catch { setError(key: UserFacingError.key(for: error)) }
    }

    public func forgetLamp() async throws {
        guard sessionIsActive else { throw CancellationError() }
        wakeRequested = false
        let mutation = UUID()
        credentialMutationID = mutation
        updateBusy()
        defer { finishCredentialMutation(mutation) }
        await beginTeardown(nextState: hasCredentials ? .disconnected : .unpaired).value
        guard credentialMutationID == mutation else { throw CancellationError() }
        do { try credentialStore.delete() }
        catch {
            setError(key: UserFacingError.key(for: error))
            throw error
        }
        credentials = nil
        hasCredentials = false
        serial = ""
        lampName = ServiceLocalization.text("Meine Lampe")
        connection = .unpaired
        clearLocalizedError()
        isConnectionPaused = false
    }

    public func dismissError() { clearLocalizedError() }

    public func reloadLocalizedText() {
        errorMessage = localizedErrorKey.map { ServiceLocalization.text($0) }
        if credentials?.name.isEmpty != false {
            lampName = ServiceLocalization.text("Meine Lampe")
        } else if serial == "DEMO", let name = credentials?.name,
                  [ServiceLocalization.text("Schreibtisch", languageCode: "de"),
                   ServiceLocalization.text("Schreibtisch", languageCode: "en")].contains(name) {
            lampName = ServiceLocalization.text("Schreibtisch")
        }
    }

    func adopt(_ credentials: LampCredentials, ifCurrent: (() -> Bool)? = nil) async throws {
        guard sessionIsActive else { throw CancellationError() }
        wakeRequested = false
        guard credentials.isValid else { throw ServiceError.invalidCredentials }
        let mutation = UUID()
        credentialMutationID = mutation
        updateBusy()
        defer { finishCredentialMutation(mutation) }
        await beginTeardown(nextState: hasCredentials ? .disconnected : .unpaired).value
        guard credentialMutationID == mutation, ifCurrent?() != false else { throw CancellationError() }
        try credentialStore.save(credentials)
        assign(credentials)
        connection = .disconnected
        clearLocalizedError()
        isConnectionPaused = false
    }

    private func assign(_ value: LampCredentials) {
        credentials = value
        hasCredentials = true
        serial = value.serial
        lampName = value.name.isEmpty ? ServiceLocalization.text("Meine Lampe") : value.name
    }

    private func receiveLampState(_ value: LampState, refreshOnEffectStop: Bool = true) {
        state = value
        lastContactAt = .now
        guard lightEffectID != nil else { return }
        if value.power { effectPowerWasOn = true }
        else if activeLightEffect != nil || effectPowerWasOn {
            stopLightEffect(refreshAfterStop: refreshOnEffectStop)
        }
    }

    private func enqueue(_ action: LampAction) {
        guard sessionIsActive, !isSleeping, powerOffTask == nil, !isRestoringAutomaticLighting,
              connection == .connected else { return }
        if case .movement = action {
            // Sensor preferences can change while the effect keeps running.
        } else {
            let wasEffect = lightEffectID != nil
            stopLightEffect(refreshAfterStop: false)
            if wasEffect || { if case .preset = action { return true }; return false }() {
                inactivityProbeID = nil
                commands.discardPending { if case .movement = $0 { return false }; return true }
            }
        }
        idleTask?.cancel()
        commands.enqueue(action)
    }

    private func commandFailed(_ error: Error) {
        let failedProbe = failedInactivityProbeSession == generation
        lastFailureWasPowerOff = powerOffTask != nil
        setError(key: UserFacingError.key(for: error))
        _ = beginTeardown(nextState: .failed)
        lastConnectionFailureIsRetryable = canRetryConnection(error)
        if failedProbe, lastConnectionFailureIsRetryable {
            requestAutomaticConnection(allowFailure: true, recovery: true, initialDelay: recoveryDropDelay)
        }
    }

    private func finishCredentialMutation(_ id: UUID) {
        guard credentialMutationID == id else { return }
        credentialMutationID = nil
        updateBusy()
    }

    private func updateBusy() {
        isBusy = connection == .connecting || commandBusy || teardownID != nil || credentialMutationID != nil || powerOffTask != nil || isRestoringAutomaticLighting || isStartingLightEffect
    }

    private func setError(key: String) {
        localizedErrorKey = key
        errorMessage = ServiceLocalization.text(key)
    }

    private func clearLocalizedError() {
        localizedErrorKey = nil
        errorMessage = nil
    }

    private func cancelAutomaticLightingRestore() {
        automaticLightingRestoreID = nil
        isRestoringAutomaticLighting = false
        updateBusy()
    }

    private func requestAutomaticConnection(allowFailure: Bool = false, powerOn: Bool = false,
                                            recovery: Bool = false, resetRecoveryBudget: Bool = false,
                                            initialDelay: TimeInterval = 0) {
        guard sessionIsActive, !isRestoringAutomaticLighting, !isStartingLightEffect else { return }
        let shouldPowerOn = powerOn && syncPowerWithMac && !isConnectionPaused
        guard keepConnectionAlive || panelIsOpen || shouldPowerOn,
              !isSleeping, powerOffTask == nil, !isConnectionPaused, (allowFailure || connection != .failed),
              credentialMutationID == nil, hasCredentials else { return }
        if recovery {
            if resetRecoveryBudget || !recoveryPhaseStarted || stableConnectionMayResetRecovery {
                recoveryPhaseStarted = true
                recoveryAttemptsRemaining = 2
                stableConnectionMayResetRecovery = false
            }
            guard recoveryAttemptsRemaining > 0 else { return }
        }
        invalidateAutomaticConnection()
        pendingPowerOn = shouldPowerOn
        let request = UUID()
        automaticRequest = request
        automaticConnectionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.automaticRequest == request {
                    self.automaticConnectionTask = nil
                    self.pendingPowerOn = false
                }
            }
            let attempts = recovery ? self.recoveryAttemptsRemaining : 1
            for attempt in 0..<attempts {
                let delay = attempt == 0 ? initialDelay : self.recoveryRetrySeconds
                if delay > 0 {
                    do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                    catch { return }
                }
                guard !Task.isCancelled, self.automaticRequest == request,
                      self.keepConnectionAlive || self.panelIsOpen || self.pendingPowerOn,
                      !self.isSleeping, !self.isConnectionPaused,
                      self.credentialMutationID == nil else { return }
                if recovery, self.connection != .connected {
                    guard self.recoveryAttemptsRemaining > 0 else { return }
                    self.recoveryAttemptsRemaining -= 1
                }
                await self.connect(automatically: true, request: request)
                guard !Task.isCancelled, self.automaticRequest == request else { return }
                if self.connection == .connected {
                    self.enqueuePendingLifecyclePowerOn(request: request)
                    return
                }
                guard self.lastConnectionFailureIsRetryable else { return }
            }
        }
    }

    private func enqueuePendingLifecyclePowerOn(request: UUID) {
        guard automaticRequest == request, !isSleeping, !isConnectionPaused,
              connection == .connected, pendingPowerOn, syncPowerWithMac else { return }
        pendingPowerOn = false
        let powerPolicy = powerPolicy
        let session = generation
        idleTask?.cancel()
        commands.enqueue(.power(true), ifAllowed: { [weak self] in
            guard let self else { return false }
            return self.powerPolicy == powerPolicy && self.generation == session &&
                self.syncPowerWithMac && !self.isSleeping && !self.isConnectionPaused
        })
    }

    private func invalidateAutomaticConnection() {
        automaticRequest = UUID()
        automaticConnectionTask?.cancel()
        automaticConnectionTask = nil
        pendingPowerOn = false
    }

    private func canRetryConnection(_ error: Error) -> Bool {
        if let error = error as? ServiceError, case .deadline = error { return true }
        guard let error = error as? MorphError else { return false }
        switch error {
        case .timeout, .bluetooth: return true
        case .bluetoothState(let issue):
            return issue == .poweredOff || issue == .unavailable || issue == .disconnected
        default: return false
        }
    }

    private func scheduleIdleRelease() {
        idleTask?.cancel()
        guard !keepConnectionAlive, !panelIsOpen, !isSleeping, powerOffTask == nil, !isRestoringAutomaticLighting,
              !isStartingLightEffect, activeLightEffect == nil,
              connection == .connected, !commandBusy else { return }
        let seconds = idleSeconds
        idleTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(max(0.001, seconds) * 1_000_000_000)) }
            catch { return }
            guard let self, !self.keepConnectionAlive, !self.panelIsOpen,
                  !self.isSleeping, !self.isRestoringAutomaticLighting, !self.isStartingLightEffect,
                  self.activeLightEffect == nil, !self.commandBusy else { return }
            await self.beginTeardown(nextState: .disconnected).value
        }
    }
}
