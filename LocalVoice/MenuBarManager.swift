import AppKit
import Combine
import OSLog
import SwiftData
import SwiftUI

@MainActor
class MenuBarManager: NSObject, ObservableObject, NSMenuDelegate {
    private let logger = Logger(subsystem: "app.localvoice.LocalVoice", category: "MenuBarWindowFlow")

    @Published var isMenuBarOnly: Bool {
        didSet {
            UserDefaults.standard.set(isMenuBarOnly, forKey: "IsMenuBarOnly")
            applyActivationPolicy(logPreferenceChange: true)
        }
    }

    private var modelContainer: ModelContainer?
    private var engine: LocalVoiceEngine?
    private var statusItem: NSStatusItem?
    private var recordingStateObservation: AnyCancellable?
    private var configuredActivationPolicy: NSApplication.ActivationPolicy {
        isMenuBarOnly ? .accessory : .regular
    }

    override init() {
        self.isMenuBarOnly = UserDefaults.standard.bool(forKey: "IsMenuBarOnly")
        super.init()
        logger.notice(
            "🧭 MenuBarManager initialized. isMenuBarOnly=\(self.isMenuBarOnly, privacy: .public); activationPolicy=\(WindowDiagnostics.activationPolicyDescription(NSApplication.shared.activationPolicy()), privacy: .public)"
        )
        applyActivationPolicy()
        installStatusItem()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userFacingWindowWillClose),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    func ensureStatusItemInstalled() {
        installStatusItem()
        statusItem?.isVisible = true
        updateStatusItem(for: engine?.recordingState ?? .idle)
    }

