import XCTest
@testable import MorphServices

@MainActor
final class EffectFrameWriterTests: XCTestCase {
    private enum Failure: Error { case rawWrite }

    func testWritesBrightnessThenKelvinAndSkipsPreviouslySentValues() async throws {
        let writer = EffectFrameWriter(minimumGap: .milliseconds(5))
        let frame = LightEffectFrame(brightness: 60, kelvin: 4200)
        var writes: [String] = []
        for _ in 0..<2 {
            try await writer.write(frame, baseline: nil, ifAllowed: { true },
                setBrightness: { writes.append("brightness:\($0)") },
                setKelvin: { writes.append("kelvin:\($0)") })
        }
        XCTAssertEqual(writes, ["brightness:60", "kelvin:4200"])
    }

    func testBaselineAndPerAttributeCacheWriteOnlyChangedValues() async throws {
        let writer = EffectFrameWriter(minimumGap: .milliseconds(5))
        let baseline = LightEffectFrame(brightness: 30, kelvin: 3000)
        var writes: [String] = []
        for frame in [baseline, .init(brightness: 30, kelvin: 4200), .init(brightness: 60, kelvin: 4200)] {
            try await writer.write(frame, baseline: baseline, ifAllowed: { true },
                setBrightness: { writes.append("brightness:\($0)") },
                setKelvin: { writes.append("kelvin:\($0)") })
        }
        XCTAssertEqual(writes, ["kelvin:4200", "brightness:60"])
    }

    func testDefaultGapAppliesWithinAndBetweenFrames() async throws {
        let writer = EffectFrameWriter()
        var brightnessCompletion: ContinuousClock.Instant?
        var kelvinStart: ContinuousClock.Instant?
        var kelvinCompletion: ContinuousClock.Instant?
        var nextBrightnessStart: ContinuousClock.Instant?
        try await writer.write(.init(brightness: 60, kelvin: 4200), baseline: nil, ifAllowed: { true },
            setBrightness: { _ in brightnessCompletion = .now },
            setKelvin: { _ in kelvinStart = .now; kelvinCompletion = .now })
        try await writer.write(.init(brightness: 61, kelvin: 4200), baseline: nil, ifAllowed: { true },
            setBrightness: { _ in nextBrightnessStart = .now },
            setKelvin: { _ in XCTFail("Unchanged temperature must not be written") })
        XCTAssertGreaterThanOrEqual(brightnessCompletion!.duration(to: kelvinStart!), .milliseconds(150))
        XCTAssertGreaterThanOrEqual(kelvinCompletion!.duration(to: nextBrightnessStart!), .milliseconds(150))
    }

    func testStopAfterBrightnessSkipsKelvinAndKeepsSuccessfulCache() async throws {
        let writer = EffectFrameWriter(minimumGap: .milliseconds(5))
        let frame = LightEffectFrame(brightness: 60, kelvin: 4200)
        var allowed = true
        var writes: [String] = []
        try await writer.write(frame, baseline: nil, ifAllowed: { allowed },
            setBrightness: { value in writes.append("brightness:\(value)"); allowed = false },
            setKelvin: { _ in XCTFail("Stopped frame must not write its second characteristic") })
        allowed = true
        try await writer.write(frame, baseline: nil, ifAllowed: { allowed },
            setBrightness: { _ in XCTFail("Successful first write must remain cached") },
            setKelvin: { writes.append("kelvin:\($0)") })
        XCTAssertEqual(writes, ["brightness:60", "kelvin:4200"])
    }

    func testNotAllowedFrameWritesNothingWithoutError() async throws {
        let writer = EffectFrameWriter(minimumGap: .milliseconds(5))
        try await writer.write(.init(brightness: 60, kelvin: 4200), baseline: nil, ifAllowed: { false },
            setBrightness: { _ in XCTFail("Disallowed frame must not write") },
            setKelvin: { _ in XCTFail("Disallowed frame must not write") })
    }

