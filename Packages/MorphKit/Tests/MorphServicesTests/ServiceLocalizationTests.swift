import XCTest
import MorphCore
@testable import MorphServices

@MainActor
final class ServiceLocalizationTests: XCTestCase {
    private var originalLanguagePreference: Any?

    override func setUp() {
        super.setUp()
        originalLanguagePreference = UserDefaults.standard.object(forKey: ServiceLocalization.languagePreferenceKey)
    }

    override func tearDown() {
        if let originalLanguagePreference {
            UserDefaults.standard.set(originalLanguagePreference, forKey: ServiceLocalization.languagePreferenceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: ServiceLocalization.languagePreferenceKey)
        }
        super.tearDown()
    }

    private func select(_ language: String) {
        UserDefaults.standard.set(language, forKey: ServiceLocalization.languagePreferenceKey)
    }

    func testExplicitLanguageOverridesSystemAndSystemUsesGermanOtherwiseEnglish() {
        XCTAssertEqual(ServiceLocalization.resolvedLanguageCode(preference: "de", preferredLanguages: ["en-US"]), "de")
        XCTAssertEqual(ServiceLocalization.resolvedLanguageCode(preference: "en", preferredLanguages: ["de-AT"]), "en")
        for language in ["de", "de-AT", "de_DE", "DE-Latn-AT"] {
            XCTAssertEqual(ServiceLocalization.resolvedLanguageCode(preference: "system", preferredLanguages: [language]), "de")
        }
        for languages in [["en-US"], ["fr-FR", "de-AT"], [], ["ja-JP"]] {
            XCTAssertEqual(ServiceLocalization.resolvedLanguageCode(preference: "system", preferredLanguages: languages), "en")
        }
    }

    func testMissingAndInvalidPersistedPreferenceFallBackToSystemWithoutRewritingIt() {
        for preference in [nil, "", "invalid", "fr"] as [String?] {
            if let preference { select(preference) }
            else { UserDefaults.standard.removeObject(forKey: ServiceLocalization.languagePreferenceKey) }
            let expected = ServiceLocalization.resolvedLanguageCode(preference: nil, preferredLanguages: Locale.preferredLanguages)
            XCTAssertEqual(ServiceLocalization.languageCode, expected)
            XCTAssertEqual(UserDefaults.standard.string(forKey: ServiceLocalization.languagePreferenceKey), preference)
        }
        UserDefaults.standard.set(42, forKey: ServiceLocalization.languagePreferenceKey)
        XCTAssertEqual(ServiceLocalization.languageCode,
                       ServiceLocalization.resolvedLanguageCode(preference: nil, preferredLanguages: Locale.preferredLanguages))
    }

    func testLanguageSelectionIsReadLiveAndMissingKeysRemainReadable() {
        select("de")
        XCTAssertEqual(ServiceLocalization.languageCode, "de")
        XCTAssertEqual(ServiceLocalization.text("Meine Lampe"), "Meine Lampe")
        select("en")
        XCTAssertEqual(ServiceLocalization.languageCode, "en")
        XCTAssertEqual(ServiceLocalization.text("Meine Lampe"), "My lamp")
        XCTAssertEqual(ServiceLocalization.text("Unknown fallback key"), "Unknown fallback key")
    }

    func testPairingValidationErrorCanChangeLanguageWithoutChangingInputOrStartingCloudLogin() async {
        select("de")
        let cloud = FakeCloud()
        let model = PairingModel(cloudFactory: { _ in cloud })
        model.email = "invalid"
        model.password = "temporary-secret"
        await model.sendCode()
        let key = "Gib deine Dyson-E-Mail-Adresse und dein Passwort ein."
        XCTAssertEqual(model.errorMessage, ServiceLocalization.text(key, languageCode: "de"))
        select("en")
        model.reloadLocalizedText()
        XCTAssertEqual(model.errorMessage, ServiceLocalization.text(key, languageCode: "en"))
        XCTAssertEqual(model.email, "invalid")
        XCTAssertEqual(model.password, "temporary-secret")
        XCTAssertEqual(cloud.beginCalls, 0)
        XCTAssertEqual(model.stage, .account)
        model.clearError()
        select("de")
        model.reloadLocalizedText()
        XCTAssertNil(model.errorMessage)
    }

