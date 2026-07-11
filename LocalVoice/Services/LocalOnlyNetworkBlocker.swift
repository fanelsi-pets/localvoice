import Foundation

/// Defense in depth for the offline build. The app sandbox also ships without
/// network client/server entitlements, so outgoing traffic is denied by macOS.
final class LocalOnlyNetworkBlocker: URLProtocol {
    private static let blockedSchemes: Set<String> = ["http", "https", "ws", "wss"]
    private static let allowedHosts: Set<String> = [
        "generativelanguage.googleapis.com",
        "api.openai.com",
    ]

    static func install() {
        URLProtocol.registerClass(LocalOnlyNetworkBlocker.self)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme?.lowercased() else { return false }
        guard blockedSchemes.contains(scheme) else { return false }
        return !allowedHosts.contains(request.url?.host?.lowercased() ?? "")
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
