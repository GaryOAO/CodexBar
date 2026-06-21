import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct SettingsStoreAdditionalTests {
    @Test
    func `menu bar metric preference handles codex and claude`() {
        let settings = Self.makeSettingsStore(suite: "SettingsStoreAdditionalTests-metric")

        settings.setMenuBarMetricPreference(.average, for: .codex)
        #expect(settings.menuBarMetricPreference(for: .codex) == .automatic)

        settings.setMenuBarMetricPreference(.primaryAndSecondary, for: .codex)
        #expect(settings.menuBarMetricPreference(for: .codex) == .primaryAndSecondary)
        #expect(settings.menuBarMetricSupportsPrimaryAndSecondary(for: .codex))

        settings.setMenuBarMetricPreference(.primaryAndSecondary, for: .claude)
        #expect(settings.menuBarMetricPreference(for: .claude) == .automatic)
        #expect(!settings.menuBarMetricSupportsPrimaryAndSecondary(for: .claude))

        settings.setMenuBarMetricPreference(.monthlyPlan, for: .codex)
        #expect(settings.menuBarMetricPreference(for: .codex) == .automatic)

        settings.menuBarMetricPreferencesRaw[UsageProvider.codex.rawValue] = MenuBarMetricPreference.monthlyPlan
            .rawValue
        #expect(settings.menuBarMetricPreference(for: .codex) == .automatic)

        settings.setMenuBarMetricPreference(.tertiary, for: .codex)
        #expect(settings.menuBarMetricPreference(for: .codex) == .automatic)

        settings.setMenuBarMetricPreference(.extraUsage, for: .claude)
        #expect(settings.menuBarMetricPreference(for: .claude) == .extraUsage)
        #expect(settings.menuBarMetricPreference(for: .claude, snapshot: nil) == .automatic)
        #expect(settings.menuBarMetricSupportsExtraUsage(for: .claude, snapshot: nil) == false)
    }

    @Test
    func `token accounts set manual cookie source when required`() {
        let settings = Self.makeSettingsStore(suite: "SettingsStoreAdditionalTests-token-accounts")

        settings.addTokenAccount(provider: .claude, label: "Primary", token: "token-1")

        #expect(settings.tokenAccounts(for: .claude).count == 1)
        #expect(settings.claudeCookieSource == .manual)
    }

    @Test
    func `detects token cost usage sources from filesystem`() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try fm.createDirectory(at: sessions, withIntermediateDirectories: true)
        let jsonl = sessions.appendingPathComponent("usage.jsonl")
        try Data("{}".utf8).write(to: jsonl)
        defer { try? fm.removeItem(at: root) }

        let env = ["CODEX_HOME": root.path]

        #expect(SettingsStore.hasAnyTokenCostUsageSources(env: env, fileManager: fm))
    }

    private static func makeSettingsStore(suite: String) -> SettingsStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)

        return SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            codexCookieStore: InMemoryCookieHeaderStore(),
            claudeCookieStore: InMemoryCookieHeaderStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
    }
}
