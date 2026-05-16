import Foundation

/// 8-byte payload sent to the pet over BLE. Binary layout matches the
/// ESP32 firmware's `cbar_status_t` exactly so we can serialise by raw
/// memcpy:
///
///   uint8_t provider_idx   // 0=none, 1=claude, 2=codex, 3=cursor, ...
///   uint8_t usage_pct      // 0..100 of the active provider
///   uint8_t mode           // PetMode value (see PetMode below)
///   uint8_t flags          // bit0: usage>=90%, bit1: rate_limited,
///                          // bit2: any_provider_fetching
///   uint32_t req_counter   // monotonic counter incremented on each
///                          // CLI hook event
///
/// Both sides are arm64 / xtensa little-endian, so the natural Swift
/// struct layout (no padding before req_counter because the four UInt8
/// fields exactly fill the alignment slot) matches packed C.
public struct PetStatus: Sendable, Equatable {
    public var providerIdx: UInt8
    public var usagePct: UInt8
    public var mode: UInt8
    public var flags: UInt8
    public var reqCounter: UInt32

    public init(
        providerIdx: UInt8 = 0,
        usagePct: UInt8 = 0,
        mode: UInt8 = 0,
        flags: UInt8 = 0,
        reqCounter: UInt32 = 0)
    {
        self.providerIdx = providerIdx
        self.usagePct = usagePct
        self.mode = mode
        self.flags = flags
        self.reqCounter = reqCounter
    }

    /// Wire-encode to exactly 8 little-endian bytes.
    public func encoded() -> Data {
        var data = Data(capacity: 8)
        data.append(self.providerIdx)
        data.append(self.usagePct)
        data.append(self.mode)
        data.append(self.flags)
        var ctrLE = self.reqCounter.littleEndian
        withUnsafeBytes(of: &ctrLE) { data.append(contentsOf: $0) }
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
