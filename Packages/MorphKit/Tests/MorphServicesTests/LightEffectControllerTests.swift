import XCTest
import MorphCore
@testable import MorphServices

@MainActor
final class LightEffectControllerTests: XCTestCase {
    private func workingLamp(power: Bool = true) -> FakeTransport {
        let fake = FakeTransport()
        fake.state.power = power
        fake.state.daylight = true
        fake.state.autoBrightness = true
        fake.state.preset = .study
        fake.state.movement = false
        fake.applyHandler = { [weak fake] action in
            guard let fake else { return }
            switch action {
            case .power(let value): fake.state.power = value
            case .preset(let value): fake.state.preset = value
            case .daylight(let value): fake.state.daylight = value
            case .autoBrightness(let value): fake.state.autoBrightness = value
            case .movement(let value): fake.state.movement = value
            case .brightness(let value): fake.state.brightness = value
            case .kelvin(let value): fake.state.kelvin = value
            case .effectFrame(let frame):
                fake.state.brightness = frame.brightness
                fake.state.kelvin = frame.kelvin
            case .refresh: break
            }
        }
        return fake
    }

    private func controller(_ fake: FakeTransport, keepAlive: Bool = true, sync: Bool = false) -> LampController {
        LampController(store: MemoryCredentialStore(sampleCredentials()), transportFactory: { fake },
                       idleSeconds: 0.02, keepConnectionAlive: keepAlive, syncPowerWithMac: sync,
                       commandMinimumGap: .milliseconds(1), effectTickSeconds: 0.01)
    }

