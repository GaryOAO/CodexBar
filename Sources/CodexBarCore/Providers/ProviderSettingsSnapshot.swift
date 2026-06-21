import Foundation

public protocol ProviderCookieSettings: Sendable {
    var cookieSource: ProviderCookieSource { get }
    var manualCookieHeader: String? { get }

    init(cookieSource: ProviderCookieSource, manualCookieHeader: String?)
}

public struct ProviderSettingsSnapshot: Sendable {
    public static func make(
        debugMenuEnabled: Bool = false,
        debugKeepCLISessionsAlive: Bool = false,
        codex: CodexProviderSettings? = nil,
        claude: ClaudeProviderSettings? = nil) -> ProviderSettingsSnapshot
    {
        ProviderSettingsSnapshot(
            debugMenuEnabled: debugMenuEnabled,
            debugKeepCLISessionsAlive: debugKeepCLISessionsAlive,
            codex: codex,
            claude: claude)
    }

    public struct CodexProviderSettings: Sendable {
        public let usageDataSource: CodexUsageDataSource
        public let cookieSource: ProviderCookieSource
        public let manualCookieHeader: String?
        public let managedAccountStoreUnreadable: Bool
        public let managedAccountTargetUnavailable: Bool
        public let profileAccountTargetUnavailable: Bool
        public let openAIWebCacheScope: CookieHeaderCache.Scope?
        public let dashboardAuthorityKnownOwners: [CodexDashboardKnownOwnerCandidate]

        public init(
            usageDataSource: CodexUsageDataSource,
            cookieSource: ProviderCookieSource,
            manualCookieHeader: String?,
            managedAccountStoreUnreadable: Bool = false,
            managedAccountTargetUnavailable: Bool = false,
            profileAccountTargetUnavailable: Bool = false,
            openAIWebCacheScope: CookieHeaderCache.Scope? = nil,
            dashboardAuthorityKnownOwners: [CodexDashboardKnownOwnerCandidate] = [])
        {
            self.usageDataSource = usageDataSource
            self.cookieSource = cookieSource
            self.manualCookieHeader = manualCookieHeader
            self.managedAccountStoreUnreadable = managedAccountStoreUnreadable
            self.managedAccountTargetUnavailable = managedAccountTargetUnavailable
            self.profileAccountTargetUnavailable = profileAccountTargetUnavailable
            self.openAIWebCacheScope = openAIWebCacheScope
            self.dashboardAuthorityKnownOwners = dashboardAuthorityKnownOwners
        }
    }

    public struct ClaudeProviderSettings: Sendable {
        public let usageDataSource: ClaudeUsageDataSource
        public let webExtrasEnabled: Bool
        public let cookieSource: ProviderCookieSource
        public let manualCookieHeader: String?
        public let organizationID: String?

        public init(
            usageDataSource: ClaudeUsageDataSource,
            webExtrasEnabled: Bool,
            cookieSource: ProviderCookieSource,
            manualCookieHeader: String?,
            organizationID: String? = nil)
        {
            self.usageDataSource = usageDataSource
            self.webExtrasEnabled = webExtrasEnabled
            self.cookieSource = cookieSource
            self.manualCookieHeader = manualCookieHeader
            self.organizationID = organizationID
        }
    }

    public struct CookieProviderSettings: ProviderCookieSettings {
        public let cookieSource: ProviderCookieSource
        public let manualCookieHeader: String?

        public init(cookieSource: ProviderCookieSource = .auto, manualCookieHeader: String? = nil) {
            self.cookieSource = cookieSource
            self.manualCookieHeader = manualCookieHeader
        }
    }

    public let debugMenuEnabled: Bool
    public let debugKeepCLISessionsAlive: Bool
    public let codex: CodexProviderSettings?
    public let claude: ClaudeProviderSettings?

    public init(
        debugMenuEnabled: Bool,
        debugKeepCLISessionsAlive: Bool,
        codex: CodexProviderSettings?,
        claude: ClaudeProviderSettings?)
    {
        self.debugMenuEnabled = debugMenuEnabled
        self.debugKeepCLISessionsAlive = debugKeepCLISessionsAlive
        self.codex = codex
        self.claude = claude
    }
}

public enum ProviderSettingsSnapshotContribution: Sendable {
    case codex(ProviderSettingsSnapshot.CodexProviderSettings)
    case claude(ProviderSettingsSnapshot.ClaudeProviderSettings)
}

public struct ProviderSettingsSnapshotBuilder: Sendable {
    public var debugMenuEnabled: Bool
    public var debugKeepCLISessionsAlive: Bool
    public var codex: ProviderSettingsSnapshot.CodexProviderSettings?
    public var claude: ProviderSettingsSnapshot.ClaudeProviderSettings?

    public init(debugMenuEnabled: Bool = false, debugKeepCLISessionsAlive: Bool = false) {
        self.debugMenuEnabled = debugMenuEnabled
        self.debugKeepCLISessionsAlive = debugKeepCLISessionsAlive
    }

    public mutating func apply(_ contribution: ProviderSettingsSnapshotContribution) {
        switch contribution {
        case let .codex(value): self.codex = value
        case let .claude(value): self.claude = value
        }
    }

    public func build() -> ProviderSettingsSnapshot {
        ProviderSettingsSnapshot(
            debugMenuEnabled: self.debugMenuEnabled,
            debugKeepCLISessionsAlive: self.debugKeepCLISessionsAlive,
            codex: self.codex,
            claude: self.claude)
    }
}
