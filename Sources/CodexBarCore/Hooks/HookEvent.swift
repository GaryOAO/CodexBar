import Foundation

/// One Claude-style lifecycle hook event delivered from a CLI (Claude Code or
/// Codex CLI) to CodexBar via the local Unix socket.
///
/// The shim script that forwards the CLI's stdin to our socket may add the
/// `petbar_source` field so we know which CLI sent it. Other fields mirror the
/// CLI hook payload — we only model the keys we currently react to and stash
/// the raw JSON for anything else.
public struct HookEvent: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case sessionStart = "SessionStart"
        case userPromptSubmit = "UserPromptSubmit"
        case preToolUse = "PreToolUse"
        case postToolUse = "PostToolUse"
        case permissionRequest = "PermissionRequest"
        case stop = "Stop"
        case preCompact = "PreCompact"
        case notification = "Notification"
        case unknown = ""
    }

    public enum Source: String, Sendable {
        case claudeCode
        case codexCli
        case unknown
    }

    public let kind: Kind
    public let source: Source
    public let toolName: String?
    public let sessionId: String?
    public let receivedAt: Date
    /// Raw JSON object as decoded — useful for any consumers that want fields
    /// we haven't promoted to typed properties yet (e.g. `permission_mode`).
    public let raw: [String: String]

    public init(
        kind: Kind,
        source: Source,
        toolName: String? = nil,
        sessionId: String? = nil,
        receivedAt: Date = Date(),
        raw: [String: String] = [:])
    {
        self.kind = kind
        self.source = source
        self.toolName = toolName
        self.sessionId = sessionId
        self.receivedAt = receivedAt
        self.raw = raw
    }

    /// Parse one line of NDJSON. Returns nil for empty input or unparseable
    /// JSON; an `unknown` kind is preserved (caller may still want to log it)
    /// so a future Claude/Codex hook event name doesn't get silently dropped.
    public static func decode(jsonLine line: String) -> HookEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8) else { return nil }
        guard let any = try? JSONSerialization.jsonObject(with: data) else { return nil }
        guard let obj = any as? [String: Any] else { return nil }

        let kindRaw = (obj["hook_event_name"] as? String) ?? (obj["event"] as? String) ?? ""
        let kind = Kind(rawValue: kindRaw) ?? .unknown

        let sourceRaw = (obj["petbar_source"] as? String) ?? ""
        let source: Source = switch sourceRaw {
        case "claude-code", "claudeCode": .claudeCode
        case "codex-cli", "codexCli": .codexCli
        default: .unknown
        }

        // Tool name lives under different keys depending on hook event kind.
        // PreToolUse/PostToolUse: tool_name at top level (Claude) or
        // tool_input.tool_name (older Codex builds). Try both.
        let toolName = (obj["tool_name"] as? String)
            ?? ((obj["tool_input"] as? [String: Any])?["tool_name"] as? String)

        let sessionId = (obj["session_id"] as? String) ?? (obj["sessionId"] as? String)

        // Flatten the top-level scalars into raw[] for downstream debug logging.
        var raw: [String: String] = [:]
        for (k, v) in obj {
            if let s = v as? String {
                raw[k] = s
            } else if let b = v as? Bool {
                raw[k] = b ? "true" : "false"
            } else if let n = v as? NSNumber {
                raw[k] = n.stringValue
            }
        }

        return HookEvent(
            kind: kind,
            source: source,
            toolName: toolName,
            sessionId: sessionId,
            raw: raw)
    }
}
