import Foundation

enum AppLanguagePreference {
    static let userDefaultsKey = "AppLanguagePreference"
    static let systemValue = "system"

    private static let appleLanguagesKey = "AppleLanguages"
    private static let managesAppleLanguagesKey = "AppLanguagePreferenceManagedAppleLanguages"
    private static let bundledLanguageIdentifiers = ["en", "uk"]

    struct Option: Identifiable, Hashable {
        let id: String
        let displayName: String
    }

    static var availableOptions: [Option] {
        return [
            Option(id: systemValue, displayName: String(localized: "System"))
        ]
            + availableLanguageIdentifiers.map { identifier in
                Option(id: identifier, displayName: displayName(for: identifier))
            }
    }

    static var storedRawValue: String {
        let rawValue = UserDefaults.standard.string(forKey: userDefaultsKey) ?? systemValue
        return normalizedRawValue(rawValue)
    }

    static func applyStored() {
        apply(rawValue: storedRawValue)
    }

    static func apply(rawValue: String) {
        let preferenceRawValue = normalizedRawValue(rawValue)

        if preferenceRawValue == systemValue {
            if UserDefaults.standard.bool(forKey: managesAppleLanguagesKey) {
                UserDefaults.standard.removeObject(forKey: appleLanguagesKey)
            }
            UserDefaults.standard.removeObject(forKey: managesAppleLanguagesKey)
        } else {
            UserDefaults.standard.set([preferenceRawValue], forKey: appleLanguagesKey)
            UserDefaults.standard.set(true, forKey: managesAppleLanguagesKey)
        }
    }

    static func normalizedRawValue(_ rawValue: String) -> String {
        guard rawValue != systemValue else { return systemValue }
        return availableLanguageIdentifiers.contains(rawValue) ? rawValue : systemValue
    }

    private static var availableLanguageIdentifiers: [String] {
        bundledLanguageIdentifiers
    }

    private static func displayName(for identifier: String) -> String {
        Locale(identifier: identifier).localizedString(forIdentifier: identifier) ?? identifier
    }
}
