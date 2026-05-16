import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct PetIntegrationTests {
    @Test
    func `pet status encodes eighteen byte payload with one billion tokens`() {
        let status = PetStatus(
            providerIdx: PetProvider.claude.rawValue,
            usage5hPct: 90,
            usageWeekPct: 91,
            mode: PetMode.celebrating.rawValue,
            flags: PetStatus.flagBitFiveHourWarning | PetStatus.flagBitWeeklyWarning,
            presentation: 0x12,
            reset5hMinutes: 15,
            resetWeekMinutes: 120,
            todayTokens: 1_000_000_000,
            epochSeconds: 1_800_000_000)

        let data = status.encoded()

        #expect(data.count == PetStatus.wireSize)
        #expect(Array(data.prefix(6)) == [
            PetProvider.claude.rawValue,
            90,
            91,
            PetMode.celebrating.rawValue,
            PetStatus.flagBitFiveHourWarning | PetStatus.flagBitWeeklyWarning,
            0x12,
        ])
        #expect(data[10] == 0x00)
        #expect(data[11] == 0xCA)
        #expect(data[12] == 0x9A)
        #expect(data[13] == 0x3B)
    }

    @Test
    func `pet settings persist sanitized defaults`() throws {
        let suite = "PetIntegrationTests-settings"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(90.0, forKey: "petPushIntervalSeconds")
        defaults.set(99, forKey: "petQuietHoursStart")
        defaults.set(-1, forKey: "petQuietHoursEnd")
        defaults.set("bad-display", forKey: "petUsageDisplay")
        defaults.set("bad-personality", forKey: "petPersonality")
        let settings = Self.makeSettingsStore(userDefaults: defaults, suite: suite)

        #expect(settings.petEnabled == false)
        #expect(settings.petPushIntervalSeconds == 60.0)
        #expect(settings.petQuietHoursStart == 23)
        #expect(settings.petQuietHoursEnd == 0)
        #expect(settings.petUsageDisplay == .remaining)
        #expect(settings.petPersonality == .playful)

        settings.petEnabled = true
        settings.petPushIntervalSeconds = 0
        settings.petUsageDisplay = .both
        settings.petPersonality = .focus

        #expect(defaults.bool(forKey: "petEnabled"))
        #expect(defaults.double(forKey: "petPushIntervalSeconds") == 1.0)
        #expect(defaults.string(forKey: "petUsageDisplay") == "both")
        #expect(defaults.string(forKey: "petPersonality") == "focus")
    }

    @Test
    func `quiet hours handles same day and midnight wrapped windows`() {
        #expect(PetUsageBridge.isHourInQuietWindow(hour: 23, start: 22, end: 7))
        #expect(PetUsageBridge.isHourInQuietWindow(hour: 3, start: 22, end: 7))
        #expect(!PetUsageBridge.isHourInQuietWindow(hour: 12, start: 22, end: 7))
        #expect(PetUsageBridge.isHourInQuietWindow(hour: 10, start: 9, end: 17))
        #expect(!PetUsageBridge.isHourInQuietWindow(hour: 18, start: 9, end: 17))
        #expect(!PetUsageBridge.isHourInQuietWindow(hour: 9, start: 9, end: 9))
    }

    @Test
    func `pet bridge matches token UI today semantics and presentation settings`() throws {
        let suite = "PetIntegrationTests-bridge"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = Self.makeSettingsStore(userDefaults: defaults, suite: suite)
        settings.petQuipsEnabled = false
        settings.petMicroActionsEnabled = false
        settings.petMilestoneCelebrationsEnabled = false
        settings.petUsageDisplay = .both
        settings.petPersonality = .focus
        let store = Self.makeUsageStore(settings: settings)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 100,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(15 * 60),
                    resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 91,
                    windowMinutes: 7 * 24 * 60,
                    resetsAt: now.addingTimeInterval(120 * 60),
                    resetDescription: nil),
                updatedAt: now),
            provider: .claude)
        store._setTokenSnapshotForTesting(
            CostUsageTokenSnapshot(
                sessionTokens: 1_000_000_000,
                sessionCostUSD: 1.25,
                last30DaysTokens: nil,
                last30DaysCostUSD: nil,
                daily: [
                    CostUsageDailyReport.Entry(
                        date: "2026-05-16",
                        inputTokens: nil,
                        outputTokens: nil,
                        totalTokens: 42,
                        costUSD: nil,
                        modelsUsed: nil,
                        modelBreakdowns: nil),
                ],
                updatedAt: now),
            provider: .claude)

        let status = PetUsageBridge(store: store, settings: settings).snapshot()

        #expect(status.usage5hPct == 100)
        #expect(status.usageWeekPct == 91)
        #expect(status.todayTokens == 1_000_000_000)
        #expect(status.flags & PetStatus.flagBitFiveHourWarning != 0)
        #expect(status.flags & PetStatus.flagBitWeeklyWarning != 0)
        #expect(status.flags & PetStatus.flagBitRateLimited != 0)
        #expect(status.flags & PetStatus.flagBitQuipsDisabled != 0)
        #expect(status.flags & PetStatus.flagBitMicroActionsDisabled != 0)
        #expect(status.flags & PetStatus.flagBitMilestonesDisabled != 0)
        #expect(status.presentation == 0x22)
    }

    private static func makeSettingsStore(userDefaults: UserDefaults, suite: String) -> SettingsStore {
        SettingsStore(
            userDefaults: userDefaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
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

    private static func makeUsageStore(settings: SettingsStore) -> UsageStore {
        UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
    }
}
