import XCTest
import MorphCore
@testable import MorphServices

final class UserFacingLocalizationTests: XCTestCase {
    private func assertMapping(_ error: Error, key: String, english: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(UserFacingError.key(for: error), key, file: file, line: line)
        XCTAssertEqual(ServiceLocalization.text(key, languageCode: "de"), key, file: file, line: line)
        XCTAssertEqual(ServiceLocalization.text(key, languageCode: "en"), english, file: file, line: line)
    }

    func testCloudStatusErrorsHaveSafeLocalizedGuidance() {
        for status in [401, 403] {
            assertMapping(DysonCloudError.httpStatus(status),
                key: "Die Anmeldung wurde abgelehnt. Prüfe Passwort und Bestätigungscode und melde dich erneut an.",
                english: "Sign-in was rejected. Check your password and verification code, then sign in again.")
        }
        assertMapping(DysonCloudError.httpStatus(404),
            key: "Die Lampe ist in diesem Dyson-Konto nicht registriert. Füge sie zuerst in MyDyson hinzu.",
            english: "The lamp is not registered to this Dyson account. Add it in MyDyson first.")
        assertMapping(DysonCloudError.httpStatus(429),
            key: "Zu viele Anmeldeversuche. Bitte warte etwas und versuche es erneut.",
            english: "Too many sign-in attempts. Please wait a while and try again.")
        for status in [400, 500, 503] {
            assertMapping(DysonCloudError.httpStatus(status),
                key: "Dyson ist gerade nicht erreichbar. Bitte versuche es später erneut.",
                english: "Dyson is currently unavailable. Please try again later.")
        }
    }

    func testCloudValidationAndEveryResponseStageAreLocalized() {
        assertMapping(DysonCloudError.invalidCountry,
            key: "Wähle das Land deines Dyson-Kontos.",
            english: "Choose the country of your Dyson account.")
        assertMapping(DysonCloudError.invalidResponse,
            key: "Die Antwort von Dyson konnte nicht verarbeitet werden. Bitte versuche es später erneut.",
            english: "Dyson's response could not be processed. Please try again later.")
        assertMapping(DysonCloudError.unexpectedResponse(.login),
            key: "Dyson hat nach der Codebestätigung keine gültigen Anmeldedaten geliefert. Bitte melde dich erneut an. (Anmeldung)",
            english: "Dyson did not return valid sign-in details after code verification. Please sign in again. (Sign-in)")
        assertMapping(DysonCloudError.unexpectedResponse(.devices),
            key: "Die Geräteliste von Dyson hat ein unbekanntes Format. Bitte versuche es erneut. (Geräteliste)",
            english: "Dyson's device list has an unknown format. Please try again. (Device list)")
        assertMapping(DysonCloudError.unexpectedResponse(.lampKey),
            key: "Der Lampenschlüssel von Dyson konnte nicht verarbeitet werden. Bitte versuche es erneut. (Lampenschlüssel)",
            english: "The lamp key returned by Dyson could not be processed. Please try again. (Lamp key)")
    }

    func testEveryServiceErrorFamilyIsLocalized() {
        assertMapping(ServiceError.deadline,
            key: "Die Verbindung dauert zu lange. Prüfe, ob die Lampe eingeschaltet und MyDyson geschlossen ist.",
            english: "The connection is taking too long. Check that the lamp has power and MyDyson is closed.")
        assertMapping(ServiceError.notPaired, key: "Verbinde zuerst deine Lampe.", english: "Connect your lamp first.")
        assertMapping(ServiceError.emptyDevices,
            key: "In diesem Konto wurde keine Bluetooth-Lampe gefunden. Registriere die Solarcycle Morph zuerst in MyDyson.",
            english: "No Bluetooth lamp was found in this account. Register your Solarcycle Morph in MyDyson first.")
        assertMapping(ServiceError.invalidCredentials,
            key: "Die gespeicherte Kopplung ist ungültig. Entferne die Lampe und kopple sie erneut.",
            english: "The saved pairing is invalid. Remove the lamp and pair it again.")
        assertMapping(ServiceError.keychain(-25293),
            key: "Auf den macOS-Schlüsselbund kann nicht zugegriffen werden. Entsperre deinen Mac und versuche es erneut.",
            english: "The macOS Keychain could not be accessed. Unlock your Mac and try again.")
    }

    func testEveryBluetoothIssueIsLocalized() {
        assertMapping(MorphError.bluetoothState(.permissionDenied),
            key: "Erlaube Bluetooth für diese App unter Systemeinstellungen → Datenschutz & Sicherheit → Bluetooth.",
            english: "Allow Bluetooth for this app in System Settings → Privacy & Security → Bluetooth.")
        assertMapping(MorphError.bluetoothState(.poweredOff),
            key: "Bluetooth ist ausgeschaltet. Aktiviere Bluetooth auf deinem Mac.",
            english: "Bluetooth is off. Turn on Bluetooth on your Mac.")
        assertMapping(MorphError.bluetoothState(.unsupported),
            key: "Dieser Mac unterstützt die benötigte Bluetooth-Verbindung nicht.",
            english: "This Mac does not support the required Bluetooth connection.")
        assertMapping(MorphError.bluetoothState(.sessionOccupied),
            key: "Die Lampe antwortet nicht auf die Anmeldung. Schließe MyDyson oder andere Lampensteuerungen und versuche es erneut.",
            english: "The lamp is not responding to the connection request. Close MyDyson or other lamp control apps and try again.")
        for issue in [BluetoothIssue.unavailable, .disconnected] {
            assertMapping(MorphError.bluetoothState(issue),
                key: "Die Bluetooth-Verbindung wurde unterbrochen. Verbinde die Lampe erneut.",
                english: "The Bluetooth connection was interrupted. Reconnect the lamp.")
        }
    }

