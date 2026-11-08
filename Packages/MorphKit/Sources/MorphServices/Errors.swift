import Foundation
import MorphCore

enum ServiceError: LocalizedError {
    case deadline, notPaired, emptyDevices, invalidCredentials
    case keychain(Int32)

    var errorDescription: String? { UserFacingError.message(for: self) }
}

enum UserFacingError {
    static func message(for error: Error) -> String {
        ServiceLocalization.text(key(for: error))
    }

    /// These keys are deliberately fixed strings. Raw transport or server
    /// details must never enter user-visible messages or localization lookups.
    static func key(for error: Error) -> String {
        if let error = error as? DysonCloudError {
            switch error {
            case .httpStatus(401), .httpStatus(403):
                return "Die Anmeldung wurde abgelehnt. Prüfe Passwort und Bestätigungscode und melde dich erneut an."
            case .httpStatus(404):
                return "Die Lampe ist in diesem Dyson-Konto nicht registriert. Füge sie zuerst in MyDyson hinzu."
            case .httpStatus(429):
                return "Zu viele Anmeldeversuche. Bitte warte etwas und versuche es erneut."
            case .httpStatus:
                return "Dyson ist gerade nicht erreichbar. Bitte versuche es später erneut."
            case .invalidCountry:
                return "Wähle das Land deines Dyson-Kontos."
            case .invalidResponse:
                return "Die Antwort von Dyson konnte nicht verarbeitet werden. Bitte versuche es später erneut."
            case .unexpectedResponse(.login):
                return "Dyson hat nach der Codebestätigung keine gültigen Anmeldedaten geliefert. Bitte melde dich erneut an. (Anmeldung)"
            case .unexpectedResponse(.devices):
                return "Die Geräteliste von Dyson hat ein unbekanntes Format. Bitte versuche es erneut. (Geräteliste)"
            case .unexpectedResponse(.lampKey):
                return "Der Lampenschlüssel von Dyson konnte nicht verarbeitet werden. Bitte versuche es erneut. (Lampenschlüssel)"
            }
        }
        if let error = error as? ServiceError {
            switch error {
            case .deadline:
                return "Die Verbindung dauert zu lange. Prüfe, ob die Lampe eingeschaltet und MyDyson geschlossen ist."
            case .notPaired:
                return "Verbinde zuerst deine Lampe."
            case .emptyDevices:
                return "In diesem Konto wurde keine Bluetooth-Lampe gefunden. Registriere die Solarcycle Morph zuerst in MyDyson."
            case .invalidCredentials:
                return "Die gespeicherte Kopplung ist ungültig. Entferne die Lampe und kopple sie erneut."
            case .keychain:
                return "Auf den macOS-Schlüsselbund kann nicht zugegriffen werden. Entsperre deinen Mac und versuche es erneut."
            }
        }
        if let error = error as? MorphError {
            switch error {
            case .bluetoothState(.permissionDenied):
                return "Erlaube Bluetooth für diese App unter Systemeinstellungen → Datenschutz & Sicherheit → Bluetooth."
            case .bluetoothState(.poweredOff):
                return "Bluetooth ist ausgeschaltet. Aktiviere Bluetooth auf deinem Mac."
            case .bluetoothState(.unsupported):
                return "Dieser Mac unterstützt die benötigte Bluetooth-Verbindung nicht."
            case .bluetoothState(.sessionOccupied):
                return "Die Lampe antwortet nicht auf die Anmeldung. Schließe MyDyson oder andere Lampensteuerungen und versuche es erneut."
            case .bluetoothState:
                return "Die Bluetooth-Verbindung wurde unterbrochen. Verbinde die Lampe erneut."
            case .lampStuck:
                return "Die Lampe meldet einen Bluetooth-Fehler. Schließe andere Lampensteuerungen und verbinde sie erneut. Falls nötig, trenne die Lampe für zehn Sekunden vom Strom."
            case .protocolError:
                return "Die Lampe konnte nicht authentifiziert werden. Versuche es erneut oder kopple sie neu."
            case .notPaired:
                return "Verbinde zuerst deine Lampe."
            case .timeout, .bluetooth:
                return "Die Lampe ist nicht erreichbar. Prüfe die Stromversorgung und schließe MyDyson oder andere Lampensteuerungen."
            case .cloud:
                return "Die Anmeldung bei Dyson ist fehlgeschlagen. Bitte versuche es erneut."
            case .usage:
                return "Die Einstellung konnte nicht übernommen werden. Bitte versuche es erneut."
            }
        }
        if error is URLError { return "Keine Verbindung zu Dyson. Prüfe deine Internetverbindung und versuche es erneut." }
        if error is CancellationError { return "Der Vorgang wurde abgebrochen." }
        return "Der Vorgang konnte nicht abgeschlossen werden. Bitte versuche es erneut."
    }
}
