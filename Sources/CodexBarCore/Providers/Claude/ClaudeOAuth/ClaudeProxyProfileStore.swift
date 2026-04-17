import Foundation

public struct ClaudeProxyProfile: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var baseURL: String
    public var token: String

    public init(id: UUID = UUID(), name: String, baseURL: String, token: String) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.token = token
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
        if let id = self.activeProfileID(), let match = profiles.first(where: { $0.id == id }) {
            return match
        }
        return profiles.first
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
