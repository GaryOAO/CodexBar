import Foundation

/// 18-byte payload sent to the pet over BLE. Binary layout matches the
/// ESP32 firmware's `cbar_status_t` exactly so we can serialise by writing
/// the fields in declaration order:
///
///   [0]  uint8  provider_idx       0=none, 1=claude, 2=codex, ...
///   [1]  uint8  usage_5h_pct       0..100, Claude 5-hour block
///   [2]  uint8  usage_week_pct     0..100, Claude weekly
///   [3]  uint8  mode               PetMode enum
///   [4]  uint8  flags              bit0: 5h>=90%, bit1: week>=90%,
///                                  bit2: rate_limited, bit3: any_fetching,
///                                  bit4: quips_disabled (preferences),
///                                  bit5: micro_actions_disabled (preferences),
///                                  bit6: milestones_disabled (preferences),
///                                  bit7: quiet_hours_active (preferences)
///   [5]  uint8  presentation        low nibble: usage display,
///                                  high nibble: personality preset
///   [6:8]  uint16 reset_5h_minutes    0xFFFF = unknown
///   [8:10] uint16 reset_week_minutes  0xFFFF = unknown
///   [10:14] uint32 today_tokens     Claude tokens spent today
///   [14:18] uint32 epoch_seconds    current unix time
public struct PetStatus: Sendable, Equatable, Codable {
    public static let unknownReset: UInt16 = 0xFFFF
    public static let wireSize = 18

    /// Flag bit (0x01) — 5-hour quota is at/above the warning threshold.
    public static let flagBitFiveHourWarning: UInt8 = 0x01
    /// Flag bit (0x02) — weekly quota is at/above the warning threshold.
    public static let flagBitWeeklyWarning: UInt8 = 0x02
    /// Flag bit (0x04) — the visible Claude window is effectively exhausted.
    public static let flagBitRateLimited: UInt8 = 0x04
    /// Flag bit (0x08) — CodexBar is currently refreshing provider/token state.
    public static let flagBitAnyFetching: UInt8 = 0x08
    /// Flag bit (0x10) — pet should silence text quips. Driven by the
    /// "Random one-liner quips" preference toggle in the desktop app.
    public static let flagBitQuipsDisabled: UInt8 = 0x10
    /// Flag bit (0x20) — pet should skip blink/micro-action overlays.
    public static let flagBitMicroActionsDisabled: UInt8 = 0x20
    /// Flag bit (0x40) — pet should skip token-milestone celebration overlays.
    public static let flagBitMilestonesDisabled: UInt8 = 0x40
    /// Flag bit (0x80) — pet should dim or sleep regardless of activity
    /// because the desktop app is currently inside the user's quiet hours.
    public static let flagBitQuietHoursActive: UInt8 = 0x80

    public var providerIdx: UInt8
    public var usage5hPct: UInt8
    public var usageWeekPct: UInt8
    public var mode: UInt8
    public var flags: UInt8
    public var presentation: UInt8
    public var reset5hMinutes: UInt16
    public var resetWeekMinutes: UInt16
    public var todayTokens: UInt32
    public var epochSeconds: UInt32

    public init(
        providerIdx: UInt8 = 0,
        usage5hPct: UInt8 = 0,
        usageWeekPct: UInt8 = 0,
        mode: UInt8 = 0,
        flags: UInt8 = 0,
        presentation: UInt8 = 0,
        reset5hMinutes: UInt16 = PetStatus.unknownReset,
        resetWeekMinutes: UInt16 = PetStatus.unknownReset,
        todayTokens: UInt32 = 0,
        epochSeconds: UInt32 = 0)
    {
        self.providerIdx = providerIdx
        self.usage5hPct = usage5hPct
        self.usageWeekPct = usageWeekPct
        self.mode = mode
        self.flags = flags
        self.presentation = presentation
        self.reset5hMinutes = reset5hMinutes
        self.resetWeekMinutes = resetWeekMinutes
        self.todayTokens = todayTokens
        self.epochSeconds = epochSeconds
    }

