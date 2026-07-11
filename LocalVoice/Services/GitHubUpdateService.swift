import AppKit
import CryptoKit
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
        guard let dmg = release.dmgAsset, let checksum = release.checksumAsset else {
            NSWorkspace.shared.open(release.htmlURL)
            return
        }
        guard !isDownloading else { return }

        isDownloading = true
        errorMessage = nil
        defer { isDownloading = false }

        do {
            async let dmgDownload = URLSession.shared.download(from: dmg.downloadURL)
            async let checksumData = URLSession.shared.data(from: checksum.downloadURL)
            let ((temporaryURL, response), (checksumBytes, checksumResponse)) = try await (dmgDownload, checksumData)
            try Self.requireSuccessful(response)
            try Self.requireSuccessful(checksumResponse)

            let expected = String(decoding: checksumBytes, as: UTF8.self)
                .split(whereSeparator: { $0.isWhitespace })
                .first
                .map(String.init)?
                .lowercased()
            let actual = try Self.sha256(of: temporaryURL)
            guard expected == actual else { throw UpdateError.checksumMismatch }

            let updateDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("LocalVoiceUpdates", isDirectory: true)
            try FileManager.default.createDirectory(at: updateDirectory, withIntermediateDirectories: true)
            let destination = updateDirectory.appendingPathComponent(dmg.name)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            NSWorkspace.shared.open(destination)
        } catch {
            errorMessage = error.localizedDescription
            NSWorkspace.shared.open(release.htmlURL)
        }
    }

    private static func requireSuccessful(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    private static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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

    private enum UpdateError: LocalizedError {
        case checksumMismatch

        var errorDescription: String? {
            String(localized: "The update could not be verified.")
        }
    }
}
