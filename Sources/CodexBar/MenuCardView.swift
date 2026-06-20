import AppKit
import CodexBarCore
import SwiftUI

enum UsageMenuCardLayout {
    static let horizontalPadding: CGFloat = 20
    static let headerOnlyVerticalPadding: CGFloat = 7
    static let sectionTopPadding: CGFloat = 6
    static let sectionBottomPadding: CGFloat = 6
    static let headerLineSpacing: CGFloat = 4
    static let headerColumnSpacing: CGFloat = 12
}

/// SwiftUI card used inside the NSMenu to mirror Apple's rich menu panels.
struct UsageMenuCardView: View {
    struct Model {
        enum PercentStyle: String {
            case left
            case used

            var labelSuffix: String {
                switch self {
                case .left: L("usage_percent_suffix_left")
                case .used: L("usage_percent_suffix_used")
                }
            }

            var accessibilityLabel: String {
                switch self {
                case .left: L("Usage remaining")
                case .used: L("Usage used")
                }
            }
        }

        struct Metric: Identifiable {
            let id: String
            let title: String
            let percent: Double
            let percentStyle: PercentStyle
            let statusText: String?
            let resetText: String?
            let detailText: String?
            let detailLeftText: String?
            let detailRightText: String?
            let pacePercent: Double?
            let paceOnTop: Bool
            let warningMarkerPercents: [Double]
            let cardStyle: Bool

            init(
                id: String,
                title: String,
                percent: Double,
                percentStyle: PercentStyle,
                statusText: String? = nil,
                resetText: String?,
                detailText: String?,
                detailLeftText: String?,
                detailRightText: String?,
                pacePercent: Double?,
                paceOnTop: Bool,
                warningMarkerPercents: [Double] = [],
                cardStyle: Bool = false)
            {
                self.id = id
                self.title = title
                self.percent = percent
                self.percentStyle = percentStyle
                self.statusText = statusText
                self.resetText = resetText
                self.detailText = detailText
                self.detailLeftText = detailLeftText
                self.detailRightText = detailRightText
                self.pacePercent = pacePercent
                self.paceOnTop = paceOnTop
                self.warningMarkerPercents = warningMarkerPercents
                self.cardStyle = cardStyle
            }

            var percentLabel: String {
                String(format: "%.0f%% %@", self.percent, self.percentStyle.labelSuffix)
            }
        }

        enum SubtitleStyle {
            case info
            case loading
            case error
        }

        struct TokenUsageSection {
            let sessionLine: String
            let monthLine: String
            let hintLine: String?
            let errorLine: String?
            let errorCopyText: String?
        }

        struct ProviderCostSection {
            let title: String
            let percentUsed: Double?
            let spendLine: String
            let percentLine: String?
            var personalSpendLine: String?
        }

        let provider: UsageProvider
        let providerName: String
        let email: String
        let subtitleText: String
        let subtitleStyle: SubtitleStyle
        var usesLiveSubtitle: Bool = false
        let planText: String?
        let metrics: [Metric]
        let usageNotes: [String]
        let inlineUsageDashboard: InlineUsageDashboardModel?
        let creditsText: String?
        let creditsRemaining: Double?
        let creditsHintText: String?
        let creditsHintCopyText: String?
        var codexResetCreditsText: String?
        var codexResetCreditsDetailText: String?
        let providerCost: ProviderCostSection?
        let tokenUsage: TokenUsageSection?
        let placeholder: String?
        let progressColor: Color
    }

    let model: Model
    var layoutModel: Model?
    let width: CGFloat
    @Environment(\.menuItemHighlighted) private var isHighlighted
    @Environment(\.menuCardRefreshMonitor) private var refreshMonitor

    static func popupMetricTitle(provider: UsageProvider, metric: Model.Metric) -> String {
        metric.title
    }

