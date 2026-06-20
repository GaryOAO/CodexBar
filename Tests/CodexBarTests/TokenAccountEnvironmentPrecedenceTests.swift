import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct TokenAccountEnvironmentPrecedenceTests {
    @Test
    func `claude OAuth token account overrides environment in app environment builder`() {
        let settings = Self.makeSettingsStore(suite: "TokenAccountEnvironmentPrecedenceTests-claude-app")
        settings.addTokenAccount(provider: .claude, label: "OAuth", token: "Bearer sk-ant-oat-account-token")

        let env = ProviderRegistry.makeEnvironment(
            base: ["FOO": "bar"],
            provider: .claude,
            settings: settings,
            tokenOverride: nil)

        #expect(env["FOO"] == "bar")
        #expect(env[ClaudeOAuthCredentialsStore.environmentTokenKey] == "sk-ant-oat-account-token")
    }

    @Test
    func `claude session account strips ambient admin api credentials in app environment builder`() {
        let settings = Self.makeSettingsStore(suite: "TokenAccountEnvironmentPrecedenceTests-claude-admin-strip-app")
        settings.claudeAdminAPIKey = "sk-ant-admin-config"
        settings.addTokenAccount(provider: .claude, label: "Session", token: "sk-ant-session-token")

        let env = ProviderRegistry.makeEnvironment(
            base: [
                "FOO": "bar",
                ClaudeAdminAPISettingsReader.alternateAdminAPIKeyEnvironmentKey: "sk-ant-admin-base",
                ClaudeOAuthCredentialsStore.environmentTokenKey: "sk-ant-oat-base",
            ],
            provider: .claude,
            settings: settings,
            tokenOverride: nil)

        #expect(env["FOO"] == "bar")
        #expect(env[ClaudeAdminAPISettingsReader.adminAPIKeyEnvironmentKey] == nil)
        #expect(env[ClaudeAdminAPISettingsReader.alternateAdminAPIKeyEnvironmentKey] == nil)
        #expect(env[ClaudeOAuthCredentialsStore.environmentTokenKey] == nil)
    }

    @Test
    func `claude session key selection carries organization id in app settings snapshot`() throws {
        let settings = Self.makeSettingsStore(suite: "TokenAccountEnvironmentPrecedenceTests-claude-org-app")
        settings.addTokenAccount(
            provider: .claude,
            label: "Team",
            token: "sk-ant-session-token",
            organizationID: " org-team ")

        let snapshot = ProviderRegistry.makeSettingsSnapshot(settings: settings, tokenOverride: nil)
        let claudeSettings = try #require(snapshot.claude)

        #expect(claudeSettings.manualCookieHeader == "sessionKey=sk-ant-session-token")
        #expect(claudeSettings.organizationID == "org-team")
    }
}

extension TokenAccountEnvironmentPrecedenceTests {
    fileprivate static func makeSettingsStore(suite: String) -> SettingsStore {
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
