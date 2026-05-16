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
    private weak var settings: SettingsStore?

    init(store: UsageStore, settings: SettingsStore) {
        self.store = store
        self.settings = settings
    }

    func snapshot() -> PetStatus {
        guard let store = self.store else { return PetStatus() }
        let usage = store.snapshot(for: .claude)
        let tokens = store.tokenSnapshot(for: .claude)

        let pct5h = self.pct(usage?.primary?.usedPercent)
        let pctWk = self.pct(usage?.secondary?.usedPercent)
        let reset5h = self.resetMinutes(usage?.primary?.resetsAt)
        let resetWk = self.resetMinutes(usage?.secondary?.resetsAt)

        // Today's tokens. CostUsageFetcher.sessionTokens is sourced from
        // `currentDay?.totalTokens` (the most recent daily bucket) and
        // already includes cache reads — that's what shows up in CodexBar's
        // own UI and what the user sees as "today". Use it as the primary
        // source and only re-derive from the daily array if it's missing.
        // The ESP32 formatter picks K / M / B so 1B+ days render cleanly.
        var todayRaw = 0
        if let sess = tokens?.sessionTokens, sess > 0 {
            todayRaw = sess
        } else if let buckets = tokens?.daily {
            todayRaw = Self.sumTokensForToday(buckets)
        }
        let today = UInt32(clamping: todayRaw)

        var flags: UInt8 = 0
        if pct5h >= 90 { flags |= 0x01 }
        if pctWk >= 90 { flags |= 0x02 }
        flags |= self.preferenceFlags()

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

    /// Translate the user's preference toggles into PetStatus flag bits so
    /// the firmware can suppress overlays without us re-pushing on every
    /// settings change. Flags 4..7 carry the toggles defined in
    /// PetStatus.flagBit*; bit7 also gates on the current local-hour falling
    /// inside the quiet-hours window.
    private func preferenceFlags() -> UInt8 {
        guard let settings = self.settings else { return 0 }
        var bits: UInt8 = 0
        if !settings.petQuipsEnabled { bits |= PetStatus.flagBitQuipsDisabled }
        if !settings.petMicroActionsEnabled { bits |= PetStatus.flagBitMicroActionsDisabled }
        if !settings.petMilestoneCelebrationsEnabled { bits |= PetStatus.flagBitMilestonesDisabled }
        if settings.petQuietHoursEnabled,
           Self.isHourInQuietWindow(
               hour: Calendar.current.component(.hour, from: Date()),
               start: settings.petQuietHoursStart,
               end: settings.petQuietHoursEnd)
        {
            bits |= PetStatus.flagBitQuietHoursActive
        }
        return bits
    }

    /// Quiet-hours window is `[start, end)` in local time. When `end < start`
    /// the window wraps midnight (e.g. 22..7 covers 22, 23, 0..6). When
    /// `start == end` the window is treated as empty.
    static func isHourInQuietWindow(hour: Int, start: Int, end: Int) -> Bool {
        let h = max(0, min(23, hour))
        let s = max(0, min(23, start))
        let e = max(0, min(23, end))
        if s == e { return false }
        if s < e { return h >= s && h < e }
        return h >= s || h < e
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

    /// Sum totalTokens across any daily entries whose `date` matches today
    /// in local time. CostUsageFetcher stores dates as strings — different
    /// providers use different formats ("2026-05-16", "2026-05-16T00:00:00Z",
    /// etc.) — so we match by string prefix on the YYYY-MM-DD portion.
    private static func sumTokensForToday(_ buckets: [CostUsageDailyReport.Entry]) -> Int {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        let today = formatter.string(from: Date())
        return buckets
            .filter { $0.date.hasPrefix(today) }
            .compactMap(\.totalTokens)
            .reduce(0, +)
    }
}
#endif