    var body: some View {
        let liveModel = self.liveModel
        VStack(alignment: .leading, spacing: 6) {
            UsageMenuCardHeaderView(model: self.layoutModel ?? self.model)

            if self.hasDetails(model: liveModel) {
                Divider()
            }

            if !liveModel.usesStackedDetailLayout {
                if let dashboard = liveModel.inlineUsageDashboard {
                    InlineUsageDashboardContent(model: dashboard)
                } else if !liveModel.usageNotes.isEmpty {
                    UsageNotesContent(notes: liveModel.usageNotes)
                } else if let placeholder = liveModel.placeholder {
                    Text(placeholder)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .font(.subheadline)
                }
            } else {
                let hasUsage = liveModel.hasUsageContent
                let hasCredits = liveModel.creditsText != nil
                let hasProviderCost = liveModel.providerCost != nil
                let hasCost = liveModel.tokenUsage != nil || hasProviderCost

                VStack(alignment: .leading, spacing: 12) {
                    if hasUsage {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(liveModel.metrics, id: \.id) { metric in
                                MetricRow(
                                    metric: metric,
                                    title: Self.popupMetricTitle(provider: liveModel.provider, metric: metric),
                                    progressColor: liveModel.progressColor)
                            }
                            if let resetCredits = liveModel.codexResetCreditsText {
                                Divider()
                                CodexResetCreditsContent(
                                    text: resetCredits,
                                    detailText: liveModel.codexResetCreditsDetailText)
                            }
                            if let dashboard = liveModel.inlineUsageDashboard {
                                InlineUsageDashboardContent(model: dashboard)
                            } else if !liveModel.usageNotes.isEmpty {
                                UsageNotesContent(notes: liveModel.usageNotes)
                            } else if let placeholder = liveModel.placeholder {
                                Text(placeholder)
                                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                                    .font(.subheadline)
                            }
                        }
                    }
                    if hasUsage, hasCredits || hasCost {
                        Divider()
                    }
                    if let credits = liveModel.creditsText {
                        CreditsBarContent(
                            creditsText: credits,
                            creditsRemaining: liveModel.creditsRemaining,
                            hintText: liveModel.creditsHintText,
                            hintCopyText: liveModel.creditsHintCopyText,
                            progressColor: liveModel.progressColor)
                    }
                    if hasCredits, hasCost {
                        Divider()
                    }
                    if let providerCost = liveModel.providerCost {
                        ProviderCostContent(
                            section: providerCost,
                            progressColor: liveModel.progressColor)
                    }
                    if hasProviderCost, liveModel.tokenUsage != nil {
                        Divider()
                    }
                    if let tokenUsage = liveModel.tokenUsage {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L("cost_header_estimated"))
                                .font(.body)
                                .fontWeight(.medium)
                            Text(tokenUsage.sessionLine)
                                .font(.footnote)
                                .lineLimit(1)
                            Text(tokenUsage.monthLine)
                                .font(.footnote)
                                .lineLimit(1)
                            if let hint = tokenUsage.hintLine, !hint.isEmpty {
                                Text(hint)
                                    .font(.footnote)
                                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                                    .lineLimit(4)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let error = tokenUsage.errorLine, !error.isEmpty {
                                Text(error)
                                    .font(.footnote)
                                    .foregroundStyle(MenuHighlightStyle.error(self.isHighlighted))
                                    .lineLimit(4)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .overlay {
                                        ClickToCopyOverlay(copyText: tokenUsage.errorCopyText ?? error)
                                    }
                            }
                        }
                    }
                }
                .padding(.bottom, liveModel.creditsText == nil ? 6 : 0)
            }
        }
        .padding(.horizontal, UsageMenuCardLayout.horizontalPadding)
        .padding(
            .top,
            self.hasDetails(model: liveModel)
                ? UsageMenuCardLayout.sectionTopPadding
                : UsageMenuCardLayout.headerOnlyVerticalPadding)
        .padding(
            .bottom,
            self.hasDetails(model: liveModel)
                ? UsageMenuCardLayout.sectionBottomPadding
                : UsageMenuCardLayout.headerOnlyVerticalPadding)
        .frame(width: self.width, alignment: .leading)
    }

    private var liveModel: Model {
        guard self.model.usesLiveSubtitle else { return self.model }
        return self.refreshMonitor?.model(for: self.model.provider, fallback: self.model) ?? self.model
    }

    private func hasDetails(model: Model) -> Bool {
        model.hasUsageContent || model.usesStackedDetailLayout
    }
}

private struct UsageMenuCardHeaderView: View {
    let model: UsageMenuCardView.Model
    @Environment(\.menuItemHighlighted) private var isHighlighted
    @Environment(\.menuCardRefreshMonitor) private var refreshMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: UsageMenuCardLayout.headerLineSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: UsageMenuCardLayout.headerColumnSpacing) {
                Text(self.model.providerName).font(.headline)
                    .fontWeight(.semibold)
                    .lineLimit(1).truncationMode(.tail).layoutPriority(1)
                Spacer()
                Text(self.model.email).font(.subheadline)
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    .lineLimit(1).truncationMode(.middle)
            }
            let liveSubtitle = self.liveSubtitle
            // Keep the geometry AppKit measured for this hosted row. A new error stays one line
            // until the next rebuild; a recovered error keeps its reserved height until then.
            let usesErrorLayout = self.model.subtitleStyle == .error
            let subtitleAlignment: VerticalAlignment = usesErrorLayout ? .top : .firstTextBaseline
            HStack(alignment: subtitleAlignment, spacing: UsageMenuCardLayout.headerColumnSpacing) {
                if usesErrorLayout {
                    Text(self.model.subtitleText)
                        .font(.footnote)
                        .lineLimit(4)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 4)
                        .hidden()
                        .overlay(alignment: .topLeading) {
                            Text(liveSubtitle.text)
                                .font(.footnote)
                                .foregroundStyle(self.subtitleColor(for: liveSubtitle.style))
                                .lineLimit(4)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .clipped()
                        .layoutPriority(1)
                } else {
                    Text(liveSubtitle.text)
                        .font(.footnote)
                        .foregroundStyle(self.subtitleColor(for: liveSubtitle.style))
                        .lineLimit(1)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                }
                Spacer()
                if usesErrorLayout {
                    let showsCopyButton = liveSubtitle.style == .error && !liveSubtitle.text.isEmpty
                    CopyIconButton(copyText: liveSubtitle.text, isHighlighted: self.isHighlighted)
                        .opacity(showsCopyButton ? 1 : 0)
                        .allowsHitTesting(showsCopyButton)
                        .accessibilityHidden(!showsCopyButton)
                }
                if let plan = self.model.planText {
                    Text(plan)
                        .font(.footnote)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .lineLimit(1)
                }
            }
        }
    }

    private var liveSubtitle: MenuCardLiveSubtitle {
        let fallback = MenuCardLiveSubtitle(text: self.model.subtitleText, style: self.model.subtitleStyle)
        guard self.model.usesLiveSubtitle else { return fallback }
        return self.refreshMonitor?.subtitle(for: self.model.provider, fallback: fallback) ?? fallback
    }

    private func subtitleColor(for style: UsageMenuCardView.Model.SubtitleStyle) -> Color {
        switch style {
        case .info: MenuHighlightStyle.secondary(self.isHighlighted)
        case .loading: MenuHighlightStyle.secondary(self.isHighlighted)
        case .error: MenuHighlightStyle.error(self.isHighlighted)
        }
    }
}

