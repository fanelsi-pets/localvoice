import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MeetingTranscribeView: View {
    @EnvironmentObject private var whisperModelManager: WhisperModelManager
    @EnvironmentObject private var navigation: MainWindowNavigation
    @EnvironmentObject private var aiService: AIService
    @ObservedObject var manager: MeetingTranscriptionManager
    @ObservedObject var session: MeetingSessionState
    @ObservedObject var playerController: MeetingMediaPlayerController
    @State private var isDropTargeted = false

    private var selectedModel: WhisperModelFile? {
        whisperModelManager.availableModels.first { $0.name == session.selectedModelName }
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
            if let sourceURL = session.sourceURL {
                if playerController.player.currentItem == nil {
                    playerController.load(sourceURL)
                }

                if !manager.isAnalyzingSpeakers,
                    !manager.isProcessing,
                    manager.transcript == nil,
                    manager.speakerSegments.isEmpty
                {
                    manager.analyzeSpeakers(
                        sourceURL: sourceURL,
                        expectedSpeakerCount: session.expectedSpeakerCount > 0
                            ? session.expectedSpeakerCount : nil
                    )
                }
            }
        }
        .onChange(of: whisperModelManager.availableModels.map(\.name)) { _, _ in
            selectDefaultModelIfNeeded()
        }
        .onChange(of: session.sourceURL) { _, newURL in
            sourceDidChange(newURL)
        }
        .onChange(of: session.expectedSpeakerCount) { _, newValue in
            guard let sourceURL = session.sourceURL, !manager.isProcessing else { return }
            manager.analyzeSpeakers(
                sourceURL: sourceURL,
                expectedSpeakerCount: newValue > 0 ? newValue : nil
            )
        }
        .onChange(of: manager.speakerSegments) { _, newSegments in
            let speakerIDs = Set(newSegments.map(\.speakerID))
            session.detectedSpeakerNames = session.detectedSpeakerNames.filter { speakerIDs.contains($0.key) }
            for speakerID in speakerIDs where session.detectedSpeakerNames[speakerID] == nil {
                session.detectedSpeakerNames[speakerID] = ""
            }
        }
        // Meetings intentionally has its own picker and drop target; shared file-opening
        // notifications continue to belong exclusively to the existing Transcribe Audio screen.
        .onDrop(of: [.fileURL, .audio, .movie], isTargeted: $isDropTargeted, perform: handleDrop)
        .onDisappear {
            playerController.pause()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Расшифровка встречи")
                    .font(.title3.weight(.semibold))
                Text("Импортируйте запись Zoom, разделите голоса и расшифруйте её локально на Mac")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let transcript = manager.transcript {
                CopyIconButton(textToCopy: transcript.markdown)
                SaveIconButton(textToSave: transcript.markdown)
                Button("Новая встреча") { beginNewMeeting() }
                    .buttonStyle(.bordered)
            } else if manager.isProcessing {
                Button("Отменить") { manager.cancel() }
                    .buttonStyle(.bordered)
            } else {
                Button("Запустить обработку") { start() }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        session.sourceURL == nil || selectedModel == nil || hasInvalidAnchors
                            || manager.isAnalyzingSpeakers
                    )
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var setupView: some View {
        ScrollView {
            VStack(spacing: 18) {
                fileDropZone

                if session.sourceURL != nil {
                    mediaPlayerCard(speakerNames: session.detectedSpeakerNames)
                    speakerAnalysisCard
                }

                if whisperModelManager.availableModels.isEmpty {
                    missingModelCard
                } else {
                    settingsCard
                }

                if session.sourceURL != nil {
                    speakersCard
                }

                if manager.isProcessing || isFailure {
                    progressCard
                }
            }
            .padding(24)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
    }

    private func mediaPlayerCard(speakerNames: [String: String]) -> some View {
        MeetingMediaPlayerView(
            controller: playerController,
            speakerSegments: manager.speakerSegments,
            speakerNames: speakerNames,
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
                    Text("Этот предварительный этап ищет разные голоса, но ещё не распознаёт текст.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !manager.isAnalyzingSpeakers {
                    Button("Повторить") {
                        guard let sourceURL = session.sourceURL else { return }
                        manager.analyzeSpeakers(
                            sourceURL: sourceURL,
                            expectedSpeakerCount: session.expectedSpeakerCount > 0
                                ? session.expectedSpeakerCount : nil,
                            force: true
                        )
                    }
                    .buttonStyle(.borderless)
                    .disabled(manager.isProcessing)
                }
            }

            if let progress = manager.speakerAnalysisStage.progress,
                manager.isAnalyzingSpeakers
            {
                HStack(spacing: 10) {
                    ProgressView(value: clamped(progress), total: 1)
                    Text(percent(progress))
                        .font(.system(.caption, design: .monospaced).weight(.medium))
                        .frame(width: 40, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Прогресс анализа голосов")
                .accessibilityValue(percent(progress))
            }

            HStack {
                Text("Ожидается спикеров")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $session.expectedSpeakerCount) {
                    Text("Определить автоматически").tag(0)
                    ForEach(2...10, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                .labelsHidden()
                .frame(width: 190)
                .disabled(manager.isProcessing || manager.isAnalyzingSpeakers)
            }

            if manualSpeakerCount > detectedSpeakerCount,
                session.expectedSpeakerCount == 0,
                !manager.isAnalyzingSpeakers
            {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppTheme.Status.warningStrong)
                    Text("В якорях указано \(manualSpeakerCount) участников, а найдено только \(detectedSpeakerCount). Пересчитайте анализ с точным числом голосов.")
                        .font(.caption)
                    Spacer()
                    Button("Пересчитать на \(manualSpeakerCount)") {
                        session.expectedSpeakerCount = manualSpeakerCount
                    }
                    .buttonStyle(.bordered)
                }
            }

            if case .preparingModels = manager.speakerAnalysisStage {
                Text("При первом запуске модели разделения голосов могут один раз загрузиться из интернета. После загрузки Meetings работает офлайн.")
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
                Image(systemName: session.sourceURL == nil ? "waveform.badge.plus" : "waveform.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(
                        session.sourceURL == nil ? AppTheme.Accent.primary : AppTheme.Status.positive
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(session.sourceURL?.lastPathComponent ?? "Выберите запись встречи")
                        .font(.headline)
                        .lineLimit(1)
                    Text(
                        session.sourceURL == nil
                            ? "Перетащите сюда аудио или видео из Zoom: M4A, MP3, WAV, MP4 или MOV"
                            : "Нажмите, чтобы заменить файл"
                    )
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
                        style: StrokeStyle(
                            lineWidth: isDropTargeted ? 2 : 1,
                            dash: session.sourceURL == nil ? [7] : []
                        )
                    )
            }
        }
        .buttonStyle(.plain)
        .disabled(manager.isProcessing || manager.isAnalyzingSpeakers)
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
                    .frame(width: 140, alignment: .leading)
                Picker("", selection: $session.selectedModelName) {
                    ForEach(whisperModelManager.availableModels, id: \.name) { model in
                        Text(model.name).tag(model.name)
                    }
                }
                .labelsHidden()
                .disabled(manager.isProcessing)
            }

            HStack {
                Text("Язык")
                    .frame(width: 140, alignment: .leading)
                Picker("", selection: $session.language) {
                    Text("Определить автоматически").tag("auto")
                    Text("Русский").tag("ru")
                    Text("Украинский").tag("uk")
                    Text("English").tag("en")
                }
                .labelsHidden()
                .disabled(manager.isProcessing)
            }

            Divider()

            Toggle("Онлайн AI-итоги и follow-up (необязательно)", isOn: $session.useAIInsights)
                .disabled(manager.isProcessing)

            if session.useAIInsights {
                if let provider = configuredAIProvider {
                    Label(
                        "Аудио остаётся на Mac. Только готовый текст будет отправлен в \(provider.rawValue), чтобы выделить решения, задачи и сроки.",
                        systemImage: "text.badge.checkmark"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text("AI-провайдер не подключён. Транскрипция всё равно будет выполнена локально, а итоги — собраны локальными правилами.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.Status.warningStrong)
                        Spacer()
                        Button("Подключить") { navigation.selectedView = .models }
                            .buttonStyle(.borderless)
                    }
                }
            } else {
                Label(
                    "Выключено по умолчанию: запись и текст встречи никуда не отправляются.",
                    systemImage: "lock.fill"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(AppTheme.Surface.subtle, in: RoundedRectangle(cornerRadius: 12))
    }

    private var speakersCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Голоса и якоря", systemImage: "person.2")
                    .font(.headline)
                Spacer()
                Button(action: addManualAnchorAtCurrentTime) {
                    Label(
                        playerController.duration > 0
                            ? "Якорь на \(MeetingTimecode.format(playerController.currentTime))"
                            : "Добавить якорь",
                        systemImage: "plus"
                    )
                }
                .buttonStyle(.borderless)
                .disabled(manager.isProcessing)
            }

            Text("Прослушайте пример каждого найденного голоса и впишите имя. Якорь связывает имя с голосом, который звучит в указанную секунду.")
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
                            .frame(width: 140, alignment: .leading)

                            TextField("Имя участника", text: speakerNameBinding(for: speakerID))
                                .textFieldStyle(.roundedBorder)
                                .disabled(manager.isProcessing)

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
            } else if !manager.isAnalyzingSpeakers {
                Text("После анализа здесь появятся найденные голоса и кнопки для прослушивания примеров.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Якоря на конкретных секундах")
                .font(.subheadline.weight(.medium))

            if session.anchors.isEmpty {
                Text("Поставьте запись на момент, где участник говорит один, нажмите «Якорь», затем укажите его имя.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach($session.anchors) { $anchor in
                HStack(spacing: 10) {
                    Button {
                        play(anchor: anchor)
                    } label: {
                        Image(systemName: "play.circle")
                    }
                    .buttonStyle(.plain)
                    .disabled(anchor.timeInterval == nil)
                    .help("Перейти к этой секунде")

                    TextField(
                        "0:00",
                        text: Binding(
                            get: { anchor.timestamp },
                            set: { anchor.updateTimestampManually($0) }
                        )
                    )
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 100)
                        .disabled(manager.isProcessing)
                    Text("—")
                        .foregroundStyle(.secondary)
                    TextField("Имя участника", text: $anchor.speakerName)
                        .textFieldStyle(.roundedBorder)
                        .disabled(manager.isProcessing)
                    Button {
                        session.anchors.removeAll { $0.id == anchor.id }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(manager.isProcessing)
                    .help("Удалить якорь")
                }
            }

            if hasInvalidAnchors {
                Text("Проверьте якоря: у каждого должно быть имя и время в формате ММ:СС или ЧЧ:ММ:СС.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Status.error)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(AppTheme.Surface.subtle, in: RoundedRectangle(cornerRadius: 12))
    }

    private var progressCard: some View {
        let progress = clamped(manager.stage.progress ?? 0)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                if manager.isProcessing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppTheme.Status.error)
                }
                Text(manager.stage.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(isFailure ? AppTheme.Status.error : .primary)
                Spacer()
                if manager.isProcessing {
                    Text(percent(progress))
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                }
            }

            if manager.isProcessing {
                ProgressView(value: progress, total: 1)
                    .accessibilityLabel("Общий прогресс обработки встречи")
                    .accessibilityValue(percent(progress))

                HStack(spacing: 6) {
                    processingPhase("Аудио", systemImage: "waveform", range: 0..<0.15, progress: progress)
                    processingPhase("Голоса", systemImage: "person.2.wave.2", range: 0.15..<0.58, progress: progress)
                    processingPhase("Текст", systemImage: "text.bubble", range: 0.58..<0.94, progress: progress)
                    processingPhase("Результат", systemImage: "doc.text", range: 0.94..<1.01, progress: progress)
                }
            }

            if case .preparingDiarizationModels = manager.stage {
                Text("При первом запуске модели голосов загрузятся один раз. После этого интернет для Meetings не нужен.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if case .transcribing = manager.stage {
                Text("Whisper обрабатывает запись локально. Для длинного файла этот этап может занять несколько минут.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(AppTheme.Accent.fillSubtle, in: RoundedRectangle(cornerRadius: 12))
    }

    private func processingPhase(
        _ title: String,
        systemImage: String,
        range: Range<Double>,
        progress: Double
    ) -> some View {
        let isComplete = progress >= range.upperBound
        let isCurrent = progress >= range.lowerBound && progress < range.upperBound

        return Label(title, systemImage: isComplete ? "checkmark.circle.fill" : systemImage)
            .font(.caption.weight(isCurrent ? .semibold : .regular))
            .foregroundStyle(
                isComplete
                    ? AppTheme.Status.positive
                    : (isCurrent ? AppTheme.Accent.primary : Color.secondary)
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(
                isCurrent ? AppTheme.Accent.fill : AppTheme.Surface.subtle,
                in: RoundedRectangle(cornerRadius: 8)
            )
    }

    private func resultView(_ transcript: MeetingTranscript) -> some View {
        VStack(spacing: 0) {
            mediaPlayerCard(speakerNames: transcript.speakerNames)
                .padding(.horizontal, 24)
                .padding(.top, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Транскрипция готова", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                            .foregroundStyle(AppTheme.Status.positive)
                        Spacer()
                        Text("\(transcript.turns.count) реплик")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let warning = manager.insightsWarning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(AppTheme.Status.warningStrong)
                            .padding(12)
                            .background(
                                AppTheme.Status.warningStrong.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                    }

                    MarkdownContentView(
                        transcript.markdown,
                        fontSize: 14,
                        foregroundColor: AppTheme.Text.primary
                    )
                }
                .padding(24)
                .frame(maxWidth: 820, alignment: .leading)
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
            session.anchors
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
        let duration = max(playerController.duration, manager.speakerAnalysisDuration)
        return session.anchors.contains { anchor in
            let hasAnyValue = !anchor.timestamp.trimmingCharacters(in: .whitespaces).isEmpty
                || !anchor.speakerName.trimmingCharacters(in: .whitespaces).isEmpty
            let time = anchor.timeInterval
            return hasAnyValue
                && (time == nil
                    || anchor.speakerName.trimmingCharacters(in: .whitespaces).isEmpty
                    || (duration > 0 && time! > duration))
        }
    }

    private var isFailure: Bool {
        if case .failed = manager.stage { return true }
        return false
    }

    private func selectDefaultModelIfNeeded() {
        if !whisperModelManager.availableModels.contains(where: { $0.name == session.selectedModelName }) {
            session.selectedModelName = whisperModelManager.availableModels.first?.name ?? ""
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie]
        if panel.runModal() == .OK, let url = panel.url {
            if session.sourceURL == url {
                sourceDidChange(url)
            } else {
                session.sourceURL = url
            }
        }
    }

    private func sourceDidChange(_ newURL: URL?) {
        session.detectedSpeakerNames = [:]
        session.anchors = []
        // Replacing the recording starts a distinct meeting and therefore needs
        // fresh consent before any transcript text can be sent to an AI provider.
        session.useAIInsights = false
        manager.reset()

        guard let newURL else {
            playerController.cleanup()
            return
        }

        playerController.load(newURL)
        manager.analyzeSpeakers(
            sourceURL: newURL,
            expectedSpeakerCount: session.expectedSpeakerCount > 0 ? session.expectedSpeakerCount : nil
        )
    }

    private func beginNewMeeting() {
        manager.reset()
        playerController.cleanup()
        session.clearRecordingInputs()
    }

    private func start() {
        guard let sourceURL = session.sourceURL, let selectedModel else { return }
        var validAnchors = session.anchors.filter {
            $0.timeInterval != nil && !$0.speakerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        var existingNames = Set(validAnchors.map { $0.speakerName.lowercased() })
        for speakerID in detectedSpeakerIDs {
            let name = session.detectedSpeakerNames[speakerID]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty,
                !existingNames.contains(name.lowercased()),
                let segment = representativeSegment(for: speakerID)
            else { continue }
            validAnchors.append(
                MeetingSpeakerAnchor(
                    timestamp: MeetingTimecode.format((segment.startTime + segment.endTime) / 2),
                    speakerName: name,
                    speakerID: speakerID
                )
            )
            existingNames.insert(name.lowercased())
        }

        let inferredCount = Set(validAnchors.map { $0.speakerName.lowercased() }).count
        let count: Int?
        if session.expectedSpeakerCount > 0 {
            count = session.expectedSpeakerCount
        } else if inferredCount > detectedSpeakerCount {
            count = inferredCount
        } else {
            count = nil
        }

        playerController.pause()
        manager.start(
            sourceURL: sourceURL,
            whisperModel: selectedModel,
            language: session.language,
            expectedSpeakerCount: count,
            anchors: validAnchors,
            whisperModelManager: whisperModelManager,
            insightConfiguration: meetingInsightConfiguration,
            aiService: meetingInsightConfiguration == nil ? nil : aiService
        )
    }

    private var meetingInsightConfiguration: MeetingInsightAnalysisConfiguration? {
        guard session.useAIInsights, let provider = configuredAIProvider else { return nil }
        return MeetingInsightAnalysisConfiguration(
            provider: provider,
            modelName: aiService.selectedModel(for: provider)
        )
    }

    private func addManualAnchorAtCurrentTime() {
        addAnchorFromPlayer(time: playerController.currentTime, speakerID: activeSpeakerID)
    }

    private func addAnchorFromPlayer(time: TimeInterval, speakerID: String?) {
        let suggestedName = speakerID.flatMap { session.detectedSpeakerNames[$0] } ?? ""
        session.anchors.append(
            MeetingSpeakerAnchor(
                timestamp: MeetingTimecode.format(time),
                speakerName: suggestedName,
                speakerID: speakerID
            )
        )
    }

    private func speakerNameBinding(for speakerID: String) -> Binding<String> {
        Binding(
            get: { session.detectedSpeakerNames[speakerID] ?? "" },
            set: { session.detectedSpeakerNames[speakerID] = $0 }
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
        playerController.play(until: segment.endTime)
    }

    private func play(anchor: MeetingSpeakerAnchor) {
        guard let time = anchor.timeInterval else { return }
        playerController.seek(to: time)
        playerController.play()
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !manager.isProcessing,
            !manager.isAnalyzingSpeakers,
            let provider = providers.first(where: {
                $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            })
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
                DispatchQueue.main.async {
                    if session.sourceURL == url {
                        sourceDidChange(url)
                    } else {
                        session.sourceURL = url
                    }
                }
            }
        }
        return true
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private func percent(_ value: Double) -> String {
        "\(Int((clamped(value) * 100).rounded()))%"
    }
}
