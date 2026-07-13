import AppKit
import Foundation

@MainActor
final class GitHubUpdateService: ObservableObject {
    static let shared = GitHubUpdateService()

    @Published private(set) var availableRelease: Release?
    @Published private(set) var isChecking = false
    @Published private(set) var isDownloading = false
    @Published private(set) var errorMessage: String?

    private let repository = "fanelsi-pets/localvoice"
    private var lastCheck: Date?
    private var workspaceMountObserver: NSObjectProtocol?

    private init() {
        workspaceMountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { notification in
            Task { @MainActor in
                GitHubUpdateService.shared.handleMountedVolume(notification)
            }
        }
    }

    struct Release: Decodable {
        let tagName: String
        let htmlURL: URL
        let assets: [Asset]
        let draft: Bool
        let prerelease: Bool

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case assets, draft, prerelease
        }

        var dmgAsset: Asset? {
            assets.first { $0.name.lowercased().hasSuffix(".dmg") }
        }

        var checksumAsset: Asset? {
            guard let dmgName = dmgAsset?.name.lowercased() else { return nil }
            return assets.first {
                let name = $0.name.lowercased()
                return name == "\(dmgName).sha256" || name.hasSuffix("sha256sums.txt")
            }
        }
    }

    struct Asset: Decodable {
        let name: String
        let downloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case downloadURL = "browser_download_url"
        }
    }

    func checkForUpdates(force: Bool = false) async {
        if !force, let lastCheck, Date().timeIntervalSince(lastCheck) < 15 * 60 { return }
        guard !isChecking else { return }

        isChecking = true
        errorMessage = nil
        defer {
            isChecking = false
            lastCheck = Date()
        }

        do {
            let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("LocalVoice-Updater", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 15

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }
            if http.statusCode == 404 {
                availableRelease = nil
                return
            }
            guard (200...299).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }

            let release = try JSONDecoder().decode(Release.self, from: data)
            guard !release.draft, !release.prerelease else { return }
            availableRelease = Self.isNewer(
                release.tagName,
                than: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            ) ? release : nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func installAvailableUpdate() async {
        guard let release = availableRelease else { return }
        guard let dmg = release.dmgAsset else {
            NSWorkspace.shared.open(release.htmlURL)
            return
        }

        isDownloading = true
        if NSWorkspace.shared.open(dmg.downloadURL) {
            terminateForUpdate(after: 0.8)
        } else {
            isDownloading = false
            NSWorkspace.shared.open(release.htmlURL)
        }
    }

    /// Finder cannot replace a running app bundle. If the user mounts a newer
    /// LocalVoice DMG manually, quit before they drag it into Applications.
    private func handleMountedVolume(_ notification: Notification) {
        guard
            let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL,
            let installedIdentifier = Bundle.main.bundleIdentifier
        else { return }

        let candidateURL = volumeURL.appendingPathComponent("LocalVoice.app", isDirectory: true)
        guard
            let candidateBundle = Bundle(url: candidateURL),
            candidateBundle.bundleIdentifier == installedIdentifier,
            let candidateVersion = candidateBundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String
        else { return }

        let installedVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0"

        guard Self.isNewer(candidateVersion, than: installedVersion) else { return }
        terminateForUpdate(after: 0.35)
    }

    private func terminateForUpdate(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            NSApplication.shared.terminate(nil)
        }
    }

    private static func isNewer(_ candidate: String, than installed: String) -> Bool {
        let lhs = versionComponents(candidate)
        let rhs = versionComponents(installed)
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    private static func versionComponents(_ value: String) -> [Int] {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            .split(separator: ".")
            .map { component in
                Int(component.prefix(while: { $0.isNumber })) ?? 0
            }
    }
}