private struct CopyIconButtonStyle: ButtonStyle {
    let isHighlighted: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(4)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(MenuHighlightStyle.secondary(self.isHighlighted).opacity(configuration.isPressed ? 0.18 : 0))
            }
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct CopyIconButton: View {
    let copyText: String
    let isHighlighted: Bool

    @State private var didCopy = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button {
            self.handleCopy()
        } label: {
            Image(systemName: self.didCopy ? "checkmark" : "doc.on.doc")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(CopyIconButtonStyle(isHighlighted: self.isHighlighted))
        .accessibilityLabel(self.didCopy ? L("Copied") : L("Copy error"))
    }

    private func handleCopy() {
        let text = self.copyText
        self.resetTask?.cancel()
        MenuPasteboardCopy.perform(text, completion: {
            self.didCopy = true
            self.resetTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.9))
                self.didCopy = false
            }
        })
    }
}

private struct ProviderCostContent: View {
    let section: UsageMenuCardView.Model.ProviderCostSection
    let progressColor: Color
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(self.section.title)
                .font(.body)
                .fontWeight(.medium)
            if let percentUsed = self.section.percentUsed {
                UsageProgressBar(
                    percent: percentUsed,
                    tint: self.progressColor,
                    accessibilityLabel: L("Extra usage spent"))
            }
            HStack(alignment: .firstTextBaseline) {
                Text(self.section.spendLine).font(.footnote).lineLimit(1)
                Spacer()
                if let percentLine = self.section.percentLine {
                    Text(percentLine)
                        .font(.footnote)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .lineLimit(1)
                }
            }
            if let personalSpendLine = self.section.personalSpendLine {
                Text(personalSpendLine)
                    .font(.footnote).foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted)).lineLimit(1)
            }
        }
    }
}

