import AppKit
import Foundation
import SwiftUI

struct EmailSupport {
    private static let supportEmailAddress = "support@trylocalvoice.com"
    private static let supportEmailSubject = "Local Voice Support Request"

    static func generateSupportEmailBody() -> String {
        let systemInfo = SystemInfoService.shared.getSystemInfoString()

        return """

            ------------------------
            ✨ **DIAGNOSTIC DETAILS ARE HELPFUL** ✨
            ▶️ Describe the exact steps that reproduce the issue.
            ▶️ Attach relevant screenshots or exported logs when available.

            📝 ISSUE DETAILS:
            - What steps did you take before the issue occurred?
            - What did you expect to happen?
            - What actually happened instead?


            ## 📋 COMMON ISSUES:
            Check out our Common Issues page before sending an email: https://trylocalvoice.com/common-issues
            ------------------------

            System Information:
            \(systemInfo)


            """
    }

    static func generateSupportEmailURL() -> URL? {
        let encodedSubject = supportEmailSubject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "mailto:\(supportEmailAddress)?subject=\(encodedSubject)")
    }

    static func openSupportEmail() {
        let body = generateSupportEmailBody()

        if let sharingService = NSSharingService(named: .composeEmail) {
            sharingService.recipients = [supportEmailAddress]
            sharingService.subject = supportEmailSubject
            sharingService.perform(withItems: [body])
            return
        }

        SystemInfoService.shared.copySystemInfoToClipboard()

        if let emailURL = generateSupportEmailURL() {
            NSWorkspace.shared.open(emailURL)
        }
    }
}
