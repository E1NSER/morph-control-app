import XCTest
import MorphCore
@testable import MorphServices

@MainActor
final class ConnectionRecoveryTests: XCTestCase {
    private func makeController(_ fake: FakeTransport, keepAlive: Bool = true, sync: Bool = false,
                                probeAfter: TimeInterval = 0, stableAfter: TimeInterval = 0.05,
                                factory: (() -> LampTransport)? = nil) -> LampController {
        LampController(store: MemoryCredentialStore(sampleCredentials()), transportFactory: factory ?? { fake },
                       keepConnectionAlive: keepAlive, syncPowerWithMac: sync,
                       commandMinimumGap: .milliseconds(1), effectTickSeconds: 0.01,
                       recoveryRetrySeconds: 0.02, recoveryDropDelay: 0.01,
                       recoveryStableSeconds: stableAfter, inactivityProbeSeconds: probeAfter,
                       inactivityProbeTimeout: 0.02)
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(condition(), "Expected recovery transition did not occur", file: file, line: line)
    }

    func testEarlyWakeFailureHasOneDelayedRetryAndPreservesOffState() async {
        let fake = FakeTransport()
        fake.connectError = MorphError.bluetoothState(.poweredOff)
        let controller = makeController(fake)
        controller.resumeAfterWake()
        await waitUntil { fake.connectCalls == 1 && controller.connection == .failed }
        fake.connectError = nil
        await waitUntil { fake.connectCalls == 2 && controller.connection == .connected }
        XCTAssertFalse(controller.state?.power ?? true)
        XCTAssertTrue(fake.actions.isEmpty)
        await controller.releaseConnection()
    }

    func testGenuineWakePowerSyncRunsOnceAfterRetryButPanelDoesNotCreateIt() async {
        let fake = FakeTransport()
        fake.connectError = MorphError.timeout("Synthetic early wake")
        let controller = makeController(fake, sync: true)
        controller.resumeAfterWake()
        controller.panelOpened()
        await waitUntil { fake.connectCalls == 1 && controller.connection == .failed }
        fake.connectError = nil
        await waitUntil { fake.actions == [.power(true)] }
        XCTAssertEqual(fake.connectCalls, 2)
        await controller.releaseConnection()
        let panelFake = FakeTransport()
        let panel = makeController(panelFake, sync: true)
        panel.panelOpened()
        await waitUntil { panel.connection == .connected }
        XCTAssertTrue(panelFake.actions.isEmpty)
        XCTAssertFalse(panel.state?.power ?? true)
        await panel.releaseConnection()
    }

    func testPanelCanRetryFailedStateInsteadOfLeavingAppLockedOut() async {
        let fake = FakeTransport()
        fake.connectError = MorphError.protocolError("Synthetic rejected handshake")
        let controller = makeController(fake, sync: true)
        await controller.connect()
        XCTAssertEqual(controller.connection, .failed)
        fake.connectError = nil
        controller.panelOpened()
        await waitUntil { fake.connectCalls == 2 && controller.connection == .connected }
        XCTAssertTrue(fake.actions.isEmpty)
        await controller.releaseConnection()
    }

    func testRecoveryStopsAfterTwoAttemptsAndUnlockDoesNotResetExhaustedBudget() async {
        let fake = FakeTransport()
        fake.connectError = MorphError.timeout("Synthetic missing lamp")
        let controller = makeController(fake)
        controller.resumeAfterWake()
        await waitUntil { fake.connectCalls == 2 && controller.connection == .failed && !controller.isBusy }
        for _ in 0..<4 { controller.recoverAfterInactivity() }
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(fake.connectCalls, 2)
        fake.connectError = nil
        controller.panelOpened()
        await waitUntil { fake.connectCalls == 3 && controller.connection == .connected }
        await controller.releaseConnection()
    }

    func testNewRealWakeRetriesTransientFailureEvenIfSleepNotificationWasMissed() async {
        let fake = FakeTransport()
        fake.connectError = MorphError.timeout("Synthetic missing lamp")
        let controller = makeController(fake)
        controller.resumeAfterWake()
        await waitUntil { fake.connectCalls == 2 && controller.connection == .failed && !controller.isBusy }
        fake.connectError = nil
        controller.resumeAfterWake()
        await waitUntil { fake.connectCalls == 3 && controller.connection == .connected }
        XCTAssertTrue(fake.actions.isEmpty)
        await controller.releaseConnection()
    }

