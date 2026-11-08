import CoreBluetooth
import XCTest
@testable import MorphCore

/// Uses the production continuation/notification machinery with plain endpoint
/// objects. No central manager, peripheral, radio or Bluetooth permission exists.
final class GATTLifecycleTests: XCTestCase {
    private final class Endpoint {
        var notifying = false
        var requests: [Bool] = []
    }
    private enum DriverError: Error { case finished }
    private let service = CBUUID(string: "2DD10010-1C37-452D-8979-D1B4A787D0A4")

    private func drive(_ lamp: Lamp, _ body: @escaping () throws -> Void) async {
        let _: Bool? = try? await lamp.wait("test:driver", timeout: 1) {
            try body()
            throw DriverError.finished
        }
    }

    func testAlreadyEnabledAndAlreadyDisabledDoNotWriteNotifications() async throws {
        let lamp = Lamp()
        let endpoint = Endpoint()
        for enabled in [false, true] {
            await drive(lamp) { endpoint.notifying = enabled }
            try await lamp.changeNotificationState(enabled, for: "test", target: ObjectIdentifier(endpoint),
                isCurrent: { true }, isNotifying: { endpoint.notifying },
                request: { endpoint.requests.append($0) })
        }
        XCTAssertTrue(endpoint.requests.isEmpty)
    }

    func testOppositeStateCallbackCannotConfirmRequestedTransition() async {
        let lamp = Lamp()
        let endpoint = Endpoint()
        do {
            try await lamp.changeNotificationState(true, for: "test", target: ObjectIdentifier(endpoint), timeout: 0.02,
                isCurrent: { true }, isNotifying: { endpoint.notifying }, request: { enabled in
                    endpoint.requests.append(enabled)
                    lamp.notificationStateDidChange(for: "test", target: ObjectIdentifier(endpoint),
                                                    isNotifying: false, error: nil)
                })
            XCTFail("An opposite-state callback must not complete the transition")
        } catch {
            guard case MorphError.timeout("notify:test") = error else {
                return XCTFail("Expected the bounded notification timeout, got \(error)")
            }
        }
        XCTAssertEqual(endpoint.requests, [true])
    }

    func testWrongEndpointCallbackIsIgnoredUntilRequestedStateArrives() async throws {
        let lamp = Lamp()
        let endpoint = Endpoint()
        let previousEndpoint = Endpoint()
        try await lamp.changeNotificationState(true, for: "test", target: ObjectIdentifier(endpoint),
            isCurrent: { true }, isNotifying: { endpoint.notifying }, request: { enabled in
                endpoint.requests.append(enabled)
                lamp.notificationStateDidChange(for: "test", target: ObjectIdentifier(previousEndpoint),
                                                isNotifying: true,
                                                error: NSError(domain: CBATTErrorDomain, code: CBATTError.insufficientResources.rawValue))
                lamp.notificationStateDidChange(for: "test", target: ObjectIdentifier(endpoint),
                                                isNotifying: false, error: nil)
                endpoint.notifying = true
                lamp.notificationStateDidChange(for: "test", target: ObjectIdentifier(endpoint),
                                                isNotifying: endpoint.notifying, error: nil)
            })
        XCTAssertEqual(endpoint.requests, [true])
    }

    func testFailedNotificationCanBeRequestedAgainWithoutStaleWaiter() async throws {
        let lamp = Lamp()
        let endpoint = Endpoint()
        do {
            try await lamp.changeNotificationState(true, for: "test", target: ObjectIdentifier(endpoint),
                isCurrent: { true }, isNotifying: { endpoint.notifying }, request: { enabled in
                    endpoint.requests.append(enabled)
                    lamp.notificationStateDidChange(for: "test", target: ObjectIdentifier(endpoint), isNotifying: false,
                        error: NSError(domain: CBATTErrorDomain, code: CBATTError.attributeNotFound.rawValue))
                })
            XCTFail("Expected the ATT failure")
        } catch {
            guard case MorphError.lampStuck = error else { return XCTFail("Expected typed ATT failure") }
        }
        try await lamp.changeNotificationState(true, for: "test", target: ObjectIdentifier(endpoint),
            isCurrent: { true }, isNotifying: { endpoint.notifying }, request: { enabled in
                endpoint.requests.append(enabled)
                endpoint.notifying = enabled
                lamp.notificationStateDidChange(for: "test", target: ObjectIdentifier(endpoint),
                                                isNotifying: endpoint.notifying, error: nil)
            })
        XCTAssertEqual(endpoint.requests, [true, true])
    }

