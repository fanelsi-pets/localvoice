import SwiftUI

struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var purchaseManager: PurchaseManager

    var body: some View {
        VStack(spacing: 24) {
            HStack {
                Spacer()
                if purchaseManager.accessState != .expired {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
            }

            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 46, weight: .semibold))
                .foregroundStyle(AppTheme.Accent.primary)
                .frame(width: 88, height: 88)
                .background(AppTheme.Accent.fill, in: RoundedRectangle(cornerRadius: 24))

            VStack(spacing: 9) {
                Text("Keep speaking. Keep LocalVoice forever.")
                    .font(.system(size: 27, weight: .bold))
                    .multilineTextAlignment(.center)
                Text(paywallSubtitle)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }

            VStack(alignment: .leading, spacing: 13) {
                paywallFeature("mic.fill", "Voice typing in any app")
                paywallFeature("lock.shield.fill", "Local models and privacy controls")
                paywallFeature("text.badge.checkmark", "History, cleanup, and text improvement")
                paywallFeature("infinity", "One purchase. No subscription.")
            }
            .frame(maxWidth: 390, alignment: .leading)
            .padding(18)
            .background(AppTheme.Surface.control.opacity(0.55), in: RoundedRectangle(cornerRadius: 18))

            if let error = purchaseManager.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.Status.error)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 10) {
                Button {
                    Task { await purchaseManager.purchaseLifetime() }
                } label: {
                    HStack {
                        if purchaseManager.isPurchasing {
                            ProgressView().controlSize(.small)
                        }
                        Text(
                            String(
                                format: String(localized: "Buy Once for %@"),
                                purchaseManager.displayPrice
                            )
                        )
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                }
                .buttonStyle(.borderedProminent)
                .disabled(purchaseManager.isPurchasing || purchaseManager.isLoading)

                Button("Restore Purchase") {
                    Task { await purchaseManager.restorePurchases() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .disabled(purchaseManager.isPurchasing || purchaseManager.isLoading)
            }

            Text("Payment is charged only when you confirm the purchase with Apple. The 7-day trial does not renew or charge automatically.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .padding(28)
        .frame(width: 560)
        .background(AppTheme.Surface.window)
        .onChange(of: purchaseManager.hasLifetimeAccess) { _, ownsLifetime in
            if ownsLifetime { dismiss() }
        }
    }

    private var paywallSubtitle: String {
        switch purchaseManager.accessState {
        case .trial(let daysRemaining, _):
            return String(
                format: String(localized: "You still have %lld trial days. Unlock lifetime access now for %@."),
                daysRemaining,
                purchaseManager.displayPrice
            )
        case .lifetime:
            return String(localized: "Lifetime access is active on this Apple Account.")
        case .expired:
            return String(
                format: String(localized: "Your 7-day trial has ended. Pay %@ once and keep every feature forever."),
                purchaseManager.displayPrice
            )
        case .loading, .unrestrictedDistribution:
            return String(localized: "7 days free. Then one lifetime purchase. No subscription.")
        }
    }

    private func paywallFeature(_ systemImage: String, _ title: LocalizedStringKey) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .frame(width: 22)
                .foregroundStyle(AppTheme.Accent.primary)
            Text(title)
                .font(.system(size: 13, weight: .medium))
        }
    }
}

struct PurchaseStatusCard: View {
    @EnvironmentObject private var purchaseManager: PurchaseManager
    let onShowPaywall: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: statusIcon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppTheme.Accent.primary)
                .frame(width: 34, height: 34)
                .background(AppTheme.Accent.fill, in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.system(size: 13, weight: .semibold))
                Text(statusSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if shouldShowButton {
                Button(buttonTitle, action: onShowPaywall)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .background(AppCardBackground(cornerRadius: 15))
    }

    private var statusIcon: String {
        switch purchaseManager.accessState {
        case .lifetime, .unrestrictedDistribution: return "checkmark.seal.fill"
        case .trial: return "clock.fill"
        case .expired: return "lock.fill"
        case .loading: return "ellipsis"
        }
    }

    private var statusTitle: LocalizedStringKey {
        switch purchaseManager.accessState {
        case .lifetime, .unrestrictedDistribution: return "Lifetime access"
        case .trial: return "7-day free trial"
        case .expired: return "Trial ended"
        case .loading: return "Checking purchase…"
        }
    }

    private var statusSubtitle: String {
        switch purchaseManager.accessState {
        case .lifetime:
            return String(localized: "LocalVoice is yours forever.")
        case .unrestrictedDistribution:
            return String(localized: "This direct-download edition includes full access.")
        case .trial(let daysRemaining, _):
            return String(
                format: String(localized: "%lld days remaining. Then %@ once — no subscription."),
                daysRemaining,
                purchaseManager.displayPrice
            )
        case .expired:
            return String(
                format: String(localized: "Unlock forever for %@ — no subscription."),
                purchaseManager.displayPrice
            )
        case .loading:
            return String(localized: "Connecting securely to the App Store.")
        }
    }

    private var shouldShowButton: Bool {
        switch purchaseManager.accessState {
        case .trial, .expired: return true
        case .loading, .lifetime, .unrestrictedDistribution: return false
        }
    }

    private var buttonTitle: LocalizedStringKey {
        switch purchaseManager.accessState {
        case .trial: return "Buy Once"
        default: return "Unlock"
        }
    }
}
