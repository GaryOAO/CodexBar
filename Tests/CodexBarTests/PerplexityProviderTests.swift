import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct PerplexityProviderTests {
    private struct StubClaudeFetcher: ClaudeUsageFetching {
        func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
            throw ClaudeUsageError.parseFailed("stub")
        }

        func debugRawProbe(model _: String) async -> String {
            "stub"
        }

        func detectVersion() -> String? {
            nil
        }
    }

    private func makeContext(
        settings: ProviderSettingsSnapshot?,
        env: [String: String] = [:]) -> ProviderFetchContext
    {
        ProviderFetchContext(
            runtime: .app,
            sourceMode: .auto,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: settings,
            fetcher: UsageFetcher(environment: env),
            claudeFetcher: StubClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0))
    }

    @Test
    func offModeIgnoresEnvironmentSessionCookie() async {
        let strategy = PerplexityWebFetchStrategy()
        let settings = ProviderSettingsSnapshot.make(
            perplexity: ProviderSettingsSnapshot.PerplexityProviderSettings(
                cookieSource: .off,
                manualCookieHeader: nil))
        let context = self.makeContext(
            settings: settings,
            env: ["PERPLEXITY_COOKIE": "authjs.session-token=env-token"])

        #expect(await strategy.isAvailable(context) == false)
    }
}
