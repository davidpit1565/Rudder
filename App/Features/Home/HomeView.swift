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
    @State private var speechRecognizer = SpeechRecognizer()
    /// What was already in the field when voice input started, so listening
    /// appends to existing text instead of replacing it.
    @State private var promptBeforeListening = ""
    /// The user's manual research-depth choice, from the "Options" disclosure.
    /// `.auto` (the default) is the untouched, auto-classified path -- most
    /// people never open this.
    @State private var tierChoice: TierChoice = .auto
    @State private var showingOptions = false

    private enum TierChoice: Hashable {
        case auto, simple, medium, complex

        var complexity: DecisionComplexity? {
            switch self {
            case .auto: return nil
            case .simple: return .simple
            case .medium: return .medium
            case .complex: return .complex
            }
        }
    }

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
                    options
                    if !isInputFocused {
                        quotaSummary
                        examples
                        recentDecisions
                    }
                }
                .screenPadding()
                .padding(.top, RudderSpacing.m)
                .padding(.bottom, RudderSpacing.xxl)
            }
            .scrollDismissesKeyboard(.interactively)
            // A drag-to-dismiss alone isn't enough -- a plain tap anywhere
            // empty should also put the keyboard away, same as other apps.
            // `simultaneousGesture` rather than a plain tap gesture so it
            // never steals a tap meant for a button or row underneath.
            .simultaneousGesture(TapGesture().onEnded { isInputFocused = false })
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
        .task { await environment.refreshQuotaStatus() }
        .fullScreenCover(item: $activeDecision) { active in
            DecisionFlowView(prompt: active.prompt, complexityOverride: active.complexityOverride)
        }
        .onChange(of: activeDecision) { oldValue, newValue in
            // Returning from a finished decision should start the next one with
            // a clean slate, not whatever was typed for the last one.
            if oldValue != nil && newValue == nil {
                prompt = ""
                tierChoice = .auto
                showingOptions = false
            }
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
        .onDisappear { speechRecognizer.stop() }
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
            ZStack(alignment: .bottomTrailing) {
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
                .padding(.trailing, RudderSpacing.minimumTouchTarget)
                .background(RudderColor.surface)
                .clipShape(RoundedRectangle(cornerRadius: RudderSpacing.cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: RudderSpacing.cornerRadius, style: .continuous)
                        .stroke(isInputFocused ? RudderColor.accent : RudderColor.separator, lineWidth: 1)
                )
                .accessibilityLabel("What are you deciding?")
                .accessibilityIdentifier(RudderID.decisionInput)

                Button(action: toggleListening) {
                    Image(systemName: speechRecognizer.isRecording ? "mic.fill" : "mic")
                        .font(.body)
                        .foregroundStyle(speechRecognizer.isRecording ? RudderColor.onAccent : RudderColor.secondaryText)
                        .frame(width: RudderSpacing.minimumTouchTarget, height: RudderSpacing.minimumTouchTarget)
                        .background(speechRecognizer.isRecording ? RudderColor.accent : .clear, in: .circle)
                }
                .buttonStyle(.plain)
                .padding(RudderSpacing.xs)
                .accessibilityLabel(speechRecognizer.isRecording ? "Stop voice input" : "Start voice input")
                .accessibilityIdentifier(RudderID.voiceInput)
            }

            if let errorMessage = speechRecognizer.errorMessage {
                InlineNotice(text: errorMessage, kind: .warning)
            } else if !isConnected {
                InlineNotice(
                    text: "You're offline. A new decision needs a connection — your saved decisions are still here.",
                    kind: .warning
                )
            }
        }
    }

    private func toggleListening() {
        if speechRecognizer.isRecording {
            speechRecognizer.stop()
            return
        }
        promptBeforeListening = prompt
        isInputFocused = true
        speechRecognizer.start { transcript in
            prompt = promptBeforeListening.isEmpty ? transcript : "\(promptBeforeListening) \(transcript)"
        }
    }

    private var autoClassification: DecisionClassifier.Classification? {
        canDecide ? DecisionClassifier.classify(trimmedPrompt) : nil
    }

    /// Hidden by default: most people never need to see this, let alone
    /// touch it. Opening it shows what RUDDER would pick on its own, today's
    /// remaining quota per tier, and an optional manual override -- nothing
    /// here changes behaviour unless the user actually picks something.
    @ViewBuilder
    private var options: some View {
        VStack(alignment: .leading, spacing: RudderSpacing.xs) {
            Button {
                withAnimation { showingOptions.toggle() }
            } label: {
                HStack(spacing: RudderSpacing.xs) {
                    Text("Options")
                        .font(RudderFont.footnote.weight(.medium))
                        .foregroundStyle(RudderColor.secondaryText)
                    Image(systemName: showingOptions ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(RudderColor.tertiaryText)
                }
                .frame(minHeight: RudderSpacing.minimumTouchTarget, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showingOptions {
                RudderCard {
                    VStack(alignment: .leading, spacing: RudderSpacing.s) {
                        Text("How deep should I go?")
                            .font(RudderFont.footnote.weight(.medium))
                            .foregroundStyle(RudderColor.tertiaryText)
                        tierRow(
                            .auto,
                            title: "Auto",
                            subtitle: autoClassification.map { "Currently picks \($0.complexity.tierLabel)" }
                                ?? "Picks a depth automatically based on what you type"
                        )
                        Divider().overlay(RudderColor.separator)
                        tierRow(.simple, title: DecisionComplexity.simple.tierLabel, subtitle: "No daily limit")
                        tierRow(.medium, title: DecisionComplexity.medium.tierLabel, subtitle: quotaSubtitle(for: .medium))
                        tierRow(.complex, title: DecisionComplexity.complex.tierLabel, subtitle: quotaSubtitle(for: .complex))
                    }
                }
            }
        }
    }

    private func tierRow(_ choice: TierChoice, title: String, subtitle: String?) -> some View {
        Button {
            tierChoice = choice
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: RudderSpacing.xs) {
                        Text(title)
                            .font(RudderFont.callout.weight(.medium))
                            .foregroundStyle(RudderColor.primaryText)
                        if choice != .auto, autoClassification?.complexity == choice.complexity {
                            Text("Suggested")
                                .font(RudderFont.caption.weight(.semibold))
                                .foregroundStyle(RudderColor.accent)
                        }
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(RudderFont.footnote)
                            .foregroundStyle(RudderColor.secondaryText)
                    }
                }
                Spacer()
                Image(systemName: tierChoice == choice ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(tierChoice == choice ? RudderColor.accent : RudderColor.separator)
            }
            .frame(minHeight: RudderSpacing.minimumTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(tierChoice == choice ? [.isButton, .isSelected] : .isButton)
    }

    private func quotaSubtitle(for complexity: DecisionComplexity) -> String? {
        guard let status = environment.quotaStatus else { return nil }
        switch complexity {
        case .simple:
            return "No daily limit"
        case .medium:
            return "\(status.medium.used) of \(status.medium.limit) used today"
        case .complex:
            if let daily = status.complex.daily {
                return "\(daily.used) of \(daily.limit) used today"
            }
            if let monthly = status.complex.monthly {
                return "\(monthly.used) of \(monthly.limit) used this month"
            }
            return nil
        }
    }

    /// A glance at today's usage without opening "Options" -- never shown
    /// while the keyboard is up, same as the examples and recent decisions below it.
    @ViewBuilder
    private var quotaSummary: some View {
        if let status = environment.quotaStatus {
            HStack(spacing: RudderSpacing.s) {
                quotaChip(label: DecisionComplexity.medium.tierLabel, bucket: status.medium)
                if let daily = status.complex.daily {
                    quotaChip(label: DecisionComplexity.complex.tierLabel, bucket: daily)
                } else if let monthly = status.complex.monthly {
                    quotaChip(label: DecisionComplexity.complex.tierLabel, bucket: monthly)
                }
                Spacer()
            }
        }
    }

    private func quotaChip(label: String, bucket: QuotaBucketStatus) -> some View {
        HStack(spacing: RudderSpacing.xs) {
            Text(label)
                .font(RudderFont.caption.weight(.medium))
                .foregroundStyle(RudderColor.tertiaryText)
            Text("\(max(0, bucket.limit - bucket.used))/\(bucket.limit) left")
                .font(RudderFont.caption.weight(.semibold))
                .foregroundStyle(RudderColor.secondaryText)
        }
        .padding(.horizontal, RudderSpacing.s)
        .padding(.vertical, 4)
        .background(RudderColor.surfaceRaised, in: Capsule())
        .accessibilityElement(children: .combine)
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
        speechRecognizer.stop()
        // The manual override (if any) is what actually runs, so it's also
        // what the Free/Pro gate checks -- otherwise picking "Deep" by hand
        // would bypass the same limit auto-classifying into "complex" hits.
        let complexity = tierChoice.complexity ?? DecisionClassifier.classify(trimmedPrompt).complexity
        guard environment.canStartDecision(complexity: complexity) else {
            environment.analytics.track(.paywallShown, properties: [.source: "deep_decision_limit"])
            showingPaywall = true
            return
        }
        activeDecision = ActiveDecision(prompt: trimmedPrompt, complexityOverride: tierChoice.complexity)
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
    /// Set only when the user picked a tier manually in the "Options"
    /// disclosure -- nil is the untouched, auto-classified path.
    var complexityOverride: DecisionComplexity? = nil
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