    /// Wire-encode to exactly 18 little-endian bytes matching the C layout.
    public func encoded() -> Data {
        var data = Data(capacity: Self.wireSize)
        data.append(self.providerIdx)
        data.append(self.usage5hPct)
        data.append(self.usageWeekPct)
        data.append(self.mode)
        data.append(self.flags)
        data.append(self.presentation)
        var r5 = self.reset5hMinutes.littleEndian
        withUnsafeBytes(of: &r5) { data.append(contentsOf: $0) }
        var rw = self.resetWeekMinutes.littleEndian
        withUnsafeBytes(of: &rw) { data.append(contentsOf: $0) }
        var tt = self.todayTokens.littleEndian
        withUnsafeBytes(of: &tt) { data.append(contentsOf: $0) }
        var es = self.epochSeconds.littleEndian
        withUnsafeBytes(of: &es) { data.append(contentsOf: $0) }
        return data
    }
}

/// Pet mode enum mirroring user_app's PetMode. The numeric values must stay
/// in sync with the C++ enum; if either side reorders, the pet renders the
/// wrong animation.
public enum PetMode: UInt8, Sendable, Codable {
    case greeting = 0
    case idle = 1
    case thinking = 2
    case working = 3
    case outputting = 4
    case debugging = 5
    case wizard = 6
    case carrying = 7
    case conducting = 8
    case juggling = 9
    case sweeping = 10
    case ultraThink = 11
    case overheated = 12
    case reviewing = 13
    case notification = 14
    case error = 15
    case disconnected = 16
    case celebrating = 17
    case resting = 18

    /// Map a Claude / Codex CLI hook event to the closest pet mode. The
    /// mapping mirrors clawd-tank's tool-aware moods so it reads naturally
    /// on the pet (Read/Grep → Debugger, Edit/Write → Typing, etc.).
    public static func from(hookEvent: HookEvent) -> PetMode {
        switch hookEvent.kind {
        // The firmware owns the "first connected" greeting. Treat CLI
        // session starts as standby so reconnects / new shell sessions do not
        // make the pet bounce between HELLO and idle/resting.
        case .sessionStart: .idle
        case .stop: .idle
        case .userPromptSubmit: .thinking
        case .permissionRequest: .notification
        case .preCompact: .sweeping
        case .notification: .notification
        case .preToolUse, .postToolUse:
            self.fromTool(hookEvent.toolName)
        case .unknown: .idle
        }
    }

    private static func fromTool(_ tool: String?) -> PetMode {
        guard let tool, !tool.isEmpty else { return .idle }
        switch tool {
        case "Read", "Grep", "Glob", "LS": return .debugging
        case "Edit", "Write", "MultiEdit": return .working
        case "Bash", "BashOutput", "KillShell": return .working
        case "WebSearch", "WebFetch": return .wizard
        case "Task", "Agent": return .conducting
        case "TodoWrite": return .reviewing
        default: return .working
        }
    }
}

/// Provider enum mirroring the order seen in CodexBar's UsageProvider /
/// orderedProviders(). Values here are stable wire identifiers used in
/// PetStatus.providerIdx — extending requires bumping nothing because the
/// pet only displays names from a small fixed catalogue today.
public enum PetProvider: UInt8, Sendable, Codable {
    case none = 0
    case claude = 1
    case codex = 2
    case cursor = 3
    case copilot = 4
    case gemini = 5
    case openai = 6
    case opencode = 7
    case other = 255
}

/// Codex-side companion to `PetStatus`. Same 18-byte wire shape so encode
/// path is shared, but cached in a separate slot on the pet so OVERVIEW /
/// METRICS / LIVING can show Claude and Codex side-by-side. Setting
/// `usage5hPct = 0xFF` (or `usageWeekPct = 0xFF`) means "no data yet" and
/// the pet renders a dash for that cell.
public struct PetCodexStatus: Sendable, Equatable, Codable {
    public static let unknownPct: UInt8 = 0xFF
    public static let wireSize = PetStatus.wireSize

    public var usage5hPct: UInt8
    public var usageWeekPct: UInt8
    public var reset5hMinutes: UInt16
    public var resetWeekMinutes: UInt16
    public var todayTokens: UInt32
    public var epochSeconds: UInt32

