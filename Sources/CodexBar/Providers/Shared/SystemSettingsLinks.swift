import AppKit
import Foundation

enum SystemSettingsLinks {
    static let installedCodexBarAppURL = URL(fileURLWithPath: "/Applications/CodexBar.app")

    /// Opens System Settings → Privacy & Security → Full Disk Access (best effort).
    static func openFullDiskAccess() {
        // Best-effort deep link. On older betas it sometimes opened the wrong pane; on modern macOS this is stable.
        let urls: [URL] = [
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"),
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy"),
            URL(string: "x-apple.systempreferences:com.apple.preference.security"),
        ].compactMap(\.self)

        for url in urls where NSWorkspace.shared.open(url) {
            return
        }
    }

    /// Opens System Settings → Privacy & Security → Bluetooth (best effort).
    static func openBluetoothPrivacy() {
        let urls: [URL] = [
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"),
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy"),
            URL(string: "x-apple.systempreferences:com.apple.preference.security"),
        ].compactMap(\.self)

        for url in urls where NSWorkspace.shared.open(url) {
            return
        }
    }

    static func revealInstalledCodexBarApp() {
        NSWorkspace.shared.activateFileViewerSelecting([self.installedCodexBarAppURL])
    }

    static func copyInstalledCodexBarAppPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(self.installedCodexBarAppURL.path, forType: .string)
    }
}
