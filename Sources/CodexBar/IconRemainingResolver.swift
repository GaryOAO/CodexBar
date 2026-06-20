import CodexBarCore

enum IconRemainingResolver {
    private static func codexProjection(snapshot: UsageSnapshot) -> CodexConsumerProjection {
        CodexConsumerProjection.make(
            surface: .menuBar,
            context: CodexConsumerProjection.Context(
                snapshot: snapshot,
                rawUsageError: nil,
                liveCredits: nil,
                rawCreditsError: nil,
                liveDashboard: nil,
                rawDashboardError: nil,
                dashboardAttachmentAuthorized: false,
                dashboardRequiresLogin: false,
                now: snapshot.updatedAt))
    }

    private static func codexVisibleWindows(snapshot: UsageSnapshot) -> [RateWindow] {
        let projection = self.codexProjection(snapshot: snapshot)
        return projection.visibleRateLanes.compactMap { projection.rateWindow(for: $0) }
    }

    static func resolvedWindows(
        snapshot: UsageSnapshot,
        style: IconStyle,
        secondaryOverrideWindowID: String? = nil)
        -> (primary: RateWindow?, secondary: RateWindow?)
    {
        if style == .codex {
            let windows = self.codexVisibleWindows(snapshot: snapshot)
            return (
                primary: windows.first,
                secondary: windows.dropFirst().first)
        }
        return (
            primary: snapshot.primary,
            secondary: snapshot.secondary)
    }

    static func resolvedRemaining(
        snapshot: UsageSnapshot,
        style: IconStyle,
        secondaryOverrideWindowID: String? = nil)
        -> (primary: Double?, secondary: Double?)
    {
        let windows = self.resolvedWindows(
            snapshot: snapshot,
            style: style,
            secondaryOverrideWindowID: secondaryOverrideWindowID)
        return (
            primary: windows.primary?.remainingPercent,
            secondary: windows.secondary?.remainingPercent)
    }

    static func resolvedPercents(
        snapshot: UsageSnapshot,
        style: IconStyle,
        showUsed: Bool,
        renderingStyle: IconStyle? = nil,
        secondaryOverrideWindowID: String? = nil)
        -> (primary: Double?, secondary: Double?)
    {
        let windows = Self.resolvedWindows(
            snapshot: snapshot,
            style: style,
            secondaryOverrideWindowID: secondaryOverrideWindowID)
        let percents = (
            primary: showUsed ? windows.primary?.usedPercent : windows.primary?.remainingPercent,
            secondary: showUsed ? windows.secondary?.usedPercent : windows.secondary?.remainingPercent)
        return percents
    }
}
