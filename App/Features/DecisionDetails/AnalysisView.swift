import SwiftUI
import Foundation
import RudderCore

/// For the user who wants to understand more. Evidence, inputs, assumptions and
/// boundaries — never the model's internal reasoning.
struct AnalysisView: View {
    let result: DecisionResult

    @State private var isChallenging = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RudderSpacing.xl) {
                whatYouToldMe
                criteria
                comparison
                whatCouldChangeTheResult
                challenge
                assumptions
                risks
                research
                conflicts
            }
            .screenPadding()
            .padding(.vertical, RudderSpacing.l)
        }
        .background(RudderColor.background)
        .navigationTitle("Analysis")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Sections

    private var whatYouToldMe: some View {
        VStack(alignment: .leading, spacing: RudderSpacing.s) {
            SectionHeader(title: "What you told me")
            RudderCard {
                VStack(alignment: .leading, spacing: RudderSpacing.s) {
                    Text(result.understanding.restatement)
                        .font(RudderFont.callout)
                        .foregroundStyle(RudderColor.primaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    if !result.understanding.knownContext.isEmpty {
                        bullets(title: "Context", items: result.understanding.knownContext)
                    }
                    if !result.understanding.whatMatters.isEmpty {
                        bullets(title: "What matters", items: result.understanding.whatMatters)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var criteria: some View {
        if !result.criteria.isEmpty {
            VStack(alignment: .leading, spacing: RudderSpacing.s) {
                SectionHeader(
                    title: "What I judged it on",
                    subtitle: "Ordered by how much weight I gave each one."
                )
                let weights = DecisionEngine.normalisedWeights(for: result.criteria)
                RudderCard {
                    VStack(alignment: .leading, spacing: RudderSpacing.m) {
                        ForEach(result.criteria.sorted { (weights[$0.id] ?? 0) > (weights[$1.id] ?? 0) }) { criterion in
                            VStack(alignment: .leading, spacing: RudderSpacing.xs) {
                                HStack {
                                    Text(criterion.name)
                                        .font(RudderFont.callout.weight(.medium))
                                        .foregroundStyle(RudderColor.primaryText)
                                    Spacer()
                                    Text(importanceLabel(for: weights[criterion.id] ?? 0))
                                        .font(RudderFont.caption)
                                        .foregroundStyle(RudderColor.secondaryText)
                                }
                                if let rationale = criterion.rationale, !rationale.isEmpty {
                                    Text(rationale)
                                        .font(RudderFont.footnote)
                                        .foregroundStyle(RudderColor.secondaryText)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var comparison: some View {
        if result.ranking.count > 1 {
            VStack(alignment: .leading, spacing: RudderSpacing.s) {
                SectionHeader(
                    title: "How the options compare",
                    subtitle: "My assessment based on the information available — not an objective score."
                )
                RudderCard {
                    VStack(alignment: .leading, spacing: RudderSpacing.m) {
                        ForEach(result.ranking) { scored in
                            OptionComparisonRow(
                                scored: scored,
                                option: result.option(withID: scored.optionID),
                                criteria: result.criteria,
                                isRecommended: scored.optionID == result.recommendedOptionID
                            )
                        }
                    }
                }

                if !result.eliminated.isEmpty {
                    RudderCard {
                        VStack(alignment: .leading, spacing: RudderSpacing.xs) {
                            Text("Ruled out")
                                .font(RudderFont.footnote.weight(.medium))
                                .foregroundStyle(RudderColor.tertiaryText)
                            ForEach(result.eliminated) { option in
                                Text("\(option.name) — \(option.failedConstraints.joined(separator: ", "))")
                                    .font(RudderFont.footnote)
                                    .foregroundStyle(RudderColor.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var whatCouldChangeTheResult: some View {
        if !result.stability.flips.isEmpty {
            VStack(alignment: .leading, spacing: RudderSpacing.s) {
                SectionHeader(
                    title: "What could change the result",
                    subtitle: "The boundaries of this recommendation."
                )
                RudderCard {
                    VStack(alignment: .leading, spacing: RudderSpacing.s) {
                        ForEach(result.stability.flips.prefix(4)) { flip in
                            HStack(alignment: .top, spacing: RudderSpacing.s) {
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.caption)
                                    .foregroundStyle(RudderColor.tertiaryText)
                                Text("\(flip.label), I'd point at \(flip.winnerName ?? "a different option").")
                                    .font(RudderFont.footnote)
                                    .foregroundStyle(RudderColor.primaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var challenge: some View {
        if let challenge = result.challenge {
            VStack(alignment: .leading, spacing: RudderSpacing.s) {
                SectionHeader(title: "Challenge this recommendation")
                RudderCard {
                    VStack(alignment: .leading, spacing: RudderSpacing.s) {
                        if isChallenging {
                            Text(challenge.strongestCaseAgainst)
                                .font(RudderFont.callout)
                                .foregroundStyle(RudderColor.primaryText)
                                .fixedSize(horizontal: false, vertical: true)

                            ForEach(challenge.additionalCounterpoints, id: \.self) { point in
                                Text("• \(point)")
                                    .font(RudderFont.footnote)
                                    .foregroundStyle(RudderColor.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            if challenge.didSwitchRecommendation {
                                InlineNotice(text: "This challenge already changed my recommendation once.")
                            }
                        } else {
                            Text("Try to convince me to choose the other option.")
                                .font(RudderFont.callout)
                                .foregroundStyle(RudderColor.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            SecondaryButton(title: "Make the case against") {
                                withAnimation { isChallenging = true }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var assumptions: some View {
        if !result.assumptions.isEmpty {
            VStack(alignment: .leading, spacing: RudderSpacing.s) {
                SectionHeader(title: "What I had to assume")
                RudderCard {
                    VStack(alignment: .leading, spacing: RudderSpacing.m) {
                        ForEach(result.assumptions) { assumption in
                            VStack(alignment: .leading, spacing: RudderSpacing.xs) {
                                Text(assumption.statement)
                                    .font(RudderFont.callout)
                                    .foregroundStyle(RudderColor.primaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                                if !assumption.impactIfWrong.isEmpty {
                                    Text("If that's wrong: \(assumption.impactIfWrong)")
                                        .font(RudderFont.footnote)
                                        .foregroundStyle(RudderColor.secondaryText)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var risks: some View {
        if !result.risks.isEmpty {
            VStack(alignment: .leading, spacing: RudderSpacing.s) {
                SectionHeader(title: "What could go wrong")
                RudderCard {
                    VStack(alignment: .leading, spacing: RudderSpacing.m) {
                        ForEach(result.risks) { risk in
                            VStack(alignment: .leading, spacing: RudderSpacing.xs) {
                                HStack(spacing: RudderSpacing.s) {
                                    Text(risk.title)
                                        .font(RudderFont.callout.weight(.medium))
                                        .foregroundStyle(RudderColor.primaryText)
                                    Text(severityLabel(risk.severity))
                                        .font(RudderFont.caption)
                                        .foregroundStyle(RudderColor.secondaryText)
                                }
                                Text(risk.detail)
                                    .font(RudderFont.footnote)
                                    .foregroundStyle(RudderColor.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var research: some View {
        if !result.research.isEmpty {
            VStack(alignment: .leading, spacing: RudderSpacing.s) {
                SectionHeader(
                    title: "What I checked",
                    subtitle: result.unverifiedResearch ? "I couldn't verify everything below." : nil
                )
                RudderCard {
                    VStack(alignment: .leading, spacing: RudderSpacing.m) {
                        ForEach(result.research) { finding in
                            ResearchRow(finding: finding)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var conflicts: some View {
        if !result.conflicts.isEmpty {
            VStack(alignment: .leading, spacing: RudderSpacing.s) {
                SectionHeader(title: "Where sources disagreed")
                RudderCard {
                    VStack(alignment: .leading, spacing: RudderSpacing.m) {
                        ForEach(result.conflicts) { conflict in
                            VStack(alignment: .leading, spacing: RudderSpacing.xs) {
                                Text(conflict.topic)
                                    .font(RudderFont.callout.weight(.medium))
                                    .foregroundStyle(RudderColor.primaryText)
                                Text(conflict.detail)
                                    .font(RudderFont.footnote)
                                    .foregroundStyle(RudderColor.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
    }

    // MARK: Helpers

    private func bullets(title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: RudderSpacing.xs) {
            Text(title)
                .font(RudderFont.footnote.weight(.medium))
                .foregroundStyle(RudderColor.tertiaryText)
            ForEach(items, id: \.self) { item in
                Text("• \(item)")
                    .font(RudderFont.footnote)
                    .foregroundStyle(RudderColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Words, not numbers: the user never has to read a weight.
    private func importanceLabel(for weight: Double) -> String {
        switch weight {
        case 0.35...: return "Decisive"
        case 0.2..<0.35: return "Important"
        case 0.1..<0.2: return "Worth weighing"
        default: return "Minor"
        }
    }

    private func severityLabel(_ severity: RiskSeverity) -> String {
        switch severity {
        case .low: return "Low"
        case .medium: return "Worth knowing"
        case .high: return "Serious"
        }
    }
}

private struct OptionComparisonRow: View {
    let scored: ScoredOption
    let option: DecisionOption?
    let criteria: [Criterion]
    let isRecommended: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: RudderSpacing.s) {
            HStack {
                Text(scored.name)
                    .font(RudderFont.callout.weight(.semibold))
                    .foregroundStyle(RudderColor.primaryText)
                if isRecommended {
                    Text("Recommended")
                        .font(RudderFont.caption)
                        .foregroundStyle(RudderColor.accent)
                }
                Spacer()
            }

            if let summary = option?.summary, !summary.isEmpty {
                Text(summary)
                    .font(RudderFont.footnote)
                    .foregroundStyle(RudderColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let option {
                VStack(spacing: RudderSpacing.xs) {
                    ForEach(criteria) { criterion in
                        HStack(spacing: RudderSpacing.s) {
                            Text(criterion.name)
                                .font(RudderFont.caption)
                                .foregroundStyle(RudderColor.secondaryText)
                                .frame(width: 110, alignment: .leading)
                            ScoreBar(value: option.score(for: criterion.id))
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(criterion.name): \(ScoreBar.label(for: option.score(for: criterion.id)))")
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// A relative indicator, not a score out of ten — and always paired with a
/// spoken label for VoiceOver.
private struct ScoreBar: View {
    let value: Double

    static func label(for value: Double) -> String {
        switch value {
        case 0.8...: return "Very strong"
        case 0.6..<0.8: return "Strong"
        case 0.4..<0.6: return "Middling"
        case 0.2..<0.4: return "Weak"
        default: return "Very weak"
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(RudderColor.surfaceRaised)
                Capsule()
                    .fill(RudderColor.accent.opacity(0.75))
                    .frame(width: max(4, proxy.size.width * value))
            }
        }
        .frame(height: 6)
    }
}

private struct ResearchRow: View {
    let finding: ResearchFinding

    var body: some View {
        VStack(alignment: .leading, spacing: RudderSpacing.xs) {
            Text(finding.claim)
                .font(RudderFont.footnote)
                .foregroundStyle(RudderColor.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: RudderSpacing.s) {
                if let url = finding.sourceURL {
                    Link(destination: url) {
                        Text(finding.sourceTitle ?? url.host() ?? "Source")
                            .font(RudderFont.caption)
                            .underline()
                    }
                    .frame(minHeight: RudderSpacing.minimumTouchTarget * 0.7)
                } else if let title = finding.sourceTitle {
                    Text(title)
                        .font(RudderFont.caption)
                        .foregroundStyle(RudderColor.secondaryText)
                }

                if let retrievedAt = finding.retrievedAt {
                    Text("Checked \(retrievedAt.formatted(.dateTime.month(.abbreviated).day().year()))")
                        .font(RudderFont.caption)
                        .foregroundStyle(RudderColor.tertiaryText)
                }

                if finding.unverified {
                    Text("Unverified")
                        .font(RudderFont.caption)
                        .foregroundStyle(RudderColor.moderate)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
