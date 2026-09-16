import SwiftUI
import Foundation
import RudderCore

extension DecisionRecord {
    /// Research goes out of date. After a couple of months, a decision that leaned
    /// on current facts is worth a second look — without quietly rewriting it.
    var isPotentiallyStale: Bool {
        guard result.researchLevel != .none else { return false }
        return Date().timeIntervalSince(createdAt) > 60 * 60 * 24 * 60
    }

    var shouldReview: Bool { needsReview || isPotentiallyStale }

    /// Everything worth matching a search against.
    ///
    /// Short-circuits rather than building the list first: this runs for every
    /// stored decision on every keystroke.
    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }

        func hit(_ candidate: String) -> Bool {
            candidate.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }

        if hit(title) || hit(prompt) || hit(result.understanding.restatement) { return true }
        if hit(result.category.rawValue.replacingOccurrences(of: "_", with: " ")) { return true }
        if result.options.contains(where: { hit($0.name) }) { return true }
        return result.criteria.contains(where: { hit($0.name) })
    }
}

struct DecisionsView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case recent = "Recent"
        case needsReview = "Needs review"

        var id: String { rawValue }
    }

    @Environment(AppEnvironment.self) private var environment
    @State private var query = ""
    @State private var filter: Filter = .all

    private var filtered: [DecisionRecord] {
        let base = environment.visibleDecisions.filter { $0.matches(query) }
        switch filter {
        case .all:
            return base
        case .recent:
            let cutoff = Date().addingTimeInterval(-60 * 60 * 24 * 30)
            return base.filter { $0.createdAt >= cutoff }
        case .needsReview:
            return base.filter(\.shouldReview)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if environment.decisions.isEmpty {
                    EmptyStateView(
                        title: "Your decisions will appear here.",
                        message: "Everything you decide is saved on this device.",
                        systemImage: "square.stack.3d.up"
                    )
                    .screenPadding()
                } else {
                    ScrollView {
                        VStack(spacing: RudderSpacing.s) {
                            Picker("Filter", selection: $filter) {
                                ForEach(Filter.allCases) { option in
                                    Text(option.rawValue).tag(option)
                                }
                            }
                            .pickerStyle(.segmented)
                            .padding(.bottom, RudderSpacing.xs)

                            if filtered.isEmpty {
                                EmptyStateView(
                                    title: "Nothing here",
                                    message: query.isEmpty
                                        ? "No decisions match this filter."
                                        : "No decisions match “\(query)”.",
                                    systemImage: "magnifyingglass"
                                )
                            } else {
                                ForEach(filtered) { record in
                                    NavigationLink {
                                        DecisionDetailsView(record: record)
                                    } label: {
                                        DecisionRow(record: record)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier(RudderID.historyRow)
                                }
                            }

                            if environment.hasHiddenHistory {
                                HiddenHistoryNotice(hidden: environment.decisions.count - FeatureAccess.freeHistoryLimit)
                            }
                        }
                        .screenPadding()
                        .padding(.vertical, RudderSpacing.m)
                    }
                }
            }
            .background(RudderColor.background)
            .navigationTitle("Your decisions")
            .searchable(text: $query, prompt: "Search decisions")
        }
    }
}

private struct HiddenHistoryNotice: View {
    let hidden: Int
    @State private var showingPaywall = false

    var body: some View {
        RudderCard {
            VStack(alignment: .leading, spacing: RudderSpacing.s) {
                Text("\(hidden) older \(hidden == 1 ? "decision is" : "decisions are") still saved on this device")
                    .font(RudderFont.callout.weight(.medium))
                    .foregroundStyle(RudderColor.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Pro shows your full history. Nothing has been deleted.")
                    .font(RudderFont.footnote)
                    .foregroundStyle(RudderColor.secondaryText)
                SecondaryButton(title: "See Pro") { showingPaywall = true }
            }
        }
        .sheet(isPresented: $showingPaywall) {
            PaywallView(context: .history)
        }
    }
}
