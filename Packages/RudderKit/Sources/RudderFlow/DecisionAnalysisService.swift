import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RudderCore

/// What the app sends to its own backend. No credentials, no device identifiers —
/// just the decision and what the user has already told us.
public struct DecisionAnalysisRequest: Encodable, Sendable {
    public struct Answer: Codable, Sendable {
        public let questionId: String
        public let answer: String

        public init(questionId: String, answer: String) {
            self.questionId = questionId
            self.answer = answer
        }
    }

    public let schemaVersion: Int
    public let prompt: String
    public let answers: [Answer]
    /// Preferences the user explicitly agreed to remember.
    public let knownPreferences: [String]
    public let category: String
    public let complexity: String
    public let researchLevel: String
    public let maximumResearchCalls: Int
    public let maximumSources: Int
    public let questionsAlreadyAsked: Int
    public let questionCeiling: Int
    /// Set on a retry after a malformed response, so the backend can be stricter.
    public let strictSchema: Bool
    public let locale: String

    public init(
        prompt: String,
        answers: [Answer] = [],
        knownPreferences: [String] = [],
        classification: DecisionClassifier.Classification,
        budget: DecisionBudget,
        questionsAlreadyAsked: Int = 0,
        strictSchema: Bool = false,
        locale: Locale = .current
    ) {
        self.schemaVersion = AIDecisionResponse.currentSchemaVersion
        self.prompt = prompt
        self.answers = answers
        self.knownPreferences = knownPreferences
        self.category = classification.category.rawValue
        self.complexity = classification.complexity.rawValue
        self.researchLevel = budget.researchLevel.rawValue
        self.maximumResearchCalls = budget.maximumResearchCalls
        self.maximumSources = budget.maximumSources
        self.questionsAlreadyAsked = questionsAlreadyAsked
        self.questionCeiling = budget.questionCeiling
        self.strictSchema = strictSchema
        self.locale = locale.identifier
    }
}

/// Everything needed to pick a decision's polling back up after the app that
/// started it is fully closed and relaunched -- the one thing a single
/// in-memory `Task`, however long its background-execution grace window,
/// cannot survive on its own. Persisted by whoever owns `DecisionCoordinator`
/// (see its `onPendingJob`/`resume(from:)`) the moment a job is slow enough to
/// need it, and cleared the moment it resolves either way.
public struct PendingDecisionJob: Codable, Sendable, Equatable {
    public let jobId: String
    public let prompt: String
    public let answers: [DecisionAnalysisRequest.Answer]
    public let questionsAsked: [String]
    public let complexityOverride: DecisionComplexity?
    public let decisionID: UUID
    public let createdAt: Date

    public init(
        jobId: String,
        prompt: String,
        answers: [DecisionAnalysisRequest.Answer],
        questionsAsked: [String],
        complexityOverride: DecisionComplexity?,
        decisionID: UUID,
        createdAt: Date = Date()
    ) {
        self.jobId = jobId
        self.prompt = prompt
        self.answers = answers
        self.questionsAsked = questionsAsked
        self.complexityOverride = complexityOverride
        self.decisionID = decisionID
        self.createdAt = createdAt
    }
}

public protocol DecisionAnalysisService: Sendable {
    /// `onPending` fires at most once per call, the moment the backend
    /// reports `{ jobId, pending: true }` (see Backend/src/handler.ts) instead
    /// of a finished result -- the caller's only chance to persist that jobId
    /// before this same call goes on to poll it to completion itself.
    func analyse(_ request: DecisionAnalysisRequest, onPending: @escaping @Sendable (String) -> Void) async throws -> ValidatedAIResponse
    /// Picks a job's polling back up from just its ID -- no new request body,
    /// no new charge, the same `{ jobId }` shape `analyse(_:onPending:)` uses
    /// internally once it already has one.
    func continueJob(_ jobId: String) async throws -> ValidatedAIResponse
}

