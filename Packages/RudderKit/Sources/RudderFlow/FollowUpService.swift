import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RudderCore

/// What the app sends to its own backend for a follow-up question on an
/// already-finished decision. Mirrors `FollowUpRequestSchema` in
/// Backend/src/schema.ts.
public struct FollowUpRequest: Encodable, Sendable {
    public struct Exchange: Encodable, Sendable {
        public let question: String
        public let answer: String

        public init(question: String, answer: String) {
            self.question = question
            self.answer = answer
        }
    }

    public let schemaVersion: Int
    public let originalPrompt: String
    /// A compact, app-rendered summary of the finished decision -- not the
    /// full DecisionResult, which would cost far more tokens than a short
    /// follow-up answer needs.
    public let decisionContext: String
    /// Prior exchanges in this same thread, oldest first.
    public let history: [Exchange]
    public let question: String
    public let locale: String

    public init(
        originalPrompt: String,
        decisionContext: String,
        history: [Exchange] = [],
        question: String,
        locale: Locale = .current
    ) {
        self.schemaVersion = AIDecisionResponse.currentSchemaVersion
        self.originalPrompt = originalPrompt
        self.decisionContext = decisionContext
        self.history = history
        self.question = question
        self.locale = locale.identifier
    }
}

/// Quota usage after spending this follow-up -- same shape `peekDailyQuota`
/// reports in Backend/src/quota.ts, plus which bucket it came from.
public struct FollowUpQuotaInfo: Decodable, Sendable, Equatable {
    public let bucket: String
    public let used: Int
    public let limit: Int
    public let resetsAt: String
}

public struct FollowUpResult: Sendable {
    public let response: FollowUpResponseDTO
    public let quota: FollowUpQuotaInfo?

    public init(response: FollowUpResponseDTO, quota: FollowUpQuotaInfo?) {
        self.response = response
        self.quota = quota
    }
}

public protocol FollowUpService: Sendable {
    func answer(_ request: FollowUpRequest) async throws -> FollowUpResult
}

/// Talks to RUDDER's own `POST /v1/decisions/followup` -- a single short,
/// cheap call, not the full analyse pipeline `RemoteDecisionAnalysisService`
/// drives. No strict-schema retry: a follow-up's contract is far smaller, and
/// the tolerant decoding in FollowUpResponseDTO already absorbs a missing
/// optional field.
public struct RemoteFollowUpService: FollowUpService {
    let configuration: AppConfiguration
    let session: URLSession
    let reachability: @Sendable () -> Bool
    let installId: String
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
            config.timeoutIntervalForRequest = 25
            config.timeoutIntervalForResource = 30
            config.httpAdditionalHeaders = ["Content-Type": "application/json"]
            self.session = URLSession(configuration: config)
        }
        self.reachability = reachability ?? { Reachability.shared.isConnected }
        self.installId = installId
        self.proTransactionProvider = proTransactionProvider
    }

    public func answer(_ request: FollowUpRequest) async throws -> FollowUpResult {
        guard configuration.isBackendConfigured else { throw RudderServiceError.notConfigured }
        guard reachability() else { throw RudderServiceError.offline }
        guard let baseURL = configuration.apiBaseURL else { throw RudderServiceError.notConfigured }
        let endpoint = baseURL.appendingPathComponent("v1/decisions/followup")

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

        // `quota` sits alongside the follow-up's own fields in the same JSON
        // object (see handleFollowUp in Backend/src/handler.ts), so both are
        // decoded from the same top-level container rather than a nested one.
        struct Wire: Decodable {
            let response: FollowUpResponseDTO
            let quota: FollowUpQuotaInfo?

            enum CodingKeys: String, CodingKey { case quota }

            init(from decoder: any Decoder) throws {
                response = try FollowUpResponseDTO(from: decoder)
                let container = try decoder.container(keyedBy: CodingKeys.self)
                quota = try container.decodeIfPresent(FollowUpQuotaInfo.self, forKey: .quota)
            }
        }

        do {
            let decoded = try JSONDecoder().decode(Wire.self, from: data)
            guard !decoded.response.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RudderServiceError.invalidResponse
            }
            return FollowUpResult(response: decoded.response, quota: decoded.quota)
        } catch let error as RudderServiceError {
            throw error
        } catch {
            throw RudderServiceError.invalidResponse
        }
    }
}
