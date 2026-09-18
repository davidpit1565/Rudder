import Foundation
import StoreKit
import Observation

/// Entitlement is one piece of state, owned by one object, derived from StoreKit.
///
/// Nothing else in the app decides whether someone is Pro, and nothing writes
/// "isPro" into UserDefaults: the only source of truth is the current entitlement.
@MainActor
@Observable
final class SubscriptionService {

    enum Entitlement: Equatable {
        /// Before the first check completes. The UI shows a loading state rather
        /// than guessing, so Pro features are never falsely shown or falsely hidden.
        case unknown
        case checking
        case notSubscribed
        case subscribed(expires: Date?, isInGracePeriod: Bool)
        /// Renewal failed and Apple is retrying. Access continues while Apple says it should.
        case billingRetry(expires: Date?)
        case expired(on: Date?)

        var grantsPro: Bool {
            switch self {
            case .subscribed, .billingRetry: return true
            case .unknown, .checking, .notSubscribed, .expired: return false
            }
        }

        var isResolved: Bool {
            switch self {
            case .unknown, .checking: return false
            default: return true
            }
        }
    }

    enum PurchaseOutcome: Equatable {
        case success
        case pending
        case cancelled
        case failed(String)
    }

    enum ProductID {
        static let monthly = "com.rudder.app.pro.monthly"
        static let annual = "com.rudder.app.pro.annual"
        static let all = [monthly, annual]
    }

    private(set) var entitlement: Entitlement = .unknown
    private(set) var products: [Product] = []
    private(set) var isLoadingProducts = false
    private(set) var productLoadFailed = false
    /// Whether this Apple Account can still redeem each product's introductory
    /// offer -- false once it's been used before, on this or another subscription
    /// in the same group. Read fresh per load rather than assumed, so the paywall
    /// never promises a trial that StoreKit won't actually grant.
    private(set) var introOfferEligibility: [String: Bool] = [:]

    /// The single question the rest of the app asks.
    var isPro: Bool { entitlement.grantsPro }

    /// Held for the lifetime of the app: StoreKit can deliver a transaction at any
    /// time — a renewal, a purchase made on another device, a refund — and missing
    /// one would leave the entitlement stale.
    private var updatesTask: Task<Void, Never>?

    init() {
        updatesTask = listenForTransactions()
    }

    var monthly: Product? { products.first { $0.id == ProductID.monthly } }
    var annual: Product? { products.first { $0.id == ProductID.annual } }

    /// Saving versus twelve months of the monthly plan, computed from live prices
    /// rather than hard-coded, so it can never drift from what the user is charged.
    var annualSavingPercentage: Int? {
        guard let monthly, let annual else { return nil }
        let yearAtMonthlyRate = monthly.price * 12
        guard yearAtMonthlyRate > 0, annual.price < yearAtMonthlyRate else { return nil }
        let saving = (yearAtMonthlyRate - annual.price) / yearAtMonthlyRate
        return Int((saving as NSDecimalNumber).doubleValue * 100)
    }

    func loadProducts() async {
        guard products.isEmpty else { return }
        isLoadingProducts = true
        productLoadFailed = false
        defer { isLoadingProducts = false }

        do {
            let loaded = try await Product.products(for: ProductID.all)
            products = loaded.sorted { lhs, rhs in
                // Monthly first, annual second — the comparison the user makes.
                lhs.id == ProductID.monthly && rhs.id == ProductID.annual
            }
            productLoadFailed = loaded.isEmpty
            await loadIntroOfferEligibility()
        } catch {
            productLoadFailed = true
        }
    }

    private func loadIntroOfferEligibility() async {
        var eligibility: [String: Bool] = [:]
        for product in products {
            guard let subscription = product.subscription else { continue }
            eligibility[product.id] = await subscription.isEligibleForIntroOffer
        }
        introOfferEligibility = eligibility
    }

    /// The signed JWS of the current Pro entitlement's transaction, sent to the
    /// backend as proof of purchase so it can enforce the Free/Pro line itself
    /// rather than trusting a client-declared boolean. `nil` when there is no
    /// current entitlement -- the request then falls back to the Free quota,
    /// which is the correct, safe default.
    func currentTransactionJWS() async -> String? {
        for await verification in Transaction.currentEntitlements {
            guard case .verified(let transaction) = verification else { continue }
            guard ProductID.all.contains(transaction.productID) else { continue }
            guard transaction.revocationDate == nil else { continue }
            guard let expiry = transaction.expirationDate, expiry > Date() else { continue }
            return verification.jwsRepresentation
        }
        return nil
    }

    func refreshEntitlement() async {
        if !entitlement.isResolved { entitlement = .checking }

        var resolved: Entitlement = .notSubscribed

        for await verification in Transaction.currentEntitlements {
            guard case .verified(let transaction) = verification else { continue }
            guard ProductID.all.contains(transaction.productID) else { continue }
            if let revocation = transaction.revocationDate {
                resolved = .expired(on: revocation)
                continue
            }
            if let expiry = transaction.expirationDate, expiry < Date() {
                resolved = .expired(on: expiry)
                continue
            }

            var isInGracePeriod = false
            var isInBillingRetry = false
            if let status = await transaction.subscriptionStatus,
               case .verified(let renewalInfo) = status.renewalInfo {
                isInGracePeriod = renewalInfo.gracePeriodExpirationDate.map { $0 > Date() } ?? false
                isInBillingRetry = renewalInfo.isInBillingRetry
            }

            if isInBillingRetry && !isInGracePeriod {
                resolved = .billingRetry(expires: transaction.expirationDate)
            } else {
                resolved = .subscribed(
                    expires: transaction.expirationDate,
                    isInGracePeriod: isInGracePeriod
                )
            }
            break
        }

        entitlement = resolved
    }

    func purchase(_ product: Product) async -> PurchaseOutcome {
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    await refreshEntitlement()
                    return .success
                case .unverified:
                    // A transaction we cannot verify never grants access.
                    return .failed("That purchase couldn't be verified.")
                }
            case .pending:
                // Ask to Buy, SCA, and similar: access waits for approval.
                return .pending
            case .userCancelled:
                return .cancelled
            @unknown default:
                return .failed("That purchase didn't complete.")
            }
        } catch {
            return .failed("That purchase didn't complete.")
        }
    }

    /// Required by App Store review, and the honest way back for anyone who
    /// reinstalls or changes device.
    func restorePurchases() async -> PurchaseOutcome {
        do {
            try await AppStore.sync()
            await refreshEntitlement()
            return isPro ? .success : .failed("I couldn't find an active subscription on this Apple Account.")
        } catch {
            return .failed("I couldn't reach the App Store. Try again in a moment.")
        }
    }

    private func listenForTransactions() -> Task<Void, Never> {
        Task.detached { [weak self] in
            for await verification in Transaction.updates {
                guard case .verified(let transaction) = verification else { continue }
                await transaction.finish()
                await self?.refreshEntitlement()
            }
        }
    }
}
