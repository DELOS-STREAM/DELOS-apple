import Foundation
import Testing
@testable import DelosUI

@Suite struct LanguageSettingsTests {
    @Test func languageIsAnAboutActionShowingTheAppsLanguageNotTheRegionsLanguage() throws {
        let row = try #require(AppLanguageSetting.rows(
            .about, supported: true, preferredLocalization: "cs", displayLocale: Locale(identifier: "en_US")).first)
        #expect(row.id == "list_languages")
        #expect(row.tab == .about)
        #expect(row.section == "MISC")
        #expect(row.icon == Symbols.language)
        #expect(row.label == "Language")
        #expect(row.value == .appSettings(language: "Czech"))
        #expect(row.help == "Language of the shell, its help and the stream messages.")
    }

    @Test func regionalLanguageNameDoesNotCollapseToTheGenericLanguage() throws {
        let row = try #require(AppLanguageSetting.rows(
            .about, supported: true, preferredLocalization: "pt-BR", displayLocale: Locale(identifier: "en_US")).first)
        #expect(row.value == .appSettings(language: "Portuguese (Brazil)"))
    }

    @Test func unsupportedSystemSettingsNeverOfferAnInertLanguageAction() {
        #expect(AppLanguageSetting.rows(.about, supported: false).isEmpty)
        #if os(iOS)
        #expect(SettingsTab.availableCases == [.stream, .audio, .controls, .appearance, .covers, .about])
        #else
        #expect(SettingsTab.availableCases == [.stream, .audio, .controls, .appearance, .covers])
        #expect(AppLanguageSetting.rows(.about).isEmpty)
        #endif
    }

    @Test func languageIsNotMisplacedInAppearanceOrStreamSettings() {
        for tab in [SettingsTab.stream, .audio, .controls, .appearance] {
            #expect(AppLanguageSetting.rows(tab, supported: true).isEmpty)
        }
    }
}
