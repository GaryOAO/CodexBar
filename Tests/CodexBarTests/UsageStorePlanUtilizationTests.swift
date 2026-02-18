import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite
struct UsageStorePlanUtilizationTests {
    @Test
    func codexUsesProviderCostWhenAvailable() throws {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 25,
                limit: 100,
                currencyCode: "USD",
                period: "Monthly",
                resetsAt: nil,
                updatedAt: Date()),
            updatedAt: Date())
        let credits = CreditsSnapshot(remaining: 0, events: [], updatedAt: Date())

        let percent = UsageStore.planHistoryMonthlyUsedPercent(
            provider: .codex,
            snapshot: snapshot,
            credits: credits)

        #expect(try abs(#require(percent) - 25) < 0.001)
    }

    @Test
    func claudeIgnoresProviderCostForMonthlyHistory() {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 40,
                limit: 100,
                currencyCode: "USD",
                period: "Monthly",
                resetsAt: nil,
                updatedAt: Date()),
            updatedAt: Date())

        let percent = UsageStore.planHistoryMonthlyUsedPercent(
            provider: .claude,
            snapshot: snapshot,
            credits: nil)

        #expect(percent == nil)
    }

    @Test
    func codexFallsBackToCredits() throws {
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "free")
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: nil,
            updatedAt: Date(),
            identity: identity)
        let credits = CreditsSnapshot(remaining: 640, events: [], updatedAt: Date())

        let percent = UsageStore.planHistoryMonthlyUsedPercent(
            provider: .codex,
            snapshot: snapshot,
            credits: credits)

        #expect(try abs(#require(percent) - 36) < 0.001)
    }

    @Test
    func codexFreePlanWithoutFreshCreditsReturnsNil() {
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "free")
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: nil,
            updatedAt: Date(),
            identity: identity)

        let percent = UsageStore.planHistoryMonthlyUsedPercent(
            provider: .codex,
            snapshot: snapshot,
            credits: nil)

        #expect(percent == nil)
    }

    @Test
    func codexPaidPlanDoesNotUseCreditsFallback() {
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "plus")
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: nil,
            updatedAt: Date(),
            identity: identity)
        let credits = CreditsSnapshot(remaining: 0, events: [], updatedAt: Date())

        let percent = UsageStore.planHistoryMonthlyUsedPercent(
            provider: .codex,
            snapshot: snapshot,
            credits: credits)

        #expect(percent == nil)
    }

    @Test
    func claudeWithoutProviderCostReturnsNil() {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: nil,
            updatedAt: Date())
        let credits = CreditsSnapshot(remaining: 100, events: [], updatedAt: Date())

        let percent = UsageStore.planHistoryMonthlyUsedPercent(
            provider: .claude,
            snapshot: snapshot,
            credits: credits)

        #expect(percent == nil)
    }

    @Test
    func codexWithinWindowPromotesMonthlyFromNilWithoutAppending() throws {
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "free")
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: nil,
            updatedAt: Date(),
            identity: identity)
        let now = Date()
        let nilMonthly = PlanUtilizationHistorySample(
            capturedAt: now,
            dailyUsedPercent: nil,
            weeklyUsedPercent: nil,
            monthlyUsedPercent: nil)
        let monthlyValue = try #require(
            UsageStore.planHistoryMonthlyUsedPercent(
                provider: .codex,
                snapshot: snapshot,
                credits: CreditsSnapshot(remaining: 640, events: [], updatedAt: now)))
        let promotedMonthly = PlanUtilizationHistorySample(
            capturedAt: now.addingTimeInterval(300),
            dailyUsedPercent: nil,
            weeklyUsedPercent: nil,
            monthlyUsedPercent: monthlyValue)

        let initial = try #require(
            UsageStore._updatedPlanUtilizationHistoryForTesting(
                provider: .codex,
                existingHistory: [],
                sample: nilMonthly,
                now: now))
        let updated = try #require(
            UsageStore._updatedPlanUtilizationHistoryForTesting(
                provider: .codex,
                existingHistory: initial,
                sample: promotedMonthly,
                now: now.addingTimeInterval(300)))

        #expect(updated.count == 1)
        let monthly = updated.last?.monthlyUsedPercent
        #expect(monthly != nil)
        #expect(abs((monthly ?? 0) - 36) < 0.001)
    }

    @Test
    func codexWithinWindowIgnoresNilMonthlyAfterKnownValue() throws {
        let identity = ProviderIdentitySnapshot(
            providerID: .codex,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "free")
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: nil,
            updatedAt: Date(),
            identity: identity)
        let now = Date()
        let monthlyValue = try #require(
            UsageStore.planHistoryMonthlyUsedPercent(
                provider: .codex,
                snapshot: snapshot,
                credits: CreditsSnapshot(remaining: 640, events: [], updatedAt: now)))
        let knownMonthly = PlanUtilizationHistorySample(
            capturedAt: now,
            dailyUsedPercent: nil,
            weeklyUsedPercent: nil,
            monthlyUsedPercent: monthlyValue)
        let nilMonthly = PlanUtilizationHistorySample(
            capturedAt: now.addingTimeInterval(300),
            dailyUsedPercent: nil,
            weeklyUsedPercent: nil,
            monthlyUsedPercent: nil)

        let initial = try #require(
            UsageStore._updatedPlanUtilizationHistoryForTesting(
                provider: .codex,
                existingHistory: [],
                sample: knownMonthly,
                now: now))
        let updated = UsageStore._updatedPlanUtilizationHistoryForTesting(
            provider: .codex,
            existingHistory: initial,
            sample: nilMonthly,
            now: now.addingTimeInterval(300))

        #expect(updated == nil)
        #expect(initial.count == 1)
        let monthly = initial.last?.monthlyUsedPercent
        #expect(monthly != nil)
        #expect(abs((monthly ?? 0) - 36) < 0.001)
    }
}
