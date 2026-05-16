import Darwin
import Foundation
import Logging

/// Manages the petbar-hook shim script that CLI hooks invoke as their
/// "command". The shim is short enough to keep inline here as a Swift string
/// constant so it doesn't have to be a Resource bundle file — and the
/// installer just writes it under ~/.codexbar/bin/ on first launch.
///
/// Why a Python shim instead of letting the CLI call CodexBar directly:
/// hooks run as subprocesses with stdin=event-JSON and need to exit quickly.
/// A 10-line python script that opens a Unix socket is the simplest possible
/// trampoline that works on every macOS dev machine without extra installs.
public enum PetHookShim {
    public static let binDirRelativePath = ".codexbar/bin"
    public static let shimName = "petbar-hook"

    /// Stored under ~/.codexbar/bin/petbar-hook, idempotent overwrite.
    public static var installedShimPath: String {
        let home = NSHomeDirectory()
        let dir = (home as NSString).appendingPathComponent(self.binDirRelativePath)
        return (dir as NSString).appendingPathComponent(self.shimName)
    }

    /// Source contents of the shim. Python 3 ships with macOS Command Line
    /// Tools (which any CLI user already has). Single positional arg names
    /// the source CLI; the body forwards stdin JSON with that source key
    /// added, to ~/.codexbar/hook.sock.
    public static let shimSource = """
    #!/usr/bin/env python3
    \"\"\"petbar-hook — forward a Claude Code / Codex CLI hook event to CodexBar.
    Installed by CodexBar at ~/.codexbar/bin/petbar-hook. Do not edit by hand:
    each CodexBar launch overwrites this file to keep it in sync with the
    socket path and JSON schema CodexBar expects.

    Usage (configured in ~/.claude/settings.json or ~/.codex/config.toml):
        petbar-hook claude-code
        petbar-hook codex-cli

    The CLI feeds the hook payload as stdin JSON. We add a `petbar_source`
    field and write one NDJSON line to the local socket. Exit code 0 always,
    so a failed forward never blocks the CLI.
    \"\"\"
    import json, os, socket, sys

    SOCKET_PATH = os.path.expanduser('~/.codexbar/hook.sock')
    source = sys.argv[1] if len(sys.argv) > 1 else 'unknown'

    raw = sys.stdin.read()
    try:
        payload = json.loads(raw) if raw.strip() else {}
    except Exception:
        payload = {'raw': raw[:1024]}

    if not isinstance(payload, dict):
        payload = {'value': payload}
    payload['petbar_source'] = source

    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(0.5)
        s.connect(SOCKET_PATH)
        s.sendall((json.dumps(payload, separators=(',', ':')) + '\\n').encode())
        s.close()
    except (FileNotFoundError, ConnectionRefusedError, socket.timeout, OSError):
        # CodexBar is closed / hasn't started its receiver yet. Stay silent
        # so the CLI isn't polluted by every hook firing during a session
        # where the menu bar app is offline.
        pass

    sys.exit(0)
    """

    /// Write the shim to ~/.codexbar/bin/petbar-hook with mode 0700.
    /// Idempotent — safe to call on every CodexBar launch.
    public static func ensureInstalled() throws {
        let log = CodexBarLog.logger("hooks.shim")
        let path = self.installedShimPath
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])

        let url = URL(fileURLWithPath: path)
        let bytes = Data(self.shimSource.utf8)

        // Skip writes when the file is already up to date — avoids touching
        // mtime, which various editors/tools key off.
        if let existing = try? Data(contentsOf: url), existing == bytes {
            log.debug("shim already current", metadata: ["path": path])
            return
        }

        try bytes.write(to: url, options: .atomic)
        _ = chmod(path, 0o700)
        log.info("installed petbar-hook shim", metadata: ["path": path])
    }
}
