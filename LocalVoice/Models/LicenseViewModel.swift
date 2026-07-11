import AppKit
import Foundation
import os

@MainActor
class LicenseViewModel: ObservableObject {
    enum LicenseState: Equatable {
        case unlicensed
        case trial(daysRemaining: Int)
        case trialExpired
        case licensed
    }

    @Published private(set) var licenseState: LicenseState = .unlicensed
    @Published var licenseKey: String = ""
    @Published var isValidating = false
    @Published var validationMessage: String?
    @Published var validationSuccess: Bool = false
    @Published private(set) var activationsLimit: Int = 0

    private let trialPeriodDays = 7
    private let polarService = PolarService()
    private let logger = Logger(subsystem: "com.prakashjoshipax.localvoice", category: "LicenseViewModel")
    private let userDefaults = UserDefaults.standard
    private let licenseManager = LicenseManager.shared

    init() {
        // Local Voice is an offline, GPL-licensed build and never contacts a licensing server.
        licenseState = .licensed
    }

    func startTrial() {
        let didStartTrial = licenseManager.startTrialIfNeeded()
        refreshTrialState()
        NotificationCenter.default.post(name: .licenseStatusChanged, object: nil)

        if didStartTrial {
            requestLicenseCelebration()
        }
    }

    private func loadLicenseState() {
        // Check for existing license key
        if let storedLicenseKey = licenseManager.licenseKey {
            self.licenseKey = storedLicenseKey

            // If we have a license key, trust that it's licensed
            // Skip server validation on startup
            if licenseManager.activationId != nil || !userDefaults.bool(forKey: "LocalVoiceLicenseRequiresActivation") {
                licenseState = .licensed
                activationsLimit = userDefaults.activationsLimit
                return
            }
        }

        if let trialStartDate = licenseManager.trialStartDate {
            refreshTrialState(from: trialStartDate)
        } else {
            setUnlicensedState()
        }
    }

    var isLicensed: Bool {
        if case .licensed = licenseState {
            return true
        }

        return false
    }

    private func setUnlicensedState() {
        licenseState = .unlicensed
    }

    private func refreshTrialState() {
        guard let trialStartDate = licenseManager.trialStartDate else {
            setUnlicensedState()
            return
        }

        refreshTrialState(from: trialStartDate)
    }

    private func refreshTrialState(from trialStartDate: Date) {
        let daysSinceTrialStart = Calendar.current.dateComponents([.day], from: trialStartDate, to: Date()).day ?? 0

        if daysSinceTrialStart >= trialPeriodDays {
            licenseState = .trialExpired
        } else {
            licenseState = .trial(daysRemaining: trialPeriodDays - daysSinceTrialStart)
        }
    }

    var canUseApp: Bool {
        switch licenseState {
        case .licensed, .trial:
            return true
        case .unlicensed, .trialExpired:
            return false
        }
    }

    var usageRestrictionMessage: String? {
        switch licenseState {
        case .unlicensed, .trialExpired:
            return String(
                format: String(localized: "Your trial has ended. Upgrade to LocalVoice Pro at %@"),
                "trylocalvoice.com/buy"
            )
        case .trial, .licensed:
            return nil
        }
    }

    func openPurchaseLink() {
        if let url = URL(string: "https://trylocalvoice.com/buy") {
            NSWorkspace.shared.open(url)
        }
    }

    func validateLicense() async {
        licenseState = .licensed
        validationSuccess = true
        validationMessage = String(localized: "Local Voice works without activation.")
    }

    private func completeSuccessfulValidation(message: String) {
        licenseState = .licensed
        validationSuccess = true
        validationMessage = message
        NotificationCenter.default.post(name: .licenseStatusChanged, object: nil)
        requestLicenseCelebration()
    }

    private func requestLicenseCelebration() {
        NotificationCenter.default.post(name: .licenseCelebrationRequested, object: nil)
    }

    func removeLicense() {
        // Remove only the license credentials. Trial history stays intact.
        licenseManager.removeStoredLicense()

        // Reset UserDefaults flags
        userDefaults.set(false, forKey: "LocalVoiceLicenseRequiresActivation")
        userDefaults.activationsLimit = 0

        licenseKey = ""
        validationMessage = nil
        validationSuccess = false
        activationsLimit = 0
        loadLicenseState()
        NotificationCenter.default.post(name: .licenseStatusChanged, object: nil)
    }
}

// UserDefaults extension for non-sensitive license settings
extension UserDefaults {
    var activationsLimit: Int {
        get { integer(forKey: "LocalVoiceActivationsLimit") }
        set { set(newValue, forKey: "LocalVoiceActivationsLimit") }
    }
}
