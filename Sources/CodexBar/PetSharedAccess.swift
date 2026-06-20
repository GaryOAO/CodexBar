#if os(macOS)
import CodexBarCore
import Foundation

/// Thin global holding the live PetBLEClient so SwiftUI panes can read
/// connection state and trigger test writes without threading the client
/// through every view binding. AppDelegate sets `client` at startup;
/// preference panes read it on appear.
///
/// Single-writer, many-reader, all on the main actor — no synchronisation
/// needed beyond Swift's @MainActor.
@MainActor
public enum PetSharedAccess {
    public static var client: PetBLEClient?
    public static var helper: PetBLEHelperProxy?
    public static var requestForegroundStart: (() -> Void)?

    public static func pushStatus(_ status: PetStatus) {
        if let helper {
            helper.pushStatus(status)
            return
        }
        self.client?.pushStatus(status)
    }

    public static func pushProviderStatuses(_ status: PetStatus, codexStatus: PetCodexStatus) {
        if let helper {
            helper.pushProviderStatuses(status, codexStatus: codexStatus)
            return
        }
        self.client?.pushStatus(status)
        self.client?.pushCodexStatus(codexStatus)
    }

    public static func setTheme(_ theme: PetTheme) {
        if let helper {
            helper.setTheme(theme)
            return
        }
        self.client?.setTheme(theme)
    }

    public static func setDisplayConfig(_ config: PetDisplayConfig) {
        if let helper {
            helper.setDisplayConfig(config)
            return
        }
        self.client?.setDisplayConfig(config)
    }

    public static func snapshot() -> PetBLESnapshot? {
        if let helper {
            helper.requestSnapshot()
            return helper.lastSnapshot()
        }
        return self.client?.snapshot()
    }
}
#endif
