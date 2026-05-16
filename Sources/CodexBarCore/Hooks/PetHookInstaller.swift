import Foundation
import Logging

/// Inject / remove petbar-hook entries in the two CLI config files we care
/// about: Claude Code's ~/.claude/settings.json and Codex CLI's
/// ~/.codex/config.toml. Idempotent: re-running install does not duplicate
/// existing entries; uninstall removes only our entries and leaves the user's
/// hand-written hooks alone.
///
/// We tag every hook block we write with a fixed marker
/// (`"petbar_owner": "codexbar"` for JSON, `# petbar:codexbar` line for TOML)
/// so uninstall can find and remove them without parsing the schema fully.
public enum PetHookInstaller {
    public static let claudeSettingsRelativePath = ".claude/settings.json"
    public static let codexConfigRelativePath = ".codex/config.toml"

    /// CLI hook events we register for. Keep this short — every event
    /// fires petbar-hook as a subprocess, so registering everything is
    /// pointless when we only react to a handful of kinds today.
    public static let registeredEvents: [String] = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "Stop",
    ]

    public static let ownerMarker = "codexbar"

    public struct Report: Sendable, Equatable {
        public var claudeUpdated: Bool
        public var codexUpdated: Bool
        public var notes: [String]
    }

    public static func install() throws -> Report {
        let log = CodexBarLog.logger("hooks.installer")
        try PetHookShim.ensureInstalled()
        let shim = PetHookShim.installedShimPath

        var notes: [String] = []
        let claude = try self.installClaude(shimPath: shim)
        if claude.changed {
            notes.append("Updated \(claude.path)")
        } else {
            notes.append("Claude hooks already current")
        }
        let codex = try self.installCodex(shimPath: shim)
        if codex.changed {
            notes.append("Updated \(codex.path)")
        } else {
            notes.append("Codex hooks already current")
        }
        log.info(
            "hook install complete",
            metadata: [
                "claude": claude.changed ? "updated" : "current",
                "codex": codex.changed ? "updated" : "current",
            ])
        return Report(claudeUpdated: claude.changed, codexUpdated: codex.changed, notes: notes)
    }

    public static func uninstall() throws -> Report {
        let log = CodexBarLog.logger("hooks.installer")
        var notes: [String] = []
        let claude = try self.uninstallClaude()
        if claude.changed {
            notes.append("Removed from \(claude.path)")
        } else {
            notes.append("No petbar hooks present in Claude settings")
        }
        let codex = try self.uninstallCodex()
        if codex.changed {
            notes.append("Removed from \(codex.path)")
        } else {
            notes.append("No petbar hooks present in Codex config")
        }
        log.info(
            "hook uninstall complete",
            metadata: [
                "claude": claude.changed ? "removed" : "absent",
                "codex": codex.changed ? "removed" : "absent",
            ])
        return Report(claudeUpdated: claude.changed, codexUpdated: codex.changed, notes: notes)
    }

    // MARK: - Claude Code (JSON)

    private static func claudePath() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(self.claudeSettingsRelativePath)
    }

    private static func installClaude(shimPath: String) throws -> (path: String, changed: Bool) {
        let path = self.claudePath()
        let url = URL(fileURLWithPath: path)
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        var root: [String: Any] = if let data = try? Data(contentsOf: url),
                                     let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            parsed
        } else {
            [:]
        }

        let desired = self.buildClaudeHooksObject(shimPath: shimPath)
        let existing = root["hooks"] as? [String: Any]
        if let existing, self.dictionariesEqualByJSON(existing, desired) {
            return (path, false)
        }

        // Preserve user's other hook entries by merging per-event arrays.
        var merged: [String: Any] = existing ?? [:]
        for (event, ourEntries) in desired {
            guard let ourEntriesArr = ourEntries as? [[String: Any]] else { continue }
            var theirs = (merged[event] as? [[String: Any]]) ?? []
            // Drop any previously installed petbar entries before re-adding.
            theirs.removeAll { entry in
                Self.entryIsOurs(entry)
            }
            theirs.append(contentsOf: ourEntriesArr)
            merged[event] = theirs
        }
        root["hooks"] = merged

        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        return (path, true)
    }

    private static func uninstallClaude() throws -> (path: String, changed: Bool) {
        let path = self.claudePath()
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return (path, false)
        }
        guard var hooks = root["hooks"] as? [String: Any] else { return (path, false) }

        var changed = false
        for (event, value) in hooks {
            guard var entries = value as? [[String: Any]] else { continue }
            let before = entries.count
            entries.removeAll { entry in Self.entryIsOurs(entry) }
            if entries.count != before {
                changed = true
                if entries.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = entries
                }
            }
        }
        if !changed { return (path, false) }

        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }

        let out = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys])
        try out.write(to: url, options: .atomic)
        return (path, true)
    }

    private static func buildClaudeHooksObject(shimPath: String) -> [String: Any] {
        var result: [String: Any] = [:]
        for event in self.registeredEvents {
            let block: [String: Any] = [
                "petbar_owner": self.ownerMarker,
                "matcher": "*",
                "hooks": [[
                    "type": "command",
                    "command": "\(shimPath) claude-code",
                    "timeout": 5,
                ]],
            ]
            result[event] = [block]
        }
        return result
    }

    private static func entryIsOurs(_ entry: [String: Any]) -> Bool {
        if (entry["petbar_owner"] as? String) == self.ownerMarker { return true }
        // Older installs may not have the marker — fall back to detecting our
        // shim path inside the command list. Keeps uninstall safe across
        // CodexBar versions.
        if let hooks = entry["hooks"] as? [[String: Any]] {
            for h in hooks {
                if let cmd = h["command"] as? String,
                   cmd.contains("/.codexbar/bin/\(PetHookShim.shimName)")
                {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Codex CLI (TOML — managed as a delimited block)

    private static let codexBegin = "# >>> petbar:codexbar (managed by CodexBar — do not edit between markers)"
    private static let codexEnd = "# <<< petbar:codexbar"

    private static func codexPath() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(self.codexConfigRelativePath)
    }

    private static func installCodex(shimPath: String) throws -> (path: String, changed: Bool) {
        let path = self.codexPath()
        let url = URL(fileURLWithPath: path)
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        var existing = (try? String(contentsOf: url)) ?? ""
        let desired = self.buildCodexBlock(shimPath: shimPath)

        // Replace any existing managed block; otherwise append at end.
        let stripped = self.stripCodexBlock(existing)
        let needsTrailingNewline = !stripped.isEmpty && !stripped.hasSuffix("\n")
        let separator = stripped.isEmpty ? "" : (needsTrailingNewline ? "\n\n" : "\n")
        let newContent = stripped + separator + desired + "\n"

        if newContent == existing {
            return (path, false)
        }
        try newContent.write(to: url, atomically: true, encoding: .utf8)
        existing = newContent
        return (path, true)
    }

    private static func uninstallCodex() throws -> (path: String, changed: Bool) {
        let path = self.codexPath()
        let url = URL(fileURLWithPath: path)
        guard let existing = try? String(contentsOf: url) else { return (path, false) }
        let stripped = self.stripCodexBlock(existing)
        if stripped == existing { return (path, false) }
        try stripped.write(to: url, atomically: true, encoding: .utf8)
        return (path, true)
    }

    private static func stripCodexBlock(_ source: String) -> String {
        guard let beginRange = source.range(of: self.codexBegin) else { return source }
        guard let endRange = source.range(of: self.codexEnd, range: beginRange.upperBound..<source.endIndex)
        else { return source }
        // Also swallow the trailing newline after the end marker, if present,
        // so we don't leave a stray blank line each uninstall cycle.
        var endIndex = endRange.upperBound
        if endIndex < source.endIndex, source[endIndex] == "\n" {
            endIndex = source.index(after: endIndex)
        }
        return String(source[source.startIndex..<beginRange.lowerBound] + source[endIndex..<source.endIndex])
    }

    private static func buildCodexBlock(shimPath: String) -> String {
        var lines: [String] = [self.codexBegin]
        for event in self.registeredEvents {
            lines.append("[[hooks.\(event)]]")
            lines.append("matcher = \"*\"")
            lines.append("")
            lines.append("[[hooks.\(event).hooks]]")
            lines.append("type = \"command\"")
            lines.append("command = \"\(shimPath) codex-cli\"")
            lines.append("timeout = 5")
            lines.append("")
        }
        lines.append(self.codexEnd)
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func dictionariesEqualByJSON(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        guard
            let lhs = try? JSONSerialization.data(withJSONObject: a, options: [.sortedKeys]),
            let rhs = try? JSONSerialization.data(withJSONObject: b, options: [.sortedKeys])
        else {
            return false
        }
        return lhs == rhs
    }
}
