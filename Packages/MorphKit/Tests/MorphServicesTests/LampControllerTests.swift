import XCTest
import MorphCore
@testable import MorphServices

@MainActor
final class LampControllerTests: XCTestCase {
    func testCommandsDoNotConnectOrWriteWhileDisconnected() async {
        let fake = FakeTransport()
        let controller = LampController(store: MemoryCredentialStore(sampleCredentials()), transportFactory: { fake })
        controller.setPower(true)
        controller.setBrightness(50)
        await controller.refresh()
        XCTAssertEqual(controller.connection, .disconnected)
        XCTAssertEqual(fake.connectCalls, 0)
        XCTAssertTrue(fake.actions.isEmpty)
    }

    func testConcurrentConnectIsSingleFlightAndReleaseRejectsOldCallbacks() async {
        let fake = FakeTransport()
        fake.connectDelay = 20_000_000
        let controller = LampController(store: MemoryCredentialStore(sampleCredentials()), transportFactory: { fake })
        async let first: Void = controller.connect()
        async let second: Void = controller.connect()
        _ = await (first, second)
        XCTAssertEqual(fake.connectCalls, 1)
        XCTAssertEqual(controller.connection, .connected)
        let stale = fake.onStateChange
        await controller.releaseConnection()
        stale?(fake.state)
        XCTAssertEqual(controller.connection, .disconnected)
        XCTAssertNil(controller.state)
        XCTAssertFalse(controller.isBusy)
    }

    func testReleaseDuringConnectCancelsWithoutErrorOrReconnection() async {
        let fake = FakeTransport()
        fake.connectDelay = 5_000_000_000
        let controller = LampController(store: MemoryCredentialStore(sampleCredentials()), transportFactory: { fake })
        let connection = Task { await controller.connect() }
        while fake.connectCalls == 0 { await Task.yield() }
        let start = ContinuousClock.now
        await controller.releaseConnection()
        await connection.value
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(500))
        XCTAssertEqual(fake.connectCalls, 1)
        XCTAssertEqual(controller.connection, .disconnected)
        XCTAssertNil(controller.errorMessage)
        XCTAssertNil(controller.state)
        XCTAssertFalse(controller.isBusy)
    }

    func testDeadlineCancelsConnectionAndRequiresExplicitRetry() async {
        let fake = FakeTransport()
        fake.connectDelay = 5_000_000_000
        let controller = LampController(store: MemoryCredentialStore(sampleCredentials()), transportFactory: { fake }, connectionTimeout: 0.025)
        let start = ContinuousClock.now
        await controller.connect()
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(500))
        XCTAssertEqual(controller.connection, .failed)
        XCTAssertEqual(controller.errorMessage, UserFacingError.message(for: ServiceError.deadline))
        XCTAssertEqual(fake.connectCalls, 1)
        fake.connectDelay = 0
        await controller.connect()
        XCTAssertEqual(controller.connection, .connected)
        XCTAssertEqual(fake.connectCalls, 2)
        await controller.releaseConnection()
    }

    func testPanelKeepsConnectionAndClosedPanelReleasesAfterIdle() async {
        let fake = FakeTransport()
        let controller = LampController(store: MemoryCredentialStore(sampleCredentials()), transportFactory: { fake }, idleSeconds: 0.02)
        controller.panelOpened()
        await controller.connect()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(controller.connection, .connected)
        controller.panelClosed()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(controller.connection, .disconnected)
        XCTAssertGreaterThanOrEqual(fake.disconnectCalls, 1)
    }

    func testDemoControlsClampAndTurnPowerOnWithoutCloudOrKeychain() async throws {
        let controller = LampController(demo: true)
        await controller.connect()
        controller.setPower(false)
        await controller.refresh()
        XCTAssertEqual(controller.state?.power, false)
        controller.setBrightness(500)
        controller.setKelvin(500)
        await controller.refresh()
        XCTAssertEqual(controller.state?.power, true)
        XCTAssertEqual(controller.state?.brightness, 100)
        XCTAssertEqual(controller.state?.kelvin, 2700)
        try await controller.forgetLamp()
        XCTAssertEqual(controller.connection, .unpaired)
        XCTAssertFalse(controller.hasCredentials)
    }

    func testRenameAndForgetPersistOnlyThroughCredentialStore() async throws {
        let store = MemoryCredentialStore(sampleCredentials())
        let controller = LampController(store: store, transportFactory: { FakeTransport() })
        controller.renameLamp("  Atelier  ")
        XCTAssertEqual(controller.lampName, "Atelier")
        XCTAssertEqual(store.credentials?.name, "Atelier")
        try await controller.forgetLamp()
        XCTAssertNil(store.credentials)
        XCTAssertFalse(controller.hasCredentials)
        XCTAssertEqual(controller.serial, "")
    }

    func testStaleSessionCannotOverwriteANewConnection() async {
        let old = FakeTransport()
        let fresh = FakeTransport()
        fresh.state.kelvin = 5500
        var transports: [FakeTransport] = [old, fresh]
        let controller = LampController(store: MemoryCredentialStore(sampleCredentials()), transportFactory: { transports.removeFirst() })
        await controller.connect()
        let lateState = old.onStateChange
        let lateDisconnect = old.onDisconnect
        await controller.releaseConnection()
        await controller.connect()
        lateState?(old.state)
        lateDisconnect?()
        XCTAssertEqual(controller.connection, .connected)
        XCTAssertEqual(controller.state?.kelvin, 5500)
        await controller.releaseConnection()
    }
}
