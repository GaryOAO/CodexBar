import CodexBarCore
import Foundation
import Testing

struct ProviderTokenResolverTests {
    @Test
    func `claude admin API resolution uses environment token`() {
        let env = [ClaudeAdminAPISettingsReader.adminAPIKeyEnvironmentKey: "sk-ant-admin-token"]
        let resolution = ProviderTokenResolver.claudeAdminAPIResolution(environment: env)
        #expect(resolution?.token == "sk-ant-admin-token")
        #expect(resolution?.source == .environment)
    }

    @Test
    func `claude admin API resolution reads alternate environment key`() {
        let env = [ClaudeAdminAPISettingsReader.alternateAdminAPIKeyEnvironmentKey: "sk-ant-admin-alt"]
        let resolution = ProviderTokenResolver.claudeAdminAPIResolution(environment: env)
        #expect(resolution?.token == "sk-ant-admin-alt")
        #expect(resolution?.source == .environment)
    }

    @Test
    func `claude admin API resolution trims token`() {
        let env = [ClaudeAdminAPISettingsReader.adminAPIKeyEnvironmentKey: "  sk-ant-admin-token  "]
        let resolution = ProviderTokenResolver.claudeAdminAPIResolution(environment: env)
        #expect(resolution?.token == "sk-ant-admin-token")
    }

    @Test
    func `claude admin API resolution returns nil when missing`() {
        let resolution = ProviderTokenResolver.claudeAdminAPIResolution(environment: [:])
        #expect(resolution == nil)
    }

    @Test
    func `claude admin API token convenience matches resolution token`() {
        let env = [ClaudeAdminAPISettingsReader.adminAPIKeyEnvironmentKey: "sk-ant-admin-token"]
        #expect(ProviderTokenResolver.claudeAdminAPIToken(environment: env) == "sk-ant-admin-token")
    }
}
