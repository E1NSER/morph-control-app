import CoreBluetooth
import XCTest
@testable import MorphCore

/// Exercises target selection and the real continuation cleanup without
/// instantiating CoreBluetooth, requesting permission, or contacting a lamp.
final class ReconnectionTests: XCTestCase {
    func testAdvertisementNameCannotHideMatchingRememberedSerial() {
        XCTAssertTrue(Lamp.matchesSerial("ABC-EU-12345678",
            advertisedName: "Dyson", peripheralName: "ABC-EU-12345678"))
        XCTAssertTrue(Lamp.matchesSerial("ABC-EU-12345678",
            advertisedName: "ABC-EU-12345678", peripheralName: "Old name"))
    }

    func testSerialComparisonIsExactAndNormalizesCaseAndWhitespace() {
        XCTAssertTrue(Lamp.matchesSerial(" abc-eu-12345678\n",
            advertisedName: " ABC-EU-12345678 ", peripheralName: nil))
        XCTAssertFalse(Lamp.matchesSerial("ABC-EU-12345678",
            advertisedName: "ABC-EU-123456789", peripheralName: "ABC-EU"))
        XCTAssertFalse(Lamp.matchesSerial(" ", advertisedName: "", peripheralName: nil))
    }

    func testConnectedPeripheralNeedsMatchingSerialOrPreviouslyVerifiedID() {
        let verified = UUID()
        let other = UUID()
        XCTAssertTrue(Lamp.isExpectedPeripheral(id: verified, name: nil,
            serial: "ABC-EU-12345678", cachedId: verified))
        XCTAssertTrue(Lamp.isExpectedPeripheral(id: other, name: "ABC-EU-12345678",
            serial: "ABC-EU-12345678", cachedId: nil))
        XCTAssertFalse(Lamp.isExpectedPeripheral(id: other, name: "Another Dyson lamp",
            serial: "ABC-EU-12345678", cachedId: verified))
        XCTAssertFalse(Lamp.isExpectedPeripheral(id: other, name: nil,
            serial: "ABC-EU-12345678", cachedId: nil))
    }

    func testResettingFailsAnActiveOperationPromptly() async {
        let lamp = Lamp()
        let start = ContinuousClock.now
        do {
            let _: Bool = try await lamp.wait("read:test", timeout: 30) {
                lamp.managerStateDidChange(.resetting)
            }
            XCTFail("The old operation cannot survive a Bluetooth reset")
        } catch { assertBluetoothIssue(error, .unavailable) }
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(500))
    }

    func testInitialReadinessCanRecoverThroughResettingAndUnknown() async throws {
        let lamp = Lamp()
        let ready: Bool = try await lamp.wait("state", timeout: 1) {
            lamp.managerStateDidChange(.resetting)
            lamp.managerStateDidChange(.unknown)
            lamp.managerStateDidChange(.poweredOn)
        }
        XCTAssertTrue(ready)
    }

    func testBluetoothErrorsRemainDistinctFromNotFound() async {
        let cases: [(CBManagerState, BluetoothIssue)] = [
            (.unauthorized, .permissionDenied), (.poweredOff, .poweredOff), (.unsupported, .unsupported)
        ]
        for (state, expected) in cases {
            let lamp = Lamp()
            do {
                let _: Bool = try await lamp.wait("state", timeout: 30) {
                    lamp.managerStateDidChange(state)
                }
                XCTFail("Expected a specific Bluetooth issue")
            } catch { assertBluetoothIssue(error, expected) }
        }
    }

    func testDisconnectWithoutPeripheralStillClearsPendingOperations() async {
        let lamp = Lamp()
        let registered = expectation(description: "Pending operation")
        let task = Task {
            let _: Bool = try await lamp.wait("read:ended-session", timeout: 30) { registered.fulfill() }
        }
        await fulfillment(of: [registered], timeout: 1)
        await lamp.disconnect()
        do { try await task.value; XCTFail("Expected pending read to fail") }
        catch { assertBluetoothIssue(error, .disconnected) }
        let ready = await lamp.isReady
        let live = await lamp.isLive
        XCTAssertFalse(ready)
        XCTAssertFalse(live)
    }

    func testScanWithoutPoweredOnRuntimeFailsWithoutCreatingBluetoothManager() async {
        let lamp = Lamp()
        do { _ = try await lamp.scan(seconds: 10); XCTFail("Expected unavailable runtime") }
        catch { assertBluetoothIssue(error, .unavailable) }
    }

    func testATTRecoveryWithoutPeripheralInvalidatesPendingOperations() async {
        let lamp = Lamp()
        let registered = expectation(description: "Pending operation before fresh runtime")
        let task = Task {
            let _: Bool = try await lamp.wait("read:old-runtime", timeout: 30) { registered.fulfill() }
        }
        await fulfillment(of: [registered], timeout: 1)
        await lamp.resetAfterATTFailure()
        do { try await task.value; XCTFail("Old operation must not survive the reset") }
        catch { XCTAssertTrue(error is CancellationError) }
        let ready = await lamp.isReady
        let live = await lamp.isLive
        XCTAssertFalse(ready)
        XCTAssertFalse(live)
    }

    private func assertBluetoothIssue(_ error: Error, _ expected: BluetoothIssue,
                                      file: StaticString = #filePath, line: UInt = #line) {
        guard case MorphError.bluetoothState(let issue) = error else {
            XCTFail("Expected typed Bluetooth error, got \(error)", file: file, line: line)
            return
        }
        XCTAssertEqual(issue, expected, file: file, line: line)
    }
}