private struct MetricRow: View {
    let metric: UsageMenuCardView.Model.Metric
    let title: String
    let progressColor: Color
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(self.title)
                .font(.body)
                .fontWeight(.medium)
            if let statusText = self.metric.statusText {
                Text(statusText)
                    .font(.footnote)
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    .lineLimit(1)
            } else {
                UsageProgressBar(
                    percent: self.metric.percent,
                    tint: self.progressColor,
                    accessibilityLabel: self.metric.percentStyle.accessibilityLabel,
                    pacePercent: self.metric.pacePercent,
                    paceOnTop: self.metric.paceOnTop,
                    warningMarkerPercents: self.metric.warningMarkerPercents)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(self.metric.percentLabel)
                            .font(.footnote)
                            .lineLimit(1)
                        Spacer()
                        if let rightLabel = self.metric.resetText {
                            Text(rightLabel)
                                .font(.footnote)
                                .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                                .lineLimit(1)
                        }
                    }
                    if self.metric.detailLeftText != nil || self.metric.detailRightText != nil {
                        HStack(alignment: .firstTextBaseline) {
                            if let detailLeft = self.metric.detailLeftText {
                                Text(detailLeft)
                                    .font(.footnote)
                                    .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                                    .lineLimit(1)
                            }
                            Spacer()
                            if let detailRight = self.metric.detailRightText {
                                Text(detailRight)
                                    .font(.footnote)
                                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let detail = self.metric.detailText {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(self.metric.cardStyle ? 10 : 0)
        .background(self.metric.cardStyle ? Color.secondary.opacity(self.isHighlighted ? 0.2 : 0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: self.metric.cardStyle ? 10 : 0))
    }
}

private struct UsageNotesContent: View {
    let notes: [String]
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(self.notes.enumerated()), id: \.offset) { _, note in
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct UsageMenuCardHeaderSectionView: View {
    let model: UsageMenuCardView.Model
    let showDivider: Bool
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            UsageMenuCardHeaderView(model: self.model)

            if self.showDivider {
                Divider()
            }
        }
        .padding(.horizontal, UsageMenuCardLayout.horizontalPadding)
        .padding(.top, UsageMenuCardLayout.headerOnlyVerticalPadding)
        .padding(.bottom, self.headerBottomPadding)
        .frame(width: self.width, alignment: .leading)
    }

    private var headerBottomPadding: CGFloat {
        if self.model.subtitleStyle == .error {
            return UsageMenuCardLayout.sectionBottomPadding
        }
        return self.showDivider
            ? UsageMenuCardLayout.sectionBottomPadding
            : UsageMenuCardLayout.headerOnlyVerticalPadding
    }
}

struct UsageMenuCardUsageSectionView: View {
    let model: UsageMenuCardView.Model
    let showBottomDivider: Bool
    let bottomPadding: CGFloat
    let width: CGFloat
    @Environment(\.menuItemHighlighted) private var isHighlighted
    @Environment(\.menuCardRefreshMonitor) private var refreshMonitor

    var body: some View {
        let liveModel = self.liveModel
        VStack(alignment: .leading, spacing: 12) {
            ForEach(liveModel.metrics, id: \.id) { metric in
                MetricRow(
                    metric: metric,
                    title: UsageMenuCardView.popupMetricTitle(provider: liveModel.provider, metric: metric),
                    progressColor: liveModel.progressColor)
            }
            if let resetCredits = liveModel.codexResetCreditsText {
                if !liveModel.metrics.isEmpty {
                    Divider()
                }
                CodexResetCreditsContent(
                    text: resetCredits,
                    detailText: liveModel.codexResetCreditsDetailText)
            }
            if let dashboard = liveModel.inlineUsageDashboard {
                InlineUsageDashboardContent(model: dashboard)
            } else if !liveModel.usageNotes.isEmpty {
                UsageNotesContent(notes: liveModel.usageNotes)
            } else if let placeholder = liveModel.placeholder, liveModel.metrics.isEmpty,
                      liveModel.codexResetCreditsText == nil
            {
                Text(placeholder)
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    .font(.subheadline)
            }
            if self.showBottomDivider {
                Divider()
            }
        }
        .padding(.horizontal, UsageMenuCardLayout.horizontalPadding)
        .padding(.top, 10)
        .padding(.bottom, self.bottomPadding)
        .frame(width: self.width, alignment: .leading)
    }

    private var liveModel: UsageMenuCardView.Model {
        guard self.model.usesLiveSubtitle else { return self.model }
        return self.refreshMonitor?.model(for: self.model.provider, fallback: self.model) ?? self.model
    }
}

struct UsageMenuCardCreditsSectionView: View {
    let model: UsageMenuCardView.Model
    let showBottomDivider: Bool
    let topPadding: CGFloat
    let bottomPadding: CGFloat
    let width: CGFloat
    @Environment(\.menuCardRefreshMonitor) private var refreshMonitor

    var body: some View {
        let liveModel = self.liveModel
        if let credits = liveModel.creditsText {
            VStack(alignment: .leading, spacing: 6) {
                CreditsBarContent(
                    creditsText: credits,
                    creditsRemaining: liveModel.creditsRemaining,
                    hintText: liveModel.creditsHintText,
                    hintCopyText: liveModel.creditsHintCopyText,
                    progressColor: liveModel.progressColor)
                if self.showBottomDivider {
                    Divider()
                }
            }
            .padding(.horizontal, UsageMenuCardLayout.horizontalPadding)
            .padding(.top, self.topPadding)
            .padding(.bottom, self.bottomPadding)
            .frame(width: self.width, alignment: .leading)
        }
    }

    private var liveModel: UsageMenuCardView.Model {
        guard self.model.usesLiveSubtitle else { return self.model }
        return self.refreshMonitor?.model(for: self.model.provider, fallback: self.model) ?? self.model
    }
}

private struct CreditsBarContent: View {
    private static let fullScaleTokens: Double = 1000

    let creditsText: String
    let creditsRemaining: Double?
    let hintText: String?
    let hintCopyText: String?
    let progressColor: Color
    @Environment(\.menuItemHighlighted) private var isHighlighted

    private var percentLeft: Double? {
        guard let creditsRemaining else { return nil }
        let percent = (creditsRemaining / Self.fullScaleTokens) * 100
        return min(100, max(0, percent))
    }

    private var scaleText: String {
        let scale = UsageFormatter.tokenCountString(Int(Self.fullScaleTokens))
        return "\(scale) \(L("tokens"))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Credits"))
                .font(.body)
                .fontWeight(.medium)
            if let percentLeft {
                UsageProgressBar(
                    percent: percentLeft,
                    tint: self.progressColor,
                    accessibilityLabel: L("Credits remaining"))
                HStack(alignment: .firstTextBaseline) {
                    Text(self.creditsText)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                    Text(self.scaleText)
                        .font(.caption)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                }
            } else {
                Text(self.creditsText)
                    .font(.caption)
            }
            if let hintText, !hintText.isEmpty {
                Text(hintText)
                    .font(.footnote)
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .overlay {
                        ClickToCopyOverlay(copyText: self.hintCopyText ?? hintText)
                    }
            }
        }
    }
}

