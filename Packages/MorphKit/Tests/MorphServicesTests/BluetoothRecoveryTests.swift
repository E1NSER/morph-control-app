import Foundation
import XCTest
import MorphCore
@testable import MorphServices

/// Only injected closures are exercised; no Bluetooth transport or credentials are created.
@MainActor
final class BluetoothRecoveryTests: XCTestCase {
    func testSuccessfulAttemptDoesNotResetOrWait() async throws {
        var events: [String] = []
        let result = try await retryOnceWithFreshBluetoothSession(attempt: {
            events.append("attempt")
            return 42
        }, reset: {
            events.append("reset")
        }, cooldown: {
            events.append("cooldown")
        })
        XCTAssertEqual(result, 42)
        XCTAssertEqual(events, ["attempt"])
    }

    func testStaleSessionRetriesOnceAfterResetAndCooldown() async throws {
        var events: [String] = []
        var attempts = 0
        let result = try await retryOnceWithFreshBluetoothSession(attempt: {
            attempts += 1
            events.append("attempt\(attempts)")
            if attempts == 1 { throw MorphError.lampStuck("Synthetic ATT 10") }
            return "connected"
        }, reset: {
            events.append("reset")
        }, cooldown: {
            events.append("cooldown")
        })
        XCTAssertEqual(result, "connected")
        XCTAssertEqual(events, ["attempt1", "reset", "cooldown", "attempt2"])
    }

    func testSecondStaleSessionFailureIsPropagatedWithoutAnotherReset() async {
        var events: [String] = []
        var attempts = 0
        do {
            let _: Int = try await retryOnceWithFreshBluetoothSession(attempt: {
                attempts += 1
                events.append("attempt\(attempts)")
                throw MorphError.lampStuck(attempts == 1 ? "first" : "second")
            }, reset: {
                events.append("reset")
            }, cooldown: {
                events.append("cooldown")
            })
            XCTFail("The second failure must reach the caller")
        } catch {
            guard case MorphError.lampStuck(let detail) = error else {
                return XCTFail("Expected the second stale-session failure")
            }
            XCTAssertEqual(detail, "second")
        }
        XCTAssertEqual(events, ["attempt1", "reset", "cooldown", "attempt2"])
    }

    func testOtherFailuresAreNotRetried() async {
        let errors: [Error] = [
            MorphError.protocolError("Synthetic protocol failure"),
            MorphError.bluetoothState(.permissionDenied),
            MorphError.bluetoothState(.sessionOccupied),
            MorphError.timeout("Synthetic timeout"),
            MorphError.bluetooth("Synthetic generic Bluetooth failure"),
            ServiceError.deadline,
            CancellationError()
        ]
        for expected in errors {
            var attempts = 0
            var resets = 0
            var waits = 0
            do {
                let _: Int = try await retryOnceWithFreshBluetoothSession(attempt: {
                    attempts += 1
                    throw expected
                }, reset: {
                    resets += 1
                }, cooldown: {
                    waits += 1
                })
                XCTFail("Expected the original failure")
            } catch {
                XCTAssertEqual(String(reflecting: type(of: error)), String(reflecting: type(of: expected)))
                XCTAssertEqual(String(describing: error), String(describing: expected))
            }
            XCTAssertEqual(attempts, 1)
            XCTAssertEqual(resets, 0)
            XCTAssertEqual(waits, 0)
        }
    }

    func testInitialCancellationDoesNotStartAnAttempt() async {
        var events: [String] = []
        let task = Task {
            try await retryOnceWithFreshBluetoothSession(attempt: {
                events.append("attempt")
                return 1
            }, reset: {
                events.append("reset")
            }, cooldown: {
                events.append("cooldown")
            })
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(events.isEmpty)
    }

    func testCancellationAfterFailedAttemptDoesNotStartReset() async {
        var events: [String] = []
        let started = expectation(description: "First attempt entered")
        var finishAttempt: CheckedContinuation<Void, Never>?
        let task = Task {
            let _: Int = try await retryOnceWithFreshBluetoothSession(attempt: {
                events.append("attempt")
                await withCheckedContinuation { finishAttempt = $0; started.fulfill() }
                throw MorphError.lampStuck("Synthetic late ATT failure")
            }, reset: {
                events.append("reset")
            }, cooldown: {
                events.append("cooldown")
            })
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        finishAttempt?.resume()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(events, ["attempt"])
    }

    func testCancellationDuringResetDoesNotStartCooldownOrRetry() async {
        var events: [String] = []
        let started = expectation(description: "Reset entered")
        var finishReset: CheckedContinuation<Void, Never>?
        let task = Task {
            let _: Int = try await retryOnceWithFreshBluetoothSession(attempt: {
                events.append("attempt")
                throw MorphError.lampStuck("Synthetic ATT 17")
            }, reset: {
                events.append("reset")
                await withCheckedContinuation { finishReset = $0; started.fulfill() }
            }, cooldown: {
                events.append("cooldown")
            })
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        finishReset?.resume()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(events, ["attempt", "reset"])
    }

    func testCancellationDuringNonthrowingCooldownDoesNotRetry() async {
        var events: [String] = []
        let started = expectation(description: "Cooldown entered")
        var finishCooldown: CheckedContinuation<Void, Never>?
        let task = Task {
            let _: Int = try await retryOnceWithFreshBluetoothSession(attempt: {
                events.append("attempt")
                throw MorphError.lampStuck("Synthetic ATT 10")
            }, reset: {
                events.append("reset")
            }, cooldown: {
                events.append("cooldown")
                await withCheckedContinuation { finishCooldown = $0; started.fulfill() }
            })
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        finishCooldown?.resume()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(events, ["attempt", "reset", "cooldown"])
    }

    func testDefaultCooldownIsCancellableWithoutWaitingTwoSeconds() async {
        var attempts = 0
        let resetStarted = expectation(description: "Reset entered before default cooldown")
        let task = Task {
            let _: Int = try await retryOnceWithFreshBluetoothSession(attempt: {
                attempts += 1
                throw MorphError.lampStuck("Synthetic ATT 17")
            }, reset: {
                resetStarted.fulfill()
            })
        }
        await fulfillment(of: [resetStarted], timeout: 1)
        let cancelledAt = ContinuousClock.now
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(cancelledAt.duration(to: .now), .milliseconds(500))
        XCTAssertEqual(attempts, 1)
    }

    func testInitialLiveStateFailureRepeatsTheWholeConnectionAttempt() async throws {
        var events: [String] = []
        var attempts = 0
        let state = try await retryOnceWithFreshBluetoothSession(attempt: {
            attempts += 1
            for step in ["powerOn", "authenticate", "enableLiveState", "readInitialState"] {
                events.append("\(step)\(attempts)")
            }
            if attempts == 1 { throw MorphError.lampStuck("Synthetic initial attribute read failure") }
            return "fresh live state"
        }, reset: {
            events.append("reset")
        }, cooldown: {
            events.append("cooldown")
        })
        XCTAssertEqual(state, "fresh live state")
        XCTAssertEqual(events, [
            "powerOn1", "authenticate1", "enableLiveState1", "readInitialState1",
            "reset", "cooldown",
            "powerOn2", "authenticate2", "enableLiveState2", "readInitialState2"
        ])
    }
}
