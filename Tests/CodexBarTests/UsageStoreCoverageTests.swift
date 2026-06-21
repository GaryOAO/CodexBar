import CodexBarCore
import Foundation
import Observation
import Testing
@testable import CodexBar

@MainActor
struct UsageStoreCoverageTests {
    private final class ObservationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func set() {
            self.lock.lock()
            self.value = true
            self.lock.unlock()
        }

        func get() -> Bool {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.value
        }
    }

    @Test
    func `provider with highest usage and icon style`() throws {
        let settings = Self.makeSettingsStore(suite: "UsageStoreCoverageTests-highest")
        let store = Self.makeUsageStore(settings: settings)
        let metadata = ProviderRegistry.shared.metadata

        try settings.setProviderEnabled(provider: .codex, metadata: #require(metadata[.codex]), enabled: true)
        try settings.setProviderEnabled(provider: .claude, metadata: #require(metadata[.claude]), enabled: true)

        let now = Date()
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 50, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: now),
            provider: .codex)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: RateWindow(usedPercent: 70, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                updatedAt: now),
            provider: .claude)

        let highest = store.providerWithHighestUsage()
        #expect(highest?.provider == .codex)
        #expect(highest?.usedPercent == 50)
        #expect(store.iconStyle == .combined)

        try settings.setProviderEnabled(provider: .claude, metadata: #require(metadata[.claude]), enabled: false)
        #expect(store.iconStyle == store.style(for: .codex))

        store._setErrorForTesting("error", provider: .codex)
        #expect(store.isStale)
    }

    @Test
    func `source label adds open AI web`() {
        let settings = Self.makeSettingsStore(suite: "UsageStoreCoverageTests-source")
        settings.debugDisableKeychainAccess = false
        settings.codexUsageDataSource = .oauth
        settings.codexCookieSource = .manual

        let store = Self.makeUsageStore(settings: settings)
        store.openAIDashboard = OpenAIDashboardSnapshot(
            signedInEmail: "user@example.com",
            codeReviewRemainingPercent: nil,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            updatedAt: Date())
        store.openAIDashboardRequiresLogin = false

        let label = store.sourceLabel(for: .codex)
        #expect(label.contains("openai-web"))
    }

    @Test
    func `account info caches codex auth parsing until config revision changes`() throws {
        let settings = Self.makeSettingsStore(suite: "UsageStoreCoverageTests-account-info-cache")
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "usage-store-account-info-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        try Self.writeCodexAuthFile(homeURL: home, email: "first@example.com", plan: "plus")
        let env = ["CODEX_HOME": home.path]
        settings._test_codexReconciliationEnvironment = env
        defer { settings._test_codexReconciliationEnvironment = nil }
        let store = UsageStore(
            fetcher: UsageFetcher(environment: env),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: env)

        let first = store.accountInfo(for: .codex)
        try Self.writeCodexAuthFile(homeURL: home, email: "second@example.com", plan: "pro")
        let cached = store.accountInfo(for: .codex)
        settings.configRevision &+= 1
        let refreshed = store.accountInfo(for: .codex)

        #expect(first.email == "first@example.com")
        #expect(cached.email == "first@example.com")
        #expect(refreshed.email == "second@example.com")
    }

    @Test
    func `permission prompt errors are detected for notifications`() {
        let errors: [LocalizedTestError] = [
            LocalizedTestError("Waiting for folder trust prompt"),
            LocalizedTestError("Permission prompt is waiting in the CLI"),
        ]

        for error in errors {
            #expect(UsageStore.isPermissionPromptWaiting(error))
        }
        #expect(!UsageStore.isPermissionPromptWaiting(LocalizedTestError("network timeout")))
    }

    @Test
    func `subscription detection`() {
        let settings = Self.makeSettingsStore(suite: "UsageStoreCoverageTests-availability")
        let store = Self.makeUsageStore(settings: settings)

        let identity = ProviderIdentitySnapshot(
            providerID: .claude,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "Pro")
        store._setSnapshotForTesting(
            UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date(), identity: identity),
            provider: .claude)
        #expect(store.isClaudeSubscription())
        #expect(UsageStore.isSubscriptionPlan("Team"))
        #expect(!UsageStore.isSubscriptionPlan("api"))
    }

    @Test
    func `background refresh only tracks enabled providers`() throws {
        let settings = Self.makeSettingsStore(suite: "UsageStoreCoverageTests-background-refresh")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false

        let metadata = ProviderRegistry.shared.metadata
        for provider in UsageProvider.allCases {
            try settings.setProviderEnabled(
                provider: provider,
                metadata: #require(metadata[provider]),
                enabled: false)
        }
        try settings.setProviderEnabled(provider: .codex, metadata: #require(metadata[.codex]), enabled: true)

        let store = Self.makeUsageStore(settings: settings)
        let staleSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 25, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        store._setSnapshotForTesting(staleSnapshot, provider: .claude)
        store._setErrorForTesting("stale", provider: .claude)
        store.statuses[.claude] = ProviderStatus(indicator: .major, description: "Outage", updatedAt: Date())

        #expect(store.enabledProviders() == [.codex])

        store.clearDisabledProviderState(enabledProviders: Set(store.enabledProvidersForDisplay()))

        #expect(store.snapshot(for: .claude) == nil)
        #expect(store.errors[.claude] == nil)
        #expect(store.statuses[.claude] == nil)
    }

    @Test
    func `status indicators and failure gate`() {
        #expect(!ProviderStatusIndicator.none.hasIssue)
        #expect(ProviderStatusIndicator.maintenance.hasIssue)
        CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            #expect(ProviderStatusIndicator.unknown.label == "Status unknown")
        }

        var gate = ConsecutiveFailureGate()
        let first = gate.shouldSurfaceError(onFailureWithPriorData: true)
        #expect(!first)
        let second = gate.shouldSurfaceError(onFailureWithPriorData: true)
        #expect(second)
        gate.recordSuccess()
        let third = gate.shouldSurfaceError(onFailureWithPriorData: false)
        #expect(third)
        gate.reset()
        #expect(gate.streak == 0)
    }

    @Test
    func `token account error message ignores cancellation`() {
        let settings = Self.makeSettingsStore(suite: "UsageStoreCoverageTests-token-account-cancel")
        let store = Self.makeUsageStore(settings: settings)

        #expect(store.tokenAccountErrorMessage(CancellationError()) == nil)
        #expect(store.tokenAccountErrorMessage(ProviderFetchError.noAvailableStrategy(.codex)) != nil)
    }

    @Test
    func `isPreservableNetworkTransportError classifies transport failures correctly`() {
        #expect(UsageStore.isPreservableNetworkTransportError(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)))
        #expect(UsageStore.isPreservableNetworkTransportError(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)))
        #expect(UsageStore.isPreservableNetworkTransportError(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorDNSLookupFailed)))
        #expect(UsageStore.isPreservableNetworkTransportError(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)))
        #expect(UsageStore.isPreservableNetworkTransportError(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)))
        #expect(UsageStore.isPreservableNetworkTransportError(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)))
        #expect(UsageStore.isPreservableNetworkTransportError(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)))
        #expect(!UsageStore.isPreservableNetworkTransportError(
            NSError(domain: NSCocoaErrorDomain, code: 0)))
    }

    @Test
    func `background work settings observation ignores menu provider selection churn`() async throws {
        let settings = Self.makeSettingsStore(suite: "UsageStoreCoverageTests-switcher-selection-observation")
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        try Self.enableOnly(.codex, settings: settings)

        let store = Self.makeUsageStore(settings: settings)
        let didChange = ObservationFlag()

        withObservationTracking {
            _ = store.backgroundWorkSettingsObservationToken
        } onChange: {
            didChange.set()
        }

        settings.selectedMenuProvider = .codex
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(didChange.get() == false)

        let refreshDidChange = ObservationFlag()
        withObservationTracking {
            _ = store.backgroundWorkSettingsObservationToken
        } onChange: {
            refreshDidChange.set()
        }

        settings.refreshFrequency = .oneMinute
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(refreshDidChange.get() == true)
    }

    @Test
    func `startup status network failure schedules bounded retry`() async throws {
        let settings = Self.makeSettingsStore(suite: "UsageStoreCoverageTests-startup-status-retry")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = true
        try Self.enableOnly(.codex, settings: settings)

        let store = Self.makeUsageStore(settings: settings)
        store._test_providerRefreshOverride = { _ in }
        defer { store._test_providerRefreshOverride = nil }
        store._test_providerStatusFetchOverride = { _ in
            throw URLError(.notConnectedToInternet)
        }
        defer { store._test_providerStatusFetchOverride = nil }

        var scheduled: [(attempt: Int, delay: TimeInterval)] = []
        store._test_startupConnectivityRetryScheduled = { attempt, delay in
            scheduled.append((attempt, delay))
        }
        defer { store._test_startupConnectivityRetryScheduled = nil }

        await store.refresh()
        defer {
            store.startupConnectivityRetryTask?.cancel()
            store.startupConnectivityRetryTask = nil
        }

        #expect(scheduled.map(\.attempt) == [1])
        #expect(scheduled.map(\.delay) == [15])
        #expect(store.statuses[.codex]?.indicator == .unknown)
        #expect(store.statuses[.codex]?.description?.isEmpty == false)
    }

    @Test
    func `startup connectivity retry refreshes status and clears retry task after recovery`() async throws {
        let settings = Self.makeSettingsStore(suite: "UsageStoreCoverageTests-startup-status-recovery")
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = true
        try Self.enableOnly(.codex, settings: settings)

        let store = Self.makeUsageStore(settings: settings)
        store._test_providerRefreshOverride = { _ in }
        defer { store._test_providerRefreshOverride = nil }

        var statusAttempts = 0
        store._test_providerStatusFetchOverride = { _ in
            statusAttempts += 1
            if statusAttempts == 1 {
                throw URLError(.cannotFindHost)
            }
            return ProviderStatus(indicator: .none, description: "Operational", updatedAt: Date())
        }
        defer { store._test_providerStatusFetchOverride = nil }

        let sleepGate = StartupConnectivityRetrySleepGate()
        store._test_startupConnectivityRetrySleepOverride = { delay in
            try await sleepGate.sleep(delay)
        }
        defer { store._test_startupConnectivityRetrySleepOverride = nil }

        await store.refresh()
        await sleepGate.waitUntilSleeping()
        let retryTask = try #require(store.startupConnectivityRetryTask)

        await sleepGate.resume()
        await retryTask.value

        #expect(statusAttempts == 2)
        #expect(store.statuses[.codex]?.indicator == ProviderStatusIndicator.none)
        #expect(store.statuses[.codex]?.description == "Operational")
        #expect(store.startupConnectivityRetryTask == nil)
    }

    @Test
    func `startup connectivity retry classification is bounded and excludes cancellation`() {
        #expect(UsageStore.startupConnectivityRetryDelay(forAttempt: 1) == 15)
        #expect(UsageStore.startupConnectivityRetryDelay(forAttempt: 4) == 300)
        #expect(UsageStore.startupConnectivityRetryDelay(forAttempt: 5) == nil)
        #expect(UsageStore.isStartupConnectivityRetryableError(URLError(.timedOut)))
        #expect(UsageStore.isStartupConnectivityRetryableError(URLError(.notConnectedToInternet)))
        #expect(!UsageStore.isStartupConnectivityRetryableError(URLError(.cancelled)))
        #expect(!UsageStore.isStartupConnectivityRetryableError(CancellationError()))
    }

    private static func makeSettingsStore(suite: String) -> SettingsStore {
        let settings = testSettingsStore(suiteName: suite)
        settings.providerDetectionCompleted = true
        return settings
    }

    private static func makeUsageStore(settings: SettingsStore) -> UsageStore {
        UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            environmentBase: [:])
    }

    private static func writeCodexAuthFile(homeURL: URL, email: String, plan: String) throws {
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        let auth = try [
            "tokens": [
                "accessToken": "access-token",
                "refreshToken": "refresh-token",
                "idToken": Self.fakeCodexJWT(email: email, plan: plan),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: auth)
        try data.write(to: homeURL.appendingPathComponent("auth.json"), options: .atomic)
    }

    private static func fakeCodexJWT(email: String, plan: String) throws -> String {
        let header = try JSONSerialization.data(withJSONObject: ["alg": "none"])
        let payload = try JSONSerialization.data(withJSONObject: [
            "email": email,
            "chatgpt_plan_type": plan,
            "https://api.openai.com/auth": [
                "chatgpt_plan_type": plan,
            ],
        ])
        return "\(Self.base64URL(header)).\(Self.base64URL(payload))."
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }

    private static func enableOnly(_ enabledProvider: UsageProvider, settings: SettingsStore) throws {
        let metadata = ProviderRegistry.shared.metadata
        for provider in UsageProvider.allCases {
            try settings.setProviderEnabled(
                provider: provider,
                metadata: #require(metadata[provider]),
                enabled: provider == enabledProvider)
        }
    }
}

private actor StartupConnectivityRetrySleepGate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func sleep(_ delay: TimeInterval) async throws {
        #expect(delay == 15)
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.resumeWaiters()
        }
    }

    func waitUntilSleeping() async {
        if self.continuation != nil { return }
        await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
    }

    func resume() {
        self.continuation?.resume()
        self.continuation = nil
    }

    private func resumeWaiters() {
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private struct LocalizedTestError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        self.message
    }
}
