import Foundation

/// App and service text share one explicit language preference. Resolving the
/// language bundle per lookup also permits changing it without restarting BLE.
public enum ServiceLocalization {
    public static let languagePreferenceKey = "morph.language"
    private static let preferenceLock = NSLock()
    private static var temporaryPreference: String?

    /// Demo language changes stay in process memory, including service text.
    public static func setTemporaryLanguage(_ preference: String?) {
        preferenceLock.lock()
        temporaryPreference = preference
        preferenceLock.unlock()
    }

    public static var languageCode: String {
        preferenceLock.lock()
        let temporary = temporaryPreference
        preferenceLock.unlock()
        return resolvedLanguageCode(preference: temporary ?? UserDefaults.standard.string(forKey: languagePreferenceKey),
                                    preferredLanguages: Locale.preferredLanguages)
    }

    public static func resolvedLanguageCode(preference: String?, preferredLanguages: [String]) -> String {
        switch preference?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "de": return "de"
        case "en": return "en"
        default:
            let primary = preferredLanguages.first?.split(whereSeparator: { $0 == "-" || $0 == "_" }).first?.lowercased()
            return primary == "de" ? "de" : "en"
        }
    }

    public static func text(_ key: String, languageCode: String? = nil) -> String {
        let selected = languageCode.map { resolvedLanguageCode(preference: $0, preferredLanguages: Locale.preferredLanguages) }
            ?? self.languageCode
        guard let path = Bundle.module.path(forResource: selected, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }
}
