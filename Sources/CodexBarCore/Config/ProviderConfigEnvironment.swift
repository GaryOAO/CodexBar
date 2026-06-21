import Foundation

public enum ProviderConfigEnvironment {
    public static func applyAPIKeyOverride(
        base: [String: String],
        provider: UsageProvider,
        config: ProviderConfig?) -> [String: String]
    {
        if let env = self.applyDedicatedProviderOverrides(base: base, provider: provider, config: config) {
            return env
        }
        guard let apiKey = config?.sanitizedAPIKey, !apiKey.isEmpty else { return base }
        var env = base
        if let key = self.directAPIKeyEnvironmentKey(for: provider) {
            env[key] = apiKey
            return env
        }

        return env
    }

    public static func supportsAPIKeyOverride(for provider: UsageProvider) -> Bool {
        if self.directAPIKeyEnvironmentKey(for: provider) != nil { return true }
        return false
    }

    private static func applyDedicatedProviderOverrides(
        base _: [String: String],
        provider _: UsageProvider,
        config _: ProviderConfig?) -> [String: String]?
    {
        nil
    }

    private static func directAPIKeyEnvironmentKey(for provider: UsageProvider) -> String? {
        switch provider {
        case .claude:
            ClaudeAdminAPISettingsReader.adminAPIKeyEnvironmentKey
        default:
            nil
        }
    }

    public static func applyProviderConfigOverrides(
        base: [String: String],
        provider: UsageProvider,
        config: ProviderConfig?) -> [String: String]
    {
        self.applyAPIKeyOverride(base: base, provider: provider, config: config)
    }
}
