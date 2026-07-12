import Foundation

/// Defense in depth for the offline build. The app sandbox also ships without
/// network client/server entitlements, so outgoing traffic is denied by macOS.
final class LocalOnlyNetworkBlocker: URLProtocol {
    private static let blockedSchemes: Set<String> = ["http", "https", "ws", "wss"]
    private static let allowedHosts: Set<String> = [
        "generativelanguage.googleapis.com",
        "api.openai.com",
        "api.anthropic.com",
        "api.github.com",
        "github.com",
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com",
        "huggingface.co",
        "cdn-lfs.hf.co",
        "cdn-lfs-us-1.hf.co",
        "cas-bridge.xethub.hf.co",
        "transfer.xethub.hf.co",
    ]

    static func install() {
        URLProtocol.registerClass(LocalOnlyNetworkBlocker.self)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme?.lowercased() else { return false }
        guard blockedSchemes.contains(scheme) else { return false }
        let host = request.url?.host?.lowercased() ?? ""
        return !isAllowedHost(host)
    }

    private static func isAllowedHost(_ host: String) -> Bool {
        allowedHosts.contains(host)
            || host.hasSuffix(".huggingface.co")
            || host.hasSuffix(".hf.co")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let error = NSError(
            domain: "app.localvoice.offline",
            code: NSURLErrorNotConnectedToInternet,
            userInfo: [NSLocalizedDescriptionKey: "Local Voice does not allow network connections."]
        )
        client?.urlProtocol(self, didFailWithError: error)
    }

    override func stopLoading() {}
}
