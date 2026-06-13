import Foundation

#if os(macOS)
import os.lock
import SweetCookieKit

public enum BrowserCookieAccessGate {
    private struct State {
        var loaded = false
        var deniedUntilByBrowser: [String: Date] = [:]
    }

    private static let lock = OSAllocatedUnfairLock<State>(initialState: State())
    private static let defaultsKey = "browserCookieAccessDeniedUntil"
    private static let cooldownInterval: TimeInterval = 60 * 60 * 6
    private static let log = CodexBarLog.logger(LogCategories.browserCookieGate)

    /// User-facing master switch. When false (default), CodexBar will NOT
    /// touch any browser cookie keychain item (Chrome/Chromium Safe Storage,
    /// etc.) for automatic refreshes — the system "wants to use confidential
    /// information" prompt only appears after the user explicitly toggles
    /// this on. Local-patch (2026-05-17): the previous behavior attempted on
    /// every refresh and only suppressed AFTER a deny + 6h cooldown, which
    /// still produced one prompt per browser per session. This makes the
    /// prompt strictly opt-in.
    public static let manualOptInDefaultsKey = "browserCookieAutoImportEnabled"

    public static func shouldAttempt(_ browser: Browser, now: Date = Date()) -> Bool {
        guard browser.usesKeychainForCookieDecryption else { return true }
        guard !KeychainAccessGate.isDisabled else { return false }
        // Master opt-in gate (default false = no automatic keychain prompts).
        guard UserDefaults.standard.bool(forKey: self.manualOptInDefaultsKey) else {
            self.log.debug(
                "Browser cookie auto-import disabled (opt-in)",
                metadata: ["browser": browser.displayName])
            return false
        }
        let shouldCheckKeychain = self.lock.withLock { state in
            self.loadIfNeeded(&state)
            if let blockedUntil = state.deniedUntilByBrowser[browser.rawValue] {
                if blockedUntil > now {
                    self.log.debug(
                        "Cookie access blocked",
                        metadata: ["browser": browser.displayName, "until": "\(blockedUntil.timeIntervalSince1970)"])
                    return false
                }
                state.deniedUntilByBrowser.removeValue(forKey: browser.rawValue)
                self.persist(state)
            }
            return true
        }
        guard shouldCheckKeychain else { return false }

        let requiresInteraction = self.chromiumKeychainRequiresInteraction()
        return self.lock.withLock { state in
            self.loadIfNeeded(&state)
            if requiresInteraction {
                state.deniedUntilByBrowser[browser.rawValue] = now.addingTimeInterval(self.cooldownInterval)
                self.persist(state)
                self.log.info(
                    "Cookie access requires keychain interaction; suppressing",
                    metadata: ["browser": browser.displayName])
                return false
            }
            self.log.debug("Cookie access allowed", metadata: ["browser": browser.displayName])
            return true
        }
    }

    public static func recordIfNeeded(_ error: Error, now: Date = Date()) {
        guard let error = error as? BrowserCookieError else { return }
        guard case .accessDenied = error else { return }
        self.recordDenied(for: error.browser, now: now)
    }

    public static func recordDenied(for browser: Browser, now: Date = Date()) {
        guard browser.usesKeychainForCookieDecryption else { return }
        let blockedUntil = now.addingTimeInterval(self.cooldownInterval)
        self.lock.withLock { state in
            self.loadIfNeeded(&state)
            state.deniedUntilByBrowser[browser.rawValue] = blockedUntil
            self.persist(state)
        }
        self.log
            .info(
                "Browser cookie access denied; suppressing prompts",
                metadata: [
                    "browser": browser.displayName,
                    "until": "\(blockedUntil.timeIntervalSince1970)",
                ])
    }

    public static func resetForTesting() {
        self.lock.withLock { state in
            state.loaded = true
            state.deniedUntilByBrowser.removeAll()
            UserDefaults.standard.removeObject(forKey: self.defaultsKey)
        }
    }

    private static func chromiumKeychainRequiresInteraction() -> Bool {
        for label in self.safeStorageLabels {
            switch KeychainAccessPreflight.checkGenericPassword(service: label.service, account: label.account) {
            case .allowed:
                return false
            case .interactionRequired:
                return true
            case .notFound, .failure:
                continue
            }
        }
        return false
    }

    private static let safeStorageLabels: [(service: String, account: String)] = Browser.safeStorageLabels

    private static func loadIfNeeded(_ state: inout State) {
        guard !state.loaded else { return }
        state.loaded = true
        guard let raw = UserDefaults.standard.dictionary(forKey: self.defaultsKey) as? [String: Double] else {
            return
        }
        state.deniedUntilByBrowser = raw.compactMapValues { Date(timeIntervalSince1970: $0) }
    }

    private static func persist(_ state: State) {
        let raw = state.deniedUntilByBrowser.mapValues { $0.timeIntervalSince1970 }
        UserDefaults.standard.set(raw, forKey: self.defaultsKey)
    }
}

extension BrowserCookieClient {
    public func codexBarRecords(
        matching query: BrowserCookieQuery,
        in browser: Browser,
        logger: ((String) -> Void)? = nil) throws -> [BrowserCookieStoreRecords]
    {
        guard BrowserCookieAccessGate.shouldAttempt(browser) else { return [] }
        return try self.records(matching: query, in: browser, logger: logger)
    }
}
#else
public enum BrowserCookieAccessGate {
    public static func shouldAttempt(_ browser: Browser, now: Date = Date()) -> Bool {
        true
    }

    public static func recordIfNeeded(_ error: Error, now: Date = Date()) {}
    public static func recordDenied(for browser: Browser, now: Date = Date()) {}
    public static func resetForTesting() {}
}
#endif
