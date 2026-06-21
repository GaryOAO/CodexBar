import CodexBarCore
import SwiftUI

struct InlineUsageDashboardModel: Equatable {
    struct KPI: Equatable {
        let title: String
        let value: String
        let emphasis: Bool
    }

    struct Point: Equatable, Identifiable {
        let id: String
        let label: String
        let value: Double
        let accessibilityValue: String
    }

    enum ValueStyle: Equatable {
        case currencyUSD
        case currency(symbol: String)
        case tokens
        case points
    }

    let accessibilityLabel: String
    let valueStyle: ValueStyle
    let kpis: [KPI]
    let points: [Point]
    let detailLines: [String]
    /// Provider branding color used to fill the mini usage bars. When nil the bars fall back to a
    /// neutral palette derived from `valueStyle`.
    var barColor: Color?
}

extension UsageMenuCardView.Model {
    static func apiProviderUsageNotes(input: Input) -> [String]? {
        nil
    }

    static func inlineUsageDashboard(input: Input) -> InlineUsageDashboardModel? {
        guard var model = self.resolveInlineUsageDashboard(input: input) else { return nil }
        model.barColor = Self.inlineDashboardBarColor(for: input.provider)
        return model
    }

    /// Provider branding color for the inline usage bars, matching the provider's switcher tab and
    /// detailed cost-history chart.
    static func inlineDashboardBarColor(for provider: UsageProvider) -> Color {
        let color = ProviderDescriptorRegistry.descriptor(for: provider).branding.color
        return Color(red: color.red, green: color.green, blue: color.blue)
    }

    private static func resolveInlineUsageDashboard(input: Input) -> InlineUsageDashboardModel? {
        if self.usesProviderCostHistoryAsPrimaryDashboard(input.provider),
           let tokenSnapshot = primaryCostHistorySnapshot(input: input),
           !tokenSnapshot.daily.isEmpty
        {
            return self.costHistoryInlineDashboard(provider: input.provider, snapshot: tokenSnapshot)
        }
        if input.provider == .claude,
           let usage = input.snapshot?.claudeAdminAPIUsage
        {
            return Self.claudeAdminAPIInlineDashboard(usage)
        }
        if [.codex, .claude].contains(input.provider),
           input.tokenCostUsageEnabled,
           let tokenSnapshot = input.tokenSnapshot,
           !tokenSnapshot.daily.isEmpty
        {
            return Self.costHistoryInlineDashboard(provider: input.provider, snapshot: tokenSnapshot)
        }
        return nil
    }

    static func usesProviderCostHistoryAsPrimaryDashboard(_ provider: UsageProvider) -> Bool {
        false
    }

    static func primaryCostHistorySnapshot(input: Input) -> CostUsageTokenSnapshot? {
        input.tokenSnapshot
    }

