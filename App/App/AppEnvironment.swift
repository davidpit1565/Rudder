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
    /// Deep decisions (the full research + analysis pipeline) per calendar month on Free,
    /// beyond the one always-free first decision. Mirrors
    /// DEFAULT_FREE_DEEP_DECISIONS_PER_MONTH in Backend/src/quota.ts, which enforces the
    /// real ceiling server-side -- keep the two in sync by hand.
    /// Set to 0, not a small positive number: a recurring monthly allowance is something
    /// a casual user can settle into permanently, with nothing ever pushing them toward
    /// Pro. The first decision stays unconditionally free (see `allowsDeepDecision`'s own
    /// `completedDecisionCount == 0` check); beyond that, the real "try it" mechanism is
    /// the App Store's introductory free trial on the Pro subscription, which has a
    /// natural end and converts to a real subscription unless cancelled -- unlike a
    /// standing free allowance, it can't be "good enough forever."
    static let freeDeepDecisionsPerMonth = 0
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
    /// Today's/this-month's usage across every quota the backend actually
    /// enforces (Backend/src/quota.ts), fetched read-only -- never computed
    /// from local decisions, which can't see another device's spend or
    /// survive a reinstall. `nil` until the first successful fetch, or again
    /// whenever a fetch fails; the Profile screen simply omits the section
    /// rather than showing a stale or fabricated number.
    private(set) var quotaStatus: QuotaStatus?

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

    // MARK: - Follow-up

    private func followUpService() -> FollowUpService {
        #if DEBUG
        if let scripted = UITestHarness.followUpService() { return scripted }
        #endif
        return RemoteFollowUpService(
            configuration: configuration,
            installId: InstallIdentity.current,
            proTransactionProvider: { [subscriptions] in await subscriptions.currentTransactionJWS() }
        )
    }

    func followUpExchanges(for record: DecisionRecord) -> [FollowUpExchange] {
        (try? persistence.followUpExchanges(for: record.id)) ?? []
    }

    /// Renders a finished decision down to the compact context a follow-up
    /// call needs -- not the full DecisionResult, which would cost far more
    /// tokens than a short follow-up answer needs.
    private func followUpContext(for record: DecisionRecord) -> String {
        var parts: [String] = [record.result.understanding.restatement]

        if let recommended = record.result.recommendedOption {
            parts.append("Recommended: \(recommended.name). \(record.result.headline)")
            for reason in record.result.reasons {
                parts.append("- \(reason.title): \(reason.detail)")
            }
        }
        if let chosen = record.chosenOption, chosen.id != record.result.recommendedOptionID {
            parts.append("The user actually chose: \(chosen.name).")
        }
        for tradeOff in record.result.tradeOffs {
            parts.append("Trade-off: gained \(tradeOff.gaining), gave up \(tradeOff.givingUp).")
        }
        return parts.joined(separator: "\n")
    }

    /// Asks a follow-up question about an already-finished decision and
    /// persists the exchange on success, so it survives app restarts.
    /// Throws rather than returning nil on failure, same as a new decision's
    /// own analysis -- the caller shows what actually went wrong.
    func askFollowUp(_ question: String, about record: DecisionRecord) async throws -> FollowUpExchange {
        let history = followUpExchanges(for: record).map {
            FollowUpRequest.Exchange(question: $0.question, answer: $0.answer)
        }
        let request = FollowUpRequest(
            originalPrompt: record.prompt,
            decisionContext: followUpContext(for: record),
            history: history,
            question: question
        )
        let result = try await followUpService().answer(request)
        let exchange = FollowUpExchange(
            question: question,
            answer: result.response.answer,
            suggestedNewDecisionPrompt: result.response.needsResearch ? result.response.suggestedNewDecisionPrompt : nil,
            durablePreferenceStatement: result.response.durablePreference?.statement
        )
        try? persistence.addFollowUpExchange(exchange, to: record.id)
        analytics.track(.followUpAsked)
        return exchange
    }

    /// Consent-gated, same principle as `acceptPendingMemory`: a preference a
    /// follow-up revealed is never written automatically. Unlike that
    /// statistical candidate, this has no repeated-pattern evidence behind it
    /// -- it is accepted on the strength of one conversation, so it starts at
    /// evidenceCount 1.
    func acceptFollowUpPreference(_ statement: String, exchangeID: UUID) {
        do {
            let entry = MemoryEntry(key: "followup:\(exchangeID.uuidString)", statement: statement, evidenceCount: 1)
            try MemorySafety.validate(entry.statement)
            try persistence.saveMemory(entry)
            analytics.track(.memoryAccepted)
        } catch {
            // An unsafe or unstorable statement is dropped silently, same as
            // acceptPendingMemory -- never worth bothering the user about.
        }
        try? persistence.clearFollowUpDurablePreference(exchangeID: exchangeID)
        reload()
    }

    func declineFollowUpPreference(exchangeID: UUID) {
        try? persistence.clearFollowUpDurablePreference(exchangeID: exchangeID)
        reload()
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

    // MARK: - Quota status

    private func quotaStatusService() -> QuotaStatusService {
        RemoteQuotaStatusService(
            configuration: configuration,
            installId: InstallIdentity.current,
            proTransactionProvider: { [subscriptions] in await subscriptions.currentTransactionJWS() }
        )
    }

    /// Best-effort, silent on failure: this is a read-only convenience for the
    /// Profile screen, never on the critical path for starting or completing
    /// a decision, so a failed fetch just means that screen doesn't show live
    /// numbers this time -- never a reason to surface an error.
    func refreshQuotaStatus() async {
        guard configuration.isBackendConfigured else { return }
        quotaStatus = try? await quotaStatusService().fetchStatus()
    }
}