    func testPermissionProtocolOccupiedAndStuckErrorsAreNotAutomaticallyRepeated() async {
        let errors: [Error] = [MorphError.bluetoothState(.permissionDenied), MorphError.bluetoothState(.unsupported),
                               MorphError.bluetoothState(.sessionOccupied), MorphError.protocolError("Synthetic invalid protocol"),
                               MorphError.lampStuck("Synthetic stuck lamp")]
        for error in errors {
            let fake = FakeTransport()
            fake.connectError = error
            let controller = makeController(fake)
            controller.resumeAfterWake()
            await waitUntil { controller.connection == .failed && !controller.isBusy }
            controller.recoverAfterInactivity()
            controller.resumeAfterWake()
            try? await Task.sleep(nanoseconds: 45_000_000)
            XCTAssertEqual(fake.connectCalls, 1)
            XCTAssertNotNil(controller.errorMessage)
            await controller.releaseConnection()
        }
    }

    func testManualReleaseForgetAndSleepCancelPendingRetry() async throws {
        for operation in 0...2 {
            let fake = FakeTransport()
            fake.connectError = MorphError.timeout("Synthetic missing lamp")
            let controller = makeController(fake)
            controller.resumeAfterWake()
            await waitUntil { fake.connectCalls == 1 && controller.connection == .failed }
            if operation == 0 { await controller.releaseConnection() }
            else if operation == 1 { try await controller.forgetLamp() }
            else { await controller.suspendForSleep() }
            fake.connectError = nil
            controller.recoverAfterInactivity()
            try? await Task.sleep(nanoseconds: 60_000_000)
            XCTAssertEqual(fake.connectCalls, 1)
            XCTAssertTrue(fake.actions.isEmpty)
        }
    }

    func testUnexpectedDropReconnectsWithoutPowerOnOrReplayingQueuedSlider() async {
        let old = FakeTransport()
        let fresh = FakeTransport()
        var creations = 0
        let controller = makeController(old, sync: true, factory: {
            creations += 1
            return creations == 1 ? old : fresh
        })
        await controller.connect()
        old.applyDelay = 5_000_000_000
        controller.setBrightness(10)
        await waitUntil { old.actions == [.brightness(10)] }
        controller.setBrightness(90)
        controller.setKelvin(6000)
        old.onDisconnect?()
        await waitUntil { fresh.connectCalls == 1 && controller.connection == .connected }
        XCTAssertEqual(old.disconnectCalls, 1)
        XCTAssertEqual(old.actions, [.brightness(10)])
        XCTAssertTrue(fresh.actions.isEmpty)
        XCTAssertFalse(controller.state?.power ?? true)
        XCTAssertNil(controller.activeLightEffect)
        await controller.releaseConnection()
    }

    func testFlappingSuccessesDoNotGiveEveryDropANewBudget() async {
        let fake = FakeTransport()
        let controller = makeController(fake, stableAfter: 1)
        await controller.connect()
        for expected in 2...3 {
            fake.onDisconnect?()
            await waitUntil { fake.connectCalls == expected && controller.connection == .connected }
        }
        fake.onDisconnect?()
        try? await Task.sleep(nanoseconds: 70_000_000)
        XCTAssertEqual(fake.connectCalls, 3)
        XCTAssertEqual(controller.connection, .disconnected)
        controller.panelOpened()
        await waitUntil { fake.connectCalls == 4 && controller.connection == .connected }
        await controller.releaseConnection()
    }

    func testStableConnectionAllowsANewRecoveryBudget() async {
        let fake = FakeTransport()
        let controller = makeController(fake, stableAfter: 0.03)
        await controller.connect()
        for expected in 2...3 {
            fake.onDisconnect?()
            await waitUntil { fake.connectCalls == expected && controller.connection == .connected }
        }
        try? await Task.sleep(nanoseconds: 40_000_000)
        fake.onDisconnect?()
        await waitUntil { fake.connectCalls == 4 && controller.connection == .connected }
        await controller.releaseConnection()
    }

    func testConnectedProbeIsDeduplicatedAndNeverPowersOnLamp() async {
        let fake = FakeTransport()
        let controller = makeController(fake, sync: true)
        await controller.connect()
        for _ in 0..<4 { controller.recoverAfterInactivity() }
        await waitUntil { fake.refreshCalls.count == 1 && !controller.isBusy }
        XCTAssertEqual(fake.connectCalls, 1)
        XCTAssertEqual(fake.disconnectCalls, 0)
        XCTAssertTrue(fake.actions.isEmpty)
        XCTAssertFalse(controller.state?.power ?? true)
        await controller.releaseConnection()
    }