    func testFailedBrightnessIsRetriedAndNotCached() async throws {
        let writer = EffectFrameWriter(minimumGap: .milliseconds(5))
        let frame = LightEffectFrame(brightness: 60, kelvin: 4200)
        var brightnessAttempts = 0
        var kelvinWrites = 0
        do {
            try await writer.write(frame, baseline: nil, ifAllowed: { true },
                setBrightness: { _ in brightnessAttempts += 1; throw Failure.rawWrite },
                setKelvin: { _ in XCTFail("Failure must stop the frame") })
            XCTFail("Expected raw write failure")
        } catch Failure.rawWrite {}
        try await writer.write(frame, baseline: nil, ifAllowed: { true },
            setBrightness: { _ in brightnessAttempts += 1 }, setKelvin: { _ in kelvinWrites += 1 })
        XCTAssertEqual(brightnessAttempts, 2)
        XCTAssertEqual(kelvinWrites, 1)
    }

    func testFailedKelvinRetriesOnlyKelvin() async throws {
        let writer = EffectFrameWriter(minimumGap: .milliseconds(5))
        let frame = LightEffectFrame(brightness: 60, kelvin: 4200)
        var brightnessWrites = 0
        var kelvinAttempts = 0
        do {
            try await writer.write(frame, baseline: nil, ifAllowed: { true },
                setBrightness: { _ in brightnessWrites += 1 },
                setKelvin: { _ in kelvinAttempts += 1; throw Failure.rawWrite })
            XCTFail("Expected raw write failure")
        } catch Failure.rawWrite {}
        try await writer.write(frame, baseline: nil, ifAllowed: { true },
            setBrightness: { _ in brightnessWrites += 1 }, setKelvin: { _ in kelvinAttempts += 1 })
        XCTAssertEqual(brightnessWrites, 1)
        XCTAssertEqual(kelvinAttempts, 2)
    }

    func testCancellationDuringPacingDoesNotSendAnotherWrite() async throws {
        let writer = EffectFrameWriter(minimumGap: .milliseconds(150))
        var rawWrites = 0
        try await writer.write(.init(brightness: 60, kelvin: 3000),
            baseline: .init(brightness: 30, kelvin: 3000), ifAllowed: { true },
            setBrightness: { _ in rawWrites += 1 }, setKelvin: { _ in rawWrites += 1 })
        var started = false
        let nextFrame = Task {
            started = true
            try await writer.write(.init(brightness: 61, kelvin: 4200), baseline: nil, ifAllowed: { true },
                setBrightness: { _ in rawWrites += 1 }, setKelvin: { _ in rawWrites += 1 })
        }
        while !started { await Task.yield() }
        nextFrame.cancel()
        do { try await nextFrame.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
        XCTAssertEqual(rawWrites, 1)
    }

    func testResetClearsCacheAndPreservesRawWriteGap() async throws {
        let writer = EffectFrameWriter()
        let frame = LightEffectFrame(brightness: 60, kelvin: 3000)
        var lastCompletion: ContinuousClock.Instant?
        var nextStart: ContinuousClock.Instant?
        try await writer.write(frame, baseline: .init(brightness: 30, kelvin: 3000), ifAllowed: { true },
            setBrightness: { _ in lastCompletion = .now }, setKelvin: { _ in XCTFail("Unchanged temperature") })
        writer.reset()
        try await writer.write(frame, baseline: nil, ifAllowed: { true },
            setBrightness: { _ in nextStart = .now }, setKelvin: { _ in })
        XCTAssertGreaterThanOrEqual(lastCompletion!.duration(to: nextStart!), .milliseconds(150))
    }

    func testResetDuringWritePreventsOldFrameFromRepopulatingCache() async throws {
        let writer = EffectFrameWriter(minimumGap: .milliseconds(5))
        let frame = LightEffectFrame(brightness: 60, kelvin: 4200)
        var brightnessWrites = 0
        try await writer.write(frame, baseline: nil, ifAllowed: { true },
            setBrightness: { _ in brightnessWrites += 1; writer.reset() },
            setKelvin: { _ in XCTFail("Reset invalidates the old frame") })
        try await writer.write(frame, baseline: nil, ifAllowed: { true },
            setBrightness: { _ in brightnessWrites += 1 }, setKelvin: { _ in })
        XCTAssertEqual(brightnessWrites, 2)
    }
}
