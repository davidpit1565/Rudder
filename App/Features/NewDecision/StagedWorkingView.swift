import SwiftUI
import RudderCore

/// What's genuinely happening during the one network call behind
/// `.working(.understanding)` -- research (if the request actually asks for
/// it), then analysis, same order the backend itself runs them in
/// (`Backend/src/analyze.ts`: `runResearch()` before the analysis call).
///
/// The backend has no way to push a live "now I'm on step 2" signal back
/// mid-request -- it's a single request/response, not a stream -- so this
/// infers which step is likely active from elapsed time against the
/// backend's own real, configured ceilings (`RESEARCH_TIMEOUT_MS` = 15s,
/// `Backend/src/research.ts`), not an arbitrary animation. It never claims
/// to be further along than it can know: past the last threshold it simply
/// stays on the final stage, however long the real call actually takes, and
/// disappears the instant a real response (or failure) changes
/// `DecisionCoordinator.phase` -- it is a display over real state, not a
/// substitute for it.
struct ProgressStage: Identifiable, Equatable {
    enum Status: Equatable { case done, active, pending }

    let id: String
    let title: String
    let subtitle: String?
    var status: Status
}

enum StagedProgress {
    /// Seconds after which the "looking things up" stage gives way to
    /// "analyzing" -- matches `RESEARCH_TIMEOUT_MS` in `Backend/src/research.ts`,
    /// the real cap the backend itself places on that step.
    static let researchCeilingSeconds: TimeInterval = 15
    /// A brief opening beat before assuming research/analysis is under way --
    /// long enough that it isn't a flicker, short enough that it never reads
    /// as a stall.
    static let openingBeatSeconds: TimeInterval = 2

    static func stages(researchLevel: ResearchLevel?, elapsed: TimeInterval) -> [ProgressStage] {
        let researching = (researchLevel ?? .none) != .none

        var items: [(id: String, title: String, subtitle: String?, threshold: TimeInterval)] = [
            ("understanding", "Understanding your decision", "Figuring out what matters before analyzing it.", 0)
        ]
        if researching {
            items.append((
                "research",
                "Looking up what I can",
                "So I don't have to ask you what's easy to find out.",
                openingBeatSeconds
            ))
        }
        items.append((
            "analyze",
            "Analyzing your decision",
            "Weighing the options against what matters to you.",
            researching ? openingBeatSeconds + researchCeilingSeconds : openingBeatSeconds
        ))

        // The active stage is the last one whose threshold has passed; every
        // earlier one reads as done, every later one as not started yet.
        let activeIndex = items.lastIndex { elapsed >= $0.threshold } ?? 0
        return items.enumerated().map { index, item in
            let status: ProgressStage.Status = index < activeIndex ? .done : (index == activeIndex ? .active : .pending)
            return ProgressStage(id: item.id, title: item.title, subtitle: item.subtitle, status: status)
        }
    }
}

/// Renders `StagedProgress.stages`, re-evaluated once a second against how
/// long this screen has actually been showing.
///
/// `startedAt` is `@State`, set once when this view is first created --
/// the caller forces a fresh one (`.id(state)`) exactly when a genuinely new
/// network call begins, so elapsed time always reflects that call, never
/// however long the whole decision has taken so far.
struct StagedWorkingView: View {
    let researchLevel: ResearchLevel?
    @State private var startedAt = Date()

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            let elapsed = context.date.timeIntervalSince(startedAt)
            let stages = StagedProgress.stages(researchLevel: researchLevel, elapsed: elapsed)
            VStack(alignment: .leading, spacing: RudderSpacing.m) {
                ForEach(stages) { stage in
                    StageRow(stage: stage)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                stages.first { $0.status == .active }.map { "\($0.title). \($0.subtitle ?? "")" } ?? "Working"
            )
        }
    }
}

private struct StageRow: View {
    let stage: ProgressStage

    var body: some View {
        HStack(alignment: .top, spacing: RudderSpacing.s) {
            icon
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: RudderSpacing.xs) {
                Text(stage.title)
                    .font(stage.status == .active ? RudderFont.title : RudderFont.callout)
                    .foregroundStyle(stage.status == .pending ? RudderColor.tertiaryText : RudderColor.primaryText)
                if stage.status == .active, let subtitle = stage.subtitle {
                    Text(subtitle)
                        .font(RudderFont.callout)
                        .foregroundStyle(RudderColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: stage.status)
    }

    @ViewBuilder
    private var icon: some View {
        switch stage.status {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(RudderColor.accent)
        case .active:
            ProgressView()
                .progressViewStyle(.circular)
        case .pending:
            Image(systemName: "circle")
                .font(.system(size: 18))
                .foregroundStyle(RudderColor.separator)
        }
    }
}
