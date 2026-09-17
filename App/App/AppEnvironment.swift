import Foundation
import Observation
import WidgetKit
import RudderCore
import RudderFlow

/// What Free gets and what Pro adds.
///
/// The rule that matters: nobody meets a paywall before they have had a real,
/// finished decision out of RUDDER.
enum FeatureAccess {
    /// Deep decisions (the full research + analysis pipeline) per calendar month on Free.
    /// Mirrors DEFAULT_FREE_DEEP_DECISIONS_PER_MONTH in Backend/src/quota.ts, which
    /// enforces the real ceiling server-side -- keep the two in sync by hand.
    /// Set low deliberately: at bootstrap-stage volume, Free's own AI cost is the
    /// real financial risk, and this is the most direct lever on it. It never
    /// affects simple/medium decisions (still unlimited) or a new install's very
    /// first decision (always free, see allowsDeepDecision below).
    static let freeDeepDecisionsPerMonth = 1
    /// How far back Free history goes.
    static let freeHistoryLimit = 10

    static func allowsDeepDecision(
        isPro: Bool,
        completedDecisionCount: Int,
        deepDecisionsThisMonth: Int
    ) -> Bool {
        if isPro { return true }
        // The first decision is always free, whatever it costs us.
        if completedDecisionCount == 0 { return true }
        return deepDecisionsThisMonth < freeDeepDecisionsPerMonth
    }
}

/// Everything the app needs, assembled once at launch.
@MainActor
@Observable
final class AppEnvironment {
    let configuration: AppConfiguration
    let persistence: PersistenceService
    let subscriptions: SubscriptionService
    let analytics: AnalyticsService

    private(set) var decisions: [DecisionRecord] = []
    private(set) var memory: [MemoryEntry] = []
    /// Preference candidates the user has already said "not now" to, so the same
    /// suggestion doesn't reappear on the very next decision.
    private(set) var declinedMemoryKeys: Set<String> = []
    /// A preference RUDDER would like to remember, waiting on the user's answer.
    private(set) var pendingMemoryCandidate: MemoryCandidate?
    private(set) var storageError: String?

    init(
        configuration: AppConfiguration = .shared,
        persistence: PersistenceService,
        subscriptions: SubscriptionService = SubscriptionService(),
        analytics: AnalyticsService = NoOpAnalyticsService()
    ) {
        self.configuration = configuration
        self.persistence = persistence
        self.subscriptions = subscriptions
        self.analytics = analytics
        reload()
    }

    var isPro: Bool { subscriptions.isPro }

    /// Set when decisions will not survive a restart, so the app can say so once
    /// instead of failing silently.
    var storageWarning: String? {
        switch persistence.mode {
        case .onDisk:
            return nil
        case .inMemory:
            return "I couldn't open your saved decisions on this device, so anything you decide now won't be kept after you close the app."
        case .unavailable:
            return "Storage isn't available on this device, so decisions can't be saved. Everything else still works."
        }
    }

    var visibleDecisions: [DecisionRecord] {
        isPro ? decisions : Array(decisions.prefix(FeatureAccess.freeHistoryLimit))
    }

    var hasHiddenHistory: Bool { !isPro && decisions.count > FeatureAccess.freeHistoryLimit }

    var completedDecisionCount: Int { decisions.filter { $0.chosenOptionID != nil }.count }

    var deepDecisionsThisMonth: Int {
        let calendar = Calendar.current
        let now = Date()
        return decisions.filter {
            $0.result.complexity == .complex && calendar.isDate($0.createdAt, equalTo: now, toGranularity: .month)
        }.count
    }

    func canStartDecision(complexity: DecisionComplexity) -> Bool {
        guard complexity == .complex else { return true }
        return FeatureAccess.allowsDeepDecision(
            isPro: isPro,
            completedDecisionCount: completedDecisionCount,
            deepDecisionsThisMonth: deepDecisionsThisMonth
        )
    }

    // MARK: - Loading

    func reload() {
        do {
            decisions = try persistence.allDecisions()
            memory = try persistence.allMemory()
            declinedMemoryKeys = try persistence.declinedMemoryKeys()
            storageError = nil
        } catch {
            storageError = "I couldn't open your saved decisions."
        }
        updateWidget()
    }