    func testRecentConnectionAndBusyControllerSkipProbe() async {
        let fake = FakeTransport()
        let controller = makeController(fake, probeAfter: 0.03)
        await controller.connect()
        controller.recoverAfterInactivity()
        await Task.yield()
        XCTAssertTrue(fake.refreshCalls.isEmpty)
        fake.applyDelay = 50_000_000
        controller.setBrightness(40)
        await waitUntil { fake.actions == [.brightness(40)] }
        try? await Task.sleep(nanoseconds: 35_000_000)
        controller.recoverAfterInactivity()
        XCTAssertTrue(fake.refreshCalls.isEmpty)
        await controller.releaseConnection()
    }

    func testFailedStaleConnectedProbeClosesOldSessionBeforeRecovery() async {
        let old = FakeTransport()
        old.refreshError = MorphError.bluetoothState(.disconnected)
        let fresh = FakeTransport()
        var creations = 0
        let controller = makeController(old, sync: true, factory: {
            creations += 1
            XCTAssertTrue(creations == 1 || old.disconnectCalls == 1)
            return creations == 1 ? old : fresh
        })
        await controller.connect()
        controller.recoverAfterInactivity()
        await waitUntil { fresh.connectCalls == 1 && controller.connection == .connected }
        XCTAssertEqual(old.refreshCalls, [false])
        XCTAssertEqual(old.disconnectCalls, 1)
        XCTAssertTrue(fresh.actions.isEmpty)
        XCTAssertFalse(controller.state?.power ?? true)
        await controller.releaseConnection()
    }

    func testStalledProbeHasDeadlineAndRecoversThroughFreshTransport() async {
        let old = FakeTransport()
        old.refreshDelay = 5_000_000_000
        let fresh = FakeTransport()
        var creations = 0
        let controller = makeController(old, factory: {
            creations += 1
            return creations == 1 ? old : fresh
        })
        await controller.connect()
        controller.recoverAfterInactivity()
        await waitUntil { fresh.connectCalls == 1 && controller.connection == .connected }
        XCTAssertEqual(old.disconnectCalls, 1)
        XCTAssertTrue(fresh.actions.isEmpty)
        await controller.releaseConnection()
    }

    func testQueuedProbeCannotTurnAMacroReadFailureIntoAutomaticRecovery() async {
        for startEffect in [false, true] {
            let fake = FakeTransport()
            fake.refreshError = MorphError.timeout("Synthetic attribute read failure")
            let controller = makeController(fake)
            await controller.connect()
            controller.recoverAfterInactivity()
            if startEffect { await controller.startLightEffect(.morph) }
            else { await controller.restoreAutomaticLighting() }
            await waitUntil { !controller.isBusy }
            try? await Task.sleep(nanoseconds: 65_000_000)
            XCTAssertEqual(fake.connectCalls, 1)
            XCTAssertEqual(controller.connection, .failed)
            XCTAssertNil(controller.activeLightEffect)
            XCTAssertFalse(controller.isRestoringAutomaticLighting)
        }
    }

    func testRealWakeReplacesConnectedSessionWhenSleepNotificationWasMissed() async {
        let fake = FakeTransport()
        let controller = makeController(fake)
        await controller.connect()
        controller.resumeAfterWake()
        await waitUntil { fake.connectCalls == 2 && controller.connection == .connected }
        XCTAssertEqual(fake.disconnectCalls, 1)
        XCTAssertTrue(fake.actions.isEmpty)
        XCTAssertFalse(controller.state?.power ?? true)
        await controller.releaseConnection()
    }

    func testDelayedPowerOffFailureAfterEarlyWakeDoesNotReconnectOrPowerOn() async {
        let fake = FakeTransport()
        fake.applyDelay = 30_000_000
        fake.applyError = MorphError.bluetooth("Synthetic delayed off failure")
        let controller = makeController(fake, sync: true)
        await controller.connect()
        let sleep = Task { await controller.suspendForSleep() }
        await waitUntil { fake.actions == [.power(false)] }
        controller.resumeAfterWake()
        await sleep.value
        await waitUntil { !controller.isBusy }
        try? await Task.sleep(nanoseconds: 65_000_000)
        XCTAssertEqual(fake.connectCalls, 1)
        XCTAssertEqual(fake.actions, [.power(false)])
        XCTAssertEqual(controller.connection, .failed)
        XCTAssertNotNil(controller.errorMessage)
        await controller.releaseConnection()
    }
}
