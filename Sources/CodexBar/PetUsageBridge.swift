#if os(macOS)
import CodexBarCore
import Foundation

/// Reads current Claude usage state from `UsageStore` and assembles a
/// `PetStatus` snapshot the BLE central can push to the pet.
///
/// Mode is intentionally NOT filled in here — it comes from the hook event
/// stream and is overlaid on top of this snapshot. The bridge fills in the
/// "slow" numeric fields (5h%, week%, today tokens, reset times, epoch).
@MainActor
final class PetUsageBridge {
    private weak var store: UsageStore?

    init(store: UsageStore) {
        self.store = store
    }

    func snapshot() -> PetStatus {
        guard let store = self.store else { return PetStatus() }
        let usage = store.snapshot(for: .claude)
        let tokens = store.tokenSnapshot(for: .claude)

        let pct5h = self.pct(usage?.primary?.usedPercent)
        let pctWk = self.pct(usage?.secondary?.usedPercent)
        let reset5h = self.resetMinutes(usage?.primary?.resetsAt)
        let resetWk = self.resetMinutes(usage?.secondary?.resetsAt)

        // Empirically, `sessionTokens` is a current-Claude-session figure
        // that can be much larger than a calendar-day count (long sessions
        // span days; cache reads inflate the number). For the pet's "TODAY"
        // dashboard we want the per-calendar-day bucket. Prefer the dated
        // bucket and only fall back to sessionTokens if no daily breakdown
        // is available yet. Also cap at 9.9M so the display formatter has a
        // chance of staying inside its 7-char ESP32 cell.
        var todayRaw = 0
        if let buckets = tokens?.daily,
           let todayBucket = Self.todayBucket(buckets),
           let total = todayBucket.totalTokens
        {
            todayRaw = total
        } else if let sess = tokens?.sessionTokens, sess > 0 {
            todayRaw = sess
        }
        let todayCapped = min(max(todayRaw, 0), 9_999_999)
        let today = UInt32(todayCapped)

        var flags: UInt8 = 0
        if pct5h >= 90 { flags |= 0x01 }
        if pctWk >= 90 { flags |= 0x02 }

        return PetStatus(
            providerIdx: PetProvider.claude.rawValue,
            usage5hPct: pct5h,
            usageWeekPct: pctWk,
            mode: 0,
            flags: flags,
            reset5hMinutes: reset5h,
            resetWeekMinutes: resetWk,
            todayTokens: today,
            epochSeconds: UInt32(Date().timeIntervalSince1970))
    }

    private func pct(_ value: Double?) -> UInt8 {
        guard let value, value.isFinite else { return 0 }
        let clamped = max(0, min(100, Int(value.rounded())))
        return UInt8(clamped)
    }

    private func resetMinutes(_ resetsAt: Date?) -> UInt16 {
        guard let date = resetsAt else { return PetStatus.unknownReset }
        let minutes = Int(date.timeIntervalSinceNow / 60)
        if minutes <= 0 { return 0 }
        return UInt16(min(minutes, 0xFFFE))
    }

    private static func todayBucket(_ buckets: [CostUsageDailyReport.Entry]) -> CostUsageDailyReport.Entry? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let todayString = formatter.string(from: Date())
        return buckets.first(where: { $0.date.hasPrefix(todayString) })
    }
}
#endif
