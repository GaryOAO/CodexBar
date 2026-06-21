import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct StatusItemAnimationTests {
    private func maxAlpha(in rep: NSBitmapImageRep) -> CGFloat {
        var maxAlpha: CGFloat = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                let alpha = (rep.colorAt(x: x, y: y) ?? .clear).alphaComponent
                if alpha > maxAlpha {
                    maxAlpha = alpha
                }
            }
        }
        return maxAlpha
    }

    private func makeStatusBarForTesting() -> NSStatusBar {
        // Use the real system status bar in tests. Creating standalone NSStatusBar instances
        // has caused AppKit teardown crashes under swiftpm-testing-helper.
        .system
    }

    @Test
    func `merged icon loading animation tracks selected provider only`() {
        let settings = testSettingsStore(suiteName: "StatusItemAnimationTests-merged")
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let claudeMeta = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 50, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())

        store._setSnapshotForTesting(snapshot, provider: .codex)
        store._setSnapshotForTesting(nil, provider: .claude)
        store._setErrorForTesting(nil, provider: .codex)
        store._setErrorForTesting(nil, provider: .claude)

        #expect(controller.needsMenuBarIconAnimation() == false)
    }

    @Test
    func `merged icon loading animation does not flip layout when weekly hits zero`() {
        let settings = testSettingsStore(suiteName: "StatusItemAnimationTests-weekly")
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.menuBarShowsBrandIconWithPercent = false

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let claudeMeta = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)

        // Seed with data so init doesn't start the animation driver.
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 50, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 50, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())
        store._setSnapshotForTesting(snapshot, provider: .codex)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        // Enter loading state: no data, no stale error.
        store._setSnapshotForTesting(nil, provider: .codex)
        store._setSnapshotForTesting(nil, provider: .claude)
        store._setErrorForTesting(nil, provider: .codex)
        store._setErrorForTesting(nil, provider: .claude)

        controller.animationPattern = .knightRider
        #expect(controller.needsMenuBarIconAnimation() == true)

        // At phase = π/2, the secondary bar hits 0 (weeklyRemaining == 0) due to a π offset.
        // Regression: this used to flip IconRenderer into the "weekly exhausted" layout and cause toolbar flicker.
        controller.applyIcon(phase: .pi / 2)

        guard let image = controller.statusItem.button?.image else {
            #expect(Bool(false))
            return
        }
        let rep = image.representations.compactMap { $0 as? NSBitmapImageRep }.first(where: {
            $0.pixelsWide == 36 && $0.pixelsHigh == 36
        })
        #expect(rep != nil)
        guard let rep else { return }

        let alpha = (rep.colorAt(x: 18, y: 12) ?? .clear).alphaComponent
        #expect(alpha > 0.05)
    }

    @Test
    func `menu bar percent uses configured metric`() {
        let settings = testSettingsStore(suiteName: "StatusItemAnimationTests-metric")
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.setMenuBarMetricPreference(.secondary, for: .codex)

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 12, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 42, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        store._setSnapshotForTesting(snapshot, provider: .codex)
        store._setErrorForTesting(nil, provider: .codex)

        let window = controller.menuBarMetricWindow(for: .codex, snapshot: snapshot)

        #expect(window?.usedPercent == 42)
    }

    @Test
    func `combined codex menu bar metric window uses most constrained visible lane`() {
        let settings = testSettingsStore(suiteName: "StatusItemAnimationTests-codex-combined-window")
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.setMenuBarMetricPreference(.primaryAndSecondary, for: .codex)

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 12, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 91, windowMinutes: 7 * 24 * 60, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        store._setSnapshotForTesting(snapshot, provider: .codex)
        store._setErrorForTesting(nil, provider: .codex)

        let window = controller.menuBarMetricWindow(for: .codex, snapshot: snapshot)

        #expect(window?.usedPercent == 91)
        #expect(window?.windowMinutes == 7 * 24 * 60)
    }

    @Test
    func `menu bar display text formats percent and pace`() {
        let now = Date(timeIntervalSince1970: 0)
        let percentWindow = RateWindow(usedPercent: 40, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
        let paceWindow = RateWindow(
            usedPercent: 30,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(60 * 60 * 24 * 6),
            resetDescription: nil)
        let paceValue = UsagePace.weekly(window: paceWindow, now: now, defaultWindowMinutes: 10080)

        let percent = MenuBarDisplayText.displayText(
            mode: .percent,
            percentWindow: percentWindow,
            pace: paceValue,
            showUsed: true)
        let pace = MenuBarDisplayText.displayText(
            mode: .pace,
            percentWindow: percentWindow,
            pace: paceValue,
            showUsed: true)
        let both = MenuBarDisplayText.displayText(
            mode: .both,
            percentWindow: percentWindow,
            pace: paceValue,
            showUsed: true)

        #expect(percent == "40%")
        #expect(pace == "+16%")
        #expect(both == "40% · +16%")
    }

    @Test
    func `menu bar display text formats codex combined percent lanes`() {
        let sessionWindow = RateWindow(usedPercent: 7, windowMinutes: 300, resetsAt: nil, resetDescription: nil)
        let weeklyWindow = RateWindow(usedPercent: 18, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)

        let remaining = MenuBarDisplayText.codexCombinedPercentText(
            sessionWindow: sessionWindow,
            weeklyWindow: weeklyWindow,
            showUsed: false)
        let used = MenuBarDisplayText.codexCombinedPercentText(
            sessionWindow: sessionWindow,
            weeklyWindow: weeklyWindow,
            showUsed: true)
        let weeklyOnly = MenuBarDisplayText.codexCombinedPercentText(
            sessionWindow: nil,
            weeklyWindow: weeklyWindow,
            showUsed: false)
        let nineHour = MenuBarDisplayText.codexCombinedPercentText(
            sessionWindow: RateWindow(
                usedPercent: 7,
                windowMinutes: 540,
                resetsAt: nil,
                resetDescription: nil),
            weeklyWindow: weeklyWindow,
            showUsed: false)
        let unknownSessionDuration = MenuBarDisplayText.codexCombinedPercentText(
            sessionWindow: RateWindow(
                usedPercent: 7,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: nil),
            weeklyWindow: weeklyWindow,
            showUsed: false)

        #expect(remaining == "5h 93% · W 82%")
        #expect(used == "5h 7% · W 18%")
        #expect(weeklyOnly == "W 82%")
        #expect(nineHour == "9h 93% · W 82%")
        #expect(unknownSessionDuration == "S 93% · W 82%")
    }

    @Test
    func `menu bar display text falls back to percent when pace unavailable`() {
        let percentWindow = RateWindow(usedPercent: 40, windowMinutes: nil, resetsAt: nil, resetDescription: nil)

        let pace = MenuBarDisplayText.displayText(
            mode: .pace,
            percentWindow: percentWindow,
            showUsed: true)
        let both = MenuBarDisplayText.displayText(
            mode: .both,
            percentWindow: percentWindow,
            showUsed: true)

        #expect(pace == "40%")
        #expect(both == "40%")
    }

    @Test
    func `menu bar display text falls back to percent when pace nil for codex`() {
        let percentWindow = RateWindow(usedPercent: 40, windowMinutes: nil, resetsAt: nil, resetDescription: nil)

        let pace = MenuBarDisplayText.displayText(
            mode: .pace,
            percentWindow: percentWindow,
            pace: nil,
            showUsed: true)
        let both = MenuBarDisplayText.displayText(
            mode: .both,
            percentWindow: percentWindow,
            pace: nil,
            showUsed: true)

        #expect(pace == "40%")
        #expect(both == "40%")
    }

    @Test
    func `claude primary menu bar metric computes pace from selected session window`() {
        let settings = testSettingsStore(suiteName: "StatusItemAnimationTests-claude-primary-pace")
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .claude
        settings.menuBarDisplayMode = .both
        settings.usageBarsShowUsed = false
        settings.setMenuBarMetricPreference(.primary, for: .claude)

        let registry = ProviderRegistry.shared
        if let claudeMeta = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let now = Date()
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 80,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(4 * 60 * 60),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 20,
                windowMinutes: 7 * 24 * 60,
                resetsAt: now.addingTimeInterval(24 * 60 * 60),
                resetDescription: nil),
            updatedAt: now)
        store._setSnapshotForTesting(snapshot, provider: .claude)
        store._setErrorForTesting(nil, provider: .claude)

        let displayText = controller.menuBarDisplayText(for: .claude, snapshot: snapshot)

        #expect(displayText == "20% · +60%")
    }

    @Test
    func `codex menu bar pace does not fall back to session when weekly projection is unavailable`() {
        let settings = testSettingsStore(suiteName: "StatusItemAnimationTests-codex-no-weekly-pace")
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.menuBarDisplayMode = .both
        settings.usageBarsShowUsed = false
        settings.setMenuBarMetricPreference(.primary, for: .codex)

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let now = Date()
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 80,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(4 * 60 * 60),
                resetDescription: nil),
            secondary: nil,
            updatedAt: now)
        store._setSnapshotForTesting(snapshot, provider: .codex)
        store._setErrorForTesting(nil, provider: .codex)

        let displayText = controller.menuBarDisplayText(for: .codex, snapshot: snapshot)

        #expect(displayText == "20%")
    }

    @Test
    func `menu bar display text uses credits when codex weekly is exhausted`() {
        let settings = testSettingsStore(suiteName: "StatusItemAnimationTests-credits-fallback")
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.menuBarDisplayMode = .percent
        settings.usageBarsShowUsed = false
        settings.setMenuBarMetricPreference(.secondary, for: .codex)

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        let remainingCredits = (snapshot.primary?.usedPercent ?? 0) * 4.5 + (snapshot.secondary?.usedPercent ?? 0) / 10
        store._setSnapshotForTesting(snapshot, provider: .codex)
        store._setErrorForTesting(nil, provider: .codex)
        store.credits = CreditsSnapshot(remaining: remainingCredits, events: [], updatedAt: Date())

        let displayText = controller.menuBarDisplayText(for: .codex, snapshot: snapshot)
        let expected = UsageFormatter
            .creditsString(from: remainingCredits)
            .replacingOccurrences(of: " left", with: "")

        #expect(displayText == expected)
    }

    @Test
    func `menu bar display text uses credits when codex session is exhausted`() {
        let settings = testSettingsStore(suiteName: "StatusItemAnimationTests-credits-fallback-session")
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.menuBarDisplayMode = .percent
        settings.usageBarsShowUsed = false
        settings.setMenuBarMetricPreference(.primary, for: .codex)

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 40, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        let remainingCredits = (snapshot.primary?.usedPercent ?? 0) - (snapshot.secondary?.usedPercent ?? 0) / 2
        store._setSnapshotForTesting(snapshot, provider: .codex)
        store._setErrorForTesting(nil, provider: .codex)
        store.credits = CreditsSnapshot(remaining: remainingCredits, events: [], updatedAt: Date())

        let displayText = controller.menuBarDisplayText(for: .codex, snapshot: snapshot)
        let expected = UsageFormatter
            .creditsString(from: remainingCredits)
            .replacingOccurrences(of: " left", with: "")

        #expect(displayText == expected)
    }

    @Test
    func `brand image with status overlay returns original image when no issue`() {
        let brand = NSImage(size: NSSize(width: 16, height: 16))
        brand.isTemplate = true

        let output = StatusItemController.brandImageWithStatusOverlay(brand: brand, statusIndicator: .none)

        #expect(output === brand)
    }

    @Test
    func `brand image with status overlay draws issue mark`() throws {
        let size = NSSize(width: 16, height: 16)
        let brand = NSImage(size: size)
        brand.lockFocus()
        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        brand.unlockFocus()
        brand.isTemplate = true

        let baselineData = try #require(brand.tiffRepresentation)
        let baselineRep = try #require(NSBitmapImageRep(data: baselineData))
        let baselineAlpha = self.maxAlpha(in: baselineRep)

        let output = StatusItemController.brandImageWithStatusOverlay(brand: brand, statusIndicator: .major)

        #expect(output !== brand)
        let outputData = try #require(output.tiffRepresentation)
        let outputRep = try #require(NSBitmapImageRep(data: outputData))
        let outputAlpha = self.maxAlpha(in: outputRep)
        #expect(baselineAlpha < 0.01)
        #expect(outputAlpha > 0.01)
    }
}
