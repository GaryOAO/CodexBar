import Foundation

extension TokenAccountSupportCatalog {
    static let supportByProvider: [UsageProvider: TokenAccountSupport] = [
        .claude: TokenAccountSupport(
            title: "Claude credentials",
            subtitle: "Store Claude sessionKey cookies, OAuth tokens, or Anthropic Admin API keys.",
            placeholder: "Paste sessionKey, OAuth token, or sk-ant-admin…",
            injection: .cookieHeader,
            requiresManualCookieSource: true,
            cookieName: "sessionKey"),
    ]
}
