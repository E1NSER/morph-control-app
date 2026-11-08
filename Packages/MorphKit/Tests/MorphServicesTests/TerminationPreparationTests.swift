import XCTest
@testable import MorphServices

@MainActor
final class TerminationPreparationTests: XCTestCase {
    /// Intentionally ignores cancellation, like a stuck delegate continuation.
    private final class Gate {
        var entered = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            entered = true
            await withCheckedContinuation { continuation = $0 }
        }
        func open() {
            let pending = continuation
            continuation = nil
            pending?.resume()
        }
    }

    private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let end = ContinuousClock.now.advanced(by: .seconds(1))
        while !predicate(), ContinuousClock.now < end { await Task.yield() }
        XCTAssertTrue(predicate(), "Expected termination event did not occur", file: file, line: line)
    }

    func testGracefulCleanupCompletesOnceWithoutForceOrLaterTimer() async {
        var prepareCalls = 0
        var forceCalls = 0
        var outcomes: [TerminationPreparation.Outcome] = []
        let preparation = TerminationPreparation(graceSeconds: 0.02, forceSeconds: 0.02,
            prepare: { prepareCalls += 1 }, force: { forceCalls += 1 })
        preparation.begin { outcomes.append($0) }
        preparation.begin { _ in XCTFail("A duplicate Quit must not replace the original completion") }
        await waitUntil { !outcomes.isEmpty }
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(outcomes, [.graceful])
        XCTAssertEqual(prepareCalls, 1)
        XCTAssertEqual(forceCalls, 0)
    }

    func testNoncooperativeGracefulCleanupIsForcedBeforeReplyWithoutJoiningIt() async {
        let gate = Gate()
        defer { gate.open() }
        var events: [String] = []
        var outcomes: [TerminationPreparation.Outcome] = []
        let preparation = TerminationPreparation(graceSeconds: 0.02, forceSeconds: 0.02,
            prepare: { events.append("prepare"); await gate.wait(); events.append("late-prepare") },
            force: { events.append("force") })
        preparation.begin { outcomes.append($0); events.append("reply") }
        await waitUntil { !outcomes.isEmpty }
        XCTAssertTrue(gate.entered)
        XCTAssertEqual(outcomes, [.forced])
        XCTAssertEqual(events, ["prepare", "force", "reply"])
        gate.open()
        await waitUntil { events.contains("late-prepare") }
        XCTAssertEqual(outcomes.count, 1)
    }

    func testUncooperativeForceStillHonorsTotalBudgetAndCannotReplyTwice() async {
        let grace = Gate(), force = Gate()
        defer { grace.open(); force.open() }
        var outcomes: [TerminationPreparation.Outcome] = []
        var forceWasInvokedBeforeReply = false
        let preparation = TerminationPreparation(graceSeconds: 0.02, forceSeconds: 0.02,
            prepare: { await grace.wait() }, force: { await force.wait() })
        let start = ContinuousClock.now
        preparation.begin { outcome in
            forceWasInvokedBeforeReply = force.entered
            outcomes.append(outcome)
        }
        await waitUntil { !outcomes.isEmpty }
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(500))
        XCTAssertTrue(forceWasInvokedBeforeReply)
        XCTAssertEqual(outcomes, [.forceDeadline])
        grace.open(); force.open()
        try? await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(outcomes.count, 1)
    }

    func testLateGracefulCompletionCannotBypassAlreadyStartedAbort() async {
        let grace = Gate(), force = Gate()
        defer { grace.open(); force.open() }
        var outcomes: [TerminationPreparation.Outcome] = []
        let preparation = TerminationPreparation(graceSeconds: 0.01, forceSeconds: 0.3,
            prepare: { await grace.wait() }, force: { await force.wait() })
        preparation.begin { outcomes.append($0) }
        await waitUntil { force.entered }
        grace.open()
        try? await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertTrue(outcomes.isEmpty, "Once forcing starts, its completion owns the termination reply")
        force.open()
        await waitUntil { !outcomes.isEmpty }
        XCTAssertEqual(outcomes, [.forced])
    }
}