    public init(
        usage5hPct: UInt8 = PetCodexStatus.unknownPct,
        usageWeekPct: UInt8 = PetCodexStatus.unknownPct,
        reset5hMinutes: UInt16 = PetStatus.unknownReset,
        resetWeekMinutes: UInt16 = PetStatus.unknownReset,
        todayTokens: UInt32 = 0,
        epochSeconds: UInt32 = 0)
    {
        self.usage5hPct = usage5hPct
        self.usageWeekPct = usageWeekPct
        self.reset5hMinutes = reset5hMinutes
        self.resetWeekMinutes = resetWeekMinutes
        self.todayTokens = todayTokens
        self.epochSeconds = epochSeconds
    }

    /// Encode to the same 18-byte layout as PetStatus. Fields that don't
    /// apply to a "codex-only" struct (providerIdx, mode, flags,
    /// presentation) are zeroed — firmware ignores them on this char.
    public func encoded() -> Data {
        var data = Data(capacity: Self.wireSize)
        data.append(PetProvider.codex.rawValue)
        data.append(self.usage5hPct)
        data.append(self.usageWeekPct)
        data.append(0) // mode (unused here)
        data.append(0) // flags (unused here)
        data.append(0) // presentation (unused here)
        var r5 = self.reset5hMinutes.littleEndian
        withUnsafeBytes(of: &r5) { data.append(contentsOf: $0) }
        var rw = self.resetWeekMinutes.littleEndian
        withUnsafeBytes(of: &rw) { data.append(contentsOf: $0) }
        var tt = self.todayTokens.littleEndian
        withUnsafeBytes(of: &tt) { data.append(contentsOf: $0) }
        var es = self.epochSeconds.littleEndian
        withUnsafeBytes(of: &es) { data.append(contentsOf: $0) }
        return data
    }
}

/// Display config — small persistable block CodexBar writes to the pet so
/// the user can pick locale + default layout (and later, more) without re-
/// flashing firmware. The pet stores it in NVS, so it survives reboots.
public struct PetDisplayConfig: Sendable, Equatable, Codable {
    public static let wireSize = 16
    public static let schemaVersion: UInt8 = 1

    public enum Locale: UInt8, Sendable, Codable, CaseIterable {
        case english = 0
        case chinese = 1
        case symbol = 2

        public var displayName: String {
            switch self {
            case .english: "English"
            case .chinese: "中文 (拼音)"
            case .symbol: "Symbols"
            }
        }
    }

    public enum Layout: UInt8, Sendable, Codable, CaseIterable {
        case overview = 0
        case focus = 1
        case metrics = 2
        case living = 3

        public var displayName: String {
            switch self {
            case .overview: "Overview"
            case .focus: "Focus"
            case .metrics: "Metrics"
            case .living: "Living"
            }
        }
    }

    public static let flagHideCodex: UInt8 = 0x01
    public static let flagCompact: UInt8 = 0x02

    public var version: UInt8
    public var locale: Locale
    public var defaultLayout: Layout
    public var hideCodex: Bool
    public var compactMode: Bool

    public init(
        version: UInt8 = PetDisplayConfig.schemaVersion,
        locale: Locale = .english,
        defaultLayout: Layout = .overview,
        hideCodex: Bool = false,
        compactMode: Bool = false)
    {
        self.version = version
        self.locale = locale
        self.defaultLayout = defaultLayout
        self.hideCodex = hideCodex
        self.compactMode = compactMode
    }

    public func encoded() -> Data {
        var data = Data(repeating: 0, count: Self.wireSize)
        data[0] = self.version
        data[1] = self.locale.rawValue
        data[2] = self.defaultLayout.rawValue
        var flags: UInt8 = 0
        if self.hideCodex { flags |= Self.flagHideCodex }
        if self.compactMode { flags |= Self.flagCompact }
        data[3] = flags
        return data
    }

    public static func decode(_ data: Data) -> PetDisplayConfig? {
        guard data.count == self.wireSize else { return nil }
        let bytes = [UInt8](data)
        let version = bytes[0]
        guard version > 0, version <= Self.schemaVersion else { return nil }
        let locale = Locale(rawValue: bytes[1]) ?? .english
        let layout = Layout(rawValue: bytes[2]) ?? .overview
        let flags = bytes[3]
        return PetDisplayConfig(
            version: version,
            locale: locale,
            defaultLayout: layout,
            hideCodex: (flags & Self.flagHideCodex) != 0,
            compactMode: (flags & Self.flagCompact) != 0)
    }
}
