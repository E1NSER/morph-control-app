import XCTest
import MorphCore
@testable import MorphServices

@MainActor
final class PersistentConnectionTests: XCTestCase {
    private func makeController(_ fake: FakeTransport, keepAlive: Bool = true) -> LampController {
        LampController(store: MemoryCredentialStore(sampleCredentials()), transportFactory: { fake },
                       idleSeconds: 0.02, keepConnectionAlive: keepAlive)
    }

    private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !predicate(), ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(predicate(), "Expected controller transition did not occur", file: file, line: line)
    }

    func testStartKeepsAStoredLampConnectedWithoutOpeningPanel() async {
        let fake = FakeTransport()
        let controller = makeController(fake)
        controller.start()
        await waitUntil { controller.connection == .connected }
        controller.panelClosed()
        try? await Task.sleep(nanoseconds: 70_000_000)
        XCTAssertEqual(fake.connectCalls, 1)
        XCTAssertEqual(fake.disconnectCalls, 0)
        XCTAssertEqual(controller.connection, .connected)
        await controller.releaseConnection()
    }

    func testStartWithoutKeepAliveWaitsForPanelAndUsesIdleRelease() async {
        let fake = FakeTransport()
        let controller = makeController(fake, keepAlive: false)
        controller.start()
        await Task.yield()
        XCTAssertEqual(fake.connectCalls, 0)
        controller.panelOpened()
        await waitUntil { controller.connection == .connected }
        controller.panelClosed()
        await waitUntil { fake.disconnectCalls == 1 && !controller.isBusy }
        XCTAssertEqual(controller.connection, .disconnected)
        XCTAssertFalse(controller.isConnectionPaused, "Idle release is not a manual pause")
        controller.panelOpened()
        await waitUntil { fake.connectCalls == 2 && controller.connection == .connected }
        await controller.releaseConnection()
    }

    func testTurningKeepAliveOnConnectsAndTurningItOffRestoresIdleRelease() async {
        let fake = FakeTransport()
        let controller = makeController(fake, keepAlive: false)
        controller.setKeepConnectionAlive(true)
        await waitUntil { controller.connection == .connected }
        try? await Task.sleep(nanoseconds: 70_000_000)
        XCTAssertEqual(fake.disconnectCalls, 0)
        controller.setKeepConnectionAlive(false)
        await waitUntil { fake.disconnectCalls == 1 && !controller.isBusy }
        XCTAssertEqual(controller.connection, .disconnected)
        XCTAssertFalse(controller.isConnectionPaused)
    }

    func testTurningKeepAliveOffDoesNotReleaseAnOpenPanel() async {
        let fake = FakeTransport()
        let controller = makeController(fake)
        controller.panelOpened()
        await waitUntil { controller.connection == .connected }
        controller.setKeepConnectionAlive(false)
        try? await Task.sleep(nanoseconds: 70_000_000)
        XCTAssertEqual(fake.disconnectCalls, 0)
        controller.panelClosed()
        await waitUntil { fake.disconnectCalls == 1 && !controller.isBusy }
    }

    func testTurningKeepAliveOffCancelsStartupRequestBeforeItBegins() async {
        let fake = FakeTransport()
        let controller = makeController(fake)
        controller.start()
        controller.setKeepConnectionAlive(false)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(fake.connectCalls, 0)
        XCTAssertEqual(controller.connection, .disconnected)
    }

    func testManualReleasePausesPanelStartupAndWakeUntilExplicitConnect() async {
        let fake = FakeTransport()
        let controller = makeController(fake)
        await controller.connect()
        await controller.releaseConnection()
        XCTAssertTrue(controller.isConnectionPaused)
        controller.start()
        controller.panelOpened()
        await controller.suspendForSleep()
        controller.resumeAfterWake()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(fake.connectCalls, 1)
        XCTAssertTrue(controller.isConnectionPaused)
        await controller.connect()
        XCTAssertEqual(fake.connectCalls, 2)
        XCTAssertEqual(controller.connection, .connected)
        XCTAssertFalse(controller.isConnectionPaused)
        await controller.releaseConnection()
    }

    func testReenablingKeepAliveEndsManualPause() async {
        let fake = FakeTransport()
        let controller = makeController(fake)
        await controller.releaseConnection()
        controller.setKeepConnectionAlive(false)
        controller.setKeepConnectionAlive(true)
        await waitUntil { controller.connection == .connected }
        XCTAssertFalse(controller.isConnectionPaused)
        XCTAssertEqual(fake.connectCalls, 1)
        await controller.releaseConnection()
    }

    func testSleepCancelsPendingStartupAndWakeConnectsOnce() async {
        let fake = FakeTransport()
        let controller = makeController(fake)
        controller.start()
        await controller.suspendForSleep()
        controller.panelOpened()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(fake.connectCalls, 0)
        controller.resumeAfterWake()
        await waitUntil { controller.connection == .connected }
        XCTAssertEqual(fake.connectCalls, 1)
        XCTAssertFalse(controller.isConnectionPaused)
        await controller.releaseConnection()
    }

    func testWakeReconnectWaitsForSleepTeardown() async {
        let fake = FakeTransport()
        fake.blockDisconnect = true
        let controller = makeController(fake)
        await controller.connect()
        let sleep = Task { await controller.suspendForSleep() }
        await waitUntil { fake.disconnectCalls == 1 }
        controller.resumeAfterWake()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(fake.connectCalls, 1)
        fake.unblockDisconnect()
        await sleep.value
        await waitUntil { fake.connectCalls == 2 && controller.connection == .connected }
        XCTAssertFalse(controller.isConnectionPaused)
        await controller.releaseConnection()
    }

    func testManualReleaseInvalidatesWakeWaitingForTeardown() async {
        let fake = FakeTransport()
        fake.blockDisconnect = true
        let controller = makeController(fake)
        await controller.connect()
        let sleep = Task { await controller.suspendForSleep() }
        await waitUntil { fake.disconnectCalls == 1 }
        controller.resumeAfterWake()
        await Task.yield()
        var releaseStarted = false
        let release = Task { releaseStarted = true; await controller.releaseConnection() }
        await waitUntil { releaseStarted }
        fake.unblockDisconnect()
        await sleep.value
        await release.value
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(fake.connectCalls, 1)
        XCTAssertTrue(controller.isConnectionPaused)
        XCTAssertEqual(controller.connection, .disconnected)
    }

    func testTurningKeepAliveOffInvalidatesWakeWaitingForTeardown() async {
        let fake = FakeTransport()
        fake.blockDisconnect = true
        let controller = makeController(fake)
        await controller.connect()
        let sleep = Task { await controller.suspendForSleep() }
        await waitUntil { fake.disconnectCalls == 1 }
        controller.resumeAfterWake()
        await Task.yield()
        controller.setKeepConnectionAlive(false)
        fake.unblockDisconnect()
        await sleep.value
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(fake.connectCalls, 1)
        XCTAssertFalse(controller.isConnectionPaused)
        XCTAssertEqual(controller.connection, .disconnected)
    }

    func testConnectionFailureDoesNotCreateAutomaticRetryLoop() async {
        let fake = FakeTransport()
        fake.connectError = MorphError.bluetooth("Synthetic connection failure")
        let controller = makeController(fake)
        controller.start()
        await waitUntil { controller.connection == .failed && !controller.isBusy }
        controller.start()
        try? await Task.sleep(nanoseconds: 70_000_000)
        XCTAssertEqual(fake.connectCalls, 1)
        fake.connectError = nil
        controller.setKeepConnectionAlive(false)
        controller.setKeepConnectionAlive(true)
        await waitUntil { controller.connection == .connected }
        XCTAssertEqual(fake.connectCalls, 2)
        await controller.releaseConnection()
    }

    func testUnexpectedDisconnectUsesBackoffInsteadOfImmediateRetry() async {
        let fake = FakeTransport()
        let controller = makeController(fake)
        controller.start()
        await waitUntil { controller.connection == .connected }
        fake.onDisconnect?()
        await waitUntil { controller.connection == .disconnected && !controller.isBusy }
        try? await Task.sleep(nanoseconds: 70_000_000)
        XCTAssertEqual(fake.connectCalls, 1)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertFalse(controller.isConnectionPaused)
        await controller.releaseConnection()
    }

    func testNewlyAdoptedLampDoesNotInheritManualPause() async throws {
        let fake = FakeTransport()
        let controller = makeController(fake)
        await controller.releaseConnection()
        try await controller.adopt(sampleCredentials())
        XCTAssertFalse(controller.isConnectionPaused)
        controller.start()
        await waitUntil { controller.connection == .connected }
        try await controller.forgetLamp()
        controller.start()
        controller.resumeAfterWake()
        controller.panelOpened()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(fake.connectCalls, 1)
        XCTAssertEqual(controller.connection, .unpaired)
        XCTAssertFalse(controller.isConnectionPaused)
    }
}
