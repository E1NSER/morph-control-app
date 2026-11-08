import XCTest
import MorphCore
@testable import MorphServices

@MainActor
final class PairingModelTests: XCTestCase {
    private func account(_ model: PairingModel) {
        model.email = "  test@example.com  "
        model.password = "temporary-password-secret"
        model.country = "at"
    }

    func testPairingObtainsKeysBeforeSelectionAndStoresNoLoginSecrets() async throws {
        let cloud = FakeCloud()
        let model = PairingModel(cloudFactory: { _ in cloud })
        account(model)
        await model.sendCode()
        XCTAssertEqual(model.stage, .code)
        XCTAssertEqual(cloud.receivedEmail, "test@example.com")
        model.otp = "123456"
        await model.verifyCode()
        XCTAssertEqual(model.stage, .devices)
        XCTAssertTrue(model.password.isEmpty)
        XCTAssertTrue(model.otp.isEmpty)
        XCTAssertEqual(cloud.fetchedSerials, ["TEST-EU-12345678"])
        let store = MemoryCredentialStore()
        let controller = LampController(store: store, transportFactory: { FakeTransport() })
        await model.pair(try XCTUnwrap(model.devices.first), controller: controller)
        XCTAssertEqual(model.stage, .complete)
        XCTAssertTrue(controller.hasCredentials)
        XCTAssertEqual(controller.connection, .disconnected)
        let json = String(data: try JSONEncoder().encode(try XCTUnwrap(store.credentials)), encoding: .utf8)!
        XCTAssertFalse(json.contains("temporary-password-secret"))
        XCTAssertFalse(json.contains("temporary-bearer-secret"))
    }

    func testIncorrectOtpClearsPasswordAndAllowsNewLogin() async {
        let cloud = FakeCloud()
        cloud.verifyError = DysonCloudError.httpStatus(401)
        let model = PairingModel(cloudFactory: { _ in cloud })
        account(model)
        await model.sendCode()
        model.otp = "123456"
        await model.verifyCode()
        XCTAssertEqual(model.stage, .account)
        XCTAssertTrue(model.password.isEmpty)
        XCTAssertTrue(model.otp.isEmpty)
        XCTAssertEqual(model.errorMessage, UserFacingError.message(for: DysonCloudError.httpStatus(401)))
        cloud.verifyError = nil
        model.password = "new-secret"
        await model.sendCode()
        model.otp = "654321"
        await model.verifyCode()
        XCTAssertEqual(model.stage, .devices)
        XCTAssertNil(model.errorMessage)
    }

    func testSixteenByteLampKeyCanCompletePairingAndBeRestored() async throws {
        let cloud = FakeCloud()
        cloud.returnedKey = String(repeating: "ab", count: 16)
        let model = PairingModel(cloudFactory: { _ in cloud })
        account(model)
        await model.sendCode()
        model.otp = "123456"
        await model.verifyCode()
        XCTAssertEqual(model.stage, .devices)
        let store = MemoryCredentialStore()
        let controller = LampController(store: store, transportFactory: { FakeTransport() })
        await model.pair(try XCTUnwrap(model.devices.first), controller: controller)
        XCTAssertEqual(model.stage, .complete)
        XCTAssertEqual(store.credentials?.longTermKey.count, 32)
        let restored = LampController(store: store, transportFactory: { FakeTransport() })
        XCTAssertTrue(restored.hasCredentials)
        await restored.connect()
        XCTAssertEqual(restored.connection, .connected)
        await restored.releaseConnection()
    }

    func testNetworkFailureDuringSendDoesNotRetainPassword() async {
        let cloud = FakeCloud()
        cloud.beginError = URLError(.notConnectedToInternet)
        let model = PairingModel(cloudFactory: { _ in cloud })
        account(model)
        await model.sendCode()
        XCTAssertEqual(model.stage, .account)
        XCTAssertTrue(model.password.isEmpty)
        XCTAssertEqual(model.errorMessage, UserFacingError.message(for: URLError(.notConnectedToInternet)))
    }

    func testEmptyDeviceListReturnsToAccountWithExplanation() async {
        let cloud = FakeCloud()
        cloud.lights = []
        let model = PairingModel(cloudFactory: { _ in cloud })
        account(model)
        await model.sendCode()
        model.otp = "123456"
        await model.verifyCode()
        XCTAssertEqual(model.stage, .account)
        XCTAssertTrue(model.devices.isEmpty)
        XCTAssertTrue(model.password.isEmpty)
        XCTAssertEqual(model.errorMessage, UserFacingError.message(for: ServiceError.emptyDevices))
    }

    func testInvalidCodeCanBeCorrectedWithoutSendingAnotherEmail() async {
        let cloud = FakeCloud()
        let model = PairingModel(cloudFactory: { _ in cloud })
        account(model)
        await model.sendCode()
        model.otp = "abc"
        await model.verifyCode()
        XCTAssertEqual(model.stage, .code)
        XCTAssertEqual(cloud.verifyCalls, 0)
        XCTAssertFalse(model.password.isEmpty)
        model.otp = "123456"
        await model.verifyCode()
        XCTAssertEqual(model.stage, .devices)
        XCTAssertEqual(cloud.beginCalls, 1)
    }

    func testResetCancelsPendingLoginAndIgnoresLateResults() async {
        let cloud = FakeCloud()
        cloud.delay = 5_000_000_000
        let model = PairingModel(cloudFactory: { _ in cloud })
        account(model)
        let sending = Task { await model.sendCode() }
        while cloud.beginCalls == 0 { await Task.yield() }
        model.reset()
        await sending.value
        XCTAssertEqual(model.stage, .account)
        XCTAssertTrue(model.email.isEmpty)
        XCTAssertTrue(model.password.isEmpty)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isBusy)
    }

    func testFailedKeyFetchCannotPersistPartialCredentials() async {
        let cloud = FakeCloud()
        cloud.keyError = URLError(.networkConnectionLost)
        let model = PairingModel(cloudFactory: { _ in cloud })
        account(model)
        await model.sendCode()
        model.otp = "123456"
        await model.verifyCode()
        let store = MemoryCredentialStore()
        let controller = LampController(store: store, transportFactory: { FakeTransport() })
        await model.pair(PairingDevice(name: "Forged", serial: "TEST-EU-12345678"), controller: controller)
        XCTAssertEqual(model.stage, .account)
        XCTAssertNil(store.credentials)
        XCTAssertFalse(controller.hasCredentials)
    }

    func testOneInvalidLampDoesNotHideAnotherAvailableLamp() async {
        let cloud = FakeCloud()
        cloud.lights.insert(.init(serial: "STALE-LAMP", name: "Alte Lampe", category: "light", connectionCategory: "bluetoothOnly"), at: 0)
        cloud.keyErrorsBySerial["STALE-LAMP"] = DysonCloudError.httpStatus(404)
        let model = PairingModel(cloudFactory: { _ in cloud })
        account(model)
        await model.sendCode()
        model.otp = "123456"
        await model.verifyCode()
        XCTAssertEqual(model.stage, .devices)
        XCTAssertEqual(model.devices.map(\.serial), ["TEST-EU-12345678"])
        XCTAssertEqual(model.errorMessage, ServiceLocalization.text("Nicht alle Lampen konnten geladen werden. Du kannst eine verfügbare Lampe auswählen oder es später erneut versuchen."))
        XCTAssertTrue(model.password.isEmpty)
    }
}
