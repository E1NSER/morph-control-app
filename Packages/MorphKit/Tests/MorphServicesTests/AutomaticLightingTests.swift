import XCTest
import MorphCore
@testable import MorphServices

@MainActor
final class AutomaticLightingTests: XCTestCase {
    private let macro: [LampAction] = [.preset(nil), .autoBrightness(true), .daylight(true)]

    private func makeController(_ fake: FakeTransport, syncPower: Bool = false,
                                keepAlive: Bool = true) -> LampController {
        LampController(store: MemoryCredentialStore(sampleCredentials()), transportFactory: { fake },
                       keepConnectionAlive: keepAlive, syncPowerWithMac: syncPower)
    }

    private func workingLamp() -> FakeTransport {
        let fake = FakeTransport()
        fake.state.preset = .precision
        fake.applyHandler = { [weak fake] action in
            guard let fake else { return }
            switch action {
            case .preset(let preset): fake.state.preset = preset
            case .autoBrightness(let value): fake.state.autoBrightness = value
            case .daylight(let value): fake.state.daylight = value
            case .power(let value): fake.state.power = value
            default: break
            }
        }
        return fake
    }

    private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate(), ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(predicate(), "Expected lighting transition did not occur", file: file, line: line)
    }

    func testRestoreClearsProfileEnablesBrightnessThenDaylightAndStrictlyRefreshes() async {
        let fake = workingLamp()
        let controller = makeController(fake)
        await controller.connect()
        await controller.restoreAutomaticLighting()
        XCTAssertEqual(fake.actions, macro)
        XCTAssertEqual(fake.refreshCalls, [true])
        XCTAssertEqual(fake.events.last, .refresh(true))
        XCTAssertEqual(controller.state?.daylight, true)
        XCTAssertEqual(controller.state?.autoBrightness, true)
        XCTAssertNil(controller.state?.preset)
        XCTAssertFalse(controller.isRestoringAutomaticLighting)
        XCTAssertFalse(controller.isBusy)
        XCTAssertNil(controller.errorMessage)
        let starts = fake.applyStarts + fake.refreshStarts
        for (completion, nextStart) in zip(fake.applyCompletions, starts.dropFirst()) {
            XCTAssertGreaterThanOrEqual(completion.duration(to: nextStart), .milliseconds(145))
        }
        await controller.releaseConnection()
    }

    func testRestoreDoesNotTurnLampOnChangeMovementOrConnectionPreferences() async {
        for movement in [false, true] {
            let fake = workingLamp()
            fake.state.power = false
            fake.state.movement = movement
            let controller = makeController(fake, syncPower: true, keepAlive: false)
            await controller.connect()
            await controller.restoreAutomaticLighting()
            XCTAssertFalse(controller.state?.power ?? true)
            XCTAssertEqual(controller.state?.movement, movement)
            XCTAssertTrue(controller.syncPowerWithMac)
            XCTAssertFalse(controller.keepConnectionAlive)
            XCTAssertFalse(fake.actions.contains { if case .power = $0 { return true }; return false })
            XCTAssertFalse(fake.actions.contains { if case .movement = $0 { return true }; return false })
            await controller.releaseConnection()
        }
    }

    func testRestoreDropsPendingSliderAndProfileValuesAndBlocksNewManualCommands() async {
        let fake = workingLamp()
        fake.applyDelay = 30_000_000
        let controller = makeController(fake)
        await controller.connect()
        controller.setBrightness(10)
        await waitUntil { fake.actions == [.brightness(10)] }
        controller.setBrightness(90)
        controller.setKelvin(4100)
        controller.setPreset(.relax)
        let restore = Task { await controller.restoreAutomaticLighting() }
        await waitUntil { controller.isRestoringAutomaticLighting }
        controller.setBrightness(55)
        controller.setKelvin(6000)
        controller.setPreset(.study)
        controller.setDaylight(false)
        controller.setMovement(false)
        await restore.value
        XCTAssertEqual(fake.actions, [.brightness(10)] + macro)
        XCTAssertEqual(fake.maximumActiveApplies, 1)
        XCTAssertEqual(fake.refreshCalls, [true])
        await controller.releaseConnection()
    }

    func testDoubleClickRunsOnlyOneRestoreSequence() async {
        let fake = workingLamp()
        let controller = makeController(fake)
        await controller.connect()
        async let first: Void = controller.restoreAutomaticLighting()
        async let second: Void = controller.restoreAutomaticLighting()
        _ = await (first, second)
        XCTAssertEqual(fake.actions, macro)
        XCTAssertEqual(fake.refreshCalls, [true])
        await controller.releaseConnection()
    }

    func testUnknownFinalDaylightIsNotReplacedByOptimisticSuccess() async {
        let fake = workingLamp()
        var unknown = fake.state
        unknown.daylight = nil
        unknown.autoBrightness = true
        unknown.preset = nil
        fake.refreshedState = unknown
        let controller = makeController(fake)
        await controller.connect()
        await controller.restoreAutomaticLighting()
        XCTAssertNil(controller.state?.daylight)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertEqual(controller.connection, .connected)
        XCTAssertFalse(controller.isRestoringAutomaticLighting)
        XCTAssertFalse(controller.isBusy)
        await controller.releaseConnection()
    }

    func testUnchangedLampStateDoesNotProduceOptimisticSuccess() async {
        let fake = FakeTransport()
        let controller = makeController(fake)
        await controller.connect()
        await controller.restoreAutomaticLighting()
        XCTAssertEqual(fake.actions, macro)
        XCTAssertEqual(controller.state?.daylight, false)
        XCTAssertEqual(controller.state?.autoBrightness, false)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertFalse(controller.isRestoringAutomaticLighting)
        await controller.releaseConnection()
    }

    func testUnconfirmedPresetDoesNotProduceSuccess() async {
        let fake = workingLamp()
        var unconfirmed = fake.state
        unconfirmed.daylight = true
        unconfirmed.autoBrightness = true
        unconfirmed.preset = .study
        fake.refreshedState = unconfirmed
        let controller = makeController(fake)
        await controller.connect()
        await controller.restoreAutomaticLighting()
        XCTAssertEqual(controller.state?.preset, .study)
        XCTAssertNotNil(controller.errorMessage)
        await controller.releaseConnection()
    }

    func testModeWriteFailureStopsRemainingMacroAndTearsDown() async {
        let fake = workingLamp()
        fake.applyHandler = { action in
            if action == .autoBrightness(true) { throw MorphError.bluetooth("Synthetic mode failure") }
        }
        let controller = makeController(fake)
        await controller.connect()
        await controller.restoreAutomaticLighting()
        await waitUntil { !controller.isBusy }
        XCTAssertEqual(fake.actions, [.preset(nil), .autoBrightness(true)])
        XCTAssertTrue(fake.refreshCalls.isEmpty)
        XCTAssertEqual(controller.connection, .failed)
        XCTAssertNil(controller.state)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertFalse(controller.isRestoringAutomaticLighting)
    }

    func testFinalStrictRefreshFailureDoesNotLeaveRestoringOrConfirmedState() async {
        let fake = workingLamp()
        fake.refreshError = MorphError.protocolError("Synthetic missing mode reply")
        let controller = makeController(fake)
        await controller.connect()
        await controller.restoreAutomaticLighting()
        await waitUntil { !controller.isBusy }
        XCTAssertEqual(fake.actions, macro)
        XCTAssertEqual(fake.refreshCalls, [true])
        XCTAssertEqual(controller.connection, .failed)
        XCTAssertNil(controller.state)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertFalse(controller.isRestoringAutomaticLighting)
    }

    func testManualReleaseCancelsRestoreBeforeAnyLaterMacroWrites() async {
        let fake = workingLamp()
        fake.applyDelay = 5_000_000_000
        let controller = makeController(fake)
        await controller.connect()
        let restore = Task { await controller.restoreAutomaticLighting() }
        await waitUntil { fake.actions == [.preset(nil)] }
        await controller.releaseConnection()
        await restore.value
        XCTAssertEqual(fake.actions, [.preset(nil)])
        XCTAssertTrue(fake.refreshCalls.isEmpty)
        XCTAssertEqual(controller.connection, .disconnected)
        XCTAssertTrue(controller.isConnectionPaused)
        XCTAssertFalse(controller.isRestoringAutomaticLighting)
        XCTAssertFalse(controller.isBusy)
    }

    func testSleepCancelsRestoreWithoutPowerSyncAndNoLaterModeWrites() async {
        let fake = workingLamp()
        fake.applyDelay = 5_000_000_000
        let controller = makeController(fake)
        await controller.connect()
        let restore = Task { await controller.restoreAutomaticLighting() }
        await waitUntil { fake.actions == [.preset(nil)] }
        await controller.suspendForSleep()
        await restore.value
        XCTAssertEqual(fake.actions, [.preset(nil)])
        XCTAssertFalse(controller.isRestoringAutomaticLighting)
        XCTAssertFalse(controller.isBusy)
        XCTAssertNil(controller.errorMessage)
    }

    func testPowerOffReplacesRestoreButItsFinalOffCommandIsNotCancelledByOldRestoreWaiter() async {
        let fake = workingLamp()
        fake.applyDelay = 30_000_000
        let controller = makeController(fake, syncPower: true)
        await controller.connect()
        let restore = Task { await controller.restoreAutomaticLighting() }
        await waitUntil { fake.actions == [.preset(nil)] }
        await controller.prepareForPowerOff()
        await restore.value
        XCTAssertEqual(fake.actions, [.preset(nil), .power(false)])
        XCTAssertTrue(fake.refreshCalls.isEmpty)
        XCTAssertEqual(fake.events.suffix(3), [.apply(.power(false)), .completed(.power(false)), .disconnect])
        XCTAssertFalse(controller.isRestoringAutomaticLighting)
        XCTAssertFalse(controller.isBusy)
    }

    func testForgetDuringRestoreRemovesCredentialsAndCancelsFurtherWrites() async throws {
        let fake = workingLamp()
        fake.applyDelay = 5_000_000_000
        let controller = makeController(fake)
        await controller.connect()
        let restore = Task { await controller.restoreAutomaticLighting() }
        await waitUntil { fake.actions == [.preset(nil)] }
        try await controller.forgetLamp()
        await restore.value
        XCTAssertEqual(fake.actions, [.preset(nil)])
        XCTAssertEqual(controller.connection, .unpaired)
        XCTAssertFalse(controller.hasCredentials)
        XCTAssertFalse(controller.isRestoringAutomaticLighting)
        XCTAssertFalse(controller.isBusy)
    }

    func testDisconnectDuringRestoreStopsMacroAndPreservesDisconnectError() async {
        let fake = workingLamp()
        fake.applyDelay = 5_000_000_000
        let controller = makeController(fake)
        await controller.connect()
        let restore = Task { await controller.restoreAutomaticLighting() }
        await waitUntil { fake.actions == [.preset(nil)] }
        fake.onDisconnect?()
        await restore.value
        await waitUntil { !controller.isBusy }
        XCTAssertEqual(fake.actions, [.preset(nil)])
        XCTAssertEqual(controller.connection, .disconnected)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertFalse(controller.isRestoringAutomaticLighting)
    }

    func testCancelledCallerStopsMacroAndNeverLeavesRestoringFlag() async {
        let fake = workingLamp()
        fake.applyDelay = 5_000_000_000
        let controller = makeController(fake)
        await controller.connect()
        let restore = Task { await controller.restoreAutomaticLighting() }
        await waitUntil { fake.actions == [.preset(nil)] }
        restore.cancel()
        await restore.value
        XCTAssertEqual(fake.actions, [.preset(nil)])
        XCTAssertEqual(controller.connection, .disconnected)
        XCTAssertFalse(controller.isRestoringAutomaticLighting)
        XCTAssertFalse(controller.isBusy)
    }

    func testDisconnectedRestoreDoesNotConnectOrWrite() async {
        let fake = workingLamp()
        let controller = makeController(fake)
        await controller.restoreAutomaticLighting()
        XCTAssertEqual(fake.connectCalls, 0)
        XCTAssertTrue(fake.actions.isEmpty)
        XCTAssertFalse(controller.isRestoringAutomaticLighting)
        XCTAssertFalse(controller.isBusy)
    }
}
