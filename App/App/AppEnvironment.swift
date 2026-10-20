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
    /// One switch for the whole feature, not a per-fact decision -- the
    /// per-entry "Use this" toggles below it stay for someone who wants to
    /// drop a single learned fact, but most people only ever want memory on
    /// or off entirely. Backed by UserDefaults rather than `persistence`
    /// since it's a device setting, not data to sync or export.
    private(set) var isMemoryEnabled: Bool
    private static let memoryEnabledDefaultsKey = "rudder.isMemoryEnabled"
    /// A decision whose analysis is still running on the backend after this
    /// process itself was closed and relaunched -- the one case a single
    /// `Task`'s own background-execution grace window cannot cover. Backed by
    /// UserDefaults (device-local, not data to sync or export) so it survives
    /// exactly that. Set the moment `DecisionCoordinator` reports a job it
    /// couldn't finish inline, cleared the moment that job resolves either
    /// way -- never left stale once its own outcome is known.
    private(set) var pendingDecisionJob: PendingDecisionJob?
    private static let pendingDecisionJobDefaultsKey = "rudder.pendingDecisionJob"
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
        // Defaults to on: this only has any effect for a Pro subscriber, and
        // Decision Memory has always been opt-in by consenting to each
        // proposed fact -- this switch is one more layer on top of that,
        // not instead of it.
        self.isMemoryEnabled = UserDefaults.standard.object(forKey: Self.memoryEnabledDefaultsKey) as? Bool ?? true
        if let data = UserDefaults.standard.data(forKey: Self.pendingDecisionJobDefaultsKey) {
            self.pendingDecisionJob = try? JSONDecoder().decode(PendingDecisionJob.self, from: data)
        }
        reload()
    }

    /// Passed to `DecisionCoordinator` as `onPendingJob` -- see its doc
    /// comment. Only one decision can be "the one still running" at a time,
    /// so this simply replaces whatever was there; the previous one, if any,
    /// already got its own `onJobResolved` call when it finished (that's how
    /// a decision stops being the pending one in the first place).
    func savePendingDecisionJob(_ job: PendingDecisionJob) {
        pendingDecisionJob = job
        guard let data = try? JSONEncoder().encode(job) else { return }
        UserDefaults.standard.set(data, forKey: Self.pendingDecisionJobDefaultsKey)
    }

    /// Passed to `DecisionCoordinator` as `onJobResolved`.
    func clearPendingDecisionJob() {
        pendingDecisionJob = nil
        UserDefaults.standard.removeObject(forKey: Self.pendingDecisionJobDefaultsKey)
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
        let isFirstDecision = decisions.isEmpty
        do {
            try persistence.save(record)
            analytics.track(.decisionSaved)
            reload()
            refreshMemoryCandidate()
            // Asked here, not on launch: the permission prompt follows the
            // user's first real value from the app instead of preceding it.
            if isFirstDecision {
                Task { await NotificationService.shared.requestAuthorizationIfNeeded() }
            }
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

    func setMemoryEnabled(_ isEnabled: Bool) {
        isMemoryEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: Self.memoryEnabledDefaultsKey)
        if !isEnabled {
            pendingMemoryCandidate = nil
        }
    }

    /// Looks for a preference worth proposing. Pro-only, and never automatic:
    /// the user is asked before anything is stored.
    func refreshMemoryCandidate() {
        guard isPro, isMemoryEnabled else {
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

    /// Every preference `MemoryEngine` can currently find, not just the one
    /// `refreshMemoryCandidate` proposes after a single decision -- a
    /// deliberate, user-initiated scan across everything already decided,
    /// for someone who doesn't want to wait for them one at a time.
    /// Still returns only candidates, never writes anything: the bulk
    /// "Remember" action below is the actual consent.
    func allMemoryCandidates() -> [MemoryCandidate] {
        guard isPro, isMemoryEnabled else { return [] }
        return MemoryEngine.candidates(from: decisions, existing: memory, excludedKeys: declinedMemoryKeys)
    }

    /// Consent-gated the same way `acceptPendingMemory` is, just for several
    /// candidates from one explicit "Remember selected" action instead of
    /// one standing proposal. A candidate that fails safety validation is
    /// dropped silently, same as the single-candidate path -- it never
    /// blocks the rest of the batch.
    func acceptMemoryCandidates(_ candidates: [MemoryCandidate]) {
        guard !candidates.isEmpty else { return }
        for candidate in candidates {
            guard let entry = try? MemoryEngine.accept(candidate) else { continue }
            try? persistence.saveMemory(entry)
        }
        analytics.track(.memoryAccepted)
        pendingMemoryCandidate = nil
        reload()
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
        let joined = parts.joined(separator: "\n")
        // Mirrors FollowUpRequestSchema.decisionContext's own `.max(3000)` in
        // Backend/src/schema.ts. A decision whose reasons and trade-offs sit
        // near their own max lengths can otherwise exceed it, which would
        // reject every follow-up on that decision with 400 forever rather
        // than just this one being a little less complete.
        return String(joined.prefix(3000))
    }

    /// Asks a follow-up question about an already-finished decision and
    /// persists the exchange on success, so it survives app restarts.
    /// Throws rather than returning nil on failure, same as a new decision's
    /// own analysis -- the caller shows what actually went wrong.
    func askFollowUp(_ question: String, about record: DecisionRecord) async throws -> FollowUpExchange {
        // Capped at the most recent 10, mirroring FollowUpRequestSchema.history's
        // own `.max(10)` in Backend/src/schema.ts -- without this, a decision
        // already past 10 follow-ups would send an oversized history forever,
        // and every further follow-up on it would be rejected with 400.
        let history = followUpExchanges(for: record).suffix(10).map {
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
            // Keyed by the statement's own text, not the exchange -- the same
            // wording surfacing again from a follow-up on a different decision
            // then updates the one existing entry instead of piling up an
            // identical-looking row next to it. This only catches an exact
            // repeat; a differently-worded but equivalent preference is a
            // real product call (how it should merge with MemoryEngine's own
            // "A>B" keyed candidates), not something to guess at here.
            let key = "followup:\(statement.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
            let entry = MemoryEntry(key: key, statement: statement, evidenceCount: 1)
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
            memoryProvider: { [weak self] in
                guard let self, self.isMemoryEnabled else { return [] }
                return self.memory
            },
            onPendingJob: { [weak self] job in self?.savePendingDecisionJob(job) },
            onJobResolved: { [weak self] in self?.clearPendingDecisionJob() }
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
