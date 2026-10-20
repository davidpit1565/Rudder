import SwiftUI
import Foundation
import RudderCore
import RudderFlow

/// Patterns across every decision made, and what RUDDER has learned along the
/// way. Two different kinds of "looking back" -- statistics over what already
/// happened, and memory that shapes what happens next -- share a tab because
/// both answer the same question: is this actually helping?
struct InsightsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var paywallContext: PaywallView.Context?
    @State private var memorizeAllSession: MemorizeAllSession?
    @State private var showingNoNewPatterns = false

    /// Wraps a scan's results so `.sheet(item:)` can present them -- a plain
    /// `[MemoryCandidate]` array has nothing of its own to key the sheet on.
    private struct MemorizeAllSession: Identifiable {
        let id = UUID()
        let candidates: [MemoryCandidate]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RudderSpacing.xl) {
                    if environment.decisions.isEmpty {
                        EmptyStateView(
                            title: "Nothing to show yet",
                            message: "Make a few decisions and RUDDER will start noticing patterns here.",
                            systemImage: "chart.bar.fill"
                        )
                        .padding(.top, RudderSpacing.xl)
                    } else {
                        statsSection
                    }
                    memorySection
                }
                .screenPadding()
                .padding(.vertical, RudderSpacing.m)
            }
            .background(RudderColor.background)
            .navigationTitle("Insights")
            .sheet(item: $paywallContext) { context in
                PaywallView(context: context)
            }
            .sheet(item: $memorizeAllSession) { session in
                MemorizeAllSheet(
                    candidates: session.candidates,
                    onRemember: { selectedKeys in
                        let chosen = session.candidates.filter { selectedKeys.contains($0.key) }
                        environment.acceptMemoryCandidates(chosen)
                        memorizeAllSession = nil
                    },
                    onClose: { memorizeAllSession = nil }
                )
            }
            .alert("Nothing new found", isPresented: $showingNoNewPatterns) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("I haven't noticed any new patterns across your decisions yet.")
            }
        }
    }

    private func startMemorizeAllScan() {
        let candidates = environment.allMemoryCandidates()
        if candidates.isEmpty {
            showingNoNewPatterns = true
        } else {
            memorizeAllSession = MemorizeAllSession(candidates: candidates)
        }
    }

    // MARK: Statistics

    private var decisionsThisMonth: Int {
        let calendar = Calendar.current
        let now = Date()
        return environment.decisions.filter {
            calendar.isDate($0.createdAt, equalTo: now, toGranularity: .month)
                && calendar.isDate($0.createdAt, equalTo: now, toGranularity: .year)
        }.count
    }

    private var categoryCounts: [(category: DecisionCategory, count: Int)] {
        Dictionary(grouping: environment.decisions, by: { $0.result.category })
            .map { (category: $0.key, count: $0.value.count) }
            .sorted {
                $0.count != $1.count ? $0.count > $1.count : $0.category.rawValue < $1.category.rawValue
            }
    }

    private var ratedDecisions: [DecisionRecord] {
        environment.decisions.filter { $0.outcome != nil }
    }

    private func outcomeCount(_ rating: Outcome.Rating) -> Int {
        ratedDecisions.filter { $0.outcome?.rating == rating }.count
    }

    /// Only decisions where a choice was actually made against a real
    /// recommendation -- everything else has no "did you follow it" to ask.
    private var decisionsWithKnownFollowThrough: [DecisionRecord] {
        environment.decisions.filter { $0.followedRecommendation != nil }
    }

    private var followedRecommendationRate: Double? {
        let known = decisionsWithKnownFollowThrough
        guard !known.isEmpty else { return nil }
        let followed = known.filter { $0.followedRecommendation == true }.count
        return Double(followed) / Double(known.count)
    }

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: RudderSpacing.s) {
            SectionHeader(title: "Your decisions")

            RudderCard {
                HStack(spacing: RudderSpacing.s) {
                    statTile(value: "\(environment.decisions.count)", label: "Total")
                    tileDivider
                    statTile(value: "\(decisionsThisMonth)", label: "This month")
                    if let rate = followedRecommendationRate {
                        tileDivider
                        statTile(value: "\(Int((rate * 100).rounded()))%", label: "Followed advice")
                    }
                }
            }

            if !categoryCounts.isEmpty {
                RudderCard {
                    VStack(alignment: .leading, spacing: RudderSpacing.m) {
                        Text("By category")
                            .font(RudderFont.callout.weight(.semibold))
                            .foregroundStyle(RudderColor.primaryText)
                        VStack(spacing: RudderSpacing.s) {
                            ForEach(categoryCounts, id: \.category) { entry in
                                CategoryRow(
                                    label: entry.category.displayName,
                                    count: entry.count,
                                    fraction: Double(entry.count) / Double(environment.decisions.count)
                                )
                            }
                        }
                    }
                }
            }

            if !ratedDecisions.isEmpty {
                RudderCard {
                    VStack(alignment: .leading, spacing: RudderSpacing.m) {
                        Text("How things went")
                            .font(RudderFont.callout.weight(.semibold))
                            .foregroundStyle(RudderColor.primaryText)
                        HStack(spacing: RudderSpacing.m) {
                            OutcomeTile(rating: .great, count: outcomeCount(.great), total: ratedDecisions.count)
                            OutcomeTile(rating: .mixed, count: outcomeCount(.mixed), total: ratedDecisions.count)
                            OutcomeTile(rating: .notGreat, count: outcomeCount(.notGreat), total: ratedDecisions.count)
                        }
                    }
                }
            }
        }
    }

    private var tileDivider: some View {
        Divider()
            .frame(height: 32)
            .overlay(RudderColor.separator)
    }

    private func statTile(value: String, label: String) -> some View {
        VStack(spacing: RudderSpacing.xs) {
            Text(value)
                .font(RudderFont.title.weight(.semibold))
                .foregroundStyle(RudderColor.primaryText)
            Text(label)
                .font(RudderFont.caption)
                .foregroundStyle(RudderColor.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    // MARK: Decision Memory

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
            } else {
                VStack(alignment: .leading, spacing: RudderSpacing.s) {
                    // One switch for the whole feature -- most people only ever
                    // want memory on or off, not a per-fact decision every time.
                    RudderCard {
                        Toggle(
                            "Decision Memory",
                            isOn: Binding(
                                get: { environment.isMemoryEnabled },
                                set: { environment.setMemoryEnabled($0) }
                            )
                        )
                        .font(RudderFont.callout.weight(.medium))
                        .toggleStyle(.switch)
                    }

                    if environment.isMemoryEnabled {
                        if environment.memory.isEmpty {
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
                        // A one-time, user-initiated scan across every decision
                        // already made -- for someone who'd rather do this once
                        // than wait for a candidate to surface one decision at a
                        // time. Still only a proposal: nothing here writes
                        // anything without the explicit "Remember" below.
                        SecondaryButton(title: "Scan all decisions", systemImage: "magnifyingglass") {
                            startMemorizeAllScan()
                        }
                        .disabled(environment.decisions.isEmpty)
                    }
                }
            }
        }
    }
}