    private func installStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = menuBarImage()
            image?.isTemplate = true
            image?.size = NSSize(width: 18, height: 18)
            button.image = image
            button.imagePosition = .imageOnly
            button.contentTintColor = nil
            button.toolTip = "Local Voice"
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    private func menuBarImage() -> NSImage? {
        NSImage(named: "menuBarIcon")
            ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: "Local Voice")
    }

    @objc private func openSettingsFromStatusItem() {
        NotificationCenter.default.post(
            name: .navigateToDestination,
            object: nil,
            userInfo: ["destination": "Settings"]
        )
        NotificationCenter.default.post(name: .showMainWindowRequested, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func userFacingWindowWillClose(_ notification: Notification) {
        guard isMenuBarOnly,
            let window = notification.object as? NSWindow,
            window.level == .normal,
            window.styleMask.contains(.titled)
        else {
            return
        }

        AppPresentationPolicy.restoreAccessoryIfNeededAfterUserFacingWindowClosed(
            reason: "userFacingWindowWillClose"
        )
    }

    func configure(modelContainer: ModelContainer, engine: LocalVoiceEngine) {
        self.modelContainer = modelContainer
        self.engine = engine
        recordingStateObservation = engine.$recordingState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.updateStatusItem(for: state)
            }
        logger.notice(
            "🧭 MenuBarManager configured. hasModelContainer=\((self.modelContainer != nil), privacy: .public); hasEngine=\((self.engine != nil), privacy: .public)"
        )
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildStatusMenu(menu)
    }

    private func rebuildStatusMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let stateTitle: String
        switch engine?.recordingState ?? .idle {
        case .starting: stateTitle = String(localized: "Starting…")
        case .recording: stateTitle = String(localized: "Recording…")
        case .transcribing: stateTitle = String(localized: "Transcribing…")
        case .enhancing: stateTitle = String(localized: "Enhancing…")
        case .busy: stateTitle = String(localized: "Working…")
        case .idle: stateTitle = "Local Voice"
        }
        let header = NSMenuItem(title: stateTitle, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let languageMenu = NSMenu(title: String(localized: "Dictation Language"))
        let selectedLanguage = UserDefaults.standard.string(forKey: "SelectedLanguage") ?? "en"
        for language in [("uk", "Українська"), ("ru", "Русский"), ("en", "English")] {
            let item = NSMenuItem(
                title: language.1,
                action: #selector(selectDictationLanguage(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = language.0
            item.state = selectedLanguage == language.0 ? .on : .off
            languageMenu.addItem(item)
        }
        let languageItem = NSMenuItem(title: String(localized: "Dictation Language"), action: nil, keyEquivalent: "")
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)

        let modelMenu = NSMenu(title: String(localized: "Transcription Model"))
        if let manager = engine?.transcriptionModelManager {
            for model in manager.usableModels {
                let item = NSMenuItem(
                    title: model.displayName,
                    action: #selector(selectTranscriptionModel(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = model.name
                item.state = manager.currentTranscriptionModel?.name == model.name ? .on : .off
                modelMenu.addItem(item)
            }
        }
        modelMenu.addItem(.separator())
        let downloadMedium = NSMenuItem(
            title: String(localized: "Download Medium Model…"),
            action: #selector(openModelsFromStatusItem),
            keyEquivalent: ""
        )
        downloadMedium.target = self
        modelMenu.addItem(downloadMedium)
        let modelItem = NSMenuItem(title: String(localized: "Transcription Model"), action: nil, keyEquivalent: "")
        modelItem.submenu = modelMenu
        menu.addItem(modelItem)

        menu.addItem(.separator())

        let recentTranscriptions = fetchRecentTranscriptions()
        let copyLast = NSMenuItem(
            title: String(localized: "Copy Last Transcription"),
            action: #selector(copyTranscription(_:)),
            keyEquivalent: ""
        )
        copyLast.target = self
        copyLast.representedObject = recentTranscriptions.first?.text
        copyLast.isEnabled = recentTranscriptions.first != nil
        menu.addItem(copyLast)

        let recentMenu = NSMenu(title: String(localized: "Recent Transcriptions"))
        if recentTranscriptions.isEmpty {
            let emptyItem = NSMenuItem(title: String(localized: "No transcriptions yet"), action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            recentMenu.addItem(emptyItem)
        } else {
            for transcription in recentTranscriptions {
                let item = NSMenuItem(
                    title: transcription.preview,
                    action: #selector(copyTranscription(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = transcription.text
                item.toolTip = String(localized: "Copy to Clipboard")
                recentMenu.addItem(item)
            }
        }
        let recentItem = NSMenuItem(title: String(localized: "Recent Transcriptions"), action: nil, keyEquivalent: "")
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)

        menu.addItem(.separator())
        let settings = NSMenuItem(
            title: String(localized: "Settings…"),
            action: #selector(openSettingsFromStatusItem),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(
            title: String(localized: "Quit Local Voice"),
            action: #selector(quitFromStatusItem),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)
    }

    private func fetchRecentTranscriptions(limit: Int = 6) -> [(preview: String, text: String)] {
        guard let context = modelContainer?.mainContext else { return [] }

        var descriptor = FetchDescriptor<Transcription>(
            predicate: #Predicate<Transcription> { transcription in
                transcription.transcriptionStatus == "completed"
            },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = limit

        guard let transcriptions = try? context.fetch(descriptor) else { return [] }
        return transcriptions.compactMap { transcription in
            let text = (transcription.enhancedText?.isEmpty == false)
                ? transcription.enhancedText ?? transcription.text
                : transcription.text
            let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !normalized.isEmpty else { return nil }
            let words = normalized.split(separator: " ")
            let preview = words.prefix(7).joined(separator: " ") + (words.count > 7 ? "…" : "")
            return (preview, text)
        }
    }

    @objc private func copyTranscription(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String, !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func updateStatusItem(for state: RecordingState) {
        guard let button = statusItem?.button else { return }
        let symbolName: String
        let tint: NSColor
        switch state {
        case .starting, .recording:
            symbolName = "waveform.circle.fill"
            tint = .systemRed
        case .transcribing, .enhancing, .busy:
            symbolName = "ellipsis.circle.fill"
            tint = .systemBlue
        case .idle:
            let image = menuBarImage()
            image?.isTemplate = true
            image?.size = NSSize(width: 18, height: 18)
            button.image = image
            button.contentTintColor = nil
            button.toolTip = "Local Voice"
            return
        }
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Local Voice")
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = tint
        button.toolTip = state == .recording ? String(localized: "Local Voice is recording") : String(localized: "Local Voice is processing")
    }

    @objc private func selectDictationLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        UserDefaults.standard.set(code, forKey: "SelectedLanguage")
        let updatedModes = ModeManager.shared.configurations.map { existing in
            var config = existing
            config.selectedLanguage = code
            return config
        }
        ModeManager.shared.replaceConfigurations(updatedModes)
        NotificationCenter.default.post(name: .languageDidChange, object: nil)
    }

    @objc private func selectTranscriptionModel(_ sender: NSMenuItem) {
        guard let modelName = sender.representedObject as? String,
            let manager = engine?.transcriptionModelManager,
            let model = manager.usableModels.first(where: { $0.name == modelName })
        else { return }
        manager.setDefaultTranscriptionModel(model)
        let updatedModes = ModeManager.shared.configurations.map { existing in
            var config = existing
            config.selectedTranscriptionModelName = model.name
            config.isRealtimeTranscriptionEnabled = model.supportsStreaming
            return config
        }
        ModeManager.shared.replaceConfigurations(updatedModes)
    }

    @objc private func openModelsFromStatusItem() {
        NotificationCenter.default.post(
            name: .navigateToDestination,
            object: nil,
            userInfo: ["destination": "AI Models"]
        )
        NotificationCenter.default.post(name: .showMainWindowRequested, object: nil)
    }

    @objc private func quitFromStatusItem() {
        NSApplication.shared.terminate(nil)
    }

    func toggleMenuBarOnly() {
        isMenuBarOnly.toggle()
    }

    func applyActivationPolicy(logPreferenceChange: Bool = false) {
        let changedPreferenceValue = isMenuBarOnly

        let applyPolicy = { [weak self] in
            guard let self else { return }
            if logPreferenceChange {
                self.logger.notice(
                    "🧭 Menu-bar-only preference changed. newValue=\(changedPreferenceValue, privacy: .public); activationPolicyBefore=\(WindowDiagnostics.activationPolicyDescription(NSApplication.shared.activationPolicy()), privacy: .public); snapshot=\(WindowDiagnostics.windowSnapshot(), privacy: .public)"
                )
            }

            let didSet = NSApplication.shared.setActivationPolicy(self.configuredActivationPolicy)
            self.logger.notice(
                "🧭 Applied menu-bar activation policy. isMenuBarOnly=\(self.isMenuBarOnly, privacy: .public); desiredPolicy=\(WindowDiagnostics.activationPolicyDescription(self.configuredActivationPolicy), privacy: .public); success=\(didSet, privacy: .public); activationPolicyAfter=\(WindowDiagnostics.activationPolicyDescription(NSApplication.shared.activationPolicy()), privacy: .public)"
            )

            if self.isMenuBarOnly {
                WindowManager.shared.hideMainWindow()
            }
        }

        if Thread.isMainThread {
            applyPolicy()
        } else {
            DispatchQueue.main.async(execute: applyPolicy)
        }
    }

    func activateForPresentedWindow() {
        activateForPresentedWindow(reason: "Presented Window")
    }

    func activateForPresentedWindow(reason: String) {
        let activate = { [weak self] in
            guard let self else { return }
            self.logger.notice(
                "🧭 Full window presentation requested. reason=\(reason, privacy: .public); isMenuBarOnlyPreference=\(self.isMenuBarOnly, privacy: .public); activationPolicyBefore=\(WindowDiagnostics.activationPolicyDescription(NSApplication.shared.activationPolicy()), privacy: .public); snapshot=\(WindowDiagnostics.windowSnapshot(), privacy: .public)"
            )
            AppPresentationPolicy.activateForUserFacingWindow(reason: reason)
        }

        if Thread.isMainThread {
            activate()
        } else {
            DispatchQueue.main.async(execute: activate)
        }
    }

    func openHistoryWindow() {
        guard let modelContainer = modelContainer,
            let engine = engine
        else {
            logger.error(
                "🧭 History window requested before MenuBarManager dependencies were configured. hasModelContainer=\((self.modelContainer != nil), privacy: .public); hasEngine=\((self.engine != nil), privacy: .public)"
            )
            return
        }

        let openWindow = { [weak self] in
            self?.logger.notice(
                "🧭 History window requested from menu bar. isMenuBarOnly=\(self?.isMenuBarOnly ?? false, privacy: .public); activationPolicy=\(WindowDiagnostics.activationPolicyDescription(NSApplication.shared.activationPolicy()), privacy: .public); snapshot=\(WindowDiagnostics.windowSnapshot(), privacy: .public)"
            )
            self?.activateForPresentedWindow(reason: "History")

            HistoryWindowController.shared.showHistoryWindow(
                modelContainer: modelContainer,
                engine: engine
            )
        }

        if Thread.isMainThread {
            openWindow()
        } else {
            DispatchQueue.main.async(execute: openWindow)
        }
    }
}