struct UsageMenuCardCostSectionView: View {
    let model: UsageMenuCardView.Model
    let topPadding: CGFloat
    let bottomPadding: CGFloat
    let width: CGFloat
    @Environment(\.menuItemHighlighted) private var isHighlighted
    @Environment(\.menuCardRefreshMonitor) private var refreshMonitor

    var body: some View {
        let liveModel = self.liveModel
        let hasTokenCost = liveModel.tokenUsage != nil
        return Group {
            if hasTokenCost {
                VStack(alignment: .leading, spacing: 10) {
                    if let tokenUsage = liveModel.tokenUsage {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L("cost_header_estimated"))
                                .font(.body)
                                .fontWeight(.medium)
                            Text(tokenUsage.sessionLine)
                                .font(.caption)
                                .lineLimit(1)
                            Text(tokenUsage.monthLine)
                                .font(.caption)
                                .lineLimit(1)
                            if let hint = tokenUsage.hintLine, !hint.isEmpty {
                                Text(hint)
                                    .font(.footnote)
                                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                                    .lineLimit(4)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let error = tokenUsage.errorLine, !error.isEmpty {
                                Text(error)
                                    .font(.footnote)
                                    .foregroundStyle(MenuHighlightStyle.error(self.isHighlighted))
                                    .lineLimit(4)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .overlay {
                                        ClickToCopyOverlay(copyText: tokenUsage.errorCopyText ?? error)
                                    }
                            }
                        }
                    }
                }
                .padding(.horizontal, UsageMenuCardLayout.horizontalPadding)
                .padding(.top, self.topPadding)
                .padding(.bottom, self.bottomPadding)
                .frame(width: self.width, alignment: .leading)
            }
        }
    }

    private var liveModel: UsageMenuCardView.Model {
        guard self.model.usesLiveSubtitle else { return self.model }
        return self.refreshMonitor?.model(for: self.model.provider, fallback: self.model) ?? self.model
    }
}

struct UsageMenuCardExtraUsageSectionView: View {
    let model: UsageMenuCardView.Model
    let topPadding: CGFloat
    let bottomPadding: CGFloat
    let width: CGFloat
    @Environment(\.menuCardRefreshMonitor) private var refreshMonitor

    var body: some View {
        let liveModel = self.liveModel
        Group {
            if let providerCost = liveModel.providerCost {
                ProviderCostContent(
                    section: providerCost,
                    progressColor: liveModel.progressColor)
                    .padding(.horizontal, UsageMenuCardLayout.horizontalPadding)
                    .padding(.top, self.topPadding)
                    .padding(.bottom, self.bottomPadding)
                    .frame(width: self.width, alignment: .leading)
            }
        }
    }

    private var liveModel: UsageMenuCardView.Model {
        guard self.model.usesLiveSubtitle else { return self.model }
        return self.refreshMonitor?.model(for: self.model.provider, fallback: self.model) ?? self.model
    }
}

// MARK: - Model factory

extension UsageMenuCardView.Model {
    struct Input {
        let provider: UsageProvider
        let metadata: ProviderMetadata
        let snapshot: UsageSnapshot?
        let codexProjection: CodexConsumerProjection?
        let credits: CreditsSnapshot?
        let creditsError: String?
        let dashboard: OpenAIDashboardSnapshot?
        let dashboardError: String?
        let tokenSnapshot: CostUsageTokenSnapshot?
        let tokenError: String?
        let account: AccountInfo
        let isRefreshing: Bool
        let lastError: String?
        let usageBarsShowUsed: Bool
        let resetTimeDisplayStyle: ResetTimeDisplayStyle
        let tokenCostUsageEnabled: Bool
        let showOptionalCreditsAndExtraUsage: Bool
        let copilotBudgetExtrasEnabled: Bool
        let sourceLabel: String?
        let kiloAutoMode: Bool
        let hidePersonalInfo: Bool
        let weeklyPace: UsagePace?
        let quotaWarningThresholds: [QuotaWarningWindow: [Int]]
        let workDaysPerWeek: Int?
        let usesLiveSubtitle: Bool
        let now: Date

