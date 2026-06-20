import Foundation

public struct ClaudeProxyProfile: Codable, Identifiable, Equatable, Hashable, Sendable {
    /// Where the profile's baseURL/token come from. `.manual` is the historical
    /// behaviour (typed in via Preferences). `.auto` reads them dynamically from
    /// the local Claude Code config so the user does not have to copy/paste a
    /// proxy key into a second place.
    public enum Source: String, Codable, Sendable {
        case manual
        case auto
    }

    public var id: UUID
    public var name: String
    public var baseURL: String
    public var token: String
    public var source: Source

    public init(
        id: UUID = UUID(),
        name: String,
        baseURL: String = "",
        token: String = "",
        source: Source = .manual)
    {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.token = token
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, baseURL, token, source
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.baseURL = try c.decode(String.self, forKey: .baseURL)
        self.token = try c.decode(String.self, forKey: .token)
        // Older profile JSON (pre-Auto) has no `source` key — default to manual
        // so existing on-disk profiles keep working with zero migration.
        self.source = try c.decodeIfPresent(Source.self, forKey: .source) ?? .manual
    }

    public var trimmedBaseURL: String {
        let raw = self.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return raw }
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }

    public var trimmedToken: String {
        self.token.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum ClaudeProxyProfileStore {
    public static let profilesDefaultsKey = "claudeProxyProfiles"
    public static let activeProfileIDDefaultsKey = "claudeProxyActiveProfileID"
    public static let migrationFlagDefaultsKey = "claudeProxyProfilesMigratedFromLegacy"

    public static let legacyBaseURLDefaultsKey = "claudeUsageBaseURLOverride"
    public static let legacyTokenDefaultsKey = "claudeOAuthTokenOverride"

    /// Path probed by `.auto` profiles. Mirrors the file Claude Code itself
    /// reads at startup, so whatever the user already configured for Claude
    /// Code (proxy base URL + key) is automatically reused here.
    public static let autoSourcePath = "~/.claude/settings.json"

    public struct AutoConfig: Equatable, Sendable {
        public var baseURL: String
        public var token: String
        public var sourcePath: String
    }

    /// Read `env.ANTHROPIC_BASE_URL` and `env.ANTHROPIC_API_KEY` from the
    /// local Claude Code settings file. Returns nil if the file is missing,
    /// malformed, or neither field is present — caller should keep showing
    /// whatever was last stored on the auto profile (likely empty strings).
    public static func resolveAutoConfig() -> AutoConfig? {
        let path = NSString(string: self.autoSourcePath).expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let env = parsed["env"] as? [String: Any] else { return nil }
        let baseURL = (env["ANTHROPIC_BASE_URL"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let token = (env["ANTHROPIC_API_KEY"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if baseURL.isEmpty, token.isEmpty {
            return nil
        }
        return AutoConfig(baseURL: baseURL, token: token, sourcePath: path)
    }

    /// Substitute `baseURL` and `token` from `resolveAutoConfig()` when the
    /// profile is `.auto`. `.manual` profiles are returned as-is. The persisted
    /// auto profile stores empty strings; resolution happens at read time so
    /// edits to settings.json take effect on next read without needing the GUI.
    private static func hydrate(_ profile: ClaudeProxyProfile) -> ClaudeProxyProfile {
        guard profile.source == .auto else { return profile }
        guard let config = self.resolveAutoConfig() else { return profile }
        var hydrated = profile
        hydrated.baseURL = config.baseURL
        hydrated.token = config.token
        return hydrated
    }

    public static func loadProfiles() -> [ClaudeProxyProfile] {
        self.migrateLegacyIfNeeded()
        guard let data = UserDefaults.standard.data(forKey: self.profilesDefaultsKey) else { return [] }
        return (try? JSONDecoder().decode([ClaudeProxyProfile].self, from: data)) ?? []
    }

    public static func saveProfiles(_ profiles: [ClaudeProxyProfile]) {
        let defaults = UserDefaults.standard
        if profiles.isEmpty {
            defaults.removeObject(forKey: self.profilesDefaultsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: self.profilesDefaultsKey)
    }

    public static func activeProfileID() -> UUID? {
        guard let raw = UserDefaults.standard.string(forKey: self.activeProfileIDDefaultsKey) else { return nil }
        return UUID(uuidString: raw)
    }

    public static func setActiveProfileID(_ id: UUID?) {
        let defaults = UserDefaults.standard
        if let id {
            defaults.set(id.uuidString, forKey: self.activeProfileIDDefaultsKey)
        } else {
            defaults.removeObject(forKey: self.activeProfileIDDefaultsKey)
        }
    }

    public static func activeProfile() -> ClaudeProxyProfile? {
        let profiles = self.loadProfiles()
        guard !profiles.isEmpty else { return nil }
        let selected: ClaudeProxyProfile = if let id = self.activeProfileID(),
                                              let match = profiles.first(where: { $0.id == id })
        {
            match
        } else {
            profiles.first!
        }
        return self.hydrate(selected)
    }

    /// The proxy (baseURL + token) to actually use, requiring both fields.
    /// Prefers a configured profile; otherwise falls back to the local Claude
    /// Code settings (`~/.claude/settings.json`) so a machine that already routes
    /// Claude Code through the proxy needs zero CodexBar setup — important for the
    /// multi-machine cross-machine-cost use case.
    public static func effectiveProxy() -> (baseURL: String, token: String)? {
        if let profile = self.activeProfile() {
            let baseURL = profile.trimmedBaseURL
            let token = profile.trimmedToken
            if !baseURL.isEmpty, !token.isEmpty {
                return (baseURL, token)
            }
        }
        if let auto = self.resolveAutoConfig(), !auto.baseURL.isEmpty, !auto.token.isEmpty {
            return (auto.baseURL, auto.token)
        }
        return nil
    }

    private static func migrateLegacyIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: self.migrationFlagDefaultsKey) else { return }
        defer { defaults.set(true, forKey: self.migrationFlagDefaultsKey) }

        if defaults.data(forKey: self.profilesDefaultsKey) != nil { return }

        let legacyBaseURL = (defaults.string(forKey: self.legacyBaseURLDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let legacyToken = (defaults.string(forKey: self.legacyTokenDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !legacyBaseURL.isEmpty || !legacyToken.isEmpty else { return }

        let seeded = ClaudeProxyProfile(
            name: "Default",
            baseURL: legacyBaseURL,
            token: legacyToken)
        guard let data = try? JSONEncoder().encode([seeded]) else { return }
        defaults.set(data, forKey: self.profilesDefaultsKey)
        defaults.set(seeded.id.uuidString, forKey: self.activeProfileIDDefaultsKey)
    }
}
