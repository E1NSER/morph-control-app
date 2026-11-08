import CoreBluetooth
import Foundation
import OSLog

public struct LampState: Codable, Equatable {
    public var power: Bool
    public var lumens: Int
    /// Linear position in the 100–1000 lm range. The lamp has its own, different percentage.
    public var brightness: Int
    public var kelvin: Int
    public var autoBrightness: Bool
    public var movement: Bool
    /// nil when the lamp's lighting mode could not be fully read from the attribute channel.
    public var daylight: Bool?
    public var preset: Preset?

    public init(power: Bool, lumens: Int, brightness: Int, kelvin: Int,
                autoBrightness: Bool, movement: Bool, daylight: Bool?, preset: Preset?) {
        self.power = power
        self.lumens = lumens
        self.brightness = brightness
        self.kelvin = kelvin
        self.autoBrightness = autoBrightness
        self.movement = movement
        self.daylight = daylight
        self.preset = preset
    }
}

public struct DiscoveredLamp: Codable {
    public let id: UUID
    public let name: String
    public let rssi: Int
    public let services: [String]
}

/// One BLE session with the lamp: find, connect, handshake, read, write.
///
/// All CoreBluetooth state lives on `queue`. The async methods register a
/// waiter on that queue and the delegate callbacks resolve it.
public final class Lamp: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    private static let diagnostics = Logger(subsystem: "at.einser.morphcontrol", category: "Bluetooth")
    public var log: (String) -> Void = { _ in }
    /// Called on the Bluetooth queue when a notification changed the live state.
    public var onStateChange: ((LampState) -> Void)?
    /// Called on the Bluetooth queue when the connection ends for any reason.
    public var onDisconnect: (() -> Void)?

    private let queue = DispatchQueue(label: "morph.ble")
    private var central: CBCentralManager!
    private var runtimeID = UUID()
    private var sessionID = UUID()
    private var gattInvalidated = false
    private var peripheral: CBPeripheral?
    private var chars: [CBUUID: CBCharacteristic] = [:]
    private var assembler = MessageAssembler()
    private var pendingServices = 0
    private var lastControlWrite = Date.distantPast

    private struct Pending {
        let id: UUID
        let resolve: (Any) -> Void
        let reject: (Error) -> Void
    }

    private var pending: [String: Pending] = [:]
    private struct NotificationRequest {
        let id: UUID
        let sessionID: UUID
        let target: ObjectIdentifier
        let enabled: Bool
    }
    private var notificationRequests: [String: NotificationRequest] = [:]
    /// Replies that arrived before their waiter registered.
    private var mailbox: [String: Any] = [:]

    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func cancel() { lock.lock(); value = true; lock.unlock() }
    }

    private var authenticated = false
    /// The live state. nil until `enableLiveState`, and nil again after a disconnect.
    private var cache: LampState?
    private var scanTarget: String?
    private var scanResults: [UUID: DiscoveredLamp]?
    private var scanID: UUID?

    private struct ConnectionTarget {
        let peripheral: CBPeripheral
        let runtimeID: UUID
    }

    /// The service UUIDs observed on the supported lamp. Retrieval uses any
    /// matching service, then still checks the serial or a previously verified ID.
    private static let lampServices = ["2DD10010", "2DD10020", "2DD1FFF0"].map {
        CBUUID(string: $0 + "-1C37-452D-8979-D1B4A787D0A4")
    }

    // MARK: - Public API

    public func powerOn() async throws {
        do {
            let _: Bool = try await wait("state", timeout: 10) {
                if let central = self.central {
                    switch central.state {
                    case .poweredOn: self.resolve("state", true)
                    case .poweredOff: throw MorphError.bluetoothState(.poweredOff)
                    case .unauthorized: throw MorphError.bluetoothState(.permissionDenied)
                    case .unsupported: throw MorphError.bluetoothState(.unsupported)
                    default: break // unknown/resetting may recover within this bounded wait.
                    }
                } else {
                    self.runtimeID = UUID()
                    self.central = CBCentralManager(delegate: self, queue: self.queue)
                }
            }
        } catch is CancellationError {
            await abort()
            throw CancellationError()
        }
    }

    /// True between a complete handshake and the end of the connection. The
    /// app uses it to see that the lamp dropped an idle connection.
    public var isReady: Bool {
        get async { (try? await onQueue { self.authenticated }) ?? false }
    }

    /// List the nearby peripherals that have a name, strongest signal first.
    public func scan(seconds: TimeInterval) async throws -> [DiscoveredLamp] {
        let id = UUID()
        let duration = min(30, max(0, seconds.isFinite ? seconds : 10))
        do {
            let found: [DiscoveredLamp] = try await wait("scan", timeout: duration + 2) {
                try self.requirePoweredOn()
                self.scanID = id
                self.scanTarget = nil
                self.scanResults = [:]
                self.central.scanForPeripherals(withServices: nil)
                self.queue.asyncAfter(deadline: .now() + duration) {
                    // An old timer must not stop a later scan after cancellation.
                    guard self.scanID == id else { return }
                    let results = self.scanResults ?? [:]
                    self.stopScan()
                    self.resolve("scan", Array(results.values))
                }
            }
            return found.sorted { $0.rssi > $1.rssi }
        } catch {
            try? await onQueue { if self.scanID == id { self.stopScan() } }
            throw error
        }
    }

    /// Connect and do the handshake.
    ///
    /// - Returns: the CoreBluetooth identifier of the lamp, to pass as `cachedId` next time.
    public func connect(serial: String, accountId: String, ltkHex: String, cachedId: UUID?) async throws -> UUID {
        let hexDigits = ltkHex.filter(\.isHexDigit)
        guard let ltk = Data(hex: hexDigits), !ltk.isEmpty else {
            throw MorphError.protocolError("The stored key is not hexadecimal.")
        }
        let key = MorphCrypto.deriveAesKey(ltk: ltk)

        // A lamp connected to macOS by another client may not advertise. Apple
        // still requires our central to connect locally before using it.
        let known = try await onQueue { () -> ConnectionTarget? in
            try self.requirePoweredOn()
            let connected = self.central.retrieveConnectedPeripherals(withServices: Self.lampServices)
            if let target = connected.first(where: {
                Self.isExpectedPeripheral(id: $0.identifier, name: $0.name, serial: serial, cachedId: cachedId)
            }) { return ConnectionTarget(peripheral: target, runtimeID: self.runtimeID) }
            if let cachedId,
               let target = self.central.retrievePeripherals(withIdentifiers: [cachedId]).first {
                return ConnectionTarget(peripheral: target, runtimeID: self.runtimeID)
            }
            return nil
        }
        if let known {
            log("Trying the known peripheral \(known.peripheral.identifier)")
            if try await connectAndAuthenticate(known, attempts: 1, accountId: accountId, key: key) {
                return known.peripheral.identifier
            }
        }

        log("Scanning for \(serial)")
        let found: ConnectionTarget
        let id = UUID()
        do {
            found = try await wait("find", timeout: 10) {
                try self.requirePoweredOn()
                self.scanID = id
                self.scanResults = nil
                self.scanTarget = serial.uppercased()
                self.central.scanForPeripherals(withServices: nil)
            }
        } catch {
            // Stop the scan when the app's connection attempt ends.
            try? await onQueue { if self.scanID == id { self.stopScan() } }
            guard case MorphError.timeout = error else { throw error }
            throw MorphError.bluetooth(
                "Could not find \(serial) nearby. Make sure that the lamp has power and that no other device holds the connection.")
        }
        if try await connectAndAuthenticate(found, attempts: 2, accountId: accountId, key: key) {
            return found.peripheral.identifier
        }
        throw MorphError.bluetooth(
            "Could not connect to \(serial). Make sure that no other device holds the connection "
                + "(MyDyson app, Homebridge). If the lamp refuses all connections, remove its power for ten seconds."
        )
    }

    /// Subscribe to the state characteristics and keep a copy of the state current.
    ///
    /// The attribute channel already reports daylight mode and the presets. From
    /// here on, `state(fresh: false)` needs no round trip to the lamp.
    public func enableLiveState(seed: LampState? = nil) async throws {
        let initial: LampState
        if let seed { initial = seed } else { initial = try await readState(attributes: true) }
        // The copy exists before the subscription, so that no notification is lost.
        try await onQueue {
            guard self.authenticated, !self.gattInvalidated else {
                throw MorphError.bluetoothState(.unavailable)
            }
            self.cache = initial
        }
        do {
            for uuid in LampState.liveCharacteristics {
                try await setNotifications(true, for: uuid)
            }
            // A value that changed before the subscription has no notification, for
            // example the end of a ramp. Read again: each read goes into the copy.
            _ = try await readState(attributes: false)
        } catch {
            try? await onQueue { self.cache = nil }
            throw error
        }
        log("The live state is on")
    }

    public var isLive: Bool {
        get async { (try? await onQueue { self.cache != nil }) ?? false }
    }

    /// The state after a command.
    ///
    /// - Parameter fresh: read the lamp and not the live copy. Necessary after a
    ///   write of a value that the lamp ramps to, and for an explicit refresh.
    public func state(attributes: Bool, fresh: Bool, requireAttributes: Bool = false) async throws -> LampState {
        guard await isLive else { return try await readState(attributes: attributes, requireAttributes: requireAttributes) }
        if fresh {
            let snapshot = try await readState(attributes: attributes, requireAttributes: requireAttributes)
            if attributes {
                // Failed best-effort mode reads must replace old known values
                // with unknown, rather than resurrecting a stale Auto badge.
                try await onQueue {
                    self.updateLive { $0.applyLightingModeSnapshot(snapshot) }
                }
            }
        }
        guard let cached = try await onQueue({ self.cache }) else {
            throw MorphError.bluetooth("The lamp disconnected.")
        }
        return cached
    }

    /// - Parameter attributes: also ask for daylight mode and the preset. Each
    ///   question is a paced round trip, so a caller that only switches the lamp omits them.
    public func readState(attributes: Bool = true, requireAttributes: Bool = false) async throws -> LampState {
        let power = try await readByte(CharUUID.power) != 0
        let lumens = try await readWord(CharUUID.brightnessLm)
        let kelvin = try await readWord(CharUUID.colorTemp)
        let auto = try await readByte(CharUUID.autoBrightness) != 0
        let movement = try await readByte(CharUUID.movement) != 0

        var state = LampState(
            power: power, lumens: lumens, brightness: lumensToPercent(lumens), kelvin: kelvin,
            autoBrightness: auto, movement: movement, daylight: nil, preset: nil
        )
        if attributes {
            var modeIsKnown = true
            do {
                let daylight = try await readAttribute(Attribute.daylight)
                guard let byte = daylight.first else { throw MorphError.protocolError("The lamp did not confirm daylight mode.") }
                state.daylight = byte != 0
            } catch {
                if requireAttributes { throw error }
                modeIsKnown = false
            }
            for preset in Preset.allCases {
                do {
                    let value = try await readAttribute(preset.attribute)
                    guard let byte = value.first else { throw MorphError.protocolError("The lamp did not confirm its lighting profile.") }
                    if byte != 0 { state.preset = preset }
                } catch {
                    if requireAttributes { throw error }
                    modeIsKnown = false
                }
            }
            if !modeIsKnown { state.daylight = nil }
        }
        return state
    }

    /// Power is the only control with an unambiguous result, so check it and try one more time.
    public func setPower(_ on: Bool) async throws {
        for attempt in 1...2 {
            try await writeControl(Data([on ? 1 : 0]), to: CharUUID.power)
            try await Task.sleep(nanoseconds: 250_000_000)
            let isOn = try await readByte(CharUUID.power) != 0
            if isOn == on { return }
            log("Power write \(attempt) did not take effect")
        }
        throw MorphError.bluetooth("The lamp did not change its power state.")
    }

    public func togglePower() async throws {
        try await setPower(try await readByte(CharUUID.power) == 0)
    }

    public func setLumens(_ lumens: Int) async throws {
        let clamped = min(Limits.lumens.upperBound, max(Limits.lumens.lowerBound, lumens))
        try await writeControl(le16(UInt16(clamped)), to: CharUUID.brightnessLm)
    }

    public func setKelvin(_ kelvin: Int) async throws {
        let clamped = min(Limits.kelvin.upperBound, max(Limits.kelvin.lowerBound, kelvin))
        try await writeControl(le16(UInt16(clamped)), to: CharUUID.colorTemp)
    }

    public func setAutoBrightness(_ on: Bool) async throws {
        try await writeControl(Data([on ? 1 : 0]), to: CharUUID.autoBrightness)
    }

    public func setMovement(_ on: Bool) async throws {
        try await writeControl(Data([on ? 1 : 0]), to: CharUUID.movement)
    }

    public func setDaylight(_ on: Bool) async throws {
        try await writeAttribute(Attribute.daylight, value: Data([on ? 1 : 0]))
    }

    /// Activate a preset. `nil` clears the active preset.
    public func setPreset(_ preset: Preset?) async throws {
        if let preset {
            try await writeAttribute(preset.attribute, value: Data([1]))
            return
        }
        for candidate in Preset.allCases {
            let value = try await readAttribute(candidate.attribute)
            guard let byte = value.first else { throw MorphError.protocolError("The lamp did not confirm its lighting profile.") }
            if byte != 0 {
                try await writeAttribute(candidate.attribute, value: Data([0]))
            }
        }
    }

    public func disconnect() async {
        let target = try? await onQueue { () -> CBPeripheral? in
            self.stopScan()
            self.fail("find", CancellationError())
            self.fail("scan", CancellationError())
            return self.peripheral
        }
        guard let target else {
            try? await onQueue { self.clearSession(MorphError.bluetoothState(.disconnected)) }
            return
        }
        await unsubscribeAll()
        _ = await cancelConnection(target)
    }

    /// Immediately ends scans, pending continuations and the BLE session. Used
    /// when a connection deadline expires or its owning app operation is cancelled.
    public func abort() async {
        try? await onQueue {
            self.stopScan()
            if let peripheral = self.peripheral {
                if self.central?.state == .poweredOn {
                    self.central.cancelPeripheralConnection(peripheral)
                }
            }
            self.clearSession(CancellationError(), notifyDisconnect: false)
            self.central?.delegate = nil
            self.central = nil
            self.runtimeID = UUID()
        }
    }

    /// A failed GATT request may leave the current session unusable. Cancel
    /// without more notification writes, wait for the bounded disconnect, and
    /// discard this runtime before a single fresh attempt. This does not claim
    /// to reset the lamp firmware or flush macOS's entire GATT cache.
    public func resetAfterATTFailure() async {
        if let target = try? await onQueue({ self.peripheral }) {
            _ = await cancelConnection(target)
        }
        await abort()
    }

    /// Wait for the local cancellation before reusing a peripheral. Cancel is
    /// non-blocking in CoreBluetooth; starting the next attempt immediately can
    /// let a late disconnect tear down the new handshake.
    private func cancelConnection(_ target: CBPeripheral) async -> Bool {
        let ended: Bool? = try? await wait("disconnect", timeout: 3) {
            guard self.peripheral === target,
                  self.central?.state == .poweredOn,
                  target.state != .disconnected else {
                self.resolve("disconnect", true)
                return
            }
            self.central.cancelPeripheralConnection(target)
        }
        return (try? await onQueue {
            guard self.peripheral === target else { return ended == true }
            let completed = ended == true || target.state == .disconnected
            // Even a cancelled Swift task must issue the CoreBluetooth cancel.
            if self.central?.state == .poweredOn, target.state != .disconnected {
                self.central.cancelPeripheralConnection(target)
            }
            self.clearSession(MorphError.bluetoothState(.disconnected))
            if !completed {
                // A missing disconnect callback must not contaminate a later
                // attempt. Recreate the runtime on the next powerOn instead.
                self.central?.delegate = nil
                self.central = nil
                self.runtimeID = UUID()
            }
            return completed
        }) ?? false
    }

    /// Turn off all notifications before a planned disconnect.
    ///
    /// The lamp must forget them when the link ends, but a small Bluetooth stack
    /// possibly keeps some state for each one. macOS also keeps the link open
    /// while a different process uses the lamp, and then the lamp keeps sending.
    private func unsubscribeAll() async {
        let subscribed = (try? await onQueue { () -> [CBCharacteristic] in
            guard self.peripheral?.state == .connected else { return [] }
            return self.chars.values.filter(\.isNotifying)
        }) ?? []
        for characteristic in subscribed {
            let uuid = characteristic.uuid.uuidString
            let done: Void? = try? await setNotifications(false, for: uuid, timeout: 2)
            // A lamp that does not answer here does not answer the next one either.
            guard done != nil else {
                log("The lamp did not turn off the notifications of \(uuid)")
                return
            }
        }
        if !subscribed.isEmpty { log("Turned off \(subscribed.count) notifications") }
    }

    // MARK: - Connect and handshake

    private func connectAndAuthenticate(_ candidate: ConnectionTarget, attempts: Int, accountId: String, key: Data) async throws -> Bool {
        let target = candidate.peripheral
        var silent = 0
        for attempt in 1...attempts {
            do {
                let _: Bool = try await wait("connect", timeout: 8) {
                    try self.requirePoweredOn()
                    guard self.runtimeID == candidate.runtimeID else {
                        throw MorphError.bluetoothState(.unavailable)
                    }
                    self.mailbox.removeAll()
                    self.beginConnectionSession()
                    self.peripheral = target
                    target.delegate = self
                    self.central.connect(target)
                }
                log("Connected")
                try await discover(target)
                log("Discovered the characteristics")
                try await authenticate(accountId: accountId, key: key)
                return true
            } catch is CancellationError {
                await abort()
                throw CancellationError()
            } catch let error as MorphError {
                // Stop this runtime on ATT errors. The app may make one fresh
                // session attempt; do not add CCCD writes to a failing GATT link.
                if case .lampStuck = error {
                    _ = await cancelConnection(target)
                    throw error
                }
                // A rejected key or a terminal Bluetooth state needs a targeted
                // action rather than another handshake on this runtime.
                let mustStop: Bool
                switch error {
                case .protocolError, .lampStuck, .bluetoothState: mustStop = true
                default: mustStop = false
                }
                if mustStop {
                    log("Attempt \(attempt) failed: \(error)")
                    await unsubscribeAll()
                    _ = await cancelConnection(target)
                    throw error
                }
                if case .timeout(let key) = error, key.hasPrefix("msg:") { silent += 1 }
                log("Attempt \(attempt) failed: \(error)")
            } catch {
                log("Attempt \(attempt) failed: \(error.localizedDescription)")
            }
            await unsubscribeAll()
            guard await cancelConnection(target) else {
                throw MorphError.bluetoothState(.unavailable)
            }
            try Task.checkCancellation()
            if attempt < attempts { try await Task.sleep(nanoseconds: UInt64(attempt) * 700_000_000) }
        }
        // The link is good but the lamp does not talk. A scan cannot help, so stop here.
        // This is what a second program sees while a first one has the session.
        if silent == attempts {
            throw MorphError.bluetoothState(.sessionOccupied)
        }
        return false
    }

    private func discover(_ target: CBPeripheral) async throws {
        // Characteristics are spread over three services, so sweep all of them.
        let _: Bool = try await wait("discover", timeout: 15) {
            guard self.peripheral === target, !self.gattInvalidated else {
                throw MorphError.bluetoothState(.unavailable)
            }
            self.chars = [:]
            target.discoverServices(nil)
        }
        try await setNotifications(true, for: CharUUID.auth)
    }

    /// LTK re-authentication. The lamp discards all control writes until
    /// it answers with `connectionEstablished`.
    private func authenticate(accountId: String, key: Data) async throws {
        let session = try await onQueue {
            self.assembler = MessageAssembler()
            return self.sessionID
        }

        // Some firmware needs the product-info exchange before it talks auth.
        try await send(MsgType.requestProductInfo)
        if (try? await message(MsgType.productInfo, timeout: 2)) == nil {
            try Task.checkCancellation()
            log("No product info returned; continuing with the handshake")
        }

        try await send(MsgType.reauthPayloadA, payload: MorphCrypto.buildReauthPayloadA(accountId: accountId, key: key))
        let payloadB = try await message(MsgType.reauthPayloadB, timeout: 6)

        let challenge = try MorphCrypto.parseReauthPayloadB(key: key, payload: payloadB)
        try await send(MsgType.reauthPayloadC, payload: MorphCrypto.buildReauthPayloadC(key: key, challenge: challenge))
        _ = try await message(MsgType.connectionEstablished, timeout: 6)
        try await onQueue { try self.completeAuthentication(session: session) }
        log("Handshake complete")

        // The attribute channel refuses the subscription before the handshake.
        if try await onQueue({ self.chars[CBUUID(string: CharUUID.attribute)] != nil }) {
            try? await setNotifications(true, for: CharUUID.attribute)
        }
    }

    /// Queue-only session transitions also used by the no-radio lifecycle tests.
    @discardableResult
    func beginConnectionSession() -> UUID {
        sessionID = UUID()
        gattInvalidated = false
        authenticated = false
        cache = nil
        notificationRequests.removeAll()
        return sessionID
    }

    func completeAuthentication(session: UUID) throws {
        guard session == sessionID, !gattInvalidated else {
            throw MorphError.bluetoothState(.unavailable)
        }
        authenticated = true
    }

    // MARK: - Notification lifecycle

    private func setNotifications(_ enabled: Bool, for uuid: String, timeout: TimeInterval = 5) async throws {
        let characteristic = try await onQueue { try self.characteristic(uuid) }
        try await changeNotificationState(enabled, for: uuid, target: ObjectIdentifier(characteristic), timeout: timeout,
            isCurrent: { self.peripheral?.state == .connected && self.chars[characteristic.uuid] === characteristic },
            isNotifying: { characteristic.isNotifying },
            request: { self.peripheral?.setNotifyValue($0, for: characteristic) })
    }

    /// All closures run on the Bluetooth queue. The injected endpoint permits
    /// exercising real waiters and callbacks without creating a CBPeripheral.
    func changeNotificationState(_ enabled: Bool, for uuid: String, target: ObjectIdentifier,
                                 timeout: TimeInterval = 5,
                                 isCurrent: @escaping () -> Bool,
                                 isNotifying: @escaping () -> Bool,
                                 request: @escaping (Bool) -> Void) async throws {
        let id = UUID()
        do {
            let _: Bool = try await wait("notify:\(uuid)", timeout: timeout) {
                self.notificationRequests.removeValue(forKey: uuid)
                guard !self.gattInvalidated, isCurrent() else {
                    throw MorphError.bluetoothState(.unavailable)
                }
                if isNotifying() == enabled {
                    self.resolve("notify:\(uuid)", true)
                    return
                }
                self.notificationRequests[uuid] = NotificationRequest(
                    id: id, sessionID: self.sessionID, target: target, enabled: enabled)
                request(enabled)
            }
        } catch {
            try? await onQueue {
                if self.notificationRequests[uuid]?.id == id {
                    self.notificationRequests.removeValue(forKey: uuid)
                }
            }
            throw error
        }
    }

    func notificationStateDidChange(for uuid: String, target: ObjectIdentifier, isNotifying: Bool, error: Error?) {
        guard let request = notificationRequests[uuid], request.sessionID == sessionID,
              request.target == target, !gattInvalidated else { return }
        if let error {
            notificationRequests.removeValue(forKey: uuid)
            fail("notify:\(uuid)", Self.failure("Subscription failed", error))
        } else if isNotifying == request.enabled {
            notificationRequests.removeValue(forKey: uuid)
            resolve("notify:\(uuid)", true)
        }
        // A late callback for the opposite transition cannot confirm this one.
        // Keep waiting for the requested state, with the existing finite timeout.
    }

    private func send(_ type: UInt8, payload: Data = Data()) async throws {
        try await onQueue { self.mailbox = self.mailbox.filter { !$0.key.hasPrefix("msg:") } }
        for fragment in fragmentMessage(type: type, payload: payload) {
            try await write(fragment, to: CharUUID.auth)
        }
    }

    private func message(_ type: UInt8, timeout: TimeInterval) async throws -> Data {
        try await wait("msg:\(type)", timeout: timeout) {}
    }

    // MARK: - Reads and writes

    private func readByte(_ uuid: String) async throws -> UInt8 {
        guard let byte = try await read(uuid).first else {
            throw MorphError.protocolError("Empty value from \(uuid)")
        }
        return byte
    }

    private func readWord(_ uuid: String) async throws -> Int {
        guard let word = readLE16(try await read(uuid)) else {
            throw MorphError.protocolError("Short value from \(uuid)")
        }
        return word
    }

    private func read(_ uuid: String) async throws -> Data {
        try await wait("read:\(uuid)", timeout: 5) {
            self.peripheral?.readValue(for: try self.characteristic(uuid))
        }
    }

    private func readAttribute(_ attribute: UInt16) async throws -> Data {
        let key = "attr:\(attribute)"
        try await onQueue { self.mailbox.removeValue(forKey: key) }
        for fragment in buildAttributeRead(attribute) {
            try await writeControl(fragment, to: CharUUID.attribute)
        }
        return try await wait(key, timeout: 2) {}
    }

    private func writeAttribute(_ attribute: UInt16, value: Data) async throws {
        let key = "ack:\(attribute)"
        try await onQueue { self.mailbox.removeValue(forKey: key) }
        for fragment in buildAttributeWrite(attribute, value: value) {
            try await writeControl(fragment, to: CharUUID.attribute)
        }
        let status: UInt8 = try await wait(key, timeout: 3) {}
        guard status == 0 else {
            throw MorphError.protocolError("The lamp refused attribute 0x\(String(attribute, radix: 16)) with status \(status).")
        }
        // The acknowledgement is certain. A report of the change is possibly not, so do not wait for one.
        try await onQueue { self.updateLive { $0.apply(attribute: attribute, value: value) } }
    }

    /// A control write, kept `minWriteGap` behind the previous one.
    private func writeControl(_ data: Data, to uuid: String) async throws {
        let delay = try await onQueue { Limits.minWriteGap - Date().timeIntervalSince(self.lastControlWrite) }
        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        try await write(data, to: uuid)
        try await onQueue { self.lastControlWrite = Date() }
    }

    private func write(_ data: Data, to uuid: String) async throws {
        // Use the write mode that the characteristic declares. This lamp
        // declares only write-without-response, but other models can differ.
        let acknowledged = try await onQueue { try self.characteristic(uuid).properties.contains(.write) }
        if acknowledged {
            let _: Bool = try await wait("write:\(uuid)", timeout: 5) {
                self.peripheral?.writeValue(data, for: try self.characteristic(uuid), type: .withResponse)
            }
            return
        }
        let _: Bool = try await wait("ready", timeout: 3) {
            if self.peripheral?.canSendWriteWithoutResponse == true { self.resolve("ready", true) }
        }
        try await onQueue {
            self.peripheral?.writeValue(data, for: try self.characteristic(uuid), type: .withoutResponse)
        }
    }

    private func characteristic(_ uuid: String) throws -> CBCharacteristic {
        guard !gattInvalidated else { throw MorphError.bluetoothState(.unavailable) }
        guard let c = chars[CBUUID(string: uuid)] else {
            throw MorphError.bluetooth("The lamp does not have characteristic \(uuid).")
        }
        return c
    }

    // MARK: - Waiters

    @discardableResult
    private func onQueue<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }

    func wait<T>(_ key: String, timeout: TimeInterval, _ start: @escaping () throws -> Void) async throws -> T {
        let id = UUID()
        let cancellation = CancellationFlag()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                queue.async {
                guard !cancellation.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                // One waiter for each key. A replaced waiter must not wait forever.
                self.fail(key, MorphError.protocolError("A second wait for \(key) replaced this one."))
                self.pending[key] = Pending(
                    id: id,
                    resolve: { value in
                        if let typed = value as? T {
                            continuation.resume(returning: typed)
                        } else {
                            continuation.resume(throwing: MorphError.protocolError("Unexpected value for \(key)"))
                        }
                    },
                    reject: { continuation.resume(throwing: $0) }
                )
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    if self.pending[key]?.id == id { self.fail(key, MorphError.timeout(key)) }
                }
                if let early = self.mailbox.removeValue(forKey: key) {
                    self.resolve(key, early)
                    return
                }
                do { try start() } catch { self.fail(key, error) }
                }
            }
        }, onCancel: {
            cancellation.cancel()
            self.queue.async {
                if self.pending[key]?.id == id { self.fail(key, CancellationError()) }
            }
        })
    }

    private func resolve(_ key: String, _ value: Any) {
        pending.removeValue(forKey: key)?.resolve(value)
    }

    /// Resolve the waiter, or keep the value for a waiter that registers later.
    private func deliver(_ key: String, _ value: Any) {
        if pending[key] != nil { resolve(key, value) } else { mailbox[key] = value }
    }

    private func fail(_ key: String, _ error: Error) {
        pending.removeValue(forKey: key)?.reject(error)
    }

    private func requirePoweredOn() throws {
        switch central?.state {
        case .poweredOn: return
        case .poweredOff: throw MorphError.bluetoothState(.poweredOff)
        case .unauthorized: throw MorphError.bluetoothState(.permissionDenied)
        case .unsupported: throw MorphError.bluetoothState(.unsupported)
        default: throw MorphError.bluetoothState(.unavailable)
        }
    }

    private func stopScan() {
        if central?.state == .poweredOn { central.stopScan() }
        scanID = nil
        scanTarget = nil
        scanResults = nil
    }

    /// Exact serial matching checks both names. The advertisement can contain a
    /// different/stale local name while CoreBluetooth remembers the serial.
    static func matchesSerial(_ serial: String, advertisedName: String?, peripheralName: String?) -> Bool {
        let normalized = serial.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty else { return false }
        return [advertisedName, peripheralName].contains {
            $0?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == normalized
        }
    }

    static func isExpectedPeripheral(id: UUID, name: String?, serial: String, cachedId: UUID?) -> Bool {
        id == cachedId || matchesSerial(serial, advertisedName: nil, peripheralName: name)
    }

    /// Runs only on the Bluetooth queue. Dropping every characteristic and
    /// early reply is important after a Bluetooth reset or ended connection.
    private func clearSession(_ error: Error, preserveReadinessWait: Bool = false,
                              disconnected: Bool = false, notifyDisconnect: Bool = true,
                              preservePeripheral: Bool = false, preserveDisconnectWait: Bool = false) {
        let hadConnection = authenticated
        authenticated = false
        sessionID = UUID()
        gattInvalidated = true
        cache = nil
        stopScan()
        if !preservePeripheral {
            peripheral?.delegate = nil
            peripheral = nil
        }
        chars.removeAll()
        notificationRequests.removeAll()
        pendingServices = 0
        assembler = MessageAssembler()
        mailbox.removeAll()
        let waiters = pending
        pending = pending.filter {
            (preserveReadinessWait && $0.key == "state") || (preserveDisconnectWait && $0.key == "disconnect")
        }
        for (key, waiter) in waiters {
            if preserveReadinessWait && key == "state" { continue }
            if preserveDisconnectWait && key == "disconnect" { continue }
            if disconnected && key == "disconnect" { waiter.resolve(true) }
            else { waiter.reject(error) }
        }
        if hadConnection && notifyDisconnect { onDisconnect?() }
    }

    // MARK: - CBCentralManagerDelegate

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard self.central === central else { return }
        managerStateDidChange(central.state)
    }

    // Internal so tests can exercise actual waiter invalidation without
    // creating a CBCentralManager or asking for Bluetooth permission.
    func managerStateDidChange(_ state: CBManagerState) {
        switch state {
        case .poweredOn:
            resolve("state", true)
        case .unauthorized:
            runtimeID = UUID()
            clearSession(MorphError.bluetoothState(.permissionDenied))
        case .poweredOff:
            runtimeID = UUID()
            clearSession(MorphError.bluetoothState(.poweredOff))
        case .unsupported:
            runtimeID = UUID()
            clearSession(MorphError.bluetoothState(.unsupported))
        case .unknown, .resetting:
            // Apple invalidates peripheral objects below poweredOff. Existing
            // operations fail promptly; initial readiness may still recover.
            runtimeID = UUID()
            clearSession(MorphError.bluetoothState(.unavailable), preserveReadinessWait: true)
        default:
            runtimeID = UUID()
            clearSession(MorphError.bluetoothState(.unavailable))
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard self.central === central, central.state == .poweredOn, scanID != nil else { return }
        let advertised = advertisementData[CBAdvertisementDataLocalNameKey] as? String

        if scanResults != nil, let name = advertised ?? peripheral.name {
            let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []).map(\.uuidString)
            scanResults?[peripheral.identifier] = DiscoveredLamp(
                id: peripheral.identifier, name: name, rssi: RSSI.intValue, services: services)
        }
        // The lamp advertises its serial number as its name.
        if let target = scanTarget,
           Self.matchesSerial(target, advertisedName: advertised, peripheralName: peripheral.name) {
            stopScan()
            resolve("find", ConnectionTarget(peripheral: peripheral, runtimeID: runtimeID))
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.central === central, self.peripheral === peripheral else { return }
        resolve("connect", true)
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard self.central === central, self.peripheral === peripheral else { return }
        fail("connect", MorphError.bluetooth("Connection failed: \(error?.localizedDescription ?? "unknown error")"))
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard self.central === central, self.peripheral === peripheral else { return }
        log("Disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")")
        connectionDidEnd()
    }

    /// Queue-only counterpart of the delegate callback, shared with no-radio tests.
    func connectionDidEnd() {
        clearSession(MorphError.bluetoothState(.disconnected), disconnected: true)
    }

    // MARK: - CBPeripheralDelegate

    public func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard self.peripheral === peripheral else { return }
        let usedServices = Set(chars.values.compactMap { characteristic -> CBUUID? in
            guard let uuid = characteristic.service?.uuid, Self.lampServices.contains(uuid) else { return nil }
            return uuid
        })
        guard invalidateServices(Set(invalidatedServices.map(\.uuid)), usedServices: usedServices) else { return }
        // Keep the peripheral and delegate until didDisconnect can resolve the
        // bounded cancellation waiter. No old characteristic remains usable.
        if central?.state == .poweredOn { central.cancelPeripheralConnection(peripheral) }
    }

    /// Queue-only invalidation seam; no-radio tests pass service IDs rather than
    /// manufacturing CoreBluetooth peripheral/service objects.
    @discardableResult
    func invalidateServices(_ invalidatedServices: Set<CBUUID>, usedServices: Set<CBUUID>) -> Bool {
        guard !gattInvalidated, !invalidatedServices.isEmpty,
              pending["discover"] != nil || !invalidatedServices.isDisjoint(with: usedServices) else { return false }
        Self.diagnostics.notice("GATT services changed; invalidating the current session")
        runtimeID = UUID()
        clearSession(MorphError.bluetoothState(.unavailable),
                     preservePeripheral: true, preserveDisconnectWait: true)
        return true
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard self.peripheral === peripheral, pending["discover"] != nil else { return }
        let services = peripheral.services ?? []
        guard error == nil, !services.isEmpty else {
            fail("discover", MorphError.bluetooth("Service discovery failed: \(error?.localizedDescription ?? "no services")"))
            return
        }
        pendingServices = services.count
        services.forEach { peripheral.discoverCharacteristics(nil, for: $0) }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard self.peripheral === peripheral, pending["discover"] != nil else { return }
        if let error {
            fail("discover", Self.failure("Characteristic discovery failed", error))
            return
        }
        for c in service.characteristics ?? [] {
            chars[c.uuid] = c
        }
        pendingServices -= 1
        if pendingServices == 0 { resolve("discover", true) }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, chars[characteristic.uuid] === characteristic else { return }
        notificationStateDidChange(for: characteristic.uuid.uuidString,
                                   target: ObjectIdentifier(characteristic),
                                   isNotifying: characteristic.isNotifying, error: error)
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, chars[characteristic.uuid] === characteristic else { return }
        let key = "write:\(characteristic.uuid.uuidString)"
        if let error {
            fail(key, Self.failure("Write failed", error))
        } else {
            resolve(key, true)
        }
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard self.peripheral === peripheral else { return }
        resolve("ready", true)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, chars[characteristic.uuid] === characteristic else { return }
        let uuid = characteristic.uuid.uuidString
        if let error {
            fail("read:\(uuid)", Self.failure("Read failed", error))
            return
        }
        guard let data = characteristic.value else { return }

        switch uuid {
        case CharUUID.auth:
            if let message = assembler.push(data) {
                log("← message 0x\(String(message.type, radix: 16)) (\(message.payload.count) bytes)")
                deliver("msg:\(message.type)", message.payload)
            }
        case CharUUID.attribute:
            switch decodeAttributeNotification(data) {
            case .value(let attribute, let value):
                if let value { updateLive { $0.apply(attribute: attribute, value: value) } }
                deliver("attr:\(attribute)", value ?? Data())
            case .ack(let attribute, let status):
                deliver("ack:\(attribute)", status)
            case .report(let attribute, let value):
                log("← attribute 0x\(String(attribute, radix: 16)) changed to \(value.hex)")
                updateLive { $0.apply(attribute: attribute, value: value) }
            case nil:
                log("← attribute channel: \(data.hex)")
            }
        default:
            // A read reply and a notification arrive here in the same way.
            updateLive { $0.apply(characteristic: uuid, value: data) }
            resolve("read:\(uuid)", data)
        }
    }

    /// The error for a failed operation on a characteristic that discovery found.
    ///
    /// These ATT replies can come from an unusable session or lamp resources;
    /// they do not by themselves prove that the lamp firmware requires a reset.
    static func failure(_ operation: String, _ error: Error) -> MorphError {
        let error = error as NSError
        let stuck: [CBATTError.Code] = [.attributeNotFound, .insufficientResources]
        if error.domain == CBATTErrorDomain {
            let phase: String
            switch operation {
            case "Read failed": phase = "read"
            case "Write failed": phase = "write"
            case "Subscription failed": phase = "subscription"
            case "Characteristic discovery failed": phase = "characteristic-discovery"
            default: phase = "other"
            }
            Self.diagnostics.error("ATT request failed: phase=\(phase, privacy: .public) code=\(error.code, privacy: .public)")
        }
        if error.domain == CBATTErrorDomain, stuck.contains(where: { $0.rawValue == error.code }) {
            return .lampStuck("\(operation.lowercased()): \(error.localizedDescription)")
        }
        return .bluetooth("\(operation): \(error.localizedDescription)")
    }

    private func updateLive(_ change: (inout LampState) -> Bool) {
        guard var state = cache, change(&state) else { return }
        cache = state
        onStateChange?(state)
    }
}
