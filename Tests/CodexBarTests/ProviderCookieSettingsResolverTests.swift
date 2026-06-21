import CodexBarCore
import Foundation
import Testing

struct ProviderCookieSettingsResolverTests {
    @Test
    func `shared cookie settings default to automatic source without manual header`() {
        let settings = ProviderSettingsSnapshot.CookieProviderSettings()

        #expect(settings.cookieSource == .auto)
        #expect(settings.manualCookieHeader == nil)
    }

    @Test
    func `selected Claude account overrides configured credentials`() {
        let settings = ProviderCookieSettingsResolver.resolve(
            provider: .claude,
            configuredSource: .auto,
            configuredHeader: "sessionKey=config",
            selectedAccount: Self.account(token: "account"))

        #expect(settings.cookieSource == .manual)
        #expect(settings.manualCookieHeader == "sessionKey=account")
    }

    @Test
    func `configured Claude credentials remain when no account is selected`() {
        let settings = ProviderCookieSettingsResolver.resolve(
            provider: .claude,
            configuredSource: .manual,
            configuredHeader: "Cookie: sessionKey=config",
            selectedAccount: nil)

        #expect(settings.cookieSource == .manual)
        #expect(settings.manualCookieHeader == "Cookie: sessionKey=config")
    }

    @Test
    func `providers without token account support ignore selected account`() {
        let settings = ProviderCookieSettingsResolver.resolve(
            provider: .codex,
            configuredSource: .auto,
            configuredHeader: "configured=true",
            selectedAccount: Self.account(token: "account=true"))

        #expect(settings.cookieSource == .auto)
        #expect(settings.manualCookieHeader == "configured=true")
    }

    private static func account(token: String) -> ProviderTokenAccount {
        ProviderTokenAccount(
            id: UUID(),
            label: "Test",
            token: token,
            addedAt: 0,
            lastUsed: nil)
    }
}
