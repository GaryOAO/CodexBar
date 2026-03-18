import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite
struct UsageStorePlanUtilizationResetCoalescingTests {
    @Test
    func sameHourSampleWithChangedPrimaryResetBoundaryAppendsNewSample() throws {
        let calendar = Calendar(identifier: .gregorian)
        let hourStart = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 3,
            day: 17,
            hour: 9)))
        let firstReset = hourStart.addingTimeInterval(30 * 60)
        let secondReset = hourStart.addingTimeInterval(5 * 60 + 5 * 60 * 60)
        let beforeReset = makePlanSample(
            at: hourStart.addingTimeInterval(25 * 60),
            primary: 82,
            secondary: 40,
            primaryWindowMinutes: 300,
            primaryResetsAt: firstReset,
            secondaryWindowMinutes: 10080)
        let afterReset = makePlanSample(
            at: hourStart.addingTimeInterval(35 * 60),
            primary: 4,
            secondary: 41,
            primaryWindowMinutes: 300,
            primaryResetsAt: secondReset,
            secondaryWindowMinutes: 10080)

        let initial = try #require(
            UsageStore._updatedPlanUtilizationHistoryForTesting(
                provider: .codex,
                existingHistory: [],
                sample: beforeReset))
        let updated = try #require(
            UsageStore._updatedPlanUtilizationHistoryForTesting(
                provider: .codex,
                existingHistory: initial,
                sample: afterReset))

        #expect(updated.count == 2)
        #expect(updated[0] == beforeReset)
        #expect(updated[1] == afterReset)
    }

    @Test
    func sameHourSampleWithChangedSecondaryResetBoundaryAppendsNewSample() throws {
        let calendar = Calendar(identifier: .gregorian)
        let hourStart = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 3,
            day: 17,
            hour: 9)))
        let firstReset = hourStart.addingTimeInterval(30 * 60)
        let secondReset = firstReset.addingTimeInterval(7 * 24 * 60 * 60)
        let shiftedReset = secondReset.addingTimeInterval(7 * 24 * 60 * 60)
        let beforeReset = makePlanSample(
            at: hourStart.addingTimeInterval(25 * 60),
            primary: 40,
            secondary: 77,
            primaryWindowMinutes: 300,
            primaryResetsAt: firstReset,
            secondaryWindowMinutes: 10080,
            secondaryResetsAt: secondReset)
        let afterReset = makePlanSample(
            at: hourStart.addingTimeInterval(35 * 60),
            primary: 41,
            secondary: 3,
            primaryWindowMinutes: 300,
            primaryResetsAt: firstReset,
            secondaryWindowMinutes: 10080,
            secondaryResetsAt: shiftedReset)

        let initial = try #require(
            UsageStore._updatedPlanUtilizationHistoryForTesting(
                provider: .codex,
                existingHistory: [],
                sample: beforeReset))
        let updated = try #require(
            UsageStore._updatedPlanUtilizationHistoryForTesting(
                provider: .codex,
                existingHistory: initial,
                sample: afterReset))

        #expect(updated.count == 2)
        #expect(updated[0] == beforeReset)
        #expect(updated[1] == afterReset)
    }

    @Test
    func sameHourSampleMergesWhenOnlyIncomingResetMetadataIsBackfilled() throws {
        let calendar = Calendar(identifier: .gregorian)
        let hourStart = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 3,
            day: 17,
            hour: 9)))
        let incomingReset = hourStart.addingTimeInterval(30 * 60)
        let existing = makePlanSample(
            at: hourStart.addingTimeInterval(10 * 60),
            primary: 20,
            secondary: 35,
            primaryWindowMinutes: 300,
            secondaryWindowMinutes: 10080)
        let incoming = makePlanSample(
            at: hourStart.addingTimeInterval(45 * 60),
            primary: 30,
            secondary: 40,
            primaryWindowMinutes: 300,
            primaryResetsAt: incomingReset,
            secondaryWindowMinutes: 10080)

        let updated = try #require(
            UsageStore._updatedPlanUtilizationHistoryForTesting(
                provider: .codex,
                existingHistory: [existing],
                sample: incoming))

        #expect(updated.count == 1)
        #expect(updated[0].capturedAt == incoming.capturedAt)
        #expect(updated[0].primaryUsedPercent == 30)
        #expect(updated[0].secondaryUsedPercent == 40)
        #expect(updated[0].primaryResetsAt == incomingReset)
    }

    @MainActor
    @Test
    func lateSameHourBackfillBeforeResetMergesIntoEarlierWindow() throws {
        let calendar = Calendar(identifier: .gregorian)
        let hourStart = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 3,
            day: 17,
            hour: 9)))
        let resetBoundary = hourStart.addingTimeInterval(30 * 60)
        let nextResetBoundary = resetBoundary.addingTimeInterval(5 * 60 * 60)
        let earlierWindow = makePlanSample(
            at: hourStart.addingTimeInterval(25 * 60),
            primary: 82,
            secondary: nil,
            primaryWindowMinutes: 300,
            primaryResetsAt: resetBoundary)
        let laterWindow = makePlanSample(
            at: hourStart.addingTimeInterval(35 * 60),
            primary: 4,
            secondary: nil,
            primaryWindowMinutes: 300,
            primaryResetsAt: nextResetBoundary)
        let lateBackfill = makePlanSample(
            at: hourStart.addingTimeInterval(28 * 60),
            primary: 95,
            secondary: nil,
            primaryWindowMinutes: 300,
            primaryResetsAt: nil)

        let updated = try #require(
            UsageStore._updatedPlanUtilizationHistoryForTesting(
                provider: .codex,
                existingHistory: [earlierWindow, laterWindow],
                sample: lateBackfill))

        #expect(updated.count == 2)
        #expect(updated[0].capturedAt == lateBackfill.capturedAt)
        #expect(updated[0].primaryUsedPercent == 95)
        #expect(updated[0].primaryResetsAt == resetBoundary)
        #expect(updated[1] == laterWindow)
    }

    @Test
    func lateSameHourBackfillAfterResetMergesIntoLaterWindow() throws {
        let calendar = Calendar(identifier: .gregorian)
        let hourStart = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 3,
            day: 17,
            hour: 9)))
        let resetBoundary = hourStart.addingTimeInterval(30 * 60)
        let nextResetBoundary = resetBoundary.addingTimeInterval(5 * 60 * 60)
        let earlierWindow = makePlanSample(
            at: hourStart.addingTimeInterval(25 * 60),
            primary: 82,
            secondary: nil,
            primaryWindowMinutes: 300,
            primaryResetsAt: resetBoundary)
        let laterWindow = makePlanSample(
            at: hourStart.addingTimeInterval(35 * 60),
            primary: 4,
            secondary: nil,
            primaryWindowMinutes: 300,
            primaryResetsAt: nextResetBoundary)
        let lateBackfill = makePlanSample(
            at: hourStart.addingTimeInterval(32 * 60),
            primary: 12,
            secondary: nil,
            primaryWindowMinutes: 300,
            primaryResetsAt: nil)

        let updated = try #require(
            UsageStore._updatedPlanUtilizationHistoryForTesting(
                provider: .codex,
                existingHistory: [earlierWindow, laterWindow],
                sample: lateBackfill))

        #expect(updated.count == 2)
        #expect(updated[0] == earlierWindow)
        #expect(updated[1].capturedAt == lateBackfill.capturedAt)
        #expect(updated[1].primaryUsedPercent == 12)
        #expect(updated[1].primaryResetsAt == nextResetBoundary)
    }

    @Test
    func sameHourBackfillTiePrefersLaterWindow() throws {
        let calendar = Calendar(identifier: .gregorian)
        let hourStart = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 3,
            day: 17,
            hour: 9)))
        let resetBoundary = hourStart.addingTimeInterval(30 * 60)
        let nextResetBoundary = resetBoundary.addingTimeInterval(5 * 60 * 60)
        let earlierWindow = makePlanSample(
            at: hourStart.addingTimeInterval(25 * 60),
            primary: 82,
            secondary: nil,
            primaryWindowMinutes: 300,
            primaryResetsAt: resetBoundary)
        let laterWindow = makePlanSample(
            at: hourStart.addingTimeInterval(35 * 60),
            primary: 4,
            secondary: nil,
            primaryWindowMinutes: 300,
            primaryResetsAt: nextResetBoundary)
        let ambiguousBackfill = makePlanSample(
            at: hourStart.addingTimeInterval(30 * 60),
            primary: 12,
            secondary: nil,
            primaryWindowMinutes: 300,
            primaryResetsAt: nil)

        let updated = try #require(
            UsageStore._updatedPlanUtilizationHistoryForTesting(
                provider: .codex,
                existingHistory: [earlierWindow, laterWindow],
                sample: ambiguousBackfill))

        #expect(updated.count == 2)
        #expect(updated[0] == earlierWindow)
        #expect(updated[1].capturedAt == ambiguousBackfill.capturedAt)
        #expect(updated[1].primaryUsedPercent == 12)
        #expect(updated[1].primaryResetsAt == nextResetBoundary)
    }

    @MainActor
    @Test
    func dailyChartPreservesCompletedWindowAcrossResetWithinSameHour() throws {
        let calendar = Calendar(identifier: .gregorian)
        let firstBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 17,
            hour: 4,
            minute: 30)))
        let secondBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 17,
            hour: 9,
            minute: 30)))
        let thirdBoundary = try #require(calendar.date(from: DateComponents(
            timeZone: TimeZone.current,
            year: 2026,
            month: 3,
            day: 17,
            hour: 14,
            minute: 30)))
        let samples = [
            makePlanSample(
                at: firstBoundary.addingTimeInterval(-20 * 60),
                primary: 20,
                secondary: nil,
                primaryWindowMinutes: 300,
                primaryResetsAt: firstBoundary),
            makePlanSample(
                at: secondBoundary.addingTimeInterval(-5 * 60),
                primary: 82,
                secondary: nil,
                primaryWindowMinutes: 300,
                primaryResetsAt: secondBoundary),
            makePlanSample(
                at: secondBoundary.addingTimeInterval(5 * 60),
                primary: 4,
                secondary: nil,
                primaryWindowMinutes: 300,
                primaryResetsAt: thirdBoundary),
        ]

        var history: [PlanUtilizationHistorySample] = []
        for sample in samples {
            history = try #require(
                UsageStore._updatedPlanUtilizationHistoryForTesting(
                    provider: .codex,
                    existingHistory: history,
                    sample: sample))
        }

        #expect(history.count == 3)

        let model = try #require(
            PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
                periodRawValue: "daily",
                samples: history,
                provider: .codex))

        #expect(model.pointCount == 1)
        #expect(model.selectedSource == "primary:300")
        #expect(model.usedPercents.count == 1)
        #expect(abs(model.usedPercents[0] - ((20.0 + 82.0 + 4.0) * 5.0 / 24.0)) < 0.000_1)
    }
}
