import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized)
@MainActor
struct CodexManagedRoutingTests {
    @Test
    func `provider registry injects active managed home into codex env only`() {
        let settings = self.makeSettingsStore(suite: "CodexManagedRoutingTests-registry")
        let managedHomePath = "/tmp/codex-managed-home"
        settings._test_activeManagedCodexRemoteHomePath = managedHomePath

        let codexEnv = ProviderRegistry.makeEnvironment(
            base: ["PATH": "/usr/bin"],
            provider: .codex,
            settings: settings,
            tokenOverride: nil)
        let claudeEnv = ProviderRegistry.makeEnvironment(
            base: ["PATH": "/usr/bin"],
            provider: .claude,
            settings: settings,
            tokenOverride: nil)

        #expect(codexEnv["CODEX_HOME"] == managedHomePath)
        #expect(claudeEnv["CODEX_HOME"] == nil)
    }

    @Test
    func `provider registry fails closed when managed account store is unreadable`() {
        let settings = self.makeSettingsStore(suite: "CodexManagedRoutingTests-unreadable-store")
        settings._test_unreadableManagedCodexAccountStore = true

        let env = ProviderRegistry.makeEnvironment(
            base: ["CODEX_HOME": "/Users/example/.codex"],
            provider: .codex,
            settings: settings,
            tokenOverride: nil)

        #expect(env["CODEX_HOME"] != nil)
        #expect(env["CODEX_HOME"] != "/Users/example/.codex")
        #expect(env["CODEX_HOME"]?.isEmpty == false)
    }

    @Test
    func `provider registry builds codex fetcher scoped to managed home`() throws {
        let settings = self.makeSettingsStore(suite: "CodexManagedRoutingTests-registry-fetcher")
        let managedHome = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: managedHome) }

        settings._test_activeManagedCodexRemoteHomePath = managedHome.path
        try self.writeCodexAuthFile(homeURL: managedHome, email: "managed@example.com", plan: "pro")

        let browserDetection = BrowserDetection(cacheTTL: 0)
        let specs = ProviderRegistry.shared.specs(
            settings: settings,
            metadata: ProviderDescriptorRegistry.metadata,
            codexFetcher: UsageFetcher(environment: [:]),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
        let context = try #require(specs[.codex]?.makeFetchContext())

        let account = context.fetcher.loadAccountInfo()
        #expect(account.email == "managed@example.com")
        #expect(account.plan == "pro")
    }

    @Test
    func `usage store builds codex token account fetcher scoped to managed home`() throws {
        let settings = self.makeSettingsStore(suite: "CodexManagedRoutingTests-usage-store")
        let managedHome = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: managedHome) }

        settings._test_activeManagedCodexRemoteHomePath = managedHome.path
        try self.writeCodexAuthFile(homeURL: managedHome, email: "token@example.com", plan: "team")

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        let context = store.makeFetchContext(provider: .codex, override: nil)

        let account = context.fetcher.loadAccountInfo()
        #expect(account.email == "token@example.com")
        #expect(account.plan == "team")
    }

    @Test
    func `codex O auth strategy availability reads auth from context env`() async throws {
        let managedHome = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: managedHome) }

        let credentials = CodexOAuthCredentials(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            idToken: nil,
            accountId: nil,
            lastRefresh: Date())
        try CodexOAuthCredentialsStore.save(credentials, env: ["CODEX_HOME": managedHome.path])

        let strategy = CodexOAuthFetchStrategy()
        let available = await strategy.isAvailable(self.makeContext(env: ["CODEX_HOME": managedHome.path]))

        #expect(available)
    }

    @Test
    func `codex O auth credentials store loads and saves using explicit env`() throws {
        let managedHome = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: managedHome) }

        let credentials = CodexOAuthCredentials(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            idToken: "id-token",
            accountId: "account-id",
            lastRefresh: Date())
        let env = ["CODEX_HOME": managedHome.path]

        try CodexOAuthCredentialsStore.save(credentials, env: env)

        let authURL = CodexOAuthCredentialsStore._authFileURLForTesting(env: env)
        #expect(authURL.path == managedHome.appendingPathComponent("auth.json").path)

        let loaded = try CodexOAuthCredentialsStore.load(env: env)
        #expect(loaded.accessToken == credentials.accessToken)
        #expect(loaded.refreshToken == credentials.refreshToken)
        #expect(loaded.idToken == credentials.idToken)
        #expect(loaded.accountId == credentials.accountId)
    }

    @Test
    func `codex no data message uses explicit environment home`() {
        let env = ["CODEX_HOME": "/tmp/managed-codex-home"]

        let message = CodexProviderDescriptor._noDataMessageForTesting(env: env)

        #expect(message.contains("/tmp/managed-codex-home/sessions"))
        #expect(message.contains("/tmp/managed-codex-home/archived_sessions"))
    }

    private func makeContext(env: [String: String]) -> ProviderFetchContext {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: .auto,
            includeCredits: false,
            webTimeout: 60,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: nil,
            fetcher: UsageFetcher(),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }

    private func makeSettingsStore(suite: String) -> SettingsStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        return SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: InMemoryZaiTokenStore(),
            syntheticTokenStore: InMemorySyntheticTokenStore(),
            codexCookieStore: InMemoryCookieHeaderStore(),
            claudeCookieStore: InMemoryCookieHeaderStore(),
            cursorCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            factoryCookieStore: InMemoryCookieHeaderStore(),
            minimaxCookieStore: InMemoryMiniMaxCookieStore(),
            minimaxAPITokenStore: InMemoryMiniMaxAPITokenStore(),
            kimiTokenStore: InMemoryKimiTokenStore(),
            kimiK2TokenStore: InMemoryKimiK2TokenStore(),
            augmentCookieStore: InMemoryCookieHeaderStore(),
            ampCookieStore: InMemoryCookieHeaderStore(),
            copilotTokenStore: InMemoryCopilotTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
    }

    private func writeCodexAuthFile(homeURL: URL, email: String, plan: String) throws {
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        let auth = [
            "tokens": [
                "idToken": Self.fakeJWT(email: email, plan: plan),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: auth)
        try data.write(to: homeURL.appendingPathComponent("auth.json"))
    }

    private static func fakeJWT(email: String, plan: String) -> String {
        let header = (try? JSONSerialization.data(withJSONObject: ["alg": "none"])) ?? Data()
        let payload = (try? JSONSerialization.data(withJSONObject: [
            "email": email,
            "chatgpt_plan_type": plan,
        ])) ?? Data()

        func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
        }

        return "\(base64URL(header)).\(base64URL(payload))."
    }
}

private final class InMemoryZaiTokenStore: ZaiTokenStoring, @unchecked Sendable {
    func loadToken() throws -> String? {
        nil
    }

    func storeToken(_: String?) throws {}
}

private final class InMemorySyntheticTokenStore: SyntheticTokenStoring, @unchecked Sendable {
    func loadToken() throws -> String? {
        nil
    }

    func storeToken(_: String?) throws {}
}
