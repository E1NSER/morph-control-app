import XCTest
@testable import MorphCore

/// These exercise the actual BLE continuation machinery without creating a
/// CBCentralManager, requesting Bluetooth access or requiring a physical lamp.
final class CancellationTests: XCTestCase {
    func testCancellationResolvesAnExistingWaitWithoutWaitingForTimeout() async {
        let lamp = Lamp()
        let started = expectation(description: "Continuation registered")
        let task = Task {
            let _: Bool = try await lamp.wait("cancel-test", timeout: 30) { started.fulfill() }
        }
        await fulfillment(of: [started], timeout: 1)
        let start = ContinuousClock.now
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(500))
    }

    func testCancellationBeforeRegistrationCannotLeaveAContinuationPending() async {
        for _ in 0..<30 {
            let lamp = Lamp()
            let task = Task { let _: Bool = try await lamp.wait("early-cancel", timeout: 30) {} }
            task.cancel()
            do { try await task.value; XCTFail("Expected cancellation") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
    }

    func testAbortResolvesAllWaitersAndIsSafeWithoutBluetoothInitialization() async {
        let lamp = Lamp()
        let started = expectation(description: "Both continuations registered")
        started.expectedFulfillmentCount = 2
        let first = Task { let _: Bool = try await lamp.wait("one", timeout: 30) { started.fulfill() } }
        let second = Task { let _: Bool = try await lamp.wait("two", timeout: 30) { started.fulfill() } }
        await fulfillment(of: [started], timeout: 1)
        await lamp.abort()
        for task in [first, second] {
            do { try await task.value; XCTFail("Expected aborted operation") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
    }
}
