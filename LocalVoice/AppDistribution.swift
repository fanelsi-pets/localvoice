import Foundation

enum AppDistribution {
    #if APP_STORE
        static let isAppStore = true
    #else
        static let isAppStore = false
    #endif

    static var allowsExternalUpdates: Bool { !isAppStore }
    static var allowsAppleScriptAutomation: Bool { !isAppStore }
    static var allowsCustomCommands: Bool { !isAppStore }
    static var allowsLocalCLI: Bool { !isAppStore }
    static var allowsBrowserURLAutomation: Bool { !isAppStore }
}
