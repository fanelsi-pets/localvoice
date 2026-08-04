import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MeetingTranscribeView: View {
    @EnvironmentObject private var whisperModelManager: WhisperModelManager
    @EnvironmentObject private var navigation: MainWindowNavigation
    @EnvironmentObject private var aiService: AIService
    @StateObject private var manager = MeetingTranscriptionManager()
    @StateObject private var playerController = MeetingMediaPlayerController()

    @State private var sourceURL: URL?
    @State private var selectedModelName = ""
    @State private var language = "auto"
    @State private var expectedSpeakerCount = 0
    @State private var anchors: [MeetingSpeakerAnchor] = []
    @State private var detectedSpeakerNames: [String: String] = [:]
    @State private var isDropTargeted = false
    @AppStorage("MeetingAIInsightsEnabled") private var useAIInsights = false

    private var selectedModel: WhisperModelFile? {
        whisperModelManager.availableModels.first { $0.name == selectedModelName }
            ?? whisperModelManager.availableModels.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let transcript = manager.transcript {
                resultView(transcript)
            } else {
                setupView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            selectDefaultModelIfNeeded()
            if UserDefaults.standard.object(forKey: "MeetingAIInsightsEnabled") == nil,
                configuredAIProvider != nil
            {
                useAIInsights = true
            }
            if let sourceURL,
                !manager.isAnalyzingSpeakers,
                manager.speakerSegments.isEmpty
            {
                playerController.load(sourceURL)
                manager.analyzeSpeakers(
                    sourceURL: sourceURL,
                    expectedSpeakerCount: expectedSpeakerCount > 0 ? expectedSpeakerCount : nil
                )
            }
        }
        .onChange(of: whisperModelManager.availableModels.map(\.name)) { _, _ in
            selectDefaultModelIfNeeded()
        }
        .onChange(of: sourceURL) { _, newURL in
            sourceDidChange(newURL)
        }
        .onChange(of: expectedSpeakerCount) { _, newValue in
            guard let sourceURL else { return }
            manager.analyzeSpeakers(
                sourceURL: sourceURL,
                expectedSpeakerCount: newValue > 0 ? newValue : nil
            )
        }
        .onChange(of: manager.speakerSegments) { _, newSegments in
            let speakerIDs = Set(newSegments.map(\.speakerID))
            detectedSpeakerNames = detectedSpeakerNames.filter { speakerIDs.contains($0.key) }
            for speakerID in speakerIDs where detectedSpeakerNames[speakerID] == nil {
                detectedSpeakerNames[speakerID] = ""
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openFileForTranscription)) { notification in
            guard let url = notification.userInfo?["url"] as? URL,
                SupportedMedia.isSupported(url: url)
            else { return }
            manager.reset()
            sourceURL = url
        }
        .onDrop(of: [.fileURL, .audio, .movie], isTargeted: $isDropTargeted, perform: handleDrop)
        .onDisappear {
            playerController.cleanup()
            manager.cancelSpeakerAnalysis()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Офлайн-встреча")
                    .font(.title3.weight(.semibold))
                Text("Таймкоды, спикеры, мысли и фоллоу-ап — локально на Mac")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let transcript = manager.transcript {
                CopyIconButton(textToCopy: transcript.markdown)
                SaveIconButton(textToSave: transcript.markdown)
                Button("Новая встреча") {
                    manager.reset()
                    sourceURL = nil
                    anchors = []
                    detectedSpeakerNames = [:]
                }
                .buttonStyle(.bordered)
            } else if manager.isProcessing {
                Button("Отменить") { manager.cancel() }
                    .buttonStyle(.bordered)
            } else {
                Button("Запустить") { start() }
                    .buttonStyle(.borderedProminent)
                    .disabled(sourceURL == nil || selectedModel == nil || hasInvalidAnchors)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var setupView: some View {
        ScrollView {
            VStack(spacing: 18) {
                fileDropZone

                if sourceURL != nil {
                    mediaPlayerCard
                    speakerAnalysisCard
                }

                if whisperModelManager.availableModels.isEmpty {
                    missingModelCard
                } else {
                    settingsCard
                }

                speakersCard

                if manager.isProcessing || isFailure {
                    progressCard
                }
            }
            .padding(24)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
    }

    private var mediaPlayerCard: some View {
        MeetingMediaPlayerView(
            controller: playerController,
            speakerSegments: manager.speakerSegments,
            speakerNames: detectedSpeakerNames,
            onAddAnchor: addAnchorFromPlayer
        )
    }

    private var speakerAnalysisCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                if manager.isAnalyzingSpeakers {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: manager.speakerSegments.isEmpty ? "person.wave.2" : "person.2.wave.2.fill")
                        .foregroundStyle(manager.speakerSegments.isEmpty ? .secondary : AppTheme.Status.positive)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(manager.speakerAnalysisStage.title)
                        .font(.subheadline.weight(.medium))
                    Text("Анализ запускается сразу после загрузки и не распознаёт текст — только разделяет голоса.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !manager.isAnalyzingSpeakers {
                    Button("Повторить") {
                        guard let sourceURL else { return }
                        manager.analyzeSpeakers(
                            sourceURL: sourceURL,
                            expectedSpeakerCount: expectedSpeakerCount > 0 ? expectedSpeakerCount : nil,
                            force: true
                        )
                    }
                    .buttonStyle(.borderless)
                }
            }

            if let progress = manager.speakerAnalysisStage.progress,
                manager.isAnalyzingSpeakers
            {
                ProgressView(value: progress)
            }

            HStack {
                Text("Ожидается спикеров")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $expectedSpeakerCount) {
                    Text("Авто").tag(0)
                    ForEach(2...10, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                .labelsHidden()
                .frame(width: 170)
            }

            if manualSpeakerCount > detectedSpeakerCount,
                expectedSpeakerCount == 0,
                !manager.isAnalyzingSpeakers
            {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppTheme.Status.warning)
                    Text("По именам и якорям указано \(manualSpeakerCount) участников, а найдено только \(detectedSpeakerCount). Анализ нужно пересчитать с точным числом голосов.")
                        .font(.caption)
                    Spacer()
                    Button("Пересчитать на \(manualSpeakerCount)") {
                        expectedSpeakerCount = manualSpeakerCount
                    }
                    .buttonStyle(.bordered)
                }
            }

            if case .preparingModels = manager.speakerAnalysisStage {
                Text("При первом запуске модели разделения голосов могут один раз загрузиться из интернета.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(AppTheme.Accent.fillSubtle, in: RoundedRectangle(cornerRadius: 12))
    }

    private var fileDropZone: some View {
        Button(action: chooseFile) {
            HStack(spacing: 14) {
                Image(systemName: sourceURL == nil ? "waveform.badge.plus" : "waveform.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(sourceURL == nil ? AppTheme.Accent.primary : AppTheme.Status.positive)

                VStack(alignment: .leading, spacing: 4) {
                    Text(sourceURL?.lastPathComponent ?? "Выберите аудио или видео встречи")
                        .font(.headline)
                        .lineLimit(1)
                    Text(sourceURL == nil ? "Можно перетащить M4A, MP3, WAV, MP4 или MOV" : "Нажмите, чтобы заменить файл")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
            }
            .padding(18)
            .background(AppTheme.Surface.subtle, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isDropTargeted ? AppTheme.Accent.primary : AppTheme.Border.control,
                        style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: sourceURL == nil ? [7] : [])
                    )
            }
        }
        .buttonStyle(.plain)
        .disabled(manager.isProcessing)
    }

    private var missingModelCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Нужна локальная модель Whisper", systemImage: "arrow.down.circle")
                .font(.headline)
            Text("Скачайте multilingual-модель в разделе AI Models. Для длинных русскоязычных встреч рекомендуем large-v3-turbo.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Открыть AI Models") { navigation.selectedView = .models }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(AppTheme.Surface.subtle, in: RoundedRectangle(cornerRadius: 12))
    }

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Распознавание", systemImage: "cpu")
                .font(.headline)

            HStack {
                Text("Whisper")
                    .frame(width: 130, alignment: .leading)
                Picker("", selection: $selectedModelName) {
                    ForEach(whisperModelManager.availableModels, id: \.name) { model in
                        Text(model.name).tag(model.name)
                    }
                }
                .labelsHidden()
            }

            HStack {
                Text("Язык")
                    .frame(width: 130, alignment: .leading)
                Picker("", selection: $language) {
                    Text("Авто").tag("auto")
                    Text("Русский").tag("ru")
                    Text("Украинский").tag("uk")
                    Text("English").tag("en")
                }
                .labelsHidden()
            }

            HStack {
                Text("Спикеров")
                    .frame(width: 130, alignment: .leading)
                Picker("", selection: $expectedSpeakerCount) {
                    Text("Определить автоматически").tag(0)
                    ForEach(2...10, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                .labelsHidden()
            }

            Divider()

            Toggle("Смысловые итоги и follow-up через AI", isOn: $useAIInsights)

            if useAIInsights {
                if let provider = configuredAIProvider {
                    Label(
                        "Аудио остаётся на Mac. Только текст транскрипции будет отправлен в \(provider.rawValue), чтобы выделить решения, задачи, ответственных и сроки.",
                        systemImage: "text.badge.checkmark"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text("Подключите Gemini, OpenAI или Anthropic. Иначе будут использованы локальные правила.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.Status.warningStrong)
                        Spacer()
                        Button("Подключить") { navigation.selectedView = .models }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(AppTheme.Surface.subtle, in: RoundedRectangle(cornerRadius: 12))
    }

    private var speakersCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Имена спикеров", systemImage: "person.2")
                    .font(.headline)
                Spacer()
                Button {
                    anchors.append(MeetingSpeakerAnchor())
                } label: {
                    Label("Добавить", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }

            Text("Прослушайте по одному примеру каждого найденного голоса и впишите имя. При необходимости добавьте ручной таймкод.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !detectedSpeakerIDs.isEmpty {
                VStack(spacing: 8) {
                    ForEach(detectedSpeakerIDs, id: \.self) { speakerID in
                        HStack(spacing: 10) {
                            Button {
                                playSample(for: speakerID)
                            } label: {
                                Image(systemName: "play.circle.fill")
                                    .font(.title3)
                            }
                            .buttonStyle(.plain)
                            .help("Прослушать пример этого голоса")

                            VStack(alignment: .leading, spacing: 1) {
                                Text(MeetingTranscriptBuilder.defaultSpeakerName(speakerID))
                                    .font(.subheadline.weight(.medium))
                                if let segment = representativeSegment(for: speakerID) {
                                    Text("Пример с \(MeetingTimecode.format(segment.startTime))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: 130, alignment: .leading)

                            TextField("Имя участника", text: speakerNameBinding(for: speakerID))
                                .textFieldStyle(.roundedBorder)

                            if activeSpeakerID == speakerID {
                                Label("Сейчас", systemImage: "waveform")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.Accent.primary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                Divider()
            } else if sourceURL != nil, !manager.isAnalyzingSpeakers {
                Text("Когда анализ завершится, здесь появятся найденные голоса и кнопки их прослушивания.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Ручные якоря")
                .font(.subheadline.weight(.medium))

            ForEach($anchors) { $anchor in
                HStack(spacing: 10) {
                    TextField("0:00", text: $anchor.timestamp)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                    Text("—")
                        .foregroundStyle(.secondary)
                    TextField("Имя", text: $anchor.speakerName)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        anchors.removeAll { $0.id == anchor.id }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if hasInvalidAnchors {
                Text("Проверьте таймкод: используйте формат ММ:СС или ЧЧ:ММ:СС.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Status.error)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(AppTheme.Surface.subtle, in: RoundedRectangle(cornerRadius: 12))
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if manager.isProcessing { ProgressView().controlSize(.small) }
                Text(manager.stage.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(isFailure ? AppTheme.Status.error : .primary)
            }
            if let progress = manager.stage.progress {
                ProgressView(value: progress)
            }
            if case .preparingDiarizationModels = manager.stage {
                Text("При первом запуске модели диаризации загрузятся один раз. После этого интернет не нужен.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(AppTheme.Accent.fillSubtle, in: RoundedRectangle(cornerRadius: 12))
    }

    private func resultView(_ transcript: MeetingTranscript) -> some View {
        VStack(spacing: 0) {
            if sourceURL != nil {
                mediaPlayerCard
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let warning = manager.insightsWarning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(AppTheme.Status.warningStrong)
                            .padding(12)
                            .background(AppTheme.Status.warningStrong.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }

                    MarkdownContentView(
                        transcript.markdown,
                        fontSize: 14,
                        foregroundColor: AppTheme.Text.primary
                    )
                }
                .padding(24)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var detectedSpeakerIDs: [String] {
        Set(manager.speakerSegments.map(\.speakerID)).sorted()
    }

    private var detectedSpeakerCount: Int {
        detectedSpeakerIDs.count
    }

    private var configuredAIProvider: AIProvider? {
        if aiService.connectedProviders.contains(aiService.selectedProvider) {
            return aiService.selectedProvider
        }
        return aiService.connectedProviders.first
    }

    private var manualSpeakerCount: Int {
        Set(
            anchors
                .map { $0.speakerName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        ).count
    }

    private var activeSpeakerID: String? {
        manager.speakerSegments.first {
            playerController.currentTime >= $0.startTime && playerController.currentTime <= $0.endTime
        }?.speakerID
    }

    private var hasInvalidAnchors: Bool {
        anchors.contains { anchor in
            let hasAnyValue = !anchor.timestamp.trimmingCharacters(in: .whitespaces).isEmpty
                || !anchor.speakerName.trimmingCharacters(in: .whitespaces).isEmpty
            return hasAnyValue && (anchor.timeInterval == nil || anchor.speakerName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var isFailure: Bool {
        if case .failed = manager.stage { return true }
        return false
    }

    private func selectDefaultModelIfNeeded() {
        if !whisperModelManager.availableModels.contains(where: { $0.name == selectedModelName }) {
            selectedModelName = whisperModelManager.availableModels.first?.name ?? ""
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie]
        if panel.runModal() == .OK {
            sourceURL = panel.url
        }
    }

    private func sourceDidChange(_ newURL: URL?) {
        detectedSpeakerNames = [:]
        guard let newURL else {
            playerController.cleanup()
            manager.cancelSpeakerAnalysis()
            return
        }

        playerController.load(newURL)
        manager.analyzeSpeakers(
            sourceURL: newURL,
            expectedSpeakerCount: expectedSpeakerCount > 0 ? expectedSpeakerCount : nil
        )
    }

    private func start() {
        guard let sourceURL, let selectedModel else { return }
        var validAnchors = anchors.filter { $0.timeInterval != nil && !$0.speakerName.isEmpty }
        var existingNames = Set(validAnchors.map { $0.speakerName.lowercased() })
        for speakerID in detectedSpeakerIDs {
            let name = detectedSpeakerNames[speakerID]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty,
                !existingNames.contains(name.lowercased()),
                let segment = representativeSegment(for: speakerID)
            else { continue }
            validAnchors.append(
                MeetingSpeakerAnchor(
                    timestamp: MeetingTimecode.format((segment.startTime + segment.endTime) / 2),
                    speakerName: name
                )
            )
            existingNames.insert(name.lowercased())
        }
        let inferredCount = Set(validAnchors.map { $0.speakerName.lowercased() }).count
        let count: Int?
        if expectedSpeakerCount > 0 {
            count = expectedSpeakerCount
        } else if inferredCount > detectedSpeakerCount {
            // Names and timestamp anchors are stronger evidence than automatic clustering.
            // Force FluidAudio to split merged voices instead of merely renaming three bad clusters.
            count = inferredCount
        } else {
            count = nil
        }
        manager.start(
            sourceURL: sourceURL,
            whisperModel: selectedModel,
            language: language,
            expectedSpeakerCount: count,
            anchors: validAnchors,
            whisperModelManager: whisperModelManager,
            insightConfiguration: meetingInsightConfiguration,
            aiService: meetingInsightConfiguration == nil ? nil : aiService
        )
    }

    private var meetingInsightConfiguration: MeetingInsightAnalysisConfiguration? {
        guard useAIInsights, let provider = configuredAIProvider else { return nil }
        return MeetingInsightAnalysisConfiguration(
            provider: provider,
            modelName: aiService.selectedModel(for: provider)
        )
    }

    private func addAnchorFromPlayer(time: TimeInterval, speakerID: String?) {
        let suggestedName = speakerID.flatMap { detectedSpeakerNames[$0] } ?? ""
        anchors.append(
            MeetingSpeakerAnchor(
                timestamp: MeetingTimecode.format(time),
                speakerName: suggestedName
            )
        )
    }

    private func speakerNameBinding(for speakerID: String) -> Binding<String> {
        Binding(
            get: { detectedSpeakerNames[speakerID] ?? "" },
            set: { detectedSpeakerNames[speakerID] = $0 }
        )
    }

    private func representativeSegment(for speakerID: String) -> MeetingSpeakerSegment? {
        manager.speakerSegments
            .filter { $0.speakerID == speakerID }
            .max { lhs, rhs in
                (lhs.endTime - lhs.startTime) < (rhs.endTime - rhs.startTime)
            }
    }

    private func playSample(for speakerID: String) {
        guard let segment = representativeSegment(for: speakerID) else { return }
        playerController.seek(to: segment.startTime)
        playerController.play()
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) })
        else { return false }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let item = item as? URL {
                url = item
            } else if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else {
                url = nil
            }
            if let url, SupportedMedia.isSupported(url: url) {
                DispatchQueue.main.async { sourceURL = url }
            }
        }
        return true
    }
}
