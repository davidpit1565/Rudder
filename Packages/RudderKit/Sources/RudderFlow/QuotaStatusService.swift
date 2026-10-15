import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One bucket's current usage, as the backend actually enforces it
/// (Backend/src/quota.ts) -- never computed locally, since a client-side
/// count can't see another device's spend or survive a reinstall.
public struct QuotaBucketStatus: Decodable, Sendable, Equatable {
    public let used: Int
    public let limit: Int
    /// ISO 8601. Kept as a string, like every other timestamp this app
    /// decodes from the backend -- parsed only where a view actually needs
    /// to format it.
    public let resetsAt: String
}

public struct ComplexQuotaStatus: Decodable, Sendable, Equatable {
    /// Set only for a Free install: the monthly quota that makes a recurring
    /// Free complex decision not exist (Backend/src/quota.ts).
    public let monthly: QuotaBucketStatus?
    /// Set only for a verified Pro subscriber: a daily abuse backstop,
    /// generous enough that no real user hits it.
    public let daily: QuotaBucketStatus?
}

/// Everything the Profile screen needs to show "X of Y used today", for
/// every tier a quota actually governs. "simple" is never included -- it is
/// never limited, at any tier.
public struct QuotaStatus: Decodable, Sendable, Equatable {
    public let isPro: Bool
    public let medium: QuotaBucketStatus
    public let complex: ComplexQuotaStatus
    /// Today's follow-up usage -- its own bucket, separate from starting a new
    /// decision (Backend/src/quota.ts).
    public let followup: QuotaBucketStatus
}

public protocol QuotaStatusService: Sendable {
    func fetchStatus() async throws -> QuotaStatus
}

/// Talks to RUDDER's own `GET /v1/quota/status` -- a read-only peek at the
/// same counts `RemoteDecisionAnalysisService` enforces, so the numbers
/// shown here always match what starting a decision would actually allow.
public struct RemoteQuotaStatusService: QuotaStatusService {
    let configuration: AppConfiguration
    let session: URLSession
    let installId: String
    let proTransactionProvider: @Sendable () async -> String?

    public init(
        configuration: AppConfiguration = .shared,
        session: URLSession? = nil,
        installId: String,
        proTransactionProvider: @escaping @Sendable () async -> String? = { nil }
    ) {
        self.configuration = configuration
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 20
            self.session = URLSession(configuration: config)
        }
        self.installId = installId
        self.proTransactionProvider = proTransactionProvider
    }

    public func fetchStatus() async throws -> QuotaStatus {
        guard let baseURL = configuration.apiBaseURL else { throw RudderServiceError.notConfigured }
        let endpoint = baseURL.appendingPathComponent("v1/quota/status")

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue(installId, forHTTPHeaderField: "X-Rudder-Install-Id")
        if let transaction = await proTransactionProvider() {
            urlRequest.setValue(transaction, forHTTPHeaderField: "X-Rudder-Transaction")
        }

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

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw RudderServiceError.serverUnavailable
        }

        do {
            return try JSONDecoder().decode(QuotaStatus.self, from: data)
        } catch {
            throw RudderServiceError.invalidResponse
        }
    }
}