    func testEveryOtherMorphErrorFamilyIsLocalized() {
        assertMapping(MorphError.lampStuck("raw detail"),
            key: "Die Lampe meldet einen Bluetooth-Fehler. Schließe andere Lampensteuerungen und verbinde sie erneut. Falls nötig, trenne die Lampe für zehn Sekunden vom Strom.",
            english: "The lamp reported a Bluetooth error. Close other lamp control apps and reconnect. If needed, unplug the lamp for ten seconds.")
        assertMapping(MorphError.protocolError("raw detail"),
            key: "Die Lampe konnte nicht authentifiziert werden. Versuche es erneut oder kopple sie neu.",
            english: "The lamp could not be authenticated. Try again or pair it again.")
        assertMapping(MorphError.notPaired, key: "Verbinde zuerst deine Lampe.", english: "Connect your lamp first.")
        for error in [MorphError.timeout("raw detail"), .bluetooth("raw detail")] {
            assertMapping(error,
                key: "Die Lampe ist nicht erreichbar. Prüfe die Stromversorgung und schließe MyDyson oder andere Lampensteuerungen.",
                english: "The lamp is not reachable. Check its power supply and close MyDyson or other lamp control apps.")
        }
        assertMapping(MorphError.cloud("raw detail"),
            key: "Die Anmeldung bei Dyson ist fehlgeschlagen. Bitte versuche es erneut.",
            english: "Sign-in to Dyson failed. Please try again.")
        assertMapping(MorphError.usage("raw detail"),
            key: "Die Einstellung konnte nicht übernommen werden. Bitte versuche es erneut.",
            english: "The setting could not be applied. Please try again.")
    }

    func testNetworkCancellationAndUnknownErrorsAreLocalized() {
        assertMapping(URLError(.notConnectedToInternet),
            key: "Keine Verbindung zu Dyson. Prüfe deine Internetverbindung und versuche es erneut.",
            english: "Could not connect to Dyson. Check your internet connection and try again.")
        assertMapping(CancellationError(), key: "Der Vorgang wurde abgebrochen.", english: "The operation was canceled.")
        assertMapping(NSError(domain: "test", code: 900),
            key: "Der Vorgang konnte nicht abgeschlossen werden. Bitte versuche es erneut.",
            english: "The operation could not be completed. Please try again.")
    }

    func testRawErrorDetailsNeverBecomeKeysOrTranslations() {
        let secret = "RAW_SECRET_LTK_TOKEN_ACCOUNT_FIXTURE"
        let errors: [Error] = [
            MorphError.timeout(secret), MorphError.bluetooth(secret), MorphError.protocolError(secret),
            MorphError.cloud(secret), MorphError.usage(secret), MorphError.lampStuck(secret),
            ServiceError.keychain(-25293),
            URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLStringErrorKey: "https://\(secret).invalid"]),
            NSError(domain: secret, code: 900, userInfo: [NSLocalizedDescriptionKey: secret])
        ]
        for error in errors {
            let key = UserFacingError.key(for: error)
            for value in [key, ServiceLocalization.text(key, languageCode: "de"), ServiceLocalization.text(key, languageCode: "en")] {
                XCTAssertFalse(value.contains(secret))
                XCTAssertFalse(value.contains("https://"))
                XCTAssertFalse(value.contains("25293"))
            }
        }
    }

    func testPairingAndControllerMessagesAreAvailableInBothLanguages() {
        let values: [(String, String)] = [
            ("Meine Lampe", "My lamp"),
            ("Schreibtisch", "Desk"),
            ("Gib deine Dyson-E-Mail-Adresse und dein Passwort ein.", "Enter your Dyson email address and password."),
            ("Gib den sechsstelligen Code aus deiner E-Mail ein.", "Enter the six-digit code from your email."),
            ("Gib dein Passwort erneut ein und fordere einen neuen Code an.", "Enter your password again and request a new code."),
            ("Nicht alle Lampen konnten geladen werden. Du kannst eine verfügbare Lampe auswählen oder es später erneut versuchen.",
             "Some lamps could not be loaded. Choose an available lamp or try again later."),
            ("Die Verbindung zur Lampe wurde unterbrochen. Verbinde sie erneut.", "The connection to the lamp was interrupted. Reconnect it."),
            ("Die Lampe konnte vor dem Ruhezustand oder Ausschalten nicht rechtzeitig ausgeschaltet werden.",
             "The lamp could not be switched off in time before the Mac went to sleep or shut down."),
            ("Die Lampe hat Tageslicht und automatische Helligkeit noch nicht bestätigt. Aktualisiere den Status oder versuche es erneut.",
             "The lamp has not confirmed daylight mode and automatic brightness yet. Refresh its status or try again."),
            ("Die Lampe hat die manuelle Effektsteuerung noch nicht bestätigt. Aktualisiere den Status oder versuche es erneut.",
             "The lamp has not confirmed manual control for lighting effects yet. Refresh its status or try again.")
        ]
        for (key, english) in values {
            XCTAssertEqual(ServiceLocalization.text(key, languageCode: "de"), key)
            XCTAssertEqual(ServiceLocalization.text(key, languageCode: "en"), english)
        }
    }

    func testMessageAndLocalizedErrorDescriptionUseTheSharedLookup() {
        for error in [ServiceError.deadline, .notPaired, .emptyDevices, .invalidCredentials, .keychain(-25293)] {
            let expected = ServiceLocalization.text(UserFacingError.key(for: error))
            XCTAssertEqual(UserFacingError.message(for: error), expected)
            XCTAssertEqual(error.errorDescription, expected)
        }
    }
}