    /// Keeps the Home Screen widget's snapshot of the latest decision current.
    /// Best-effort: a widget that can't be reached is not a reason to fail a reload.
    private func updateWidget() {
        WidgetBridge.write(WidgetSnapshot.make(from: decisions))
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Decisions

    func save(_ record: DecisionRecord) {
        do {
            try persistence.save(record)
            analytics.track(.decisionSaved)
            reload()
            refreshMemoryCandidate()
        } catch {
            storageError = "I couldn't save that decision."
        }
    }

    func delete(_ record: DecisionRecord) {
        do {
            try persistence.delete(decisionID: record.id)
            reload()
        } catch {
            storageError = "I couldn't delete that decision."
        }
    }

    func recordOutcome(_ outcome: Outcome, for record: DecisionRecord) {
        do {
            try persistence.recordOutcome(outcome, for: record.id)
            analytics.track(.outcomeRecorded)
            reload()
        } catch {
            storageError = "I couldn't save that."
        }
    }

    // MARK: - Memory

    /// Looks for a preference worth proposing. Pro-only, and never automatic:
    /// the user is asked before anything is stored.
    func refreshMemoryCandidate() {
        guard isPro else {
            pendingMemoryCandidate = nil
            return
        }
        let candidates = MemoryEngine.candidates(from: decisions, existing: memory, excludedKeys: declinedMemoryKeys)
        pendingMemoryCandidate = candidates.first
        if pendingMemoryCandidate != nil {
            analytics.track(.memoryProposed)
        }
    }

    func acceptPendingMemory() {
        guard let candidate = pendingMemoryCandidate else { return }
        do {
            let entry = try MemoryEngine.accept(candidate)
            try persistence.saveMemory(entry)
            analytics.track(.memoryAccepted)
            pendingMemoryCandidate = nil
            reload()
        } catch {
            // An unsafe or unstorable statement is dropped silently — it is never
            // worth bothering the user about, and nothing was stored.
            pendingMemoryCandidate = nil
        }
    }

    func declinePendingMemory() {
        guard let candidate = pendingMemoryCandidate else { return }
        try? persistence.declineMemory(key: candidate.key)
        declinedMemoryKeys.insert(candidate.key)
        pendingMemoryCandidate = nil
    }

    func setMemoryEnabled(_ isEnabled: Bool, for entry: MemoryEntry) {
        do {
            try persistence.setMemoryEnabled(isEnabled, key: entry.key)
            reload()
        } catch {
            storageError = "I couldn't update that preference."
        }
    }

    func deleteMemory(_ entry: MemoryEntry) {
        do {
            try persistence.deleteMemory(key: entry.key)
            reload()
        } catch {
            storageError = "I couldn't delete that preference."
        }
    }

    // MARK: - Data controls

    func deleteAllDecisions() {
        try? persistence.deleteAllDecisions()
        reload()
    }

    func deleteAllMemory() {
        try? persistence.deleteAllMemory()
        pendingMemoryCandidate = nil
        reload()
    }

    func deleteAllOutcomes() {
        try? persistence.deleteAllOutcomes()
        reload()
    }

    func deleteEverything() {
        try? persistence.deleteEverything()
        pendingMemoryCandidate = nil
        reload()
    }

    // MARK: - Factories

    func makeCoordinator() -> DecisionCoordinator {
        DecisionCoordinator(
            service: analysisService(),
            analytics: analytics,
            memoryProvider: { [weak self] in self?.memory ?? [] }
        )
    }

    private func analysisService() -> DecisionAnalysisService {
        #if DEBUG
        // Only ever non-nil when the app was launched by the UI test suite with
        // a scenario argument. Compiled out of Release.
        if let scripted = UITestHarness.analysisService() { return scripted }
        #endif
        return RemoteDecisionAnalysisService(
            configuration: configuration,
            installId: InstallIdentity.current,
            proTransactionProvider: { [subscriptions] in await subscriptions.currentTransactionJWS() }
        )
    }
}
