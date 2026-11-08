import XCTest
import MorphCore
@testable import MorphServices

@MainActor
final class MacPowerSyncTests: XCTestCase {
    private func makeController(_ fake: FakeTransport, keepAlive: Bool = true,
                                sync: Bool = true, timeout: TimeInterval = 2) -> LampController {
        LampController(store: MemoryCredentialStore(sampleCredentials()), transportFactory: { fake },
                       idleSeconds: 0.02, keepConnectionAlive: keepAlive,
                       syncPowerWithMac: sync, powerTransitionTimeout: timeout)
    }

    private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !predicate(), ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(predicate(), "Expected power transition did not occur", file: file, line: line)
    }

    func testDisabledPowerSyncNeverWritesPowerOnStartSleepOrShutdown() async {
        let fake = FakeTransport()
        let controller = makeController(fake, sync: false)
        controller.start()
        await waitUntil { controller.connection == .connected }
        await controller.suspendForSleep()
        controller.resumeAfterWake()
        await waitUntil { fake.connectCalls == 2 && controller.connection == .connected }
        await controller.prepareForPowerOff()
        XCTAssertTrue(fake.actions.isEmpty)
    }

    func testLifecyclePowerOnConnectsWithKeepAliveOffAndThenUsesIdleRelease() async {
        let fake = FakeTransport()
        let controller = makeController(fake, keepAlive: false)
        controller.start()
        controller.panelOpened()
        await waitUntil { fake.actions == [.power(true)] }
        controller.panelClosed()
        await waitUntil { fake.disconnectCalls == 1 && !controller.isBusy }
        XCTAssertEqual(fake.connectCalls, 1)
        XCTAssertFalse(controller.isConnectionPaused)
    }

    func testEnablingPowerSyncWaitsForNextLifecycleEvent() async {
        let fake = FakeTransport()
        let controller = makeController(fake, keepAlive: false, sync: false)
        controller.setSyncPowerWithMac(true)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(fake.connectCalls, 0)
        XCTAssertTrue(fake.actions.isEmpty)
        controller.start()
        await waitUntil { fake.actions == [.power(true)] }
        controller.setSyncPowerWithMac(false)
        await controller.suspendForSleep()
        XCTAssertEqual(fake.actions, [.power(true)])
    }

    func testTurningKeepAliveOffPreservesPendingLifecyclePowerOn() async {
        let fake = FakeTransport()
        let controller = makeController(fake)
        controller.start()
        controller.setKeepConnectionAlive(false)
        await waitUntil { fake.actions == [.power(true)] }
        XCTAssertEqual(fake.connectCalls, 1)
        await controller.releaseConnection()
    }

    func testTurningKeepAliveOffDuringConnectStillWritesLifecyclePowerOnOnce() async {
        let fake = FakeTransport()
        fake.connectDelay = 40_000_000
        let controller = makeController(fake)
        controller.start()
        await waitUntil { fake.connectCalls == 1 }
        controller.setKeepConnectionAlive(false)
        await waitUntil { fake.actions == [.power(true)] }
        XCTAssertEqual(fake.connectCalls, 1)
        await controller.releaseConnection()
    }

    func testTurningPowerSyncOffWhileConnectingPreventsPowerOn() async {
        let fake = FakeTransport()
        fake.connectDelay = 40_000_000
        let controller = makeController(fake)
        controller.start()
        await waitUntil { fake.connectCalls == 1 }
        controller.setSyncPowerWithMac(false)
        await waitUntil { controller.connection == .connected }
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(fake.actions.isEmpty)
        await controller.releaseConnection()
    }

    func testTurningPowerSyncOffAndOnDoesNotReviveQueuedOldPowerOn() async {
        let fake = FakeTransport()
        fake.applyDelay = 30_000_000
        let controller = makeController(fake)
        await controller.connect()
        controller.setBrightness(50)
        await waitUntil { fake.actions == [.brightness(50)] }
        controller.start()
        try? await Task.sleep(nanoseconds: 10_000_000)
        controller.setSyncPowerWithMac(false)
        controller.setSyncPowerWithMac(true)
        await waitUntil { !controller.isBusy }
        XCTAssertEqual(fake.actions, [.brightness(50)])
        await controller.releaseConnection()
    }

    func testSleepFinishesActiveWriteDropsPendingSlidersThenPowersOffBeforeDisconnect() async {
        let fake = FakeTransport()
        fake.applyDelay = 30_000_000
        let controller = makeController(fake)
        await controller.connect()
        controller.setBrightness(10)
        await waitUntil { fake.actions == [.brightness(10)] }
        controller.setBrightness(90)
        controller.setKelvin(4100)
        var sleepStarted = false
        let sleep = Task { sleepStarted = true; await controller.suspendForSleep() }
        await waitUntil { sleepStarted }
        controller.setBrightness(77)
        controller.setPower(true)
        await sleep.value
        XCTAssertEqual(fake.actions, [.brightness(10), .power(false)])
        XCTAssertEqual(fake.events, [.connect, .apply(.brightness(10)), .completed(.brightness(10)),
                                     .apply(.power(false)), .completed(.power(false)), .disconnect])
        XCTAssertEqual(fake.maximumActiveApplies, 1)
        XCTAssertGreaterThanOrEqual(fake.applyCompletions[0].duration(to: fake.applyStarts[1]), .milliseconds(145))
    }

    func testSystemShutdownPowersOffButNormalReleaseDoesNot() async {
        let fake = FakeTransport()
        let controller = makeController(fake)
        await controller.connect()
        await controller.releaseConnection()
        XCTAssertTrue(fake.actions.isEmpty)
        await controller.connect()
        await controller.prepareForPowerOff()
        XCTAssertEqual(fake.actions, [.power(false)])
        XCTAssertEqual(fake.events.suffix(3), [.apply(.power(false)), .completed(.power(false)), .disconnect])
    }

    func testSleepAndShutdownDoNotOpenConnectionJustToPowerOff() async {
        let fake = FakeTransport()
        let controller = makeController(fake)
        await controller.suspendForSleep()
        await controller.prepareForPowerOff()
        XCTAssertEqual(fake.connectCalls, 0)
        XCTAssertTrue(fake.actions.isEmpty)
    }

    func testManualReleaseSuppressesAllLifecyclePowerAutomation() async {
        let fake = FakeTransport()
        let controller = makeController(fake)
        await controller.connect()
        await controller.releaseConnection()
        controller.start()
        await controller.suspendForSleep()
        controller.resumeAfterWake()
        await controller.prepareForPowerOff()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(fake.connectCalls, 1)
        XCTAssertTrue(fake.actions.isEmpty)
        XCTAssertTrue(controller.isConnectionPaused)
    }

    func testEarlyWakeWaitsForPowerOffAndDisconnectBeforePoweringOn() async {
        let fake = FakeTransport()
        fake.blockDisconnect = true
        let controller = makeController(fake, keepAlive: false)
        await controller.connect()
        let sleep = Task { await controller.suspendForSleep() }
        await waitUntil { fake.disconnectCalls == 1 }
        controller.resumeAfterWake()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(fake.actions, [.power(false)])
        XCTAssertEqual(fake.connectCalls, 1)
        fake.unblockDisconnect()
        await sleep.value
        await waitUntil { fake.actions == [.power(false), .power(true)] }
        XCTAssertEqual(fake.events.prefix(7), [.connect, .apply(.power(false)), .completed(.power(false)),
                                             .disconnect, .connect, .apply(.power(true)), .completed(.power(true))])
        await controller.releaseConnection()
    }

    func testManualReleaseInvalidatesDeferredWakePowerOn() async {
        let fake = FakeTransport()
        fake.blockDisconnect = true
        let controller = makeController(fake)
        await controller.connect()
        let sleep = Task { await controller.suspendForSleep() }
        await waitUntil { fake.disconnectCalls == 1 }
        controller.resumeAfterWake()
        var releaseStarted = false
        let release = Task { releaseStarted = true; await controller.releaseConnection() }
        await waitUntil { releaseStarted }
        fake.unblockDisconnect()
        await sleep.value
        await release.value
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(fake.actions, [.power(false)])
        XCTAssertEqual(fake.connectCalls, 1)
        XCTAssertTrue(controller.isConnectionPaused)
    }

    func testPowerOnFailureTearsDownWithoutRetryLoop() async {
        let fake = FakeTransport()
        fake.applyError = MorphError.bluetooth("Synthetic power failure")
        let controller = makeController(fake)
        controller.start()
        await waitUntil { controller.connection == .failed && !controller.isBusy }
        try? await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(fake.actions, [.power(true)])
        XCTAssertEqual(fake.connectCalls, 1)
        XCTAssertEqual(fake.disconnectCalls, 1)
        XCTAssertNotNil(controller.errorMessage)
    }

    func testPowerOffFailureIsPreservedAndDoesNotReconnectOnEarlyWake() async {
        let fake = FakeTransport()
        fake.applyError = MorphError.bluetooth("Synthetic power failure")
        let controller = makeController(fake)
        await controller.connect()
        let sleep = Task { await controller.suspendForSleep() }
        await Task.yield()
        controller.resumeAfterWake()
        await sleep.value
        await waitUntil { !controller.isBusy }
        XCTAssertEqual(controller.connection, .failed)
        XCTAssertEqual(fake.actions, [.power(false)])
        XCTAssertEqual(fake.connectCalls, 1)
        XCTAssertNotNil(controller.errorMessage)
    }

    func testPowerOffDrainHasDeadlineAndCancelsStalledWrite() async {
        let fake = FakeTransport()
        fake.applyDelay = 5_000_000_000
        let controller = makeController(fake, timeout: 0.03)
        await controller.connect()
        let start = ContinuousClock.now
        await controller.prepareForPowerOff()
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(500))
        await waitUntil { fake.activeApplies == 0 && !controller.isBusy }
        XCTAssertEqual(controller.connection, .failed)
        XCTAssertEqual(fake.actions, [.power(false)])
        XCTAssertEqual(fake.disconnectCalls, 1)
        XCTAssertNotNil(controller.errorMessage)
    }

    func testForgetCancelsPendingWakeConnectionBeforePowerOn() async throws {
        let fake = FakeTransport()
        fake.connectDelay = 5_000_000_000
        let controller = makeController(fake, keepAlive: false)
        controller.resumeAfterWake()
        await waitUntil { fake.connectCalls == 1 }
        try await controller.forgetLamp()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(controller.connection, .unpaired)
        XCTAssertTrue(fake.actions.isEmpty)
        XCTAssertEqual(fake.connectCalls, 1)
    }
}
