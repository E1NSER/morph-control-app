import XCTest
@testable import MorphServices

@MainActor
final class CommandQueueTests: XCTestCase {
    func testCoalescingOrderingAndMinimumWriteGap() async {
        var performed: [LampAction] = []
        var dates: [ContinuousClock.Instant] = []
        var active = 0
        var maximumActive = 0
        var errors = 0
        let queue = CommandQueue(execute: { action in
            active += 1
            maximumActive = max(maximumActive, active)
            dates.append(.now)
            performed.append(action)
            try await Task.sleep(nanoseconds: 20_000_000)
            active -= 1
        }, onError: { _ in errors += 1 })
        queue.enqueue(.power(true))
        await Task.yield()
        for value in 1...90 { queue.enqueue(.brightness(value)) }
        queue.enqueue(.kelvin(3000))
        queue.enqueue(.kelvin(4100))
        await queue.waitUntilIdle()
        XCTAssertEqual(performed, [.power(true), .brightness(90), .kelvin(4100)])
        XCTAssertEqual(maximumActive, 1)
        XCTAssertEqual(errors, 0)
        for pair in zip(dates, dates.dropFirst()) {
            XCTAssertGreaterThanOrEqual(pair.0.duration(to: pair.1), .milliseconds(145))
        }
    }

    func testCancelDropsQueuedWorkAndStopsActiveOperation() async {
        var performed: [LampAction] = []
        var errors = 0
        let queue = CommandQueue(execute: { action in
            performed.append(action)
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }, onError: { _ in errors += 1 })
        queue.enqueue(.power(true))
        await Task.yield()
        queue.enqueue(.brightness(90))
        queue.cancel()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(performed, [.power(true)])
        XCTAssertEqual(errors, 0)
    }

    func testFailureClearsPendingCommands() async {
        var performed: [LampAction] = []
        var errors = 0
        let queue = CommandQueue(execute: { action in
            performed.append(action)
            throw ServiceError.deadline
        }, onError: { _ in errors += 1 })
        queue.enqueue(.power(true))
        queue.enqueue(.brightness(50))
        await queue.waitUntilIdle()
        XCTAssertEqual(performed, [.power(true)])
        XCTAssertEqual(errors, 1)
    }

    func testEffectFramesCoalesceToOneNewestPendingValue() async {
        let first = LightEffectFrame(brightness: 25, kelvin: 2700)
        let last = LightEffectFrame(brightness: 70, kelvin: 6500)
        var performed: [LampAction] = []
        let queue = CommandQueue(minimumGap: .milliseconds(1), execute: { action in
            performed.append(action)
            try await Task.sleep(nanoseconds: 20_000_000)
        }, onError: { _ in XCTFail("Unexpected frame failure") })
        queue.enqueue(.effectFrame(first))
        await Task.yield()
        for value in 26...69 { queue.enqueue(.effectFrame(.init(brightness: value, kelvin: 4000))) }
        queue.enqueue(.effectFrame(last))
        await queue.waitUntilIdle()
        XCTAssertEqual(performed, [.effectFrame(first), .effectFrame(last)])
    }
}
