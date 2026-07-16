

import Foundation
import Testing
@testable import LocalVoice

struct LocalVoiceTests {
    @Test func onboardingRequestsOnlyEssentialPermissions() {
        #expect(OnboardingPermissionKind.allCases == [.microphone, .accessibility])
        #expect(OnboardingPermissionKind.required == [.microphone, .accessibility])
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
