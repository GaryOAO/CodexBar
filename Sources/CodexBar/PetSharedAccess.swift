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
}
#endif