    func testOtpValidationUsesSelectedLanguageAndDoesNotInvalidateChallengeOnReload() async {
        select("en")
        let cloud = FakeCloud()
        let model = PairingModel(cloudFactory: { _ in cloud })
        model.email = "test@example.com"
        model.password = "temporary-secret"
        await model.sendCode()
        model.otp = "123"
        await model.verifyCode()
        let key = "Gib den sechsstelligen Code aus deiner E-Mail ein."
        XCTAssertEqual(model.errorMessage, ServiceLocalization.text(key, languageCode: "en"))
        select("de")
        model.reloadLocalizedText()
        XCTAssertEqual(model.errorMessage, ServiceLocalization.text(key, languageCode: "de"))
        XCTAssertEqual(model.stage, .code)
        XCTAssertEqual(model.otp, "123")
        XCTAssertEqual(model.password, "temporary-secret")
        XCTAssertEqual(cloud.beginCalls, 1)
        XCTAssertEqual(cloud.verifyCalls, 0)
        model.reset()
        model.reloadLocalizedText()
        XCTAssertNil(model.errorMessage)
    }

    func testMappedLoginFailureReloadsWithoutRepeatingAuthentication() async {
        select("en")
        let cloud = FakeCloud()
        cloud.verifyError = DysonCloudError.httpStatus(401)
        let model = PairingModel(cloudFactory: { _ in cloud })
        model.email = "test@example.com"
        model.password = "temporary-secret"
        await model.sendCode()
        model.otp = "123456"
        await model.verifyCode()
        let key = UserFacingError.key(for: DysonCloudError.httpStatus(401))
        XCTAssertEqual(model.errorMessage, ServiceLocalization.text(key, languageCode: "en"))
        select("de")
        model.reloadLocalizedText()
        XCTAssertEqual(model.errorMessage, ServiceLocalization.text(key, languageCode: "de"))
        XCTAssertEqual(cloud.verifyCalls, 1)
        XCTAssertEqual(cloud.beginCalls, 1)
        XCTAssertEqual(model.stage, .account)
        XCTAssertTrue(model.password.isEmpty)
    }

    func testControllerFailureReloadDoesNotReconnectOrChangeStoredCredentials() async {
        select("en")
        let fake = FakeTransport()
        fake.connectError = MorphError.bluetoothState(.poweredOff)
        let store = MemoryCredentialStore(sampleCredentials())
        let controller = LampController(store: store, transportFactory: { fake })
        await controller.connect()
        let key = UserFacingError.key(for: MorphError.bluetoothState(.poweredOff))
        XCTAssertEqual(controller.errorMessage, ServiceLocalization.text(key, languageCode: "en"))
        select("de")
        controller.reloadLocalizedText()
        XCTAssertEqual(controller.errorMessage, ServiceLocalization.text(key, languageCode: "de"))
        XCTAssertEqual(controller.connection, .failed)
        XCTAssertEqual(fake.connectCalls, 1)
        XCTAssertEqual(fake.disconnectCalls, 1)
        XCTAssertEqual(store.credentials, sampleCredentials())
        controller.dismissError()
        select("en")
        controller.reloadLocalizedText()
        XCTAssertNil(controller.errorMessage)
    }

    func testControllerDefaultNameChangesButUserAssignedNamesRemainUntouched() {
        select("de")
        var unnamed = sampleCredentials()
        unnamed.name = ""
        let unnamedStore = MemoryCredentialStore(unnamed)
        let controller = LampController(store: unnamedStore, transportFactory: { FakeTransport() })
        let named = LampController(store: MemoryCredentialStore(sampleCredentials()), transportFactory: { FakeTransport() })
        XCTAssertEqual(controller.lampName, "Meine Lampe")
        select("en")
        controller.reloadLocalizedText()
        named.reloadLocalizedText()
        XCTAssertEqual(controller.lampName, "My lamp")
        XCTAssertEqual(named.lampName, "Schreibtisch")
        XCTAssertEqual(unnamedStore.credentials?.name, "")
    }

    func testDemoNameAndDirectDisconnectMessageReloadWithoutStartingConnection() async {
        select("de")
        let demo = LampController(demo: true)
        XCTAssertEqual(demo.lampName, "Schreibtisch")
        select("en")
        demo.reloadLocalizedText()
        XCTAssertEqual(demo.lampName, "Desk")
        XCTAssertEqual(demo.connection, .disconnected)
        let fake = FakeTransport()
        let controller = LampController(store: MemoryCredentialStore(sampleCredentials()), transportFactory: { fake })
        await controller.connect()
        fake.onDisconnect?()
        let key = "Die Verbindung zur Lampe wurde unterbrochen. Verbinde sie erneut."
        XCTAssertEqual(controller.errorMessage, ServiceLocalization.text(key, languageCode: "en"))
        select("de")
        controller.reloadLocalizedText()
        XCTAssertEqual(controller.errorMessage, ServiceLocalization.text(key, languageCode: "de"))
        XCTAssertEqual(fake.connectCalls, 1)
        await controller.releaseConnection()
    }
}
