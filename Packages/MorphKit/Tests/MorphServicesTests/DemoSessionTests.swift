import XCTest
import MorphCore
@testable import MorphServices

@MainActor
final class DemoSessionTests: XCTestCase {
    private final class StoreSpy: CredentialStore {
        var value: LampCredentials? = sampleCredentials()
        var reads = 0
        var writes = 0
        var deletes = 0
        func load() throws -> LampCredentials? { reads += 1; return value }
        func save(_ credentials: LampCredentials) throws { writes += 1; value = credentials }
        func delete() throws { deletes += 1; value = nil }
    }

    private func demo() -> LampController {
        let transport = DemoLampTransport()
        return LampController(store: MemoryCredentialStore(sampleCredentials()), transportFactory: { transport },
                              keepConnectionAlive: true, syncPowerWithMac: true,
                              commandMinimumGap: .milliseconds(1), effectTickSeconds: 0.01, isDemo: true)
    }

    func testPublicDemoFactoryUsesSimulationAndIgnoresMacPowerPolicy() async {
        let controller = LampController(demo: true, syncPowerWithMac: true)
        XCTAssertTrue(controller.isDemo)
        XCTAssertFalse(controller.syncPowerWithMac)
        controller.setSyncPowerWithMac(true)
        await controller.connect()
        await controller.suspendForSleep()
        await controller.prepareForPowerOff()
        controller.resumeAfterWake()
        controller.recoverAfterInactivity()
        XCTAssertEqual(controller.connection, .connected)
        XCTAssertEqual(controller.state?.power, true)
        XCTAssertFalse(controller.syncPowerWithMac)
        await controller.releaseConnection()
    }

    #if DEBUG
    func testIsolatedSetupFixtureCanEnterAndExitWithoutLiveDependencies() async {
        let setup = LampController.isolatedSetupPreview()
        let pairing = PairingModel.isolatedSetupPreview()
        setup.start()
        setup.panelOpened()
        await setup.connect()
        XCTAssertFalse(setup.hasCredentials)
        XCTAssertEqual(setup.connection, .unpaired)
        // Even an accidentally submitted fixture form fails entirely locally.
        pairing.email = "demo@example.invalid"
        pairing.password = "test-only"
        await pairing.sendCode()
        XCTAssertEqual(pairing.stage, .account)
        XCTAssertFalse(pairing.isBusy)
        let session = LampSession(controller: setup, realControllerFactory: {
            XCTFail("Existing empty setup should be retained")
            return LampController.isolatedSetupPreview()
        })
        await session.enterDemo()
        XCTAssertTrue(session.controller.isDemo)
        XCTAssertEqual(session.controller.connection, .connected)
        await session.exitDemo()
        XCTAssertTrue(session.controller === setup)
        XCTAssertFalse(session.controller.hasCredentials)
        XCTAssertEqual(session.controller.connection, .unpaired)
    }
    #endif

