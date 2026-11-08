import Foundation
import SwiftUI
import MorphServices

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, german = "de", english = "en"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return AppText.string("System")
        case .german: return "Deutsch"
        case .english: return "English"
        }
    }
}

/// App language is independent of the Dyson account's country and credentials.
enum AppLocale {
    static let preferenceKey = "morph.language"

    static func resolve(preference: String?, preferredLanguages: [String]) -> String {
        if preference == "de" || preference == "en" { return preference! }
        let first = preferredLanguages.first?.lowercased().replacingOccurrences(of: "_", with: "-") ?? "en"
        return first == "de" || first.hasPrefix("de-") ? "de" : "en"
    }

    static var languageCode: String {
        ServiceLocalization.languageCode
    }
    static var locale: Locale { Locale(identifier: languageCode) }

    static var bundle: Bundle {
        guard let path = Bundle.main.path(forResource: languageCode, ofType: "lproj"),
              let localized = Bundle(path: path) else { return .main }
        return localized
    }
}

/// Explicit bundle lookup also localizes AppKit titles and dynamically built
/// accessibility strings when the user changes language without restarting.
enum AppText {
    static func string(_ key: String) -> String {
        AppLocale.bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: AppLocale.locale, arguments: arguments)
    }
}

extension Notification.Name {
    static let morphLanguageDidChange = Notification.Name("MorphControl.languageDidChange")
}

@MainActor
final class LanguageSettings: ObservableObject {
    @Published var selection: AppLanguage {
        didSet {
            guard selection != oldValue else { return }
            if demoSelection != nil || defaults == nil {
                ServiceLocalization.setTemporaryLanguage(selection.rawValue)
            } else {
                defaults?.set(selection.rawValue, forKey: AppLocale.preferenceKey)
            }
            NotificationCenter.default.post(name: .morphLanguageDidChange, object: self)
        }
    }
    private let defaults: UserDefaults?
    private var demoSelection: AppLanguage?
    private var localeObserver: NSObjectProtocol?

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        selection = AppLanguage(rawValue: defaults?.string(forKey: AppLocale.preferenceKey) ?? "system") ?? .system
        if defaults == nil { ServiceLocalization.setTemporaryLanguage(selection.rawValue) }
        localeObserver = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.selection == .system else { return }
                self.objectWillChange.send()
                NotificationCenter.default.post(name: .morphLanguageDidChange, object: self)
            }
        }
    }

    deinit {
        if let localeObserver { NotificationCenter.default.removeObserver(localeObserver) }
    }

    var locale: Locale { AppLocale.locale }

    func beginDemo() {
        guard demoSelection == nil else { return }
        demoSelection = selection
        ServiceLocalization.setTemporaryLanguage(selection.rawValue)
    }

    func endDemo() {
        guard let saved = demoSelection else { return }
        selection = saved
        demoSelection = nil
        ServiceLocalization.setTemporaryLanguage(defaults == nil ? saved.rawValue : nil)
        objectWillChange.send()
        NotificationCenter.default.post(name: .morphLanguageDidChange, object: self)
    }
}

struct MorphLanguage: ViewModifier {
    @ObservedObject var language: LanguageSettings
    func body(content: Content) -> some View {
        content
            .environmentObject(language)
            .environment(\.locale, language.locale)
    }
}
