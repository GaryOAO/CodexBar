import AppKit
import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct ProvidersPaneCoverageTests {
    @Test
    func `exercises providers pane views`() {
        let settings = Self.makeSettingsStore(suite: "ProvidersPaneCoverageTests")
        let store = Self.makeUsageStore(settings: settings)

        ProvidersPaneTestHarness.exercise(settings: settings, store: store)
    }

    @Test
    func `claude token account descriptor shows organization field`() throws {
        let settings = Self.makeSettingsStore(suite: "ProvidersPaneCoverageTests-claude-org-field")
        let store = Self.makeUsageStore(settings: settings)
        let pane = ProvidersPane(settings: settings, store: store)

        let claudeDescriptor = try #require(pane._test_tokenAccountDescriptor(for: .claude))
        #expect(claudeDescriptor.showsOrganizationField)
    }

    @Test
    func `provider search filters display names and raw ids`() {
        let providers: [UsageProvider] = [.codex, .claude]
        let names: [UsageProvider: String] = [
            .codex: "Codex",
            .claude: "Claude",
        ]

        #expect(
            ProvidersPane.filteredProviders(providers, query: "  ", displayName: { names[$0] ?? $0.rawValue })
                == providers)
        #expect(
            ProvidersPane.filteredProviders(providers, query: "codex", displayName: { names[$0] ?? $0.rawValue })
                == [.codex])
        #expect(
            ProvidersPane.filteredProviders(providers, query: "CLA", displayName: { names[$0] ?? $0.rawValue })
                == [.claude])
        #expect(
            ProvidersPane.filteredProviders(providers, query: "claude", displayName: { _ in "API" })
                == [.claude])
    }

    @Test
    func `provider reordering is inert while alphabetical sorting is enabled`() {
        let settings = Self.makeSettingsStore(suite: "ProvidersPaneCoverageTests-sorted-reorder")
        let store = Self.makeUsageStore(settings: settings)
        let pane = ProvidersPane(settings: settings, store: store)
        let original = settings.orderedProviders()

        settings.providersSortedAlphabetically = true
        pane._test_moveProviders(fromOffsets: IndexSet(integer: 0), toOffset: original.count)
        #expect(settings.orderedProviders() == original)

        settings.providersSortedAlphabetically = false
        pane._test_moveProviders(fromOffsets: IndexSet(integer: 0), toOffset: original.count)
        #expect(settings.orderedProviders().last == original.first)
    }

    @Test
    func `selected provider sidebar palette uses contrasting selected text colors`() {
        let palette = ProviderSidebarRowPalette(isSelected: true)

        #expect(palette.primary.isEqual(NSColor.alternateSelectedControlTextColor))
        #expect(palette.secondary.alphaComponent == 0.82)
        #expect(palette.tertiary.alphaComponent == 0.65)
    }

    @Test
    func `unselected provider sidebar palette uses standard label colors`() {
        let palette = ProviderSidebarRowPalette(isSelected: false)

        #expect(palette.primary.isEqual(NSColor.labelColor))
        #expect(palette.secondary.isEqual(NSColor.secondaryLabelColor))
        #expect(palette.tertiary.isEqual(NSColor.tertiaryLabelColor))
    }

    @Test
    func `claude menu bar metric picker includes extra usage when spend limit is available`() {
        let settings = Self.makeSettingsStore(suite: "ProvidersPaneCoverageTests-claude-extra-usage-picker")
        let store = Self.makeUsageStore(settings: settings)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: nil,
                secondary: nil,
                providerCost: ProviderCostSnapshot(
                    used: 67.03,
                    limit: 1000,
                    currencyCode: "USD",
                    period: "Spend limit",
                    updatedAt: Date()),
                updatedAt: Date()),
            provider: .claude)
        let pane = ProvidersPane(settings: settings, store: store)

        let picker = pane._test_menuBarMetricPicker(for: .claude)
        let ids = picker?.options.map(\.id) ?? []
        #expect(ids.contains(MenuBarMetricPreference.extraUsage.rawValue))
    }

    @Test
    func `provider detail plan row keeps plan label`() {
        Self.withEnglishLocalization {
            let row = ProviderDetailView<EmptyView>.planRow(provider: .codex, planText: "Pro")

            #expect(row?.label == "Plan")
            #expect(row?.value == "Pro")
        }
    }

    @Test
    func `provider detail renders metric status without progress`() {
        let metric = UsageMenuCardView.Model.Metric(
            id: "fixture",
            title: "Example quota",
            percent: 0,
            percentStyle: .left,
            statusText: "Unavailable",
            resetText: nil,
            detailText: nil,
            detailLeftText: nil,
            detailRightText: nil,
            pacePercent: nil,
            paceOnTop: false)

        #expect(ProviderDetailView<EmptyView>.metricInlinePresentation(metric) == .status("Unavailable"))
    }

    @Test
    func `provider detail renders ordinary metric progress`() {
        let metric = UsageMenuCardView.Model.Metric(
            id: "fixture",
            title: "Example quota",
            percent: 50,
            percentStyle: .left,
            resetText: nil,
            detailText: nil,
            detailLeftText: nil,
            detailRightText: nil,
            pacePercent: nil,
            paceOnTop: false)

        #expect(ProviderDetailView<EmptyView>.metricInlinePresentation(metric) == .progress)
    }

    @Test
    func `codex providers pane uses managed account fallback instead of ambient account`() throws {
        let settings = Self.makeSettingsStore(suite: "ProvidersPaneCoverageTests-codex-managed-fallback")
        let ambientHome = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        let managedHome = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: ambientHome)
            try? FileManager.default.removeItem(at: managedHome)
        }

        try Self.writeCodexAuthFile(homeURL: ambientHome, email: "ambient@example.com", plan: "plus")
        try Self.writeCodexAuthFile(homeURL: managedHome, email: "managed@example.com", plan: "enterprise")
        let managedAccountID = UUID()
        settings.codexActiveSource = .managedAccount(id: managedAccountID)
        settings._test_activeManagedCodexAccount = ManagedCodexAccount(
            id: managedAccountID,
            email: "managed@example.com",
            managedHomePath: managedHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)

        let store = UsageStore(
            fetcher: UsageFetcher(environment: ["CODEX_HOME": ambientHome.path]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 12, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: RateWindow(usedPercent: 34, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
                updatedAt: Date(),
                identity: nil),
            provider: .codex)

        let pane = ProvidersPane(settings: settings, store: store)
        let model = pane._test_menuCardModel(for: .codex)

        #expect(model.email == "managed@example.com")
        #expect(model.planText == "Enterprise")
    }

    private static func makeSettingsStore(suite: String) -> SettingsStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)

        return SettingsStore(userDefaults: defaults, configStore: configStore, codexCookieStore: InMemoryCookieHeaderStore(), claudeCookieStore: InMemoryCookieHeaderStore(), tokenAccountStore: InMemoryTokenAccountStore())
    }

    private static func makeUsageStore(settings: SettingsStore) -> UsageStore {
        UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
    }

    private static func withEnglishLocalization(perform body: () -> Void) {
        CodexBarLocalizationOverride.$appLanguage.withValue("en", operation: body)
    }

    private static func writeCodexAuthFile(homeURL: URL, email: String, plan: String) throws {
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        let auth = [
            "tokens": [
                "accessToken": "access-token",
                "refreshToken": "refresh-token",
                "idToken": Self.fakeJWT(email: email, plan: plan),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: auth)
        try data.write(to: homeURL.appendingPathComponent("auth.json"))
    }

    private static func fakeJWT(email: String, plan: String) -> String {
        let header = (try? JSONSerialization.data(withJSONObject: ["alg": "none"])) ?? Data()
        let payload = (try? JSONSerialization.data(withJSONObject: [
            "email": email,
            "chatgpt_plan_type": plan,
        ])) ?? Data()

        func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
        }

        return "\(base64URL(header)).\(base64URL(payload))."
    }
}
