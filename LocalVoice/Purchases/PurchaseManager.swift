import Foundation
import StoreKit

extension Notification.Name {
    static let localVoicePurchaseRequired = Notification.Name("LocalVoicePurchaseRequired")
}

@MainActor
final class PurchaseManager: ObservableObject {
    static let shared = PurchaseManager()
    static let lifetimeProductID = "app.localvoice.LocalVoice.lifetime"

    enum AccessState: Equatable {
        case unrestrictedDistribution
        case loading
        case trial(daysRemaining: Int, expirationDate: Date)
        case lifetime
        case expired
    }

    enum PurchaseError: LocalizedError {
        case failedVerification
        case productUnavailable

        var errorDescription: String? {
            switch self {
            case .failedVerification:
                return String(localized: "The App Store could not verify this purchase.")
            case .productUnavailable:
                return String(localized: "The lifetime purchase is temporarily unavailable.")
            }
        }
    }

    @Published private(set) var lifetimeProduct: Product?
    @Published private(set) var hasLifetimeAccess = false
    @Published private(set) var isLoading = false
    @Published private(set) var isPurchasing = false
    @Published private(set) var errorMessage: String?

    private static let trialStartKey = "purchase.trialStartDate.v1"
    private static let trialStartFallbackKey = "LocalVoiceTrialStartDateFallbackV1"
    private let keychain: KeychainService
    private let now: () -> Date
    private var updatesTask: Task<Void, Never>?
    private(set) var trial: TrialPeriod

    private init(
        keychain: KeychainService = .shared,
        now: @escaping () -> Date = Date.init
    ) {
        self.keychain = keychain
        self.now = now
        let startDate = Self.loadOrCreateTrialStartDate(keychain: keychain, now: now())
        self.trial = TrialPeriod(startDate: startDate)

        guard AppDistribution.isAppStore else {
            hasLifetimeAccess = true
            return
        }

        updatesTask = observeTransactionUpdates()
        Task { await refresh() }
    }

    deinit {
        updatesTask?.cancel()
    }

    var accessState: AccessState {
        guard AppDistribution.isAppStore else { return .unrestrictedDistribution }
        if hasLifetimeAccess { return .lifetime }
        if isLoading && lifetimeProduct == nil { return .loading }
        let currentDate = now()
        if trial.isActive(at: currentDate) {
            return .trial(
                daysRemaining: trial.daysRemaining(at: currentDate),
                expirationDate: trial.expirationDate()
            )
        }
        return .expired
    }

    var canUsePremiumFeatures: Bool {
        switch accessState {
        case .unrestrictedDistribution, .trial, .lifetime, .loading:
            return true
        case .expired:
            return false
        }
    }

    var displayPrice: String {
        lifetimeProduct?.displayPrice ?? "$4.99"
    }

    func requireAccess() -> Bool {
        guard canUsePremiumFeatures else {
            NotificationCenter.default.post(name: .localVoicePurchaseRequired, object: nil)
            return false
        }
        return true
    }

    func refresh() async {
        guard AppDistribution.isAppStore else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            lifetimeProduct = try await Product.products(for: [Self.lifetimeProductID]).first
            try await refreshEntitlements()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func purchaseLifetime() async {
        guard AppDistribution.isAppStore else { return }
        isPurchasing = true
        errorMessage = nil
        defer { isPurchasing = false }

        do {
            let product: Product
            if let lifetimeProduct {
                product = lifetimeProduct
            } else if let fetched = try await Product.products(for: [Self.lifetimeProductID]).first {
                lifetimeProduct = fetched
                product = fetched
            } else {
                throw PurchaseError.productUnavailable
            }

            switch try await product.purchase() {
            case .success(let verification):
                let transaction = try verified(verification)
                hasLifetimeAccess = true
                await transaction.finish()
            case .pending, .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restorePurchases() async {
        guard AppDistribution.isAppStore else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            try await AppStore.sync()
            try await refreshEntitlements()
            if !hasLifetimeAccess {
                errorMessage = String(localized: "No previous lifetime purchase was found for this Apple Account.")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshEntitlements() async throws {
        var ownsLifetime = false
        for await result in Transaction.currentEntitlements {
            let transaction = try verified(result)
            guard transaction.productID == Self.lifetimeProductID else { continue }
            guard transaction.revocationDate == nil else { continue }
            ownsLifetime = true
        }
        hasLifetimeAccess = ownsLifetime
    }

    private func observeTransactionUpdates() -> Task<Void, Never> {
        Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                do {
                    let transaction = try self.verified(result)
                    if transaction.productID == Self.lifetimeProductID {
                        self.hasLifetimeAccess = transaction.revocationDate == nil
                    }
                    await transaction.finish()
                } catch {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func verified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value):
            return value
        case .unverified:
            throw PurchaseError.failedVerification
        }
    }

    private static func loadOrCreateTrialStartDate(keychain: KeychainService, now: Date) -> Date {
        if let stored = keychain.getString(forKey: trialStartKey),
            let interval = TimeInterval(stored)
        {
            return Date(timeIntervalSince1970: interval)
        }

        if let fallback = UserDefaults.standard.object(forKey: trialStartFallbackKey) as? Date {
            _ = keychain.save(String(fallback.timeIntervalSince1970), forKey: trialStartKey)
            return fallback
        }

        let value = String(now.timeIntervalSince1970)
        if !keychain.save(value, forKey: trialStartKey) {
            UserDefaults.standard.set(now, forKey: trialStartFallbackKey)
        }
        return now
    }
}