    private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate(), ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(predicate(), "Expected effect transition did not occur", file: file, line: line)
    }

    private func frames(_ fake: FakeTransport) -> [LightEffectFrame] {
        fake.actions.compactMap { if case .effectFrame(let frame) = $0 { return frame }; return nil }
    }

    func testStartStrictlyReadsDisablesModesAndPowersOnOnlyOnceBeforeFrames() async {
        let fake = workingLamp(power: false)
        let controller = controller(fake)
        await controller.connect()
        await controller.startLightEffect(.morph)
        await waitUntil { !self.frames(fake).isEmpty }
        XCTAssertEqual(Array(fake.actions.prefix(4)), [.preset(nil), .daylight(false), .autoBrightness(false), .power(true)])
        XCTAssertEqual(fake.refreshCalls, [true, true])
        XCTAssertEqual(fake.actions.filter { $0 == .power(true) }.count, 1)
        XCTAssertEqual(controller.activeLightEffect, .morph)
        XCTAssertFalse(controller.isStartingLightEffect)
        XCTAssertFalse(controller.state?.movement ?? true)
        XCTAssertFalse(controller.syncPowerWithMac)
        XCTAssertTrue(controller.keepConnectionAlive)
        await controller.releaseConnection()
    }

    func testAlreadyPoweredLampSkipsPowerWriteAndSteadyEffectIsNotGloballyBusy() async {
        let fake = workingLamp()
        let controller = controller(fake)
        await controller.connect()
        await controller.startLightEffect(.party)
        await waitUntil { !self.frames(fake).isEmpty && !controller.isBusy }
        XCTAssertFalse(fake.actions.contains(.power(true)))
        XCTAssertEqual(controller.activeLightEffect, .party)
        XCTAssertEqual(fake.refreshCalls, [true, true], "Frames must not perform full status reads")
        await controller.releaseConnection()
    }

    func testStopFreezesLastStateAndRefreshesOnceWithoutRestoringOldModes() async {
        let fake = workingLamp()
        let controller = controller(fake)
        await controller.connect()
        await controller.startLightEffect(.party)
        await waitUntil { !self.frames(fake).isEmpty && !controller.isBusy }
        let frozen = self.frames(fake).last
        controller.stopLightEffect()
        controller.stopLightEffect()
        await waitUntil { !controller.isBusy && fake.refreshCalls.count == 3 }
        let frameCount = self.frames(fake).count
        try? await Task.sleep(nanoseconds: 70_000_000)
        XCTAssertEqual(self.frames(fake).count, frameCount)
        XCTAssertEqual(controller.state?.brightness, frozen?.brightness)
        XCTAssertEqual(controller.state?.kelvin, frozen?.kelvin)
        XCTAssertEqual(controller.state?.daylight, false)
        XCTAssertEqual(controller.state?.autoBrightness, false)
        XCTAssertNil(controller.state?.preset)
        XCTAssertNil(controller.activeLightEffect)
        XCTAssertFalse(controller.isStartingLightEffect)
        await controller.releaseConnection()
    }

    func testRestoreStopsEffectAndCompletesExistingAutomaticLightingMacro() async {
        let fake = workingLamp()
        let controller = controller(fake)
        await controller.connect()
        await controller.startLightEffect(.party)
        await waitUntil { !self.frames(fake).isEmpty }
        await controller.restoreAutomaticLighting()
        let completedCount = self.frames(fake).count
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(self.frames(fake).count, completedCount)
        XCTAssertNil(controller.activeLightEffect)
        XCTAssertEqual(controller.state?.daylight, true)
        XCTAssertEqual(controller.state?.autoBrightness, true)
        XCTAssertNil(controller.state?.preset)
        XCTAssertFalse(controller.state?.movement ?? true)
        XCTAssertNil(controller.errorMessage)
        await controller.releaseConnection()
    }

    func testEachManualLightingControlOverridesEffectWithoutLaterFrames() async {
        let actions: [(LampAction, (LampController) -> Void)] = [
            (.brightness(42), { $0.setBrightness(42) }), (.kelvin(4200), { $0.setKelvin(4200) }),
            (.power(false), { $0.setPower(false) }), (.preset(.relax), { $0.setPreset(.relax) }),
            (.daylight(true), { $0.setDaylight(true) }), (.autoBrightness(true), { $0.setAutoBrightness(true) })
        ]
        for (action, perform) in actions {
            let fake = workingLamp()
            let controller = controller(fake)
            await controller.connect()
            await controller.startLightEffect(.party)
            await waitUntil { !self.frames(fake).isEmpty && !controller.isBusy }
            perform(controller)
            await waitUntil { fake.actions.last == action && !controller.isBusy }
            let count = fake.actions.count
            try? await Task.sleep(nanoseconds: 30_000_000)
            XCTAssertEqual(fake.actions.count, count)
            XCTAssertNil(controller.activeLightEffect)
            XCTAssertFalse(controller.isStartingLightEffect)
            await controller.releaseConnection()
        }
    }

    func testMovementCanChangeWithoutStoppingEffect() async {
        let fake = workingLamp()
        let controller = controller(fake)
        await controller.connect()
        await controller.startLightEffect(.party)
        controller.setMovement(true)
        await waitUntil { fake.actions.contains(.movement(true)) }
        XCTAssertEqual(controller.activeLightEffect, .party)
        XCTAssertEqual(controller.state?.movement, true)
        await controller.releaseConnection()
    }

    func testPhysicalOrSensorPowerOffStopsEffectAndCannotBeOverriddenByFrames() async {
        let fake = workingLamp()
        let controller = controller(fake)
        await controller.connect()
        await controller.startLightEffect(.party)
        await waitUntil { !self.frames(fake).isEmpty && !controller.isBusy }
        fake.state.power = false
        fake.onStateChange?(fake.state)
        await waitUntil { controller.activeLightEffect == nil && !controller.isBusy }
        let count = self.frames(fake).count
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(self.frames(fake).count, count)
        XCTAssertFalse(controller.state?.power ?? true)
        XCTAssertFalse(fake.actions.contains(.power(true)))
        await controller.releaseConnection()
    }

    func testRefreshPowerOffStopsEffectEvenWithoutTransportNotification() async {
        let fake = workingLamp()
        let controller = controller(fake)
        await controller.connect()
        await controller.startLightEffect(.party)
        await waitUntil { !self.frames(fake).isEmpty && !controller.isBusy }
        var offState = fake.state
        offState.power = false
        fake.refreshedState = offState
        await controller.refresh()
        XCTAssertNil(controller.activeLightEffect)
        XCTAssertFalse(controller.isStartingLightEffect)
        XCTAssertFalse(controller.state?.power ?? true)
        let count = self.frames(fake).count
        try? await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(self.frames(fake).count, count)
        await controller.releaseConnection()
    }

    func testEffectHoldsClosedPanelConnectionEvenWithKeepAliveOffAndStopRestoresIdleRelease() async {
        let fake = workingLamp()
        let controller = controller(fake, keepAlive: false)
        await controller.connect()
        await controller.startLightEffect(.morph)
        controller.panelClosed()
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(controller.connection, .connected)
        XCTAssertEqual(fake.disconnectCalls, 0)
        controller.stopLightEffect()
        await waitUntil { controller.connection == .disconnected && !controller.isBusy }
        XCTAssertEqual(fake.disconnectCalls, 1)
    }

    func testSleepAndShutdownStopEffectAndPreserveFinalPowerOff() async {
        for isShutdown in [false, true] {
            let fake = workingLamp()
            let controller = controller(fake, sync: true)
            await controller.connect()
            await controller.startLightEffect(.party)
            await waitUntil { !self.frames(fake).isEmpty && !controller.isBusy }
            if isShutdown { await controller.prepareForPowerOff() }
            else { await controller.suspendForSleep() }
            XCTAssertEqual(fake.actions.last, .power(false))
            XCTAssertEqual(fake.events.last, .disconnect)
            XCTAssertNil(controller.activeLightEffect)
            XCTAssertFalse(controller.isStartingLightEffect)
            let count = self.frames(fake).count
            controller.resumeAfterWake()
            await waitUntil { controller.connection == .connected }
            try? await Task.sleep(nanoseconds: 40_000_000)
            XCTAssertNil(controller.activeLightEffect)
            XCTAssertEqual(self.frames(fake).count, count)
            await controller.releaseConnection()
        }
    }

    func testReleaseForgetAndBluetoothDropStopWithoutEffectResume() async throws {
        for operation in 0...2 {
            let fake = workingLamp()
            let controller = controller(fake)
            await controller.connect()
            await controller.startLightEffect(.party)
            await waitUntil { !self.frames(fake).isEmpty && !controller.isBusy }
            if operation == 0 { await controller.releaseConnection() }
            else if operation == 1 { try await controller.forgetLamp() }
            else { fake.onDisconnect?(); await waitUntil { !controller.isBusy } }
            XCTAssertNil(controller.activeLightEffect)
            XCTAssertFalse(controller.isStartingLightEffect)
            let count = self.frames(fake).count
            try? await Task.sleep(nanoseconds: 40_000_000)
            XCTAssertEqual(self.frames(fake).count, count)
        }
    }

    func testDoubleStartRunsOnePreparationAndSwitchHasOneFinalEffect() async {
        let fake = workingLamp()
        let controller = controller(fake)
        await controller.connect()
        async let first: Void = controller.startLightEffect(.morph)
        async let duplicate: Void = controller.startLightEffect(.morph)
        _ = await (first, duplicate)
        XCTAssertEqual(fake.refreshCalls, [true, true])
        let switchTask = Task { await controller.startLightEffect(.party) }
        await waitUntil { controller.isStartingLightEffect }
        await switchTask.value
        XCTAssertEqual(controller.activeLightEffect, .party)
        XCTAssertFalse(controller.isStartingLightEffect)
        XCTAssertEqual(fake.refreshCalls, [true, true, true, true])
        await controller.releaseConnection()
    }

    func testSwitchDuringPreparationDoesNotStartOldTimerOrClearNewFlags() async {
        let fake = workingLamp()
        fake.applyDelay = 20_000_000
        let controller = controller(fake)
        await controller.connect()
        let first = Task { await controller.startLightEffect(.morph) }
        await waitUntil { controller.isStartingLightEffect }
        let second = Task { await controller.startLightEffect(.party) }
        await first.value
        await second.value
        await waitUntil { !self.frames(fake).isEmpty }
        XCTAssertEqual(controller.activeLightEffect, .party)
        XCTAssertFalse(controller.isStartingLightEffect)
        XCTAssertEqual(self.frames(fake).first, .init(brightness: 60, kelvin: 6500))
        await controller.releaseConnection()
    }

    func testStopDuringPreparationDiscardsPendingPowerOnAndModes() async {
        let fake = workingLamp(power: false)
        fake.applyDelay = 30_000_000
        let controller = controller(fake)
        await controller.connect()
        let start = Task { await controller.startLightEffect(.morph) }
        await waitUntil { fake.actions.contains(.preset(nil)) }
        controller.stopLightEffect()
        await start.value
        await waitUntil { !controller.isBusy }
        XCTAssertEqual(fake.actions, [.preset(nil)])
        XCTAssertTrue(self.frames(fake).isEmpty)
        XCTAssertFalse(fake.state.power)
        XCTAssertNil(controller.activeLightEffect)
        XCTAssertFalse(controller.isStartingLightEffect)
        await controller.releaseConnection()
    }

    func testStartDiscardsOldPendingSliderAndProfileValues() async {
        let fake = workingLamp()
        fake.applyDelay = 20_000_000
        let controller = controller(fake)
        await controller.connect()
        controller.setBrightness(10)
        await waitUntil { fake.actions == [.brightness(10)] }
        controller.setBrightness(90)
        controller.setKelvin(4100)
        controller.setPreset(.relax)
        await controller.startLightEffect(.morph)
        XCTAssertFalse(fake.actions.contains(.brightness(90)))
        XCTAssertFalse(fake.actions.contains(.kelvin(4100)))
        XCTAssertFalse(fake.actions.contains(.preset(.relax)))
        XCTAssertEqual(controller.activeLightEffect, .morph)
        await controller.releaseConnection()
    }

    func testStrictReadFailureAndFrameWriteFailureStopWithoutRetries() async {
        let failedRead = workingLamp()
        failedRead.refreshError = MorphError.bluetooth("Synthetic read failure")
        let first = controller(failedRead)
        await first.connect()
        await first.startLightEffect(.morph)
        await waitUntil { !first.isBusy }
        XCTAssertEqual(first.connection, .failed)
        XCTAssertNil(first.activeLightEffect)
        XCTAssertFalse(first.isStartingLightEffect)
        XCTAssertTrue(failedRead.actions.isEmpty)
        let failedFrame = workingLamp()
        let handler = failedFrame.applyHandler
        failedFrame.applyHandler = { action in
            if case .effectFrame = action { throw MorphError.bluetooth("Synthetic frame failure") }
            try handler?(action)
        }
        let second = controller(failedFrame)
        await second.connect()
        await second.startLightEffect(.party)
        await waitUntil { second.connection == .failed && !second.isBusy }
        let count = self.frames(failedFrame).count
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(self.frames(failedFrame).count, count)
        XCTAssertNil(second.activeLightEffect)
        XCTAssertFalse(second.isStartingLightEffect)
        XCTAssertNotNil(second.errorMessage)
    }
}