    private static func costHistoryInlineDashboard(
        provider: UsageProvider,
        snapshot: CostUsageTokenSnapshot) -> InlineUsageDashboardModel
    {
        let historyDays = max(1, min(365, snapshot.historyDays))
        let historyTitle = snapshot.historyLabel
            ?? (historyDays == 1
                ? L("Today")
                : historyDays == 30
                ? L("30d cost")
                : "\(String(format: L("Last %d days"), historyDays)) \(L("Cost"))")
        let tokenHistoryTitle = snapshot.historyLabel.map { "\($0) \(L("tokens"))" }
            ?? (historyDays == 1
                ? L("Today tokens")
                : historyDays == 30
                ? L("30d tokens")
                : String(format: L("%@ tokens"), String(format: L("Last %d days"), historyDays)))
        let requestHistoryTitle = snapshot.historyLabel.map { "\($0) \(L("requests"))" }
            ?? (historyDays == 1
                ? L("Today requests")
                : historyDays == 30
                ? L("30d requests")
                : String(format: L("%@ requests"), String(format: L("Last %d days"), historyDays)))
        let periodLabel = snapshot.historyLabel?.lowercased()
            ?? (historyDays == 1 ? "today" : "\(historyDays) day")
        let points = snapshot.daily.suffix(historyDays).compactMap { entry -> InlineUsageDashboardModel.Point? in
            guard let cost = entry.costUSD else { return nil }
            return InlineUsageDashboardModel.Point(
                id: entry.date,
                label: Self.shortDayLabel(entry.date),
                value: cost,
                accessibilityValue: "\(entry.date): \(Self.costString(cost, currencyCode: snapshot.currencyCode))")
        }
        let latest = snapshot.daily.max { lhs, rhs in lhs.date < rhs.date }
        var details: [String] = []
        if let topModel = Self.topCostModel(from: snapshot.daily) {
            details.append("\(L("Top model")): \(Self.shortModelName(topModel))")
        }
        if let requestCount = snapshot.last30DaysRequests {
            details.append("\(requestHistoryTitle): \(UsageFormatter.tokenCountString(requestCount)) \(L("requests"))")
        }
        if let hint = Self.tokenUsageHint(provider: provider) {
            details.append(hint)
        } else {
            details.append(L("cost_estimate_hint"))
        }
        let providerName = ProviderDefaults.metadata[provider]?.displayName ?? provider.rawValue
        return InlineUsageDashboardModel(
            accessibilityLabel: "\(providerName) \(periodLabel) cost trend",
            valueStyle: Self.costValueStyle(currencyCode: snapshot.currencyCode),
            kpis: [
                .init(
                    title: L("Today"),
                    value: latest?.costUSD.map { Self.costString($0, currencyCode: snapshot.currencyCode) } ?? "—",
                    emphasis: true),
                .init(
                    title: historyTitle,
                    value: snapshot.last30DaysCostUSD
                        .map { Self.costString($0, currencyCode: snapshot.currencyCode) } ?? "—",
                    emphasis: false),
                .init(
                    title: tokenHistoryTitle,
                    value: snapshot.last30DaysTokens.map(UsageFormatter.tokenCountString) ?? "—",
                    emphasis: false),
            ] + Self.costHistoryTrailingKPIs(snapshot: snapshot, latest: latest),
            points: points,
            detailLines: details)
    }

    private static func costHistoryTrailingKPIs(
        snapshot: CostUsageTokenSnapshot,
        latest: CostUsageDailyReport.Entry?)
        -> [InlineUsageDashboardModel.KPI]
    {
        if let requests = snapshot.last30DaysRequests {
            return [
                .init(
                    title: L("Requests"),
                    value: UsageFormatter.tokenCountString(requests),
                    emphasis: false),
            ]
        }
        return [
            .init(
                title: L("Latest tokens"),
                value: latest?.totalTokens.map(UsageFormatter.tokenCountString) ?? "—",
                emphasis: false),
        ]
    }

    fileprivate static func claudeAdminAPIInlineDashboard(_ usage: ClaudeAdminAPIUsageSnapshot)
        -> InlineUsageDashboardModel
    {
        let today = usage.latestDay
        let last7 = usage.last7Days
        let last30 = usage.last30Days
        let points = usage.daily.suffix(30).map {
            InlineUsageDashboardModel.Point(
                id: $0.day,
                label: Self.shortDayLabel($0.day),
                value: $0.costUSD,
                accessibilityValue: "\($0.day): \(UsageFormatter.usdString($0.costUSD))")
        }
        var details = [
            "30d: \(UsageFormatter.tokenCountString(last30.totalTokens)) \(L("tokens"))",
            "\(L("Cache read")): \(UsageFormatter.tokenCountString(last30.cacheReadInputTokens)) \(L("tokens"))",
        ]
        if let topModel = usage.topModels.first {
            details.append("\(L("Top model")): \(Self.shortModelName(topModel.name))")
        }
        return InlineUsageDashboardModel(
            accessibilityLabel: L("Claude Admin API 30 day spend trend"),
            valueStyle: .currencyUSD,
            kpis: [
                .init(title: L("Today"), value: UsageFormatter.usdString(today.costUSD), emphasis: true),
                .init(title: L("7d spend"), value: UsageFormatter.usdString(last7.costUSD), emphasis: false),
                .init(
                    title: L("30d spend"),
                    value: UsageFormatter.usdString(last30.costUSD),
                    emphasis: false),
                .init(
                    title: L("Today tokens"),
                    value: UsageFormatter.tokenCountString(today.totalTokens),
                    emphasis: false),
            ],
            points: points,
            detailLines: details)
    }

    private static func costString(_ value: Double, currencyCode: String) -> String {
        UsageFormatter.currencyString(value, currencyCode: currencyCode)
    }

