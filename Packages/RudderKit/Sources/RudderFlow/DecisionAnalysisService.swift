import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RudderCore

/// What the app sends to its own backend. No credentials, no device identifiers —
/// just the decision and what the user has already told us.
public struct DecisionAnalysisRequest: Encodable, Sendable {
    public struct Answer: Encodable, Sendable {
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

public protocol DecisionAnalysisService: Sendable {
    func analyse(_ request: DecisionAnalysisRequest) async throws -> ValidatedAIResponse
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

    public func analyse(_ request: DecisionAnalysisRequest) async throws -> ValidatedAIResponse {
        guard configuration.isBackendConfigured else { throw RudderServiceError.notConfigured }
        guard reachability() else { throw RudderServiceError.offline }

        do {
            return try await perform(request)
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
            return try await perform(strict)
        }
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

    private func perform(_ request: DecisionAnalysisRequest) async throws -> ValidatedAIResponse {
        guard let baseURL = configuration.apiBaseURL else { throw RudderServiceError.notConfigured }
        let endpoint = baseURL.appendingPathComponent("v1/decisions/analyze")
        let body = try JSONEncoder().encode(request)
        let (data, http) = try await send(body: body, to: endpoint)
        try checkStatus(http)
        return try await resolve(data: data, endpoint: endpoint)
    }

    /// Either the finished result, or -- when the backend answered
    /// `{ jobId, pending: true }` because one analyse() attempt didn't finish
    /// inside its own time budget (see JOB_RACE_DEADLINE_MS in
    /// Backend/src/handler.ts) -- polls the same endpoint with that jobId
    /// until it is. This is what makes a slow analysis a wait instead of a
    /// failure: the previous behaviour was one request, one timeout, one
    /// error shown to the user with nothing to do but tap Try Again and hope
    /// the same race goes better. Backgrounding the app mid-poll is covered
    /// by DecisionCoordinator's existing background-task window (this loop
    /// just keeps running during it instead of a single doomed await) --
    /// resuming a poll after the app was fully closed and relaunched is not
    /// yet implemented.
    private func resolve(data: Data, endpoint: URL) async throws -> ValidatedAIResponse {
        guard let envelope = try? JSONDecoder().decode(JobEnvelope.self, from: data),
              envelope.pending == true,
              let jobId = envelope.jobId
        else {
            return try decodeResult(data)
        }

        let deadline = Date().addingTimeInterval(Self.jobPollDeadline)
        while Date() < deadline {
            guard reachability() else { throw RudderServiceError.offline }
            do {
                try await Task.sleep(nanoseconds: Self.jobPollInterval)
            } catch {
                throw RudderServiceError.cancelled
            }

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
