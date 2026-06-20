import CodexBarCore
import Foundation

extension SettingsStore {
    func menuBarMetricPreference(for provider: UsageProvider) -> MenuBarMetricPreference {
        if Self.isBalanceOnlyProvider(provider) {
            return .automatic
        }
        let raw = self.menuBarMetricPreferencesRaw[provider.rawValue] ?? ""
        let preference = MenuBarMetricPreference(rawValue: raw) ?? .automatic
        if preference == .average, !self.menuBarMetricSupportsAverage(for: provider) {
            return .automatic
        }
        if preference == .primaryAndSecondary, !self.menuBarMetricSupportsPrimaryAndSecondary(for: provider) {
            return .automatic
        }
        if preference == .tertiary, !self.menuBarMetricSupportsTertiary(for: provider) {
            return .automatic
        }
        if preference == .extraUsage, !self.menuBarMetricSupportsExtraUsage(for: provider) {
            return .automatic
        }
        if preference == .monthlyPlan {
            return .automatic
        }
        return preference
    }

    func setMenuBarMetricPreference(_ preference: MenuBarMetricPreference, for provider: UsageProvider) {
        if Self.isBalanceOnlyProvider(provider) {
            self.menuBarMetricPreferencesRaw[provider.rawValue] = MenuBarMetricPreference.automatic.rawValue
            return
        }
        if preference == .primaryAndSecondary, !self.menuBarMetricSupportsPrimaryAndSecondary(for: provider) {
            self.menuBarMetricPreferencesRaw[provider.rawValue] = MenuBarMetricPreference.automatic.rawValue
            return
        }
        if preference == .tertiary, !self.menuBarMetricSupportsTertiary(for: provider) {
            self.menuBarMetricPreferencesRaw[provider.rawValue] = MenuBarMetricPreference.automatic.rawValue
            return
        }
        if preference == .extraUsage, !self.menuBarMetricSupportsExtraUsage(for: provider) {
            self.menuBarMetricPreferencesRaw[provider.rawValue] = MenuBarMetricPreference.automatic.rawValue
            return
        }
        if preference == .monthlyPlan {
            self.menuBarMetricPreferencesRaw[provider.rawValue] = MenuBarMetricPreference.automatic.rawValue
            return
        }
        self.menuBarMetricPreferencesRaw[provider.rawValue] = preference.rawValue
    }

    func menuBarMetricSupportsAverage(for _: UsageProvider) -> Bool {
        false
    }

    func menuBarMetricSupportsPrimaryAndSecondary(for provider: UsageProvider) -> Bool {
        provider == .codex
    }

    func menuBarMetricSupportsTertiary(for _: UsageProvider) -> Bool {
        false
    }

    func menuBarMetricSupportsTertiary(for provider: UsageProvider, snapshot _: UsageSnapshot?) -> Bool {
        self.menuBarMetricSupportsTertiary(for: provider)
    }

    func menuBarMetricSupportsExtraUsage(for provider: UsageProvider) -> Bool {
        provider == .claude
    }

    func menuBarMetricSupportsExtraUsage(for provider: UsageProvider, snapshot: UsageSnapshot?) -> Bool {
        guard self.menuBarMetricSupportsExtraUsage(for: provider) else { return false }
        guard let cost = snapshot?.providerCost else { return false }
        return cost.limit > 0
    }

    func menuBarMetricPreference(for provider: UsageProvider, snapshot: UsageSnapshot?) -> MenuBarMetricPreference {
        let preference = self.menuBarMetricPreference(for: provider)
        if preference == .tertiary,
           !self.menuBarMetricSupportsTertiary(for: provider, snapshot: snapshot)
        {
            return .automatic
        }
        if preference == .extraUsage,
           !self.menuBarMetricSupportsExtraUsage(for: provider, snapshot: snapshot)
        {
            return .automatic
        }
        return preference
    }

    func isCostUsageEffectivelyEnabled(for provider: UsageProvider) -> Bool {
        guard ProviderDescriptorRegistry.descriptor(for: provider).tokenCost.supportsTokenCost else {
            return false
        }
        // Claude cost via the proxy is a remote cross-machine total (not a local log
        // scan), so it lights up whenever a proxy profile is active — independent of
        // the local cost-usage toggle.
        if provider == .claude, Self.isClaudeProxyCostActive() {
            return true
        }
        return self.costUsageEnabled
    }

    static func isClaudeProxyCostActive() -> Bool {
        ClaudeProxyProfileStore.effectiveProxy() != nil
    }

    var resetTimeDisplayStyle: ResetTimeDisplayStyle {
        self.resetTimesShowAbsolute ? .absolute : .countdown
    }

    static func isBalanceOnlyProvider(_: UsageProvider) -> Bool {
        false
    }
}
