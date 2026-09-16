import SwiftUI
import Foundation
import RudderCore
import RudderFlow

/// What RUDDER knows, and how to make it forget. No account, no profile to fill in.
struct ProfileView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var paywallContext: PaywallView.Context?
    @State private var confirmation: DataConfirmation?

    private enum DataConfirmation: String, Identifiable {
        case memory
        case decisions
        case outcomes
        case everything

        var id: String { rawValue }

        var title: String {
            switch self {
            case .memory: return "Delete all Decision Memory?"
            case .decisions: return "Delete all decisions?"
            case .outcomes: return "Delete all outcomes?"
            case .everything: return "Delete everything?"
            }
        }

        var message: String {
            switch self {
            case .memory: return "Every preference RUDDER has learned is removed. Your decisions stay."
            case .decisions: return "Every saved decision and its analysis is removed. This can't be undone."
            case .outcomes: return "Every 'how did it go' answer is removed. Your decisions stay."
            case .everything: return "Decisions, memory and outcomes are all removed from this device. This can't be undone."
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RudderSpacing.xl) {
                    subscriptionSection
                    memorySection
                    dataSection
                    aboutSection
                }
                .screenPadding()
                .padding(.vertical, RudderSpacing.m)
            }
            .background(RudderColor.background)
            .navigationTitle("Profile")
            .sheet(item: $paywallContext) { context in
                PaywallView(context: context)
            }
            .alert(
                confirmation?.title ?? "",
                isPresented: Binding(
                    get: { confirmation != nil },
                    set: { if !$0 { confirmation = nil } }
                ),
                presenting: confirmation
            ) { item in
                Button("Delete", role: .destructive) { perform(item) }
                Button("Keep", role: .cancel) {}
            } message: { item in
                Text(item.message)
            }
        }
    }

    // MARK: Sections

    private var subscriptionSection: some View {
        VStack(alignment: .leading, spacing: RudderSpacing.s) {
            SectionHeader(title: "Your plan")
            RudderCard {
                VStack(alignment: .leading, spacing: RudderSpacing.s) {
                    switch environment.subscriptions.entitlement {
                    case .unknown, .checking:
                        HStack(spacing: RudderSpacing.s) {
                            ProgressView()
                            Text("Checking your subscription…")
                                .font(RudderFont.callout)
                                .foregroundStyle(RudderColor.secondaryText)
                        }
                    case .notSubscribed:
                        Text("Free")
                            .font(RudderFont.headline)
                            .foregroundStyle(RudderColor.primaryText)
                        Text("\(FeatureAccess.freeDeepDecisionsPerMonth) deep decisions a month, and your last \(FeatureAccess.freeHistoryLimit) decisions.")
                            .font(RudderFont.footnote)
                            .foregroundStyle(RudderColor.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        SecondaryButton(title: "See Pro") { paywallContext = .profile }
                    case .subscribed(let expires, let isInGracePeriod):
                        Text("Pro")
                            .font(RudderFont.headline)
                            .foregroundStyle(RudderColor.primaryText)
                        if isInGracePeriod {
                            Text("There's a problem with your billing. Access continues while Apple retries.")
                                .font(RudderFont.footnote)
                                .foregroundStyle(RudderColor.moderate)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if let expires {
                            Text("Renews \(expires.formatted(.dateTime.month(.abbreviated).day().year()))")
                                .font(RudderFont.footnote)
                                .foregroundStyle(RudderColor.secondaryText)
                        }
                    case .billingRetry(let expires):
                        Text("Pro — billing issue")
                            .font(RudderFont.headline)
                            .foregroundStyle(RudderColor.primaryText)
                        Text("Apple couldn't take the payment\(expires.map { ". Access continues until \($0.formatted(.dateTime.month(.abbreviated).day()))" } ?? ""). You can fix this in your Apple Account settings.")
                            .font(RudderFont.footnote)
                            .foregroundStyle(RudderColor.moderate)
                            .fixedSize(horizontal: false, vertical: true)
                    case .expired(let date):
                        Text("Pro has ended")
                            .font(RudderFont.headline)
                            .foregroundStyle(RudderColor.primaryText)
                        if let date {
                            Text("Ended \(date.formatted(.dateTime.month(.abbreviated).day().year())). Your decisions are still here.")
                                .font(RudderFont.footnote)
                                .foregroundStyle(RudderColor.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        SecondaryButton(title: "See Pro") { paywallContext = .profile }
                    }

                    if environment.subscriptions.entitlement.isResolved {
                        Button("Restore purchases") {
                            Task { _ = await environment.subscriptions.restorePurchases() }
                        }
                        .font(RudderFont.footnote)
                        .frame(minHeight: RudderSpacing.minimumTouchTarget)
                    }
                }
            }
        }
    }

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: RudderSpacing.s) {
            SectionHeader(
                title: "Decision Memory",
                subtitle: "Preferences RUDDER noticed in decisions you actually made. Nothing is stored without your say-so."
            )

            if !environment.isPro {
                RudderCard {
                    VStack(alignment: .leading, spacing: RudderSpacing.s) {
                        Text("Decision Memory is part of Pro.")
                            .font(RudderFont.callout)
                            .foregroundStyle(RudderColor.primaryText)
                        SecondaryButton(title: "See Pro") { paywallContext = .memory }
                    }
                }
            } else if environment.memory.isEmpty {
                EmptyStateView(
                    title: "Nothing learned yet.",
                    message: "After a few decisions, RUDDER may notice a pattern and ask whether to remember it.",
                    systemImage: "brain"
                )
            } else {
                VStack(spacing: RudderSpacing.s) {
                    ForEach(environment.memory) { entry in
                        MemoryRow(entry: entry)
                    }
                }
            }
        }
    }

    private var dataSection: some View {
        VStack(alignment: .leading, spacing: RudderSpacing.s) {
            SectionHeader(
                title: "Your data",
                subtitle: "Everything is stored on this device. Decisions, memory and outcomes are kept separately, and can be deleted separately."
            )
            RudderCard {
                VStack(alignment: .leading, spacing: 0) {
                    dataRow("Delete all Decision Memory", isEnabled: !environment.memory.isEmpty) {
                        confirmation = .memory
                    }
                    Divider().overlay(RudderColor.separator)
                    dataRow("Delete all outcomes", isEnabled: environment.decisions.contains { $0.outcome != nil }) {
                        confirmation = .outcomes
                    }
                    Divider().overlay(RudderColor.separator)
                    dataRow("Delete all decisions", isEnabled: !environment.decisions.isEmpty) {
                        confirmation = .decisions
                    }
                    Divider().overlay(RudderColor.separator)
                    dataRow("Delete everything", isEnabled: !environment.decisions.isEmpty || !environment.memory.isEmpty) {
                        confirmation = .everything
                    }
                }
            }
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: RudderSpacing.s) {
            SectionHeader(title: "About")
            RudderCard {
                VStack(alignment: .leading, spacing: RudderSpacing.s) {
                    if let url = environment.configuration.privacyPolicyURL {
                        Link("Privacy Policy", destination: url)
                            .font(RudderFont.callout)
                            .frame(minHeight: RudderSpacing.minimumTouchTarget)
                    }
                    if let url = environment.configuration.termsURL {
                        Link("Terms of Use", destination: url)
                            .font(RudderFont.callout)
                            .frame(minHeight: RudderSpacing.minimumTouchTarget)
                    }
                    if let url = environment.configuration.supportURL {
                        Link("Support", destination: url)
                            .font(RudderFont.callout)
                            .frame(minHeight: RudderSpacing.minimumTouchTarget)
                    }
                    Text("RUDDER analyses decisions with the help of an AI model. It can be wrong, and it tells you how confident the analysis is rather than pretending to be certain. The final decision is always yours.")
                        .font(RudderFont.footnote)
                        .foregroundStyle(RudderColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                        Text("Version \(version)")
                            .font(RudderFont.caption)
                            .foregroundStyle(RudderColor.tertiaryText)
                    }
                }
            }
        }
    }

    private func dataRow(_ title: String, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(RudderFont.callout)
                    .foregroundStyle(isEnabled ? RudderColor.unclear : RudderColor.tertiaryText)
                Spacer()
            }
            .frame(maxWidth: .infinity, minHeight: RudderSpacing.minimumTouchTarget, alignment: .leading)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    private func perform(_ confirmation: DataConfirmation) {
        switch confirmation {
        case .memory: environment.deleteAllMemory()
        case .decisions: environment.deleteAllDecisions()
        case .outcomes: environment.deleteAllOutcomes()
        case .everything: environment.deleteEverything()
        }
    }
}

private struct MemoryRow: View {
    let entry: MemoryEntry
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        RudderCard {
            VStack(alignment: .leading, spacing: RudderSpacing.s) {
                Text(entry.statement)
                    .font(RudderFont.callout)
                    .foregroundStyle(RudderColor.primaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Noticed in \(entry.evidenceCount) of your decisions")
                    .font(RudderFont.caption)
                    .foregroundStyle(RudderColor.tertiaryText)

                HStack(spacing: RudderSpacing.m) {
                    Toggle(
                        "Use this",
                        isOn: Binding(
                            get: { entry.isEnabled },
                            set: { environment.setMemoryEnabled($0, for: entry) }
                        )
                    )
                    .font(RudderFont.footnote)
                    .toggleStyle(.switch)

                    Button("Remove", role: .destructive) {
                        environment.deleteMemory(entry)
                    }
                    .font(RudderFont.footnote)
                    .frame(minHeight: RudderSpacing.minimumTouchTarget)
                }
            }
        }
    }
}

/// Asked once, after a decision, and never assumed.
struct MemoryConsentSheet: View {
    let candidate: MemoryCandidate
    let onRemember: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: RudderSpacing.l) {
            VStack(alignment: .leading, spacing: RudderSpacing.s) {
                Text("I noticed something")
                    .font(RudderFont.footnote.weight(.medium))
                    .foregroundStyle(RudderColor.tertiaryText)
                Text(candidate.statement)
                    .font(RudderFont.title)
                    .foregroundStyle(RudderColor.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Want RUDDER to use this in future decisions? You can change or delete it at any time.")
                    .font(RudderFont.callout)
                    .foregroundStyle(RudderColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)

            PrimaryButton(title: "Remember", action: onRemember)
            Button("Not now", action: onDecline)
                .font(RudderFont.footnote)
                .frame(maxWidth: .infinity, minHeight: RudderSpacing.minimumTouchTarget)
        }
        .screenPadding()
        .padding(.vertical, RudderSpacing.l)
        .presentationDetents([.medium])
    }
}
