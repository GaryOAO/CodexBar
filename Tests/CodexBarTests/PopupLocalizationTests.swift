import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct PopupLocalizationTests {
    @Test
    func `descriptor account labels use selected localization`() throws {
        try CodexBarLocalizationOverride.$appLanguage.withValue("zh-Hant") {
            let suite = "PopupLocalizationTests-descriptor"
            let settings = try Self.makeSettingsStore(suite: suite)
            let store = UsageStore(
                fetcher: UsageFetcher(environment: [:]),
                browserDetection: BrowserDetection(cacheTTL: 0),
                settings: settings,
                startupBehavior: .testing)
            store._setSnapshotForTesting(
                UsageSnapshot(
                    primary: RateWindow(usedPercent: 12, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                    secondary: nil,
                    updatedAt: Date(),
                    identity: ProviderIdentitySnapshot(
                        providerID: .codex,
                        accountEmail: "codex@example.com",
                        accountOrganization: nil,
                        loginMethod: "free")),
                provider: .codex)

            let descriptor = MenuDescriptor.build(
                provider: .codex,
                store: store,
                settings: settings,
                account: AccountInfo(email: nil, plan: nil),
                updateReady: false,
                includeContextualActions: false)

            let lines = Self.textLines(from: descriptor)

            #expect(lines.contains("帳號: codex@example.com"))
            #expect(lines.contains("方案: Free"))
            #expect(!lines.contains("Account: codex@example.com"))
            #expect(!lines.contains("Plan: Free"))
        }
    }

    @Test
    func `cookie source dynamic subtitles use selected localization`() {
        CodexBarLocalizationOverride.$appLanguage.withValue("zh-Hant") {
            let subtitle = ProviderCookieSourceUI.subtitle(
                source: .manual,
                keychainDisabled: false,
                auto: "Automatically imports browser cookies.",
                manual: "Paste a Cookie header or cURL capture from T3 Chat settings.",
                off: "T3 Chat cookies are disabled.")
            let disabledSubtitle = ProviderCookieSourceUI.subtitle(
                source: .manual,
                keychainDisabled: true,
                auto: "Automatically imports browser cookies.",
                manual: "Paste a Cookie header or cURL capture from T3 Chat settings.",
                off: "T3 Chat cookies are disabled.")
            let jsonBundleSubtitle = ProviderCookieSourceUI.subtitle(
                source: .manual,
                keychainDisabled: false,
                auto: "Automatically imports browser cookies.",
                manual: "Paste the localStorage JSON bundle from Windsurf session.",
                off: "Windsurf cookies are disabled.")

            #expect(subtitle.contains("貼上"))
            #expect(!subtitle.contains("Paste a Cookie"))
            #expect(disabledSubtitle.contains("鑰匙圈"))
            #expect(!disabledSubtitle.contains("Keychain access"))
            #expect(jsonBundleSubtitle.contains("來自 Windsurf session 的 localStorage JSON"))
        }
    }

    private static func makeSettingsStore(suite: String) throws -> SettingsStore {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(userDefaults: defaults, configStore: testConfigStore(suiteName: suite))
        settings.statusChecksEnabled = false
        return settings
    }

    private static func textLines(from descriptor: MenuDescriptor) -> [String] {
        descriptor.sections.flatMap(\.entries).compactMap { entry -> String? in
            guard case let .text(text, _) = entry else { return nil }
            return text
        }
    }
}