    func testDemoControlsAndEffectsNeverReachRetainedRealLampOrCredentials() async throws {
        let store = StoreSpy()
        let saved = store.value
        let physical = FakeTransport()
        let real = LampController(store: store, transportFactory: { physical }, keepConnectionAlive: true,
                                  syncPowerWithMac: true, recoveryRetrySeconds: 0.01)
        await real.connect()
        var realFactoryCalls = 0
        let session = LampSession(controller: real, realControllerFactory: {
            realFactoryCalls += 1
            return real
        }, demoControllerFactory: { self.demo() })
        await session.enterDemo()
        let simulated = session.controller
        XCTAssertTrue(simulated.isDemo)
        XCTAssertEqual(physical.disconnectCalls, 1)
        XCTAssertTrue(physical.actions.isEmpty, "Entering demo only releases, without switching off the user's lamp")

        simulated.setPower(false)
        await simulated.refresh()
        XCTAssertEqual(simulated.state?.power, false)
        simulated.setBrightness(46)
        simulated.setKelvin(5200)
        await simulated.refresh()
        XCTAssertEqual(simulated.state?.power, true)
        XCTAssertEqual(simulated.state?.brightness, 46)
        XCTAssertEqual(simulated.state?.kelvin, 5200)
        for preset in Preset.allCases {
            simulated.setPreset(preset)
            await simulated.refresh()
            XCTAssertEqual(simulated.state?.preset, preset)
        }
        simulated.setMovement(false)
        await simulated.refresh()
        await simulated.restoreAutomaticLighting()
        XCTAssertEqual(simulated.state?.daylight, true)
        XCTAssertEqual(simulated.state?.autoBrightness, true)
        XCTAssertEqual(simulated.state?.movement, false)
        for effect in LightEffect.allCases {
            await simulated.startLightEffect(effect)
            XCTAssertEqual(simulated.activeLightEffect, effect)
            simulated.stopLightEffect()
            await simulated.refresh()
            XCTAssertNil(simulated.activeLightEffect)
        }
        simulated.renameLamp("Demo edit")

        // A stale view, recovery callback or Mac notification retaining the
        // physical controller must remain inert until an explicit demo exit.
        real.start()
        real.panelOpened()
        real.resumeAfterWake()
        real.recoverAfterInactivity()
        real.setKeepConnectionAlive(true)
        real.setSyncPowerWithMac(true)
        await real.connect()
        await real.suspendForSleep()
        await real.prepareForPowerOff()
        real.renameLamp("Must not save")
        do { try await real.forgetLamp(); XCTFail("Inactive controller must reject credential deletion") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        try? await Task.sleep(nanoseconds: 35_000_000)
        XCTAssertEqual(physical.connectCalls, 1)
        XCTAssertTrue(physical.actions.isEmpty)
        XCTAssertEqual(store.reads, 1)
        XCTAssertEqual(store.writes, 0)
        XCTAssertEqual(store.deletes, 0)
        XCTAssertEqual(store.value, saved)

        await session.exitDemo()
        XCTAssertTrue(session.controller === real)
        XCTAssertEqual(realFactoryCalls, 0)
        XCTAssertEqual(real.connection, .disconnected)
        XCTAssertTrue(real.isConnectionPaused)
        XCTAssertEqual(store.reads, 1, "Returning to an existing lamp does not reload Keychain")
        XCTAssertEqual(real.lampName, saved?.name)
        XCTAssertEqual(physical.connectCalls, 1, "Exit does not trigger real power-on or reconnect")
        XCTAssertTrue(physical.actions.isEmpty)
        await real.connect()
        XCTAssertEqual(physical.connectCalls, 2)
        await real.releaseConnection()
    }

    func testFreshDemoIsDiscardedAndUnpairedSetupIsRestored() async {
        let emptyStore = StoreSpy()
        emptyStore.value = nil
        let real = LampController(store: emptyStore, transportFactory: { XCTFail("No physical transport expected"); return FakeTransport() })
        let session = LampSession(controller: real, realControllerFactory: { real }, demoControllerFactory: { self.demo() })
        await session.enterDemo()
        let first = session.controller
        first.renameLamp("Temporary name")
        await session.exitDemo()
        XCTAssertFalse(session.controller.hasCredentials)
        XCTAssertEqual(session.controller.connection, .unpaired)
        await session.enterDemo()
        XCTAssertFalse(session.controller === first)
        XCTAssertNotEqual(session.controller.lampName, "Temporary name")
        XCTAssertEqual(emptyStore.reads, 1)
        XCTAssertEqual(emptyStore.writes, 0)
        XCTAssertEqual(emptyStore.deletes, 0)
        await session.exitDemo()
    }

    func testPairingIsCancelledAndCannotCreateCloudClientDuringDemo() async {
        let cloud = FakeCloud()
        cloud.delay = 5_000_000_000
        var factories = 0
        let pairing = PairingModel(cloudFactory: { _ in factories += 1; return cloud })
        pairing.email = "demo@example.invalid"
        pairing.password = "test-only"
        let login = Task { await pairing.sendCode() }
        while cloud.beginCalls == 0 { await Task.yield() }
        pairing.setDemoMode(true)
        await login.value
        XCTAssertFalse(pairing.isBusy)
        XCTAssertEqual(pairing.stage, .account)
        XCTAssertEqual(pairing.password, "")
        XCTAssertEqual(pairing.email, "")
        pairing.email = "demo@example.invalid"
        pairing.password = "test-only"
        await pairing.sendCode()
        await pairing.verifyCode()
        XCTAssertEqual(factories, 1)
        XCTAssertEqual(cloud.beginCalls, 1)
        XCTAssertEqual(cloud.verifyCalls, 0)
        pairing.setDemoMode(false)
        pairing.email = "demo@example.invalid"
        pairing.password = "test-only"
        cloud.delay = 0
        await pairing.sendCode()
        XCTAssertEqual(factories, 2)
        XCTAssertEqual(pairing.stage, .code)
        pairing.reset()
    }

    func testDemoLanguageOverrideDoesNotWritePersistentPreference() {
        let saved = UserDefaults.standard.object(forKey: ServiceLocalization.languagePreferenceKey) as? String
        defer { ServiceLocalization.setTemporaryLanguage(nil) }
        ServiceLocalization.setTemporaryLanguage("en")
        XCTAssertEqual(ServiceLocalization.languageCode, "en")
        ServiceLocalization.setTemporaryLanguage("de")
        XCTAssertEqual(ServiceLocalization.languageCode, "de")
        ServiceLocalization.setTemporaryLanguage("system")
        XCTAssertEqual(ServiceLocalization.languageCode,
                       ServiceLocalization.resolvedLanguageCode(preference: "system", preferredLanguages: Locale.preferredLanguages))
        XCTAssertEqual(UserDefaults.standard.object(forKey: ServiceLocalization.languagePreferenceKey) as? String, saved)
    }
}
