import SwiftUI
import Foundation
import RudderCore

/// A decision from history: what was decided, what was chosen, how it went.
struct DecisionDetailsView: View {
    let record: DecisionRecord

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var showingOutcome = false
    @State private var showingDeleteConfirmation = false
    @State private var newDecision: ActiveDecision?
    @State private var showingAnalysis = false

    private var current: DecisionRecord {
        environment.decisions.first { $0.id == record.id } ?? record
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RudderSpacing.l) {
                summary
                whatYouToldMe
                outcomeSection

                // A plain Button driving `.navigationDestination(isPresented:)`,
                // not a NavigationLink -- see the identical row in
                // RecommendationView for why: a NavigationLink here was never
                // observed to push, even though its tap was genuinely received.
                Button {
                    showingAnalysis = true
                } label: {
                    HStack {
                        Text("See full analysis")
                            .font(RudderFont.callout.weight(.medium))
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(RudderColor.accent)
                    .frame(maxWidth: .infinity, minHeight: RudderSpacing.minimumTouchTarget, alignment: .leading)
                    .contentShape(Rectangle())
                }

                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Text("Delete this decision")
                        .font(RudderFont.callout)
                        .frame(maxWidth: .infinity, minHeight: RudderSpacing.minimumTouchTarget)
                }
            }
            .screenPadding()
            .padding(.vertical, RudderSpacing.m)
        }
        .background(RudderColor.background)
        .navigationTitle(current.title)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Delete this decision?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                environment.delete(current)
                dismiss()
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("This removes the decision and everything stored with it. It can't be undone.")
        }
        .sheet(isPresented: $showingOutcome) {
            OutcomeSheet(record: current) { outcome in
                environment.recordOutcome(outcome, for: current)
                showingOutcome = false
            }
        }
        .fullScreenCover(item: $newDecision) { active in
            DecisionFlowView(prompt: active.prompt)
        }
        .navigationDestination(isPresented: $showingAnalysis) {
            AnalysisView(result: current.result)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: RudderSpacing.m) {
            VStack(alignment: .leading, spacing: RudderSpacing.xs) {
                Text(current.chosenOption != nil ? "You chose" : "I recommended")
                    .font(RudderFont.footnote.weight(.medium))
                    .foregroundStyle(RudderColor.tertiaryText)
                Text(current.chosenOption?.name ?? current.result.recommendedOption?.name ?? "No clear winner")
                    .font(RudderFont.title)
                    .foregroundStyle(RudderColor.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(current.createdAt.formatted(.dateTime.month(.wide).day().year()))
                    .font(RudderFont.footnote)
                    .foregroundStyle(RudderColor.tertiaryText)
            }
            .accessibilityElement(children: .combine)

            RudderCard {
                StrengthBadge(strength: current.result.strength, showsExplanation: true)
            }

            if let followed = current.followedRecommendation, !followed,
               let recommended = current.result.recommendedOption {
                InlineNotice(text: "I had leaned towards \(recommended.name). You went another way — that's the point.")
            }
        }
    }

    /// What RUDDER understood, and the two ways to put it right. An old decision is
    /// never rewritten in place — both routes create a new one and leave this intact.
    private var whatYouToldMe: some View {
        RudderCard {
            VStack(alignment: .leading, spacing: RudderSpacing.s) {
                Text("What you told me")
                    .font(RudderFont.footnote.weight(.medium))
                    .foregroundStyle(RudderColor.tertiaryText)

                Text(current.result.understanding.restatement)
                    .font(RudderFont.callout)
                    .foregroundStyle(RudderColor.primaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if !current.result.understanding.whatMatters.isEmpty {
                    Text(current.result.understanding.whatMatters.joined(separator: " · "))
                        .font(RudderFont.footnote)
                        .foregroundStyle(RudderColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider().overlay(RudderColor.separator)

                Text(
                    current.shouldReview
                        ? "Enough time has passed that the information behind this could be out of date."
                        : "Not quite right, or something has changed?"
                )
                .font(RudderFont.footnote)
                .foregroundStyle(current.shouldReview ? RudderColor.moderate : RudderColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

                SecondaryButton(title: "Update this decision") {
                    newDecision = ActiveDecision(prompt: current.prompt)
                }
                Button("Start a different decision") { dismiss() }
                    .font(RudderFont.footnote)
                    .frame(maxWidth: .infinity, minHeight: RudderSpacing.minimumTouchTarget)
            }
        }
    }

    @ViewBuilder
    private var outcomeSection: some View {
        if let outcome = current.outcome {
            RudderCard {
                VStack(alignment: .leading, spacing: RudderSpacing.xs) {
                    Text("How it went")
                        .font(RudderFont.footnote.weight(.medium))
                        .foregroundStyle(RudderColor.tertiaryText)
                    Text(outcomeLabel(outcome.rating))
                        .font(RudderFont.callout.weight(.medium))
                        .foregroundStyle(RudderColor.primaryText)
                    if let note = outcome.note, !note.isEmpty {
                        Text(note)
                            .font(RudderFont.footnote)
                            .foregroundStyle(RudderColor.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } else if current.chosenOptionID != nil, current.isReadyForOutcome {
            RudderCard {
                VStack(alignment: .leading, spacing: RudderSpacing.s) {
                    Text("How did it go?")
                        .font(RudderFont.headline)
                        .foregroundStyle(RudderColor.primaryText)
                    SecondaryButton(title: "Tell me") { showingOutcome = true }
                }
            }
        }
    }

    private func outcomeLabel(_ rating: Outcome.Rating) -> String {
        switch rating {
        case .great: return "Great"
        case .mixed: return "Mixed"
        case .notGreat: return "Not great"
        }
    }
}

extension DecisionRecord {
    /// Asking "how did it go?" straight after a decision is noise. It only becomes
    /// a fair question once enough time has passed to have an answer.
    var isReadyForOutcome: Bool {
        guard let chosenAt else { return false }
        return Date().timeIntervalSince(chosenAt) > 60 * 60 * 24 * 7
    }
}

/// Never a pop-up after every decision: this is opened deliberately.
struct OutcomeSheet: View {
    let record: DecisionRecord
    let onSubmit: (Outcome) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var rating: Outcome.Rating?
    @State private var note = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RudderSpacing.l) {
                    Text("How did it go?")
                        .font(RudderFont.title)
                        .foregroundStyle(RudderColor.primaryText)

                    VStack(spacing: RudderSpacing.s) {
                        ratingButton(.great, title: "Great", symbol: "hand.thumbsup")
                        ratingButton(.mixed, title: "Mixed", symbol: "equal.circle")
                        ratingButton(.notGreat, title: "Not great", symbol: "hand.thumbsdown")
                    }

                    if rating == .notGreat || rating == .mixed {
                        VStack(alignment: .leading, spacing: RudderSpacing.xs) {
                            Text("What went wrong? (optional)")
                                .font(RudderFont.footnote)
                                .foregroundStyle(RudderColor.secondaryText)
                            TextField("Optional", text: $note, axis: .vertical)
                                .font(RudderFont.body)
                                .lineLimit(2...5)
                                .padding(RudderSpacing.m)
                                .background(RudderColor.surface)
                                .clipShape(RoundedRectangle(cornerRadius: RudderSpacing.cornerRadius, style: .continuous))
                        }
                    }
                }
                .screenPadding()
                .padding(.vertical, RudderSpacing.m)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(RudderColor.background)
            .navigationTitle(record.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Not now") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                PrimaryButton(title: "Save", isEnabled: rating != nil) {
                    guard let rating else { return }
                    onSubmit(Outcome(rating: rating, note: note.isEmpty ? nil : note))
                }
                .screenPadding()
                .padding(.vertical, RudderSpacing.s)
                .background(.bar)
            }
        }
    }

    private func ratingButton(_ value: Outcome.Rating, title: String, symbol: String) -> some View {
        Button {
            rating = value
        } label: {
            HStack(spacing: RudderSpacing.m) {
                Image(systemName: symbol)
                Text(title).font(RudderFont.body)
                Spacer()
                if rating == value {
                    Image(systemName: "checkmark").foregroundStyle(RudderColor.accent)
                }
            }
            .foregroundStyle(RudderColor.primaryText)
            .frame(maxWidth: .infinity, minHeight: RudderSpacing.minimumTouchTarget, alignment: .leading)
            .padding(.horizontal, RudderSpacing.m)
            .background(RudderColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: RudderSpacing.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RudderSpacing.cornerRadius, style: .continuous)
                    .stroke(rating == value ? RudderColor.accent : RudderColor.separator, lineWidth: rating == value ? 1.5 : 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(rating == value ? [.isButton, .isSelected] : .isButton)
    }
}
