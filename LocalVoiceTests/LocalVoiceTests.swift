

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LocalVoice

struct LocalVoiceTests {
    @Test @MainActor func exportPaywallReviewScreenshotWhenRequested() throws {
        guard
            let outputPath = ProcessInfo.processInfo.environment["LOCALVOICE_PAYWALL_SCREENSHOT_PATH"],
            !outputPath.isEmpty
        else {
            return
        }

        let content = PaywallView()
            .environmentObject(PurchaseManager.shared)
            .frame(width: 560)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2

        let image = try #require(renderer.nsImage)
        let tiffData = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiffData))
        let pngData = try #require(bitmap.representation(using: .png, properties: [:]))
        let outputURL = URL(fileURLWithPath: outputPath)

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try pngData.write(to: outputURL, options: .atomic)
    }

    @Test func trialRunsForExactlySevenDays() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let trial = TrialPeriod(startDate: start)

        #expect(trial.isActive(at: start))
        #expect(trial.daysRemaining(at: start) == 7)
        #expect(trial.daysRemaining(at: start.addingTimeInterval(6 * 24 * 60 * 60 + 1)) == 1)
        #expect(!trial.isActive(at: start.addingTimeInterval(TrialPeriod.duration)))
        #expect(trial.daysRemaining(at: start.addingTimeInterval(TrialPeriod.duration)) == 0)
    }

    @Test func onboardingRequestsOnlyEssentialPermissions() {
        #expect(OnboardingPermissionKind.allCases == [.microphone, .accessibility])
        #expect(OnboardingPermissionKind.required == [.microphone, .accessibility])
    }

    @Test @MainActor func permissionPrePromptsUseNeutralContinueCopy() {
        let suiteName = "LocalVoiceTests.PermissionPrePrompt.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = OnboardingCoordinator(defaults: defaults)
        coordinator.permissionStatuses = [
            .microphone: .needsAccess,
            .accessibility: .needsAccess,
        ]

        #expect(coordinator.permissions.actionTitle(for: .microphone) == String(localized: "Continue"))
        #expect(coordinator.permissions.actionTitle(for: .accessibility) == String(localized: "Continue"))
    }

    @Test func appExposesACommandToReopenTheMainWindow() throws {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSource = try String(
            contentsOf: repositoryURL.appendingPathComponent("LocalVoice/LocalVoice.swift"),
            encoding: .utf8
        )

        #expect(appSource.contains("MainWindowCommands()"))
        #expect(appSource.contains("Button(\"Open Local Voice\")"))
        #expect(appSource.contains("openWindow(id: AppWindowID.main)"))
    }

    @Test @MainActor func comparesReleaseVersions() {
        #expect(GitHubUpdateService.isNewer("v3.0.0", than: "2.4.8"))
        #expect(GitHubUpdateService.isNewer("3.0.1", than: "3.0"))
        #expect(GitHubUpdateService.isNewer("3.1.0-beta.1", than: "3.0.9"))
        #expect(!GitHubUpdateService.isNewer("3.0.0", than: "3.0"))
        #expect(!GitHubUpdateService.isNewer("2.9.9", than: "3.0.0"))
    }

    @Test @MainActor func onlyQuitsForANewerMatchingApp() {
        #expect(
            GitHubUpdateService.shouldQuitForMountedUpdate(
                candidateIdentifier: "app.localvoice.LocalVoice",
                candidateVersion: "3.0.0",
                installedIdentifier: "app.localvoice.LocalVoice",
                installedVersion: "2.4.8"
            )
        )
        #expect(
            !GitHubUpdateService.shouldQuitForMountedUpdate(
                candidateIdentifier: "com.example.OtherApp",
                candidateVersion: "99.0.0",
                installedIdentifier: "app.localvoice.LocalVoice",
                installedVersion: "2.4.8"
            )
        )
        #expect(
            !GitHubUpdateService.shouldQuitForMountedUpdate(
                candidateIdentifier: "app.localvoice.LocalVoice",
                candidateVersion: "2.4.8",
                installedIdentifier: "app.localvoice.LocalVoice",
                installedVersion: "2.4.8"
            )
        )
    }

    @Test func multilingualProvidersExposeTheCompleteLanguageCatalog() {
        let openAIProvider = OpenAIProvider()
        #expect(openAIProvider.languageCodes == nil)

        let languages = openAIProvider.models[0].supportedLanguages
        #expect(languages.count > 80)
        #expect(languages["uk"] != nil)
        #expect(languages["es"] != nil)
        #expect(languages["ja"] != nil)
        #expect(languages["ar"] != nil)
    }

    @Test func popularLanguagesAreModelSpecificAndDoNotDuplicateEntries() {
        let supportedLanguages = [
            "auto": "Auto-detect",
            "en-US": "English (United States)",
            "uk-UA": "Ukrainian",
            "es": "Spanish",
            "ja": "Japanese",
            "eo": "Esperanto",
        ]

        let popular = TranscriptionLanguageCatalog.popularOptions(
            from: supportedLanguages,
            locale: Locale(identifier: "en")
        )
        let popularCodes = popular.map(\.code)

        #expect(popularCodes.first == "auto")
        #expect(popularCodes.contains("en-US"))
        #expect(popularCodes.contains("uk-UA"))
        #expect(popularCodes.contains("es"))
        #expect(popularCodes.contains("ja"))
        #expect(!popularCodes.contains("eo"))
        #expect(Set(popularCodes).count == popularCodes.count)

        let remainingCodes = Set(
            TranscriptionLanguageCatalog.remainingOptions(
                from: supportedLanguages,
                locale: Locale(identifier: "en")
            ).map(\.code)
        )
        #expect(remainingCodes == Set(["eo"]))
    }

    @Test func directDistributionKeepsAdvancedDesktopFeatures() {
        #expect(!AppDistribution.isAppStore)
        #expect(AppDistribution.allowsExternalUpdates)
        #expect(AppDistribution.allowsAppleScriptAutomation)
        #expect(AppDistribution.allowsCustomCommands)
    }

    @Test func userFacingCatalogsHaveCompleteUkrainianLocalization() throws {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalogURLs = [
            repositoryURL.appendingPathComponent("LocalVoice/Localizable.xcstrings"),
            repositoryURL.appendingPathComponent("LocalVoice/InfoPlist.xcstrings"),
        ]

        for catalogURL in catalogURLs {
            let data = try Data(contentsOf: catalogURL)
            let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let strings = try #require(root["strings"] as? [String: Any])
            var missingUkrainian: [String] = []
            var needsReview: [String] = []

            for (key, rawEntry) in strings {
                guard let entry = rawEntry as? [String: Any] else { continue }
                if entry["shouldTranslate"] as? Bool == false { continue }
                guard
                    let localizations = entry["localizations"] as? [String: Any],
                    let ukrainian = localizations["uk"] as? [String: Any]
                else {
                    missingUkrainian.append(key)
                    continue
                }

                if Self.containsNeedsReview(ukrainian) {
                    needsReview.append(key)
                }
            }

            #expect(missingUkrainian.isEmpty, "Missing Ukrainian strings: \(missingUkrainian.sorted())")
            #expect(needsReview.isEmpty, "Ukrainian strings requiring review: \(needsReview.sorted())")
        }
    }

    private static func containsNeedsReview(_ value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            if dictionary["state"] as? String == "needs_review" { return true }
            return dictionary.values.contains(where: containsNeedsReview)
        }
        if let array = value as? [Any] {
            return array.contains(where: containsNeedsReview)
        }
        return false
    }
}