/// Talks to RUDDER's backend, validates whatever comes back, and retries once
/// with a stricter request if the response could not be repaired.
public struct RemoteDecisionAnalysisService: DecisionAnalysisService {
    let configuration: AppConfiguration
    let session: URLSession
    let reachability: @Sendable () -> Bool
    /// A stable, anonymous per-install identifier, sent so the backend can
    /// enforce the Free tier's monthly deep-decision cap itself.
    let installId: String
    /// The current Pro entitlement's signed transaction, if any -- proof the
    /// backend independently verifies rather than trusting an "isPro" claim.
    let proTransactionProvider: @Sendable () async -> String?

    public init(
        configuration: AppConfiguration = .shared,
        session: URLSession? = nil,
        reachability: (@Sendable () -> Bool)? = nil,
        installId: String,
        proTransactionProvider: @escaping @Sendable () async -> String? = { nil }
    ) {
        self.configuration = configuration
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            // Must stay comfortably above the backend's own pipeline deadline
            // (52s, see PIPELINE_DEADLINE_MS in Backend/src/analyze.ts) and
            // Vercel's hard 60s function ceiling -- a client timeout shorter
            // than the server's own meant the app was giving up and showing
            // an error at 45s, on exactly the decisions (medium/complex with
            // research) that the server would otherwise have answered a few
            // seconds later inside its own, already-tuned budget.
            config.timeoutIntervalForRequest = 70
            config.timeoutIntervalForResource = 90
            // Deliberately not waiting for connectivity: an offline user is told
            // so straight away rather than left watching a spinner.
            config.httpAdditionalHeaders = ["Content-Type": "application/json"]
            self.session = URLSession(configuration: config)
        }
        self.reachability = reachability ?? { Reachability.shared.isConnected }
        self.installId = installId
        self.proTransactionProvider = proTransactionProvider
    }

    public func analyse(
        _ request: DecisionAnalysisRequest,
        onPending: @escaping @Sendable (String) -> Void
    ) async throws -> ValidatedAIResponse {
        guard configuration.isBackendConfigured else { throw RudderServiceError.notConfigured }
        guard reachability() else { throw RudderServiceError.offline }

        do {
            return try await perform(request, onPending: onPending)
        } catch RudderServiceError.invalidResponse {
            // One retry, asking the backend to be stricter about the schema.
            let strict = DecisionAnalysisRequest(
                prompt: request.prompt,
                answers: request.answers,
                knownPreferences: request.knownPreferences,
                classification: .init(
                    category: DecisionCategory(rawValue: request.category) ?? .other,
                    complexity: DecisionComplexity(rawValue: request.complexity) ?? .medium,
                    researchLevel: ResearchLevel(rawValue: request.researchLevel) ?? .none,
                    optionCountHint: 0
                ),
                budget: DecisionBudget(
                    researchLevel: ResearchLevel(rawValue: request.researchLevel) ?? .none,
                    maximumResearchCalls: request.maximumResearchCalls,
                    maximumSources: request.maximumSources,
                    maximumModelCalls: 2,
                    questionCeiling: request.questionCeiling
                ),
                questionsAlreadyAsked: request.questionsAlreadyAsked,
                strictSchema: true
            )
            return try await perform(strict, onPending: onPending)
        }
    }

    public func continueJob(_ jobId: String) async throws -> ValidatedAIResponse {
        guard configuration.isBackendConfigured else { throw RudderServiceError.notConfigured }
        guard reachability() else { throw RudderServiceError.offline }
        guard let baseURL = configuration.apiBaseURL else { throw RudderServiceError.notConfigured }
        let endpoint = baseURL.appendingPathComponent("v1/decisions/analyze")
        // The next poll happens immediately, not after another jobPollInterval
        // wait: resuming from a relaunch is itself evidence enough time has
        // already passed since the job was left running.
        return try await pollUntilDone(jobId: jobId, endpoint: endpoint, waitFirst: false)
    }

    /// Present only on the backend's `{ jobId, pending: true }` shape (see
    /// Backend/src/handler.ts's respondForJob) -- a real `AIDecisionResponse`
    /// has neither field, so decoding this first and checking `pending` is
    /// enough to tell the two apart without guessing from the HTTP status.
    private struct JobEnvelope: Decodable {
        let jobId: String?
        let pending: Bool?
    }

    private struct ContinueRequest: Encodable {
        let jobId: String
    }

    /// How long to keep polling an in-progress job before giving up --
    /// matches JOB_TTL_SECONDS in Backend/src/jobs.ts, so this never gives up
    /// on a job the server itself would still happily resume.
    private static let jobPollDeadline: TimeInterval = 600
    private static let jobPollInterval: UInt64 = 2_500_000_000

    private func perform(
        _ request: DecisionAnalysisRequest,
        onPending: @escaping @Sendable (String) -> Void
    ) async throws -> ValidatedAIResponse {
        guard let baseURL = configuration.apiBaseURL else { throw RudderServiceError.notConfigured }
        let endpoint = baseURL.appendingPathComponent("v1/decisions/analyze")
        let body = try JSONEncoder().encode(request)
        let (data, http) = try await send(body: body, to: endpoint)
        try checkStatus(http)

        guard let envelope = try? JSONDecoder().decode(JobEnvelope.self, from: data),
              envelope.pending == true,
              let jobId = envelope.jobId
        else {
            return try decodeResult(data)
        }
        onPending(jobId)
        return try await pollUntilDone(jobId: jobId, endpoint: endpoint, waitFirst: true)
    }

    /// Polls `{ jobId }` against the same endpoint until the job is actually
    /// done or failed, instead of treating "still working" as an error. This
    /// is what makes a slow analysis a wait instead of a failure: the
    /// previous behaviour was one request, one timeout, one error shown to
    /// the user with nothing to do but tap Try Again and hope the same race
    /// goes better. Backgrounding the app mid-poll is covered by
    /// DecisionCoordinator's existing background-task window (this loop just
    /// keeps running during it instead of a single doomed await); the app
    /// being fully closed and relaunched is covered by `continueJob(_:)`
    /// above, called from `DecisionCoordinator.resume(from:)` with a jobId
    /// persisted by `onPending` before this method was ever reached.
    private func pollUntilDone(jobId: String, endpoint: URL, waitFirst: Bool) async throws -> ValidatedAIResponse {
        let deadline = Date().addingTimeInterval(Self.jobPollDeadline)
        var shouldWait = waitFirst
        while Date() < deadline {
            guard reachability() else { throw RudderServiceError.offline }
            if shouldWait {
                do {
                    try await Task.sleep(nanoseconds: Self.jobPollInterval)
                } catch {
                    throw RudderServiceError.cancelled
                }
            }
            shouldWait = true

            let body = try JSONEncoder().encode(ContinueRequest(jobId: jobId))
            let (data, http) = try await send(body: body, to: endpoint)
            try checkStatus(http)
            if let envelope = try? JSONDecoder().decode(JobEnvelope.self, from: data), envelope.pending == true {
                continue
            }
            return try decodeResult(data)
        }
        throw RudderServiceError.timedOut
    }

    private func send(body: Data, to endpoint: URL) async throws -> (Data, HTTPURLResponse) {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue(installId, forHTTPHeaderField: "X-Rudder-Install-Id")
        if let transaction = await proTransactionProvider() {
            urlRequest.setValue(transaction, forHTTPHeaderField: "X-Rudder-Transaction")
        }
        urlRequest.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                throw RudderServiceError.offline
            case .timedOut:
                throw RudderServiceError.timedOut
            case .cancelled:
                throw RudderServiceError.cancelled
            default:
                throw RudderServiceError.serverUnavailable
            }
        } catch {
            throw RudderServiceError.unknown
        }

        guard let http = response as? HTTPURLResponse else { throw RudderServiceError.serverUnavailable }
        return (data, http)
    }

    private func checkStatus(_ http: HTTPURLResponse) throws {
        switch http.statusCode {
        case 200...299:
            return
        case 429:
            throw RudderServiceError.rateLimited
        case 400...499:
            throw RudderServiceError.invalidResponse
        default:
            throw RudderServiceError.serverUnavailable
        }
    }

    /// A response that cannot be decoded, validated or repaired is a service
    /// failure — never something that reaches the UI half-formed.
    private func decodeResult(_ data: Data) throws -> ValidatedAIResponse {
        do {
            let decoded = try JSONDecoder().decode(AIDecisionResponse.self, from: data)
            return try AIResponseValidator.validate(decoded)
        } catch {
            throw RudderServiceError.invalidResponse
        }
    }
}
