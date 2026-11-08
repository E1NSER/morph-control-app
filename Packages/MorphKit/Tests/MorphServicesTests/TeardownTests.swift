import XCTest
import MorphCore
@testable import MorphServices

@MainActor
final class TeardownTests: XCTestCase {
    private func controller(_ old: FakeTransport, _ fresh: FakeTransport, store: MemoryCredentialStore? = nil) -> LampController {
        var transports = [old, fresh]
        return LampController(store: store ?? MemoryCredentialStore(sampleCredentials()), transportFactory: { transports.removeFirst() })
    }

    func testReconnectWaitsForDisconnectAndConcurrentReleasesShareTheBarrier() async {
        let old = FakeTransport()
        old.blockDisconnect = true
        let fresh = FakeTransport()
        let controller = controller(old, fresh)
        await controller.connect()
        var releasesStarted = 0
        let firstRelease = Task { releasesStarted += 1; await controller.releaseConnection() }
        let secondRelease = Task { releasesStarted += 1; await controller.releaseConnection() }
        while releasesStarted < 2 || old.disconnectCalls == 0 { await Task.yield() }
        var reconnectStarted = false
        let reconnect = Task { reconnectStarted = true; await controller.connect() }
        while !reconnectStarted { await Task.yield() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(old.disconnectCalls, 1)
        XCTAssertEqual(fresh.connectCalls, 0, "No new BLE session may start while unsubscribe is pending")
        XCTAssertTrue(controller.isBusy)
        old.unblockDisconnect()
        await firstRelease.value
        await secondRelease.value
        await reconnect.value
        XCTAssertEqual(fresh.connectCalls, 1)
        XCTAssertEqual(controller.connection, .connected)
        XCTAssertFalse(controller.isBusy)
        await controller.releaseConnection()
    }

    func testForgetInvalidatesReconnectAlreadyWaitingForTeardown() async throws {
        let old = FakeTransport()
        old.blockDisconnect = true
        let fresh = FakeTransport()
        let store = MemoryCredentialStore(sampleCredentials())
        let controller = controller(old, fresh, store: store)
        await controller.connect()
        let release = Task { await controller.releaseConnection() }
        while old.disconnectCalls == 0 { await Task.yield() }
        var reconnectStarted = false
        let reconnect = Task { reconnectStarted = true; await controller.connect() }
        while !reconnectStarted { await Task.yield() }
        var forgetStarted = false
        let forget = Task { forgetStarted = true; try await controller.forgetLamp() }
        while !forgetStarted { await Task.yield() }
        controller.panelOpened()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(controller.isBusy)
        XCTAssertEqual(fresh.connectCalls, 0)
        old.unblockDisconnect()
        await release.value
        await reconnect.value
        try await forget.value
        await Task.yield()
        XCTAssertEqual(fresh.connectCalls, 0)
        XCTAssertNil(store.credentials)
        XCTAssertFalse(controller.hasCredentials)
        XCTAssertEqual(controller.connection, .unpaired)
        XCTAssertFalse(controller.isBusy)
    }

    func testLaterReleaseInvalidatesAnEarlierPendingReconnect() async {
        let old = FakeTransport()
        old.blockDisconnect = true
        let fresh = FakeTransport()
        let controller = controller(old, fresh)
        await controller.connect()
        let firstRelease = Task { await controller.releaseConnection() }
        while old.disconnectCalls == 0 { await Task.yield() }
        var reconnectStarted = false
        let reconnect = Task { reconnectStarted = true; await controller.connect() }
        while !reconnectStarted { await Task.yield() }
        var laterReleaseStarted = false
        let laterRelease = Task { laterReleaseStarted = true; await controller.releaseConnection() }
        while !laterReleaseStarted { await Task.yield() }
        old.unblockDisconnect()
        await firstRelease.value
        await reconnect.value
        await laterRelease.value
        XCTAssertEqual(fresh.connectCalls, 0)
        XCTAssertEqual(old.disconnectCalls, 1)
        XCTAssertEqual(controller.connection, .disconnected)
        XCTAssertFalse(controller.isBusy)
    }

    func testCommandFailureUsesTheSameBarrierBeforeExplicitRetry() async {
        let old = FakeTransport()
        old.applyError = MorphError.bluetooth("Synthetic write failure")
        old.blockDisconnect = true
        let fresh = FakeTransport()
        let controller = controller(old, fresh)
        await controller.connect()
        controller.setPower(true)
        while old.disconnectCalls == 0 { await Task.yield() }
        XCTAssertEqual(controller.connection, .failed)
        XCTAssertTrue(controller.isBusy)
        let retry = Task { await controller.connect() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(fresh.connectCalls, 0)
        old.unblockDisconnect()
        await retry.value
        XCTAssertEqual(fresh.connectCalls, 1)
        XCTAssertEqual(controller.connection, .connected)
        XCTAssertNil(controller.errorMessage)
        XCTAssertFalse(controller.isBusy)
        await controller.releaseConnection()
    }
}
