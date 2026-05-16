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
///                                  bit2: rate_limited, bit3: any_fetching
///   [5]  uint8  reserved0          0
///   [6:8]  uint16 reset_5h_minutes    0xFFFF = unknown
///   [8:10] uint16 reset_week_minutes  0xFFFF = unknown
///   [10:14] uint32 today_tokens     Claude tokens spent today
///   [14:18] uint32 epoch_seconds    current unix time
public struct PetStatus: Sendable, Equatable {
    public static let unknownReset: UInt16 = 0xFFFF
    public static let wireSize = 18

    public var providerIdx: UInt8
    public var usage5hPct: UInt8
    public var usageWeekPct: UInt8
    public var mode: UInt8
    public var flags: UInt8
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
        data.append(0) // reserved0
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
public enum PetMode: UInt8, Sendable {
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
        case .sessionStart: .greeting
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
public enum PetProvider: UInt8, Sendable {
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
