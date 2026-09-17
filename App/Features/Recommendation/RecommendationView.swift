import SwiftUI
import Foundation
import RudderCore

/// The answer first. Everything that explains it lives behind "See analysis".
struct RecommendationView: View {
    let result: DecisionResult
    var chosenOptionID: String?
    let onChoose: (String) -> Void
    let onDone: () -> Void

    @Environment(AppEnvironment.self) private var environment

    private enum Presentation: Identifiable {
        case otherOptions
        case analysis
        var id: Self { self }
    }

    @State private var presentation: Presentation?

    private var hasChosen: Bool { chosenOptionID != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RudderSpacing.l) {
                if hasChosen, let chosenID = chosenOptionID {
                    ChoiceConfirmation(result: result, chosenOptionID: chosenID)
                } else if result.strength == .unclear && result.ranking.count > 1 {
                    NoClearWinnerSection(result: result, onChoose: onChoose)
                } else if let recommended = result.recommendedOption {
                    recommendation(for: recommended)
                } else {
                    EmptyStateView(
                        title: "I couldn't land on a recommendation.",
                        message: "There wasn't enough here for me to stand behind one.",
                        systemImage: "questionmark.circle"
                    )
                }
            }
            .screenPadding()
            .padding(.top, RudderSpacing.m)
            .padding(.bottom, RudderSpacing.xxl)
        }
        .safeAreaInset(edge: .bottom) {
            bottomAction
        }
        .sheet(item: $presentation) { item in
            switch item {
            case .otherOptions:
                OtherOptionsSheet(result: result) { optionID in
                    presentation = nil
                    onChoose(optionID)
                }
            case .analysis:
                NavigationStack {
                    AnalysisView(result: result)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { presentation = nil }
                            }
                        }
                }
            }
        }
    }

    @ViewBuilder
    private var bottomAction: some View {
        VStack(spacing: RudderSpacing.s) {
            if hasChosen {
                PrimaryButton(title: "Done", identifier: RudderID.doneWithDecision, action: onDone)
            } else if let recommended = result.recommendedOption, result.strength != .unclear {
                // Never "accept". The user is not approving RUDDER's decision.
                PrimaryButton(title: "Make my decision", identifier: RudderID.makeDecision) {
                    onChoose(recommended.id)
                }
                // Lived inside the ScrollView content before; a confirmed
                // isHittable, real tap() on it there never fired its action,
                // in CI, on either device, across five different presentation
                // mechanisms (NavigationLink, navigationDestination, two
                // sheet variants). "Choose something else" right below --
                // built the same way, always in this fixed bar -- fires
                // reliably every time. Moving "See analysis" into the same
                // fixed bar removes the one variable every other fix left
                // unchanged: being inside the scrollable content.
                Button {
                    presentation = .analysis
                } label: {
                    HStack {
                        Text("See analysis")
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                    }
                    .font(RudderFont.footnote)
                    .frame(minHeight: RudderSpacing.minimumTouchTarget)
                }
                .accessibilityHint("Criteria, comparison, assumptions, risks and sources")
                if result.ranking.count > 1 {
                    Button("Choose something else") { presentation = .otherOptions }
                        .font(RudderFont.footnote)
                        .frame(minHeight: RudderSpacing.minimumTouchTarget)
                        .accessibilityIdentifier(RudderID.chooseSomethingElse)
                }
            }
        }
        .screenPadding()
        .padding(.vertical, RudderSpacing.s)
        .background(.bar)
    }

    @ViewBuilder
    private func recommendation(for option: DecisionOption) -> some View {
        VStack(alignment: .leading, spacing: RudderSpacing.l) {
            VStack(alignment: .leading, spacing: RudderSpacing.xs) {
                Text("MY RECOMMENDATION")
                    .font(RudderFont.monoLabel)
                    .foregroundStyle(RudderColor.tertiaryText)
                    .accessibilityHidden(true)
                Text(option.name)
                    .font(RudderFont.display)
                    .foregroundStyle(RudderColor.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(result.headline.isEmpty ? "Best fit for you" : result.headline)
                    .font(RudderFont.callout)
                    .foregroundStyle(RudderColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("My recommendation: \(option.name). \(result.headline)")

            if let remembered = MemoryEngine.relevantEntries(for: result, in: environment.memory).first {
                InlineNotice(text: "Using what I've learned about you: \(remembered.statement)")
            }

            if !result.reasons.isEmpty {
                VStack(alignment: .leading, spacing: RudderSpacing.m) {
                    SectionHeader(title: "Why it fits you")
                    ForEach(Array(result.reasons.prefix(3).enumerated()), id: \.element.id) { index, reason in
                        NumberedRow(index: index + 1, title: reason.title, detail: reason.detail)
                    }
                }
            }

            if let tradeOff = result.tradeOffs.first {
                RudderCard {
                    VStack(alignment: .leading, spacing: RudderSpacing.xs) {
                        Text("The trade-off")
                            .font(RudderFont.footnote.weight(.medium))
                            .foregroundStyle(RudderColor.tertiaryText)
                        Text("You're giving up \(tradeOff.givingUp.lowercasedFirst) to get \(tradeOff.gaining.lowercasedFirst).")
                            .font(RudderFont.callout)
                            .foregroundStyle(RudderColor.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }

            RudderCard {
                VStack(alignment: .leading, spacing: RudderSpacing.s) {
                    Text("Decision strength")
                        .font(RudderFont.footnote.weight(.medium))
                        .foregroundStyle(RudderColor.tertiaryText)
                    StrengthBadge(strength: result.strength, showsExplanation: true)
                }
            }

            if let challenge = result.challenge {
                RudderCard {
                    VStack(alignment: .leading, spacing: RudderSpacing.s) {
                        Text("What could make me wrong?")
                            .font(RudderFont.footnote.weight(.medium))
                            .foregroundStyle(RudderColor.tertiaryText)
                        Text(challenge.strongestCaseAgainst)
                            .font(RudderFont.callout)
                            .foregroundStyle(RudderColor.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }

            if result.unverifiedResearch {
                InlineNotice(
                    text: "I couldn't verify some of the information I used. The analysis shows what I checked.",
                    kind: .warning
                )
            }
        }
    }
}

// MARK: - No clear winner

private struct NoClearWinnerSection: View {
    let result: DecisionResult
    let onChoose: (String) -> Void

    @State private var showingConditionalPick = false

    private var topTwo: [DecisionOption] {
        result.ranking.prefix(2).compactMap { scored in
            result.options.first { $0.id == scored.optionID }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RudderSpacing.l) {
            VStack(alignment: .leading, spacing: RudderSpacing.s) {
                Text("There isn't a clear winner")
                    .font(RudderFont.display)
                    .foregroundStyle(RudderColor.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Each of these is better at something different, and neither stays ahead when your priorities shift.")
                    .font(RudderFont.callout)
                    .foregroundStyle(RudderColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)

            ForEach(topTwo) { option in
                RudderCard {
                    VStack(alignment: .leading, spacing: RudderSpacing.s) {
                        Text(option.name)
                            .font(RudderFont.headline)
                            .foregroundStyle(RudderColor.primaryText)
                        if let strengths = bestCriteria(for: option), !strengths.isEmpty {
                            Text("Choose it if \(strengths) matters most.")
                                .font(RudderFont.callout)
                                .foregroundStyle(RudderColor.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        SecondaryButton(title: "Choose \(option.name)") { onChoose(option.id) }
                    }
                }
            }

            RudderCard {
                VStack(alignment: .leading, spacing: RudderSpacing.s) {
                    StrengthBadge(strength: .unclear, showsExplanation: true)
                    if let leading = result.recommendedOption {
                        if showingConditionalPick {
                            Text("If you want me to break the tie: \(leading.name), by a margin small enough that I wouldn't defend it.")
                                .font(RudderFont.callout)
                                .foregroundStyle(RudderColor.primaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            SecondaryButton(title: "Choose \(leading.name)") { onChoose(leading.id) }
                        } else {
                            Button("Choose for me anyway") { showingConditionalPick = true }
                                .font(RudderFont.footnote)
                                .frame(minHeight: RudderSpacing.minimumTouchTarget)
                        }
                    }
                }
            }
        }
    }

    /// The criteria this option is genuinely better at than the alternative.
    private func bestCriteria(for option: DecisionOption) -> String? {
        guard let other = topTwo.first(where: { $0.id != option.id }) else { return nil }
        let names = result.criteria
            .filter { option.score(for: $0.id) - other.score(for: $0.id) > 0.1 }
            .sorted { $0.weight > $1.weight }
            .prefix(2)
            .map { $0.name.lowercased() }
        guard !names.isEmpty else { return nil }
        return names.joined(separator: " and ")
    }
}

// MARK: - Choosing something else

private struct OtherOptionsSheet: View {
    let result: DecisionResult
    let onChoose: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: RudderSpacing.s) {
                    ForEach(result.ranking) { scored in
                        Button {
                            onChoose(scored.optionID)
                        } label: {
                            RudderCard {
                                HStack {
                                    VStack(alignment: .leading, spacing: RudderSpacing.xs) {
                                        Text(scored.name)
                                            .font(RudderFont.callout.weight(.semibold))
                                            .foregroundStyle(RudderColor.primaryText)
                                        if scored.optionID == result.recommendedOptionID {
                                            Text("My recommendation")
                                                .font(RudderFont.caption)
                                                .foregroundStyle(RudderColor.secondaryText)
                                        }
                                    }
                                    Spacer(minLength: RudderSpacing.s)
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(RudderColor.tertiaryText)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(RudderID.optionRow(scored.optionID))
                    }

                    if !result.eliminated.isEmpty {
                        VStack(alignment: .leading, spacing: RudderSpacing.xs) {
                            Text("Ruled out by your requirements")
                                .font(RudderFont.footnote.weight(.medium))
                                .foregroundStyle(RudderColor.tertiaryText)
                            ForEach(result.eliminated) { option in
                                Text("\(option.name) — \(option.failedConstraints.joined(separator: ", "))")
                                    .font(RudderFont.footnote)
                                    .foregroundStyle(RudderColor.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, RudderSpacing.m)
                    }
                }
                .screenPadding()
                .padding(.vertical, RudderSpacing.m)
            }
            .background(RudderColor.background)
            .navigationTitle("Your options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - After the choice

/// No arguing, no "are you sure?". What they gain, what they give up, and it's theirs.
private struct ChoiceConfirmation: View {
    let result: DecisionResult
    let chosenOptionID: String

    private var chosen: DecisionOption? { result.option(withID: chosenOptionID) }
    private var alternative: DecisionOption? {
        guard let recommended = result.recommendedOptionID, recommended != chosenOptionID else {
            return result.ranking.first { $0.optionID != chosenOptionID }
                .flatMap { scored in result.options.first { $0.id == scored.optionID } }
        }
        return result.option(withID: recommended)
    }

    private var gaining: [String] {
        guard let chosen, let alternative else { return [] }
        return result.criteria
            .filter { chosen.score(for: $0.id) - alternative.score(for: $0.id) > 0.1 }
            .sorted { $0.weight > $1.weight }
            .prefix(3)
            .map(\.name)
    }

    private var givingUp: [String] {
        guard let chosen, let alternative else { return [] }
        return result.criteria
            .filter { alternative.score(for: $0.id) - chosen.score(for: $0.id) > 0.1 }
            .sorted { $0.weight > $1.weight }
            .prefix(3)
            .map(\.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RudderSpacing.l) {
            VStack(alignment: .leading, spacing: RudderSpacing.xs) {
                Text("You chose")
                    .font(RudderFont.footnote.weight(.medium))
                    .foregroundStyle(RudderColor.tertiaryText)
                Text(chosen?.name ?? "your option")
                    .font(RudderFont.display)
                    .foregroundStyle(RudderColor.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)

            if !gaining.isEmpty {
                RudderCard {
                    VStack(alignment: .leading, spacing: RudderSpacing.xs) {
                        Text("You're gaining")
                            .font(RudderFont.footnote.weight(.medium))
                            .foregroundStyle(RudderColor.tertiaryText)
                        ForEach(gaining, id: \.self) { item in
                            Text("• \(item)")
                                .font(RudderFont.callout)
                                .foregroundStyle(RudderColor.primaryText)
                        }
                    }
                }
            }

            if !givingUp.isEmpty {
                RudderCard {
                    VStack(alignment: .leading, spacing: RudderSpacing.xs) {
                        Text("You're giving up")
                            .font(RudderFont.footnote.weight(.medium))
                            .foregroundStyle(RudderColor.tertiaryText)
                        ForEach(givingUp, id: \.self) { item in
                            Text("• \(item)")
                                .font(RudderFont.callout)
                                .foregroundStyle(RudderColor.primaryText)
                        }
                    }
                }
            }

            Text("Your choice is yours.")
                .font(RudderFont.callout)
                .foregroundStyle(RudderColor.secondaryText)
        }
    }
}

extension String {
    /// Lowercases only the first character, so a sentence can embed a label
    /// without shouting mid-sentence.
    var lowercasedFirst: String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}
