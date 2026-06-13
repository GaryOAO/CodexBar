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
    private let now: () -> Date

    init(store: UsageStore, settings: SettingsStore, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.settings = settings
        self.now = now
    }

    /// Codex provider snapshot mirroring `snapshot()` but for Codex-only
    /// data. Returns a `PetCodexStatus` with `unknownPct` when the user
    /// hasn't authenticated Codex or no data has been fetched yet — that
    /// teaches the pet to render "—" instead of a wrong number.
    func codexSnapshot() -> PetCodexStatus {
        guard let store = self.store else { return PetCodexStatus() }
        let usage = store.snapshot(for: .codex)
        let tokens = store.tokenSnapshot(for: .codex)

        let pct5h = self.optionalPct(usage?.primary?.usedPercent)
        let pctWk = self.optionalPct(usage?.secondary?.usedPercent)
        let reset5h = self.resetMinutes(usage?.primary?.resetsAt)
        let resetWk = self.resetMinutes(usage?.secondary?.resetsAt)

        let today = self.todayTokenCount(tokens)

        return PetCodexStatus(
            usage5hPct: pct5h,
            usageWeekPct: pctWk,
            reset5hMinutes: reset5h,
            resetWeekMinutes: resetWk,
            todayTokens: today,
            epochSeconds: UInt32(self.now().timeIntervalSince1970))
    }

    /// 0..100 clamp that preserves "unknown" as 0xFF when input is nil. Used
    /// by codexSnapshot so the pet can tell "no Codex auth yet" apart from
    /// "Codex is at 0%".
    private func optionalPct(_ value: Double?) -> UInt8 {
        guard let value, value.isFinite else { return PetCodexStatus.unknownPct }
        let clamped = max(0, min(100, Int(value.rounded())))
        return UInt8(clamped)
    }

    func snapshot() -> PetStatus {
        guard let store = self.store else { return PetStatus() }
        let usage = store.snapshot(for: .claude)
        let tokens = store.tokenSnapshot(for: .claude)

        let pct5h = self.pct(usage?.primary?.usedPercent)
        let pctWk = self.pct(usage?.secondary?.usedPercent)
        let reset5h = self.resetMinutes(usage?.primary?.resetsAt)
        let resetWk = self.resetMinutes(usage?.secondary?.resetsAt)

        // Prefer an exact local-day bucket when present. When the scanner has
        // not yet emitted a new local-day row, fall back to the snapshot's
        // current session/latest bucket so Pet matches the rest of CodexBar's
        // local cost UI semantics.
        let today = self.todayTokenCount(tokens)

        var flags: UInt8 = 0
        if pct5h >= 90 { flags |= PetStatus.flagBitFiveHourWarning }
        if pctWk >= 90 { flags |= PetStatus.flagBitWeeklyWarning }
        if pct5h >= 100 || pctWk >= 100 { flags |= PetStatus.flagBitRateLimited }
        if store.isRefreshing || !store.refreshingProviders.isEmpty || store.isTokenRefreshInFlight(for: .claude) {
            flags |= PetStatus.flagBitAnyFetching
        }
        flags |= self.preferenceFlags()

        return PetStatus(
            providerIdx: PetProvider.claude.rawValue,
            usage5hPct: pct5h,
            usageWeekPct: pctWk,
            mode: 0,
            flags: flags,
            presentation: self.presentationByte(),
            reset5hMinutes: reset5h,
            resetWeekMinutes: resetWk,
            todayTokens: today,
            epochSeconds: UInt32(self.now().timeIntervalSince1970))
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
               hour: Calendar.current.component(.hour, from: self.now()),
               start: settings.petQuietHoursStart,
               end: settings.petQuietHoursEnd)
        {
            bits |= PetStatus.flagBitQuietHoursActive
        }
        return bits
    }

    private func todayTokenCount(_ tokens: CostUsageTokenSnapshot?) -> UInt32 {
        guard let tokens else { return 0 }
        if !tokens.daily.isEmpty {
            let localToday = Self.sumTokensForToday(tokens.daily, now: self.now())
            if localToday > 0 {
                return UInt32(clamping: localToday)
            }
        }
        return UInt32(clamping: max(tokens.sessionTokens ?? 0, 0))
    }

    /// Byte 5 stays inside the existing 18-byte payload. Current firmware
    /// ignores unknown presentation bits, while newer firmware can decode
    /// usage-display and personality without a wire-size bump.
    private func presentationByte() -> UInt8 {
        guard let settings = self.settings else { return 0 }
        return settings.petUsageDisplay.wireValue | (settings.petPersonality.wireValue << 4)
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
        let minutes = Int(date.timeIntervalSince(self.now()) / 60)
        if minutes <= 0 { return 0 }
        return UInt16(min(minutes, 0xFFFE))
    }

    /// Sum totalTokens across any daily entries whose `date` matches today
    /// in local time. CostUsageFetcher stores dates as strings — different
    /// providers use different formats ("2026-05-16", "2026-05-16T00:00:00Z",
    /// etc.) — so we match by string prefix on the YYYY-MM-DD portion.
    static func sumTokensForToday(_ buckets: [CostUsageDailyReport.Entry], now: Date = Date()) -> Int {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        let today = formatter.string(from: now)
        return buckets
            .filter { Self.dayKey($0.date, formatter: formatter) == today }
            .compactMap(\.totalTokens)
            .reduce(0, +)
    }

    private static func dayKey(_ text: String, formatter: DateFormatter) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 10 {
            let prefix = String(trimmed.prefix(10))
            if prefix.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
                return prefix
            }
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: trimmed) {
            return formatter.string(from: date)
        }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: trimmed) {
            return formatter.string(from: date)
        }
        return formatter.date(from: trimmed).map { formatter.string(from: $0) }
    }
}
#endif