        init(
            provider: UsageProvider,
            metadata: ProviderMetadata,
            snapshot: UsageSnapshot?,
            codexProjection: CodexConsumerProjection? = nil,
            credits: CreditsSnapshot?,
            creditsError: String?,
            dashboard: OpenAIDashboardSnapshot?,
            dashboardError: String?,
            tokenSnapshot: CostUsageTokenSnapshot?,
            tokenError: String?,
            account: AccountInfo,
            isRefreshing: Bool,
            lastError: String?,
            usageBarsShowUsed: Bool,
            resetTimeDisplayStyle: ResetTimeDisplayStyle,
            tokenCostUsageEnabled: Bool,
            showOptionalCreditsAndExtraUsage: Bool,
            copilotBudgetExtrasEnabled: Bool = false,
            sourceLabel: String? = nil,
            kiloAutoMode: Bool = false,
            hidePersonalInfo: Bool,
            weeklyPace: UsagePace? = nil,
            quotaWarningThresholds: [QuotaWarningWindow: [Int]] = [:],
            workDaysPerWeek: Int? = nil,
            usesLiveSubtitle: Bool = false,
            now: Date)
        {
            self.provider = provider
            self.metadata = metadata
            self.snapshot = snapshot
            self.codexProjection = codexProjection
            self.credits = credits
            self.creditsError = creditsError
            self.dashboard = dashboard
            self.dashboardError = dashboardError
            self.tokenSnapshot = tokenSnapshot
            self.tokenError = tokenError
            self.account = account
            self.isRefreshing = isRefreshing
            self.lastError = lastError
            self.usageBarsShowUsed = usageBarsShowUsed
            self.resetTimeDisplayStyle = resetTimeDisplayStyle
            self.tokenCostUsageEnabled = tokenCostUsageEnabled
            self.showOptionalCreditsAndExtraUsage = showOptionalCreditsAndExtraUsage
            self.copilotBudgetExtrasEnabled = copilotBudgetExtrasEnabled
            self.sourceLabel = sourceLabel
            self.kiloAutoMode = kiloAutoMode
            self.hidePersonalInfo = hidePersonalInfo
            self.weeklyPace = weeklyPace
            self.quotaWarningThresholds = quotaWarningThresholds
            self.workDaysPerWeek = workDaysPerWeek
            self.usesLiveSubtitle = usesLiveSubtitle
            self.now = now
        }
    }

    static func make(_ input: Input) -> UsageMenuCardView.Model {
        let planText = Self.plan(
            for: input.provider,
            snapshot: input.snapshot,
            account: input.account,
            metadata: input.metadata)
        let metrics = Self.redactedMetrics(
            Self.metrics(input: input),
            provider: input.provider,
            hidePersonalInfo: input.hidePersonalInfo)
        let inlineUsageDashboard = Self.inlineUsageDashboard(input: input)
        let usageNotes = Self.usageNotes(input: input)
        let rawCreditsText: String? = if input.codexProjection != nil, !input.showOptionalCreditsAndExtraUsage {
            nil
        } else {
            Self.creditsLine(
                metadata: input.metadata,
                snapshot: input.snapshot,
                credits: input.credits,
                error: input.creditsError)
        }
        let creditsText = PersonalInfoRedactor.redactEmails(in: rawCreditsText, isEnabled: input.hidePersonalInfo)
        let isClaudeAdminAPI = input.provider == .claude &&
            input.snapshot?.identity?.loginMethod == "Admin API"
        let hidesOptionalProviderCost = (input.provider == .claude && !isClaudeAdminAPI) &&
            !input.showOptionalCreditsAndExtraUsage
        let providerCost: ProviderCostSection? = if hidesOptionalProviderCost {
            nil
        } else {
            Self.providerCostSection(provider: input.provider, cost: input.snapshot?.providerCost)
        }
        let tokenUsageSnapshot = Self.tokenUsageSnapshot(input: input)
        let tokenUsage = Self.tokenUsageSection(
            provider: input.provider,
            enabled: input.tokenCostUsageEnabled,
            snapshot: tokenUsageSnapshot,
            error: input.tokenError)
        let subtitle = Self.subtitle(
            snapshot: input.snapshot,
            isRefreshing: input.isRefreshing,
            lastError: Self.lastError(input: input),
            now: input.now)
        let redacted = Self.redactedText(input: input, subtitle: subtitle)
        let placeholder = Self.placeholder(input: input)

        return UsageMenuCardView.Model(
            provider: input.provider,
            providerName: input.metadata.displayName,
            email: redacted.email,
            subtitleText: redacted.subtitleText,
            subtitleStyle: subtitle.style,
            usesLiveSubtitle: input.usesLiveSubtitle,
            planText: planText,
            metrics: metrics,
            usageNotes: usageNotes,
            inlineUsageDashboard: inlineUsageDashboard,
            creditsText: creditsText,
            creditsRemaining: input.credits?.remaining,
            creditsHintText: redacted.creditsHintText,
            creditsHintCopyText: redacted.creditsHintCopyText,
            codexResetCreditsText: Self.codexResetCreditsText(input: input),
            codexResetCreditsDetailText: Self.codexResetCreditsDetailText(input: input),
            providerCost: providerCost,
            tokenUsage: tokenUsage,
            placeholder: placeholder,
            progressColor: Self.progressColor(for: input.provider))
    }

    private static func usageNotes(input: Input) -> [String] {
        self.subscriptionMetadataNotes(snapshot: input.snapshot, provider: input.provider)
    }

    private static func email(
        for provider: UsageProvider,
        snapshot: UsageSnapshot?,
        account: AccountInfo,
        metadata: ProviderMetadata) -> String
    {
        if let email = snapshot?.accountEmail(for: provider), !email.isEmpty { return email }
        if metadata.usesAccountFallback,
           let email = account.email, !email.isEmpty
        {
            return email
        }
        return ""
    }

