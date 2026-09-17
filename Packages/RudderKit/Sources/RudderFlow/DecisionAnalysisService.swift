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
            config.timeoutIntervalForRequest = 45
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

    private func perform(_ request: DecisionAnalysisRequest) async throws -> ValidatedAIResponse {
        guard let baseURL = configuration.apiBaseURL else { throw RudderServiceError.notConfigured }
        let endpoint = baseURL.appendingPathComponent("v1/decisions/analyze")

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue(installId, forHTTPHeaderField: "X-Rudder-Install-Id")
        if let transaction = await proTransactionProvider() {
            urlRequest.setValue(transaction, forHTTPHeaderField: "X-Rudder-Transaction")
        }
        urlRequest.httpBody = try JSONEncoder().encode(request)

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
        switch http.statusCode {
        case 200...299:
            break
        case 429:
            throw RudderServiceError.rateLimited
        case 400...499:
            throw RudderServiceError.invalidResponse
        default:
            throw RudderServiceError.serverUnavailable
        }

        // A response that cannot be decoded, validated or repaired is a service
        // failure — never something that reaches the UI half-formed.
        do {
            let decoded = try JSONDecoder().decode(AIDecisionResponse.self, from: data)
            return try AIResponseValidator.validate(decoded)
        } catch {
            throw RudderServiceError.invalidResponse
        }
    }
}
