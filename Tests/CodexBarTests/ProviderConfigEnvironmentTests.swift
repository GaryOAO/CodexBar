import CodexBarCore
import Testing

struct ProviderConfigEnvironmentTests {
    @Test
    func `applies admin API key override for claude`() {
        let config = ProviderConfig(id: .claude, apiKey: "claude-admin-token")
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [:],
            provider: .claude,
            config: config)

        #expect(env[ClaudeAdminAPISettingsReader.adminAPIKeyEnvironmentKey] == "claude-admin-token")
        #expect(ProviderTokenResolver.claudeAdminAPIToken(environment: env) == "claude-admin-token")
    }

    @Test
    func `claude config override wins over environment admin key`() {
        let config = ProviderConfig(id: .claude, apiKey: "config-token")
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [ClaudeAdminAPISettingsReader.adminAPIKeyEnvironmentKey: "env-token"],
            provider: .claude,
            config: config)

        #expect(env[ClaudeAdminAPISettingsReader.adminAPIKeyEnvironmentKey] == "config-token")
        #expect(ProviderTokenResolver.claudeAdminAPIToken(environment: env) == "config-token")
    }

    @Test
    func `leaves environment when claude API key missing`() {
        let config = ProviderConfig(id: .claude, apiKey: nil)
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [ClaudeAdminAPISettingsReader.adminAPIKeyEnvironmentKey: "existing"],
            provider: .claude,
            config: config)

        #expect(env[ClaudeAdminAPISettingsReader.adminAPIKeyEnvironmentKey] == "existing")
    }

    @Test
    func `claude supports API key override`() {
        #expect(ProviderConfigEnvironment.supportsAPIKeyOverride(for: .claude) == true)
    }

    @Test
    func `codex does not support API key override`() {
        #expect(ProviderConfigEnvironment.supportsAPIKeyOverride(for: .codex) == false)
    }
}
