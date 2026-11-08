import XCTest
@testable import MorphServices

@MainActor
final class TerminationControllerTests: XCTestCase {
    private func controller(_ transport: FakeTransport, sync: Bool = true, demo: Bool = false) -> LampController {
        LampController(store: MemoryCredentialStore(sampleCredentials()), transportFactory: { transport },
                       keepConnectionAlive: true, syncPowerWithMac: sync, commandMinimumGap: .zero, isDemo: demo)
    }

    private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let end = ContinuousClock.now.advanced(by: .seconds(1))
        while !predicate(), ContinuousClock.now < end { await Task.yield() }
        XCTAssertTrue(predicate(), "Expected termination event did not occur", file: file, line: line)
    }

    func testTerminalControllerRejectsConnectWakePanelWritesAndReactivation() async {
        let fake = FakeTransport()
        let controller = controller(fake)
        await controller.connect()
        controller.beginTermination()
        controller.activateSession()
        controller.start()
        controller.resumeAfterWake()
        controller.recoverAfterInactivity()
        controller.panelOpened()
        controller.setKeepConnectionAlive(true)
        controller.setPower(true)
        controller.setBrightness(90)
        await controller.connect()
        await controller.prepareForTermination(powerOff: false)
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(fake.connectCalls, 1)
        XCTAssertEqual(fake.disconnectCalls, 1)
        XCTAssertTrue(fake.actions.isEmpty, "Normal Quit must not change lamp power")
        XCTAssertEqual(controller.connection, .disconnected)
    }

    func testConcurrentQuitCleanupSharesBarrierAndForceFindsRetainedTransport() async {
        let fake = FakeTransport()
        fake.blockDisconnect = true
        let controller = controller(fake)
        await controller.connect()
        let first = Task { await controller.prepareForTermination(powerOff: false) }
        await waitUntil { fake.disconnectCalls == 1 }
        let second = Task { await controller.prepareForTermination(powerOff: false) }
        await controller.forceAbortConnections()
        await first.value
        await second.value
        XCTAssertEqual(fake.disconnectCalls, 1)
        XCTAssertEqual(fake.abortCalls, 1, "The old transport is retained even after controller.transport was cleared")
        XCTAssertEqual(fake.connectCalls, 1)
        XCTAssertFalse(controller.isBusy)
    }

    func testSystemTerminationPowersOffOnceBeforeReleasingBluetooth() async {
        let fake = FakeTransport()
        let controller = controller(fake)
        await controller.connect()
        await controller.prepareForTermination(powerOff: true)
        await controller.prepareForTermination(powerOff: false)
        controller.resumeAfterWake()
        XCTAssertEqual(fake.events, [.connect, .apply(.power(false)), .completed(.power(false)), .disconnect])
        XCTAssertEqual(fake.abortCalls, 0)
        XCTAssertEqual(fake.connectCalls, 1)
    }

    func testTerminationDoesNotOpenConnectionJustToPowerOff() async {
        let fake = FakeTransport()
        let controller = controller(fake)
        await controller.prepareForTermination(powerOff: true)
        controller.panelOpened()
        await controller.connect()
        XCTAssertEqual(fake.connectCalls, 0)
        XCTAssertTrue(fake.actions.isEmpty)
    }

    func testForceAbortOfActiveSessionPreservesBarrierBeforeFreshConnection() async {
        let old = FakeTransport(), fresh = FakeTransport()
        old.blockDisconnect = true
        var transports = [old, fresh]
        let controller = LampController(store: MemoryCredentialStore(sampleCredentials()),
            transportFactory: { transports.removeFirst() })
        await controller.connect()
        let lateOldState = old.onStateChange
        await controller.forceAbortConnections()
        await controller.connect()
        lateOldState?(old.state)
        XCTAssertEqual(old.abortCalls, 1)
        XCTAssertEqual(old.disconnectCalls, 1)
        XCTAssertEqual(fresh.connectCalls, 1)
        XCTAssertEqual(controller.connection, .connected)
        XCTAssertEqual(controller.state, fresh.state)
        XCTAssertFalse(controller.isBusy)
        await controller.releaseConnection()
    }

    func testTerminationCancelsPendingInitializationWithoutWakeRetry() async {
        let fake = FakeTransport()
        fake.connectDelay = 5_000_000_000
        let controller = controller(fake)
        controller.start()
        await waitUntil { fake.connectCalls == 1 }
        controller.beginTermination()
        controller.resumeAfterWake()
        await controller.prepareForTermination(powerOff: true)
        XCTAssertEqual(fake.connectCalls, 1)
        XCTAssertEqual(fake.disconnectCalls, 1)
        XCTAssertTrue(fake.actions.isEmpty)
        XCTAssertFalse(controller.isBusy)
    }

    func testForceReachesNoncooperativeInitializationRetainedBehindTeardownJoin() async {
        let fake = FakeTransport()
        fake.blockConnect = true
        let controller = controller(fake)
        let connect = Task { await controller.connect() }
        await waitUntil { fake.connectCalls == 1 }
        var quitFinished = false
        let quit = Task { await controller.prepareForTermination(powerOff: false); quitFinished = true }
        await waitUntil { controller.connection == .disconnected }
        XCTAssertFalse(quitFinished, "Cancelling the task alone cannot join a noncooperative initializer")
        XCTAssertEqual(fake.disconnectCalls, 0)
        await controller.forceAbortConnections()
        await connect.value
        await quit.value
        XCTAssertTrue(quitFinished)
        XCTAssertEqual(fake.abortCalls, 1)
        XCTAssertEqual(fake.disconnectCalls, 1)
        XCTAssertEqual(fake.connectCalls, 1)
        XCTAssertTrue(fake.actions.isEmpty)
        XCTAssertFalse(controller.isBusy)
    }

    func testTerminationSuppressesPreviouslyDeferredWakeAfterSleepCleanup() async {
        let fake = FakeTransport()
        fake.blockDisconnect = true
        let controller = controller(fake)
        await controller.connect()
        let sleep = Task { await controller.suspendForSleep() }
        await waitUntil { fake.disconnectCalls == 1 }
        controller.resumeAfterWake()
        controller.beginTermination()
        let quit = Task { await controller.prepareForTermination(powerOff: false) }
        await controller.forceAbortConnections()
        await sleep.value
        await quit.value
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(fake.connectCalls, 1)
        XCTAssertEqual(fake.actions, [.power(false)])
        XCTAssertEqual(fake.disconnectCalls, 1)
    }

    func testTerminationDuringEnteringDemoDoesNotCreateOrActivateDemo() async {
        let physical = FakeTransport()
        physical.blockDisconnect = true
        let real = controller(physical)
        await real.connect()
        var demoCreations = 0
        let session = LampSession(controller: real, realControllerFactory: { real }, demoControllerFactory: {
            demoCreations += 1
            return self.controller(FakeTransport(), demo: true)
        })
        let transition = Task { await session.enterDemo() }
        await waitUntil { physical.disconnectCalls == 1 }
        session.beginTermination()
        await session.forceAbortConnections()
        await transition.value
        await session.prepareForTermination(powerOff: false)
        await session.enterDemo()
        XCTAssertTrue(session.controller === real)
        XCTAssertEqual(demoCreations, 0)
        XCTAssertEqual(physical.connectCalls, 1)
        XCTAssertFalse(session.isSwitchingMode)
    }

    func testTerminationDuringExitingDemoCannotReactivateRetainedPhysicalController() async {
        let physical = FakeTransport(), simulated = FakeTransport()
        let real = controller(physical), demo = controller(simulated, demo: true)
        await real.connect()
        let session = LampSession(controller: real, realControllerFactory: { real }, demoControllerFactory: { demo })
        await session.enterDemo()
        simulated.blockDisconnect = true
        let transition = Task { await session.exitDemo() }
        await waitUntil { simulated.disconnectCalls == 1 }
        session.beginTermination()
        await session.forceAbortConnections()
        await transition.value
        await session.prepareForTermination(powerOff: false)
        real.activateSession()
        real.start()
        await real.connect()
        await session.exitDemo()
        XCTAssertTrue(session.controller === demo)
        XCTAssertEqual(physical.connectCalls, 1)
        XCTAssertEqual(simulated.connectCalls, 1)
        XCTAssertFalse(session.isSwitchingMode)
    }
}