    private static func costValueStyle(currencyCode: String) -> InlineUsageDashboardModel.ValueStyle {
        if currencyCode == "USD" { return .currencyUSD }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        formatter.locale = Locale(identifier: "en_US")
        let symbol = formatter.currencySymbol ?? currencyCode
        return .currency(symbol: symbol)
    }

    private static func shortDayLabel(_ day: String) -> String {
        let pieces = day.split(separator: "-")
        guard pieces.count == 3, let rawDay = Int(pieces[2]) else { return day }
        return "\(rawDay)"
    }

    private static func shortModelName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 26 else { return trimmed }
        return String(trimmed.prefix(25)) + "…"
    }

    private static func topCostModel(from entries: [CostUsageDailyReport.Entry]) -> String? {
        var scores: [String: (cost: Double, tokens: Int)] = [:]
        for entry in entries {
            for model in entry.modelBreakdowns ?? [] {
                var score = scores[model.modelName] ?? (0, 0)
                score.cost += model.costUSD ?? 0
                score.tokens += model.totalTokens ?? 0
                scores[model.modelName] = score
            }
        }
        return scores.max {
            if $0.value.cost == $1.value.cost { return $0.value.tokens < $1.value.tokens }
            return $0.value.cost < $1.value.cost
        }?.key
    }
}

struct InlineUsageDashboardContent: View {
    private let model: InlineUsageDashboardModel
    @Environment(\.menuItemHighlighted) private var isHighlighted

    init(model: InlineUsageDashboardModel) {
        self.model = model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            self.kpis
            MiniUsageBars(model: self.model)
                .frame(height: 58)
                .accessibilityLabel(self.model.accessibilityLabel)
            self.detailLines
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var kpis: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(minimum: 118), alignment: .leading),
                GridItem(.flexible(minimum: 100), alignment: .leading),
            ],
            alignment: .leading,
            spacing: 6)
        {
            ForEach(Array(self.model.kpis.enumerated()), id: \.offset) { _, kpi in
                KPIBlock(title: kpi.title, value: kpi.value, emphasis: kpi.emphasis)
            }
        }
    }

    private var detailLines: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(self.model.detailLines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    .lineLimit(1)
            }
        }
    }

    private struct KPIBlock: View {
        let title: String
        let value: String
        let emphasis: Bool
        @Environment(\.menuItemHighlighted) private var isHighlighted

        var body: some View {
            VStack(alignment: .leading, spacing: 1) {
                Text(self.title)
                    .font(.caption2)
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    .lineLimit(1)
                Text(self.value)
                    .font(self.emphasis ? .headline : .subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private struct MiniUsageBars: View {
        let model: InlineUsageDashboardModel
        @Environment(\.menuItemHighlighted) private var isHighlighted

        var body: some View {
            let maxValue = max(self.model.points.map(\.value).max() ?? 0, 1)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(self.model.points) { point in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(self.fill(for: point, maxValue: maxValue))
                        .frame(maxWidth: .infinity)
                        .frame(height: self.height(for: point, maxValue: maxValue))
                        .accessibilityLabel(point.accessibilityValue)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .overlay(alignment: .bottomLeading) {
                Rectangle()
                    .fill(MenuHighlightStyle.secondary(self.isHighlighted).opacity(0.22))
                    .frame(height: 1)
            }
        }

        private func height(for point: InlineUsageDashboardModel.Point, maxValue: Double) -> CGFloat {
            let ratio = point.value / maxValue
            guard ratio > 0 else { return 1 }
            return CGFloat(max(3, min(58, ratio * 58)))
        }

        private func fill(for point: InlineUsageDashboardModel.Point, maxValue: Double) -> Color {
            let ratio = max(0.18, min(1, point.value / maxValue))
            if self.isHighlighted {
                return Color.white.opacity(0.55 + ratio * 0.35)
            }
            return self.baseColor.opacity(0.42 + ratio * 0.58)
        }

        private var baseColor: Color {
            if let barColor = self.model.barColor {
                return barColor
            }
            switch self.model.valueStyle {
            case .currencyUSD, .currency:
                return Color(red: 0.81, green: 0.56, blue: 0.24)
            case .tokens:
                return Color(red: 0.48, green: 0.41, blue: 0.86)
            case .points:
                return Color(red: 0.16, green: 0.62, blue: 0.36)
            }
        }
    }
}