    func testCancellationCleansNotificationRequestAndAllowsNextRequest() async throws {
        let lamp = Lamp()
        let endpoint = Endpoint()
        let started = expectation(description: "Notification request started")
        let task = Task {
            try await lamp.changeNotificationState(true, for: "test", target: ObjectIdentifier(endpoint),
                isCurrent: { true }, isNotifying: { endpoint.notifying }, request: { enabled in
                    endpoint.requests.append(enabled)
                    started.fulfill()
                })
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await lamp.changeNotificationState(true, for: "test", target: ObjectIdentifier(endpoint),
            isCurrent: { true }, isNotifying: { endpoint.notifying }, request: { enabled in
                endpoint.requests.append(enabled)
                endpoint.notifying = enabled
                lamp.notificationStateDidChange(for: "test", target: ObjectIdentifier(endpoint),
                                                isNotifying: enabled, error: nil)
            })
        XCTAssertEqual(endpoint.requests, [true, true])
    }

    func testUnrelatedServiceDoesNotInterruptNotificationOrAuthentication() async throws {
        let lamp = Lamp()
        let endpoint = Endpoint()
        let unrelated = CBUUID(string: "180A")
        await drive(lamp) {
            let session = lamp.beginConnectionSession()
            XCTAssertNoThrow(try lamp.completeAuthentication(session: session))
        }
        try await lamp.changeNotificationState(true, for: "test", target: ObjectIdentifier(endpoint),
            isCurrent: { true }, isNotifying: { endpoint.notifying }, request: { enabled in
                XCTAssertFalse(lamp.invalidateServices([unrelated], usedServices: [self.service]))
                endpoint.notifying = enabled
                lamp.notificationStateDidChange(for: "test", target: ObjectIdentifier(endpoint),
                                                isNotifying: endpoint.notifying, error: nil)
            })
        let ready = await lamp.isReady
        XCTAssertTrue(ready)
    }

    func testDiscoveryInvalidationRejectsPendingDiscoveryEvenBeforeCharacteristicsExist() async {
        let lamp = Lamp()
        do {
            let _: Bool = try await lamp.wait("discover", timeout: 1) {
                XCTAssertTrue(lamp.invalidateServices([self.service], usedServices: []))
            }
            XCTFail("Discovery must not survive invalidation")
        } catch { assertUnavailable(error) }
    }

    func testServiceInvalidationRejectsOldReadAndLateAuthenticationCompletion() async {
        let lamp = Lamp()
        do {
            let _: Bool = try await lamp.wait("read:test", timeout: 1) {
                let session = lamp.beginConnectionSession()
                XCTAssertNoThrow(try lamp.completeAuthentication(session: session))
                XCTAssertTrue(lamp.invalidateServices([self.service], usedServices: [self.service]))
                XCTAssertThrowsError(try lamp.completeAuthentication(session: session)) { self.assertUnavailable($0) }
                XCTAssertFalse(lamp.invalidateServices([self.service], usedServices: [self.service]))
            }
            XCTFail("The old read must fail promptly")
        } catch { assertUnavailable(error) }
        let ready = await lamp.isReady
        let live = await lamp.isLive
        XCTAssertFalse(ready)
        XCTAssertFalse(live)
    }

    func testServiceInvalidationPreservesDisconnectWaitUntilDisconnectCallback() async throws {
        let lamp = Lamp()
        let registered = expectation(description: "Disconnect waiter registered")
        let task = Task {
            let ended: Bool = try await lamp.wait("disconnect", timeout: 1) { registered.fulfill() }
            return ended
        }
        await fulfillment(of: [registered], timeout: 1)
        await drive(lamp) {
            XCTAssertTrue(lamp.invalidateServices([self.service], usedServices: [self.service]))
            lamp.connectionDidEnd()
        }
        let ended = try await task.value
        XCTAssertTrue(ended)
    }

    func testInvalidatedNotificationEndpointCannotIssueAnotherCCCDRequest() async {
        let lamp = Lamp()
        let endpoint = Endpoint()
        do {
            try await lamp.changeNotificationState(true, for: "test", target: ObjectIdentifier(endpoint),
                isCurrent: { true }, isNotifying: { endpoint.notifying }, request: { enabled in
                    endpoint.requests.append(enabled)
                    XCTAssertTrue(lamp.invalidateServices([self.service], usedServices: [self.service]))
                    lamp.notificationStateDidChange(for: "test", target: ObjectIdentifier(endpoint),
                                                    isNotifying: enabled, error: nil)
                })
            XCTFail("Invalidation must fail the pending notification")
        } catch { assertUnavailable(error) }
        do {
            try await lamp.changeNotificationState(false, for: "test", target: ObjectIdentifier(endpoint),
                isCurrent: { true }, isNotifying: { endpoint.notifying },
                request: { endpoint.requests.append($0) })
            XCTFail("An invalidated handle cannot be reused")
        } catch { assertUnavailable(error) }
        XCTAssertEqual(endpoint.requests, [true])
    }

    private func assertUnavailable(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard case MorphError.bluetoothState(.unavailable) = error else {
            return XCTFail("Expected unavailable, got \(error)", file: file, line: line)
        }
    }
}