    private static func plan(
        for provider: UsageProvider,
        snapshot: UsageSnapshot?,
        account: AccountInfo,
        metadata: ProviderMetadata) -> String?
    {
        if let plan = snapshot?.loginMethod(for: provider), !plan.isEmpty {
            return self.planDisplay(plan, for: provider)
        }
        if metadata.usesAccountFallback,
           let plan = account.plan, !plan.isEmpty
        {
            return Self.planDisplay(plan, for: provider)
        }
        return nil
    }

    private static func planDisplay(_ text: String, for provider: UsageProvider) -> String {
        let cleaned = if provider == .codex {
            CodexPlanFormatting.displayName(text) ?? UsageFormatter.cleanPlanName(text)
        } else {
            UsageFormatter.cleanPlanName(text)
        }
        return cleaned.isEmpty ? text : cleaned
    }

    private static func subtitle(
        snapshot: UsageSnapshot?,
        isRefreshing: Bool,
        lastError: String?,
        now: Date) -> (text: String, style: SubtitleStyle)
    {
        if let lastError, !lastError.isEmpty {
            return (lastError.trimmingCharacters(in: .whitespacesAndNewlines), .error)
        }

        if isRefreshing {
            return ("\(L("Refreshing"))…", .loading)
        }

        if let updated = snapshot?.updatedAt {
            return (UsageFormatter.updatedString(from: updated, now: now), .info)
        }

        return (L("Not fetched yet"), .info)
    }

    private struct RedactedText {
        let email: String
        let subtitleText: String
        let creditsHintText: String?
        let creditsHintCopyText: String?
    }

    private static func redactedText(
        input: Input,
        subtitle: (text: String, style: SubtitleStyle)) -> RedactedText
    {
        let email = PersonalInfoRedactor.redactEmail(
            Self.email(
                for: input.provider,
                snapshot: input.snapshot,
                account: input.account,
                metadata: input.metadata),
            isEnabled: input.hidePersonalInfo)
        let subtitleText = PersonalInfoRedactor.redactEmails(in: subtitle.text, isEnabled: input.hidePersonalInfo)
            ?? subtitle.text
        let creditsHintText = PersonalInfoRedactor.redactEmails(
            in: Self.dashboardHint(error: input.dashboardError),
            isEnabled: input.hidePersonalInfo)
        let creditsHintCopyText = Self.creditsHintCopyText(
            dashboardError: input.dashboardError,
            hidePersonalInfo: input.hidePersonalInfo)
        return RedactedText(
            email: email,
            subtitleText: subtitleText,
            creditsHintText: creditsHintText,
            creditsHintCopyText: creditsHintCopyText)
    }

    private static func creditsHintCopyText(dashboardError: String?, hidePersonalInfo: Bool) -> String? {
        guard let dashboardError, !dashboardError.isEmpty else { return nil }
        return hidePersonalInfo ? "" : dashboardError
    }

    private static func metrics(input: Input) -> [Metric] {
        guard let snapshot = input.snapshot else { return [] }
        var metrics: [Metric] = []
        let percentStyle: PercentStyle = input.usageBarsShowUsed ? .used : .left
        let labels = Self.rateWindowLabels(input: input, snapshot: snapshot)
        if input.provider == .codex, let codexProjection = input.codexProjection {
            metrics.append(contentsOf: Self.codexRateMetrics(
                input: input,
                projection: codexProjection,
                percentStyle: percentStyle))
        } else if let primary = snapshot.primary {
            metrics.append(Self.primaryMetric(
                input: input,
                primary: primary,
                percentStyle: percentStyle,
                title: labels.primary))
        }
        if input.provider != .codex, let weekly = snapshot.secondary {
            metrics.append(Self.secondaryMetric(
                input: input,
                weekly: weekly,
                percentStyle: percentStyle,
                title: labels.secondary))
        }
        if labels.showsTertiary, let opus = snapshot.tertiary {
            let opusResetText = Self.resetText(for: opus, style: input.resetTimeDisplayStyle, now: input.now)
            metrics.append(Metric(
                id: "tertiary",
                title: labels.tertiary,
                percent: Self.clamped(input.usageBarsShowUsed ? opus.usedPercent : opus.remainingPercent),
                percentStyle: percentStyle,
                resetText: opusResetText,
                detailText: nil,
                detailLeftText: nil,
                detailRightText: nil,
                pacePercent: nil,
                paceOnTop: true,
                warningMarkerPercents: Self.warningMarkerPercents(
                    thresholds: input.quotaWarningThresholds[.weekly],
                    showUsed: input.usageBarsShowUsed)))
        }
        metrics.append(contentsOf: Self.extraRateWindowMetrics(
            snapshot: snapshot,
            input: input,
            percentStyle: percentStyle))

        if let codexProjection = input.codexProjection,
           codexProjection.supplementalMetrics.contains(.codeReview),
           let remaining = codexProjection.remainingPercent(for: .codeReview)
        {
            let percent = input.usageBarsShowUsed ? (100 - remaining) : remaining
            let resetText = codexProjection.limitWindow(for: .codeReview).flatMap {
                Self.resetText(for: $0, style: input.resetTimeDisplayStyle, now: input.now)
            }
            metrics.append(Metric(
                id: "code-review",
                title: L("Code review"),
                percent: Self.clamped(percent),
                percentStyle: percentStyle,
                resetText: resetText,
                detailText: nil,
                detailLeftText: nil,
                detailRightText: nil,
                pacePercent: nil,
                paceOnTop: true))
        }
        return metrics
    }

