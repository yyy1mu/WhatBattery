import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english
    case simplifiedChinese

    static let preferenceKey = "preferredAppLanguage"

    private static let appleLanguagesKey = "AppleLanguages"

    var id: Self { self }

    var displayName: LocalizedStringResource {
        switch self {
        case .system:
            "Follow System"
        case .english:
            "English"
        case .simplifiedChinese:
            "Simplified Chinese"
        }
    }

    func apply(to userDefaults: UserDefaults = .standard) {
        switch self {
        case .system:
            userDefaults.removeObject(forKey: Self.appleLanguagesKey)
        case .english:
            userDefaults.set(["en"], forKey: Self.appleLanguagesKey)
        case .simplifiedChinese:
            userDefaults.set(["zh-Hans"], forKey: Self.appleLanguagesKey)
        }

        // The restarted process must see the preference immediately.
        userDefaults.synchronize()
    }
}
