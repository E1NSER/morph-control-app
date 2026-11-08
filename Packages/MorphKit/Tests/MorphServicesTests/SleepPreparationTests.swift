import XCTest
@testable import MorphServices

@MainActor
final class SleepPreparationTests: XCTestCase {
    func testCleanPreparationAcknowledgesOnceWithoutForce() async {
        var events: [String] = []
        let acknowledged = expectation(description: "Sleep acknowledged")
        let preparation = SleepPreparation(graceSeconds: 1, prepare: {
            events.append("clean")
        }, force: { events.append("force") })
        preparation.begin { events.append("ack"); acknowledged.fulfill() }
        await fulfillment(of: [acknowledged], timeout: 1)
        preparation.cancelPendingForWake()
        XCTAssertEqual(events, ["clean", "ack"])
    }

    func testDeadlineForcesCleanupBeforeAcknowledgingWithoutJoiningOldTask() async {
        var events: [String] = []
        var finishPreparation: CheckedContinuation<Void, Never>?
        let acknowledged = expectation(description: "Sleep acknowledged after force")
        let preparation = SleepPreparation(graceSeconds: 0.02, forceSeconds: 1, prepare: {
            await withCheckedContinuation { finishPreparation = $0 }
            events.append("late-clean")
        }, force: { events.append("force") })
        preparation.begin { events.append("ack"); acknowledged.fulfill() }
        await fulfillment(of: [acknowledged], timeout: 1)
        XCTAssertEqual(events, ["force", "ack"])
        finishPreparation?.resume()
        await Task.yield()
        XCTAssertEqual(events.filter { $0 == "ack" }.count, 1)
    }

    func testStalledFallbackCannotHoldSleepIndefinitely() async {
        var finishPreparation: CheckedContinuation<Void, Never>?
        var finishForce: CheckedContinuation<Void, Never>?
        var acknowledgements = 0
        let acknowledged = expectation(description: "Hard limit releases sleep")
        let preparation = SleepPreparation(graceSeconds: 0.02, forceSeconds: 0.02, prepare: {
            await withCheckedContinuation { finishPreparation = $0 }
        }, force: {
            await withCheckedContinuation { finishForce = $0 }
        })
        let began = ContinuousClock.now
        preparation.begin { acknowledgements += 1; acknowledged.fulfill() }
        await fulfillment(of: [acknowledged], timeout: 1)
        XCTAssertLessThan(began.duration(to: .now), .milliseconds(500))
        finishPreparation?.resume(); finishForce?.resume()
        await Task.yield()
        XCTAssertEqual(acknowledgements, 1)
    }

    func testCancelledPreparationCannotAcknowledgeBeforeForceFinishes() async {
        var finishForce: CheckedContinuation<Void, Never>?
        var acknowledgements = 0
        let forceEntered = expectation(description: "Fallback cleanup entered")
        let acknowledged = expectation(description: "Acknowledged after fallback")
        let preparation = SleepPreparation(graceSeconds: 0.02, forceSeconds: 1, prepare: {
            // Typical cooperative cleanup returns as soon as it is cancelled.
            try? await Task.sleep(nanoseconds: 30_000_000_000)
        }, force: {
            await withCheckedContinuation { finishForce = $0; forceEntered.fulfill() }
        })
        preparation.begin { acknowledgements += 1; acknowledged.fulfill() }
        await fulfillment(of: [forceEntered], timeout: 1)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(acknowledgements, 0)
        finishForce?.resume()
        await fulfillment(of: [acknowledged], timeout: 1)
        XCTAssertEqual(acknowledgements, 1)
    }

    func testWakeCancelsOldDeadlineAndAcknowledgesExactlyOnce() async throws {
        var finishPreparation: CheckedContinuation<Void, Never>?
        var forced = false
        var acknowledgements = 0
        let entered = expectation(description: "Preparation started")
        let preparation = SleepPreparation(graceSeconds: 0.02, prepare: {
            await withCheckedContinuation { finishPreparation = $0; entered.fulfill() }
        }, force: { forced = true })
        preparation.begin { acknowledgements += 1 }
        await fulfillment(of: [entered], timeout: 1)
        preparation.cancelPendingForWake()
        finishPreparation?.resume()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(acknowledgements, 1)
        XCTAssertFalse(forced)
    }

    func testReplacementAcknowledgesBothTokensAndIgnoresLateOldCompletion() async {
        var finishOld: CheckedContinuation<Void, Never>?
        var attempts = 0
        var acknowledgements: [String] = []
        let entered = expectation(description: "Old preparation started")
        let newAcknowledged = expectation(description: "New preparation acknowledged")
        let preparation = SleepPreparation(graceSeconds: 1, prepare: {
            attempts += 1
            if attempts == 1 {
                await withCheckedContinuation { finishOld = $0; entered.fulfill() }
            }
        }, force: { XCTFail("No force needed") })
        preparation.begin { acknowledgements.append("old") }
        await fulfillment(of: [entered], timeout: 1)
        preparation.begin { acknowledgements.append("new"); newAcknowledged.fulfill() }
        await fulfillment(of: [newAcknowledged], timeout: 1)
        finishOld?.resume()
        await Task.yield()
        XCTAssertEqual(acknowledgements, ["old", "new"])
    }
}
