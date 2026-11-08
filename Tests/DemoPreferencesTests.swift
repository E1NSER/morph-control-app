import Foundation
import MorphServices

/// Compiled with the actual native preference classes by test-demo-preferences.sh.
/// No app is launched and no production preference domain is read or written.
private final class MemoryDefaults: UserDefaults {
    private var values: [String: String]
    private(set) var writes = 0
    init(_ values: [String: String]) {
        self.values = values
        super.init(suiteName: "Morph.InMemoryPreferenceTest.\(UUID().uuidString)")!
    }
    override func string(forKey key: String) -> String? { values[key] }
    override func set(_ value: Any?, forKey key: String) {
        writes += 1
        values[key] = value as? String
    }
}

@main
private struct DemoPreferencesTests {
    @MainActor static func main() {
        let themeDefaults = MemoryDefaults([
            "morph.appearance": "dark", "morph.accent": "graphite", "morph.customAccent": "ABCDEF"
        ])
        let theme = ThemeSettings(defaults: themeDefaults)
        let original = (theme.appearance, theme.accent, theme.customHex)
        theme.beginDemo()
        theme.beginDemo() // Repeated entry must not replace the real snapshot.
        theme.appearance = .light
        theme.accent = .custom
        theme.customHex = "123456"
        theme.reset()
        precondition(themeDefaults.writes == 0, "Demo appearance changes wrote persisted settings")
        theme.endDemo()
        precondition(theme.appearance == original.0 && theme.accent == original.1 && theme.customHex == original.2,
                     "Demo exit did not restore original appearance")
        precondition(themeDefaults.writes == 0, "Restoring appearance wrote persisted settings")
        theme.accent = .rose
        precondition(themeDefaults.writes == 1, "Normal preference persistence did not resume")

        let languageDefaults = MemoryDefaults([AppLocale.preferenceKey: "de"])
        let language = LanguageSettings(defaults: languageDefaults)
        language.beginDemo()
        language.beginDemo()
        language.selection = .english
        precondition(ServiceLocalization.languageCode == "en", "Demo service language did not update")
        precondition(AppLocale.languageCode == "en", "Demo app language did not update")
        language.selection = .system
        language.selection = .english
        precondition(languageDefaults.writes == 0, "Demo language changes wrote persisted settings")
        language.endDemo()
        precondition(language.selection == .german, "Demo exit did not restore original language")
        precondition(languageDefaults.writes == 0, "Restoring language wrote persisted settings")
        language.selection = .english
        precondition(languageDefaults.writes == 1, "Normal language persistence did not resume")
        let isolatedTheme = ThemeSettings(defaults: nil)
        isolatedTheme.beginDemo()
        isolatedTheme.accent = .rose
        isolatedTheme.endDemo()
        precondition(isolatedTheme.accent == .amber, "Isolated setup appearance was not restored")
        let isolatedLanguage = LanguageSettings(defaults: nil)
        isolatedLanguage.beginDemo()
        isolatedLanguage.selection = .german
        isolatedLanguage.endDemo()
        precondition(isolatedLanguage.selection == .system, "Isolated setup language was not restored")
        precondition(ServiceLocalization.languageCode == ServiceLocalization.resolvedLanguageCode(
            preference: "system", preferredLanguages: Locale.preferredLanguages))
        ServiceLocalization.setTemporaryLanguage(nil)
        print("Demo preference tests passed: temporary appearance/language, exact restoration, normal persistence resumed.")
    }
}
