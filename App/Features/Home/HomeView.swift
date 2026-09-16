import SwiftUI
import Foundation
import RudderCore
import RudderFlow

/// One question, one field, one button. The home screen is not a dashboard.
struct HomeView: View {
    var onSeeAllDecisions: () -> Void = {}

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase
    @State private var prompt = ""
    @State private var activeDecision: ActiveDecision?
    @State private var showingPaywall = false
    @State private var isConnected = true
    @FocusState private var isInputFocused: Bool

    private var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canDecide: Bool { trimmedPrompt.count >= 3 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RudderSpacing.l) {
                    header
                    input
                    if !isInputFocused {
                        examples
                        recentDecisions
                    }
                }
                .screenPadding()
                .padding(.top, RudderSpacing.m)
                .padding(.bottom, RudderSpacing.xxl)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(RudderColor.background)
            .navigationTitle("Decide")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                // The primary action stays within thumb reach and above the keyboard.
                PrimaryButton(
                    title: "Decide",
                    systemImage: "arrow.right",
                    isEnabled: canDecide,
                    identifier: RudderID.startDecision
                ) {
                    startDecision()
                }
                .screenPadding()
                .padding(.vertical, RudderSpacing.s)
                .background(.bar)
            }
        }
        .task {
            // Reflects the connection as it changes, rather than whatever was true
            // when the screen was first drawn.
            for await connected in Reachability.shared.updates {
                isConnected = connected
            }
        }
        .fullScreenCover(item: $activeDecision) { active in
            DecisionFlowView(prompt: active.prompt)
        }
        .sheet(isPresented: $showingPaywall) {
            PaywallView(context: .deepDecisionLimit)
        }
        .task { consumePendingSiriPrompt() }
        .onChange(of: scenePhase) { _, newPhase in
            // A Siri/Shortcuts invocation runs out-of-process, so a prompt it hands
            // off can arrive while this view already exists -- re-check whenever the
            // app comes back to the foreground, not just on first appearance.
            guard newPhase == .active else { return }
            consumePendingSiriPrompt()
        }
    }

    /// Picks up a decision prompt handed off by `StartDecisionIntent`, if there is
    /// one waiting, and starts it the same way tapping the "Decide" button would.
    private func consumePendingSiriPrompt() {
        guard let pending = PendingSiriDecision.shared.consume() else { return }
        prompt = pending
        startDecision()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: RudderSpacing.s) {
            Text("What are you deciding?")
                .font(RudderFont.display)
                .foregroundStyle(RudderColor.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text("Tell me what you're trying to figure out.")
                .font(RudderFont.callout)
                .foregroundStyle(RudderColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var input: some View {
        VStack(alignment: .leading, spacing: RudderSpacing.s) {
            TextField(
                "I'm deciding between…",
                text: $prompt,
                axis: .vertical
            )
            .font(RudderFont.body)
            .lineLimit(3...8)
            .textInputAutocapitalization(.sentences)
            .submitLabel(.done)
            .focused($isInputFocused)
            .padding(RudderSpacing.m)
            .background(RudderColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: RudderSpacing.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RudderSpacing.cornerRadius, style: .continuous)
                    .stroke(isInputFocused ? RudderColor.accent : RudderColor.separator, lineWidth: 1)
            )
            .accessibilityLabel("What are you deciding?")
            .accessibilityIdentifier(RudderID.decisionInput)

            if !isConnected {
                InlineNotice(
                    text: "You're offline. A new decision needs a connection — your saved decisions are still here.",
                    kind: .warning
                )
            }
        }
    }

    private var examples: some View {
        VStack(alignment: .leading, spacing: RudderSpacing.s) {
            Text("For example")
                .font(RudderFont.footnote.weight(.medium))
                .foregroundStyle(RudderColor.tertiaryText)

            ForEach(Self.examplePrompts, id: \.self) { example in
                Button {
                    prompt = example
                    isInputFocused = true
                } label: {
                    HStack {
                        Text(example)
                            .font(RudderFont.callout)
                            .foregroundStyle(RudderColor.primaryText)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: RudderSpacing.s)
                        Image(systemName: "arrow.up.left")
                            .font(.caption)
                            .foregroundStyle(RudderColor.tertiaryText)
                    }
                    .frame(minHeight: RudderSpacing.minimumTouchTarget)
                    .padding(.horizontal, RudderSpacing.m)
                    .background(RudderColor.surface)
                    .clipShape(RoundedRectangle(cornerRadius: RudderSpacing.s, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityHint("Uses this example as your decision")
            }
        }
    }

    @ViewBuilder
    private var recentDecisions: some View {
        let recent = Array(environment.visibleDecisions.prefix(3))

        VStack(alignment: .leading, spacing: RudderSpacing.s) {
            HStack {
                Text("Recent decisions")
                    .font(RudderFont.footnote.weight(.medium))
                    .foregroundStyle(RudderColor.tertiaryText)
                Spacer()
                if !recent.isEmpty {
                    Button("See all", action: onSeeAllDecisions)
                        .font(RudderFont.footnote)
                        .frame(minHeight: RudderSpacing.minimumTouchTarget)
                }
            }

            if recent.isEmpty {
                EmptyStateView(
                    title: "Your decisions will appear here.",
                    message: nil,
                    systemImage: "square.stack.3d.up"
                )
            } else {
                ForEach(recent) { record in
                    NavigationLink {
                        DecisionDetailsView(record: record)
                    } label: {
                        DecisionRow(record: record)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(RudderID.historyRow)
                }
            }
        }
    }

    private func startDecision() {
        isInputFocused = false
        let classification = DecisionClassifier.classify(trimmedPrompt)
        guard environment.canStartDecision(complexity: classification.complexity) else {
            environment.analytics.track(.paywallShown, properties: [.source: "deep_decision_limit"])
            showingPaywall = true
            return
        }
        activeDecision = ActiveDecision(prompt: trimmedPrompt)
    }

    static let examplePrompts = [
        "Which laptop should I buy?",
        "Should I take this job?",
        "Which apartment should I choose?",
        "Should I cancel this subscription?"
    ]
}

struct ActiveDecision: Identifiable, Equatable {
    let id = UUID()
    let prompt: String
}

/// One line of history: what was decided, what was chosen, how strong it was.
struct DecisionRow: View {
    let record: DecisionRecord

    private var subtitle: String {
        let chosen = record.chosenOption?.name ?? record.result.recommendedOption?.name
        let strength = record.result.strength.title
        if let chosen {
            return "\(chosen) · \(strength)"
        }
        return "Not decided yet"
    }

    var body: some View {
        RudderCard {
            VStack(alignment: .leading, spacing: RudderSpacing.xs) {
                Text(record.title)
                    .font(RudderFont.callout.weight(.semibold))
                    .foregroundStyle(RudderColor.primaryText)
                    .multilineTextAlignment(.leading)

                HStack(spacing: RudderSpacing.s) {
                    Text(subtitle)
                        .font(RudderFont.footnote)
                        .foregroundStyle(RudderColor.secondaryText)
                    Spacer(minLength: RudderSpacing.s)
                    Text(record.createdAt.decideRelativeDescription)
                        .font(RudderFont.footnote)
                        .foregroundStyle(RudderColor.tertiaryText)
                }

                if record.shouldReview {
                    Text("Things may have changed")
                        .font(RudderFont.caption)
                        .foregroundStyle(RudderColor.moderate)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(record.title). \(subtitle). \(record.createdAt.decideRelativeDescription)")
    }
}

extension Date {
    var decideRelativeDescription: String {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: self, to: Date()).day ?? 0
        switch days {
        case 0: return "Today"
        case 1: return "Yesterday"
        case 2...6: return "\(days) days ago"
        default:
            return formatted(.dateTime.month(.abbreviated).day())
        }
    }
}
