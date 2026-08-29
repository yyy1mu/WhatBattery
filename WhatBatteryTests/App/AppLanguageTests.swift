import Foundation
import Testing
@testable import WhatBattery

@MainActor
struct AppLanguageTests {
    @Test("English and Chinese write the expected per-app language")
    func appliesExplicitLanguages() throws {
        let fixture = try LanguageDefaultsFixture()
        defer { fixture.remove() }

        AppLanguage.english.apply(to: fixture.defaults)
        #expect(fixture.storedLanguages == ["en"])

        AppLanguage.simplifiedChinese.apply(to: fixture.defaults)
        #expect(fixture.storedLanguages == ["zh-Hans"])
    }

    @Test("Following the system removes the per-app language override")
    func followsSystemLanguage() throws {
        let fixture = try LanguageDefaultsFixture()
        defer { fixture.remove() }
        fixture.defaults.set(["en"], forKey: "AppleLanguages")

        AppLanguage.system.apply(to: fixture.defaults)

        #expect(fixture.storedLanguages == nil)
    }
}

private struct LanguageDefaultsFixture {
    let suiteName: String
    let defaults: UserDefaults

    init() throws {
        suiteName = "WhatBatteryTests.AppLanguage.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    var storedLanguages: [String]? {
        defaults.persistentDomain(forName: suiteName)?["AppleLanguages"]
            as? [String]
    }

    func remove() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