private struct CategoryRow: View {
    let label: String
    let count: Int
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: RudderSpacing.xs) {
            HStack {
                Text(label)
                    .font(RudderFont.callout)
                    .foregroundStyle(RudderColor.primaryText)
                Spacer()
                Text("\(count)")
                    .font(RudderFont.callout.weight(.medium))
                    .foregroundStyle(RudderColor.secondaryText)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(RudderColor.surfaceRaised)
                    Capsule()
                        .fill(RudderColor.accent.opacity(0.75))
                        .frame(width: max(4, proxy.size.width * fraction))
                }
            }
            .frame(height: 6)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(count)")
    }
}

private struct OutcomeTile: View {
    let rating: Outcome.Rating
    let count: Int
    let total: Int

    private var colour: Color {
        switch rating {
        case .great: return RudderColor.strong
        case .mixed: return RudderColor.moderate
        case .notGreat: return RudderColor.unclear
        }
    }

    private var label: String {
        switch rating {
        case .great: return "Great"
        case .mixed: return "Mixed"
        case .notGreat: return "Not great"
        }
    }

    var body: some View {
        VStack(spacing: RudderSpacing.xs) {
            Text("\(count)")
                .font(RudderFont.title.weight(.semibold))
                .foregroundStyle(colour)
            Text(label)
                .font(RudderFont.caption)
                .foregroundStyle(RudderColor.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(count) of \(total)")
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

private extension DecisionCategory {
    var displayName: String {
        switch self {
        case .purchase: return "Purchases"
        case .career: return "Career"
        case .education: return "Education"
        case .travel: return "Travel"
        case .home: return "Home"
        case .subscription: return "Subscriptions"
        case .finance: return "Finance"
        case .technology: return "Technology"
        case .lifePlanning: return "Life planning"
        case .other: return "Other"
        }
    }
}