    private static func primaryMetric(
        input: Input,
        primary: RateWindow,
        percentStyle: PercentStyle,
        title: String? = nil) -> Metric
    {
        let primaryResetText = Self.resetText(for: primary, style: input.resetTimeDisplayStyle, now: input.now)
        var primaryDetailLeft: String?
        var primaryDetailRight: String?
        var primaryPacePercent: Double?
        var primaryPaceOnTop = true
        if let paceDetail = Self.sessionPaceDetail(
            provider: input.provider,
            window: primary,
            now: input.now,
            showUsed: input.usageBarsShowUsed)
        {
            primaryDetailLeft = paceDetail.leftLabel
            primaryDetailRight = paceDetail.rightLabel
            primaryPacePercent = paceDetail.pacePercent
            primaryPaceOnTop = paceDetail.paceOnTop
        }
        return Metric(
            id: "primary",
            title: title ?? L(input.metadata.sessionLabel),
            percent: Self.clamped(
                input.usageBarsShowUsed ? primary.usedPercent : primary.remainingPercent),
            percentStyle: percentStyle,
            statusText: nil,
            resetText: primaryResetText,
            detailText: nil,
            detailLeftText: primaryDetailLeft,
            detailRightText: primaryDetailRight,
            pacePercent: primaryPacePercent,
            paceOnTop: primaryPaceOnTop,
            warningMarkerPercents: Self.warningMarkerPercents(
                thresholds: input.quotaWarningThresholds[.session],
                showUsed: input.usageBarsShowUsed))
    }

    private static func secondaryMetric(
        input: Input,
        weekly: RateWindow,
        percentStyle: PercentStyle,
        title: String? = nil) -> Metric
    {
        let paceDetail = Self.weeklyPaceDetail(
            window: weekly,
            now: input.now,
            pace: input.weeklyPace,
            showUsed: input.usageBarsShowUsed)
        let weeklyResetText = Self.resetText(for: weekly, style: input.resetTimeDisplayStyle, now: input.now)
        return Metric(
            id: "secondary",
            title: title ?? L(input.metadata.weeklyLabel),
            percent: Self.clamped(input.usageBarsShowUsed ? weekly.usedPercent : weekly.remainingPercent),
            percentStyle: percentStyle,
            statusText: nil,
            resetText: weeklyResetText,
            detailText: nil,
            detailLeftText: paceDetail?.leftLabel,
            detailRightText: paceDetail?.rightLabel,
            pacePercent: paceDetail?.pacePercent,
            paceOnTop: paceDetail?.paceOnTop ?? true,
            warningMarkerPercents: Self.weeklyMarkerPercents(input: input, windowMinutes: weekly.windowMinutes))
    }

    private static func codexRateMetrics(
        input: Input,
        projection: CodexConsumerProjection,
        percentStyle: PercentStyle) -> [Metric]
    {
        projection.visibleRateLanes.compactMap { lane in
            guard let window = projection.rateWindow(for: lane) else { return nil }

            let title: String
            let id: String
            let paceDetail: PaceDetail?
            switch lane {
            case .session:
                title = L(input.metadata.sessionLabel)
                id = "primary"
                paceDetail = Self.sessionPaceDetail(
                    provider: input.provider,
                    window: window,
                    now: input.now,
                    showUsed: input.usageBarsShowUsed)
            case .weekly:
                title = L(input.metadata.weeklyLabel)
                id = "secondary"
                paceDetail = Self.weeklyPaceDetail(
                    window: window,
                    now: input.now,
                    pace: Self.standardWeeklyPace(input: input, window: window),
                    showUsed: input.usageBarsShowUsed)
            }

            return Metric(
                id: id,
                title: title,
                percent: Self.clamped(input.usageBarsShowUsed ? window.usedPercent : window.remainingPercent),
                percentStyle: percentStyle,
                resetText: Self.resetText(for: window, style: input.resetTimeDisplayStyle, now: input.now),
                detailText: nil,
                detailLeftText: paceDetail?.leftLabel,
                detailRightText: paceDetail?.rightLabel,
                pacePercent: paceDetail?.pacePercent,
                paceOnTop: paceDetail?.paceOnTop ?? true,
                warningMarkerPercents: Self.codexLaneMarkerPercents(
                    input: input,
                    lane: lane,
                    windowMinutes: window.windowMinutes))
        }
    }
}
