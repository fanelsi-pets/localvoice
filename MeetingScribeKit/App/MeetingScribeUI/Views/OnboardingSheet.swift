import Core
import SwiftUI

/// Онбординг первого запуска (DESIGN.md §5, SPEC.md §2 п. 8): пять шагов — проверка железа, языки,
/// модели, самопроверка, готово. Только стандартные компоненты: `Form`, `Toggle`, `Picker`,
/// `ProgressView(value:)`, SF Symbols с текстом вердикта (цвет не единственный признак — DESIGN.md §8).
struct OnboardingSheet: View {
  @Bindable var model: AppModel

  private var onboarding: OnboardingController { model.onboarding }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      header
      Divider()
      content
      Spacer(minLength: 0)
      Divider()
      footer
    }
    .padding()
    .frame(minWidth: 620, minHeight: 480)
    .task(id: onboarding.step) { await onboarding.refresh() }
    .onChange(of: model.modelDownloads.finishedText) { _, finished in
      guard finished != nil else { return }
      Task { await onboarding.refresh() }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("onboarding.sheet")
  }

  // MARK: - Шапка и кнопки

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(onboarding.step.title)
        .font(.title2)
        .accessibilityIdentifier("onboarding.title")
      Text(onboarding.step.subtitle)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Text(stepCounter)
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
  }

  private var stepCounter: String {
    let index = (OnboardingStep.allCases.firstIndex(of: onboarding.step) ?? 0) + 1
    return String(localized: "Шаг \(index) из \(OnboardingStep.allCases.count)")
  }

  @ViewBuilder private var content: some View {
    switch onboarding.step {
    case .welcome: welcomeStep
    case .languages: languagesStep
    case .models: modelsStep
    case .selfTest: selfTestStep
    case .done: doneStep
    }
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let reason = onboarding.blockingReason {
        Text(reason)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      HStack {
        Button("Пропустить") { onboarding.skip() }
          .accessibilityIdentifier("onboarding.skip")
        Spacer()
        Button("Назад") { onboarding.back() }
          .disabled(onboarding.isFirstStep)
          .accessibilityIdentifier("onboarding.back")
        if onboarding.isLastStep {
          Button("Начать") { onboarding.finish() }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("onboarding.finish")
        } else {
          Button("Далее") { onboarding.next() }
            .keyboardShortcut(.defaultAction)
            .disabled(!onboarding.canGoNext)
            .accessibilityIdentifier("onboarding.next")
        }
      }
    }
  }

  // MARK: - Шаг 1: железо

  private var welcomeStep: some View {
    Form {
      Section("Этот компьютер") {
        ForEach(onboarding.hardware.items) { item in
          LabeledContent {
            Text(item.detail)
              .font(.callout)
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.trailing)
          } label: {
            Label {
              Text(item.title)
            } icon: {
              Image(systemName: Self.icon(for: item.verdict))
                .foregroundStyle(Self.color(for: item.verdict))
            }
          }
          .accessibilityElement(children: .combine)
          .accessibilityLabel(
            "\(item.title): \(Self.verdictTitle(item.verdict)). \(item.detail)"
          )
          .accessibilityIdentifier("onboarding.check.\(item.id)")
        }
        if onboarding.hardware.items.isEmpty {
          Text("Проверяю компьютер…").foregroundStyle(.secondary)
        }
      }
      Section {
        Text(
          "Записи не покидают этот Mac: распознавание и разделение по голосам идут на Neural Engine и GPU. Интернет нужен один раз — скачать модели."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  // MARK: - Шаг 2: языки и режим

  private var languagesStep: some View {
    Form {
      Section("Языки встреч") {
        ForEach(AppSettings.defaultMeetingLanguages, id: \.code) { language in
          Toggle(
            Self.languageTitle(language),
            isOn: Binding(
              get: { onboarding.isLanguageEnabled(language) },
              set: { onboarding.setLanguage(language, enabled: $0) })
          )
          .accessibilityIdentifier("onboarding.language.\(language.code)")
        }
        Text(
          "Язык определяется для каждого спикера отдельно: русская речь остаётся русской, украинская — украинской, английские термины сохраняются латиницей."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Section("Режим обработки по умолчанию") {
        Picker(
          "Режим",
          selection: Binding(get: { onboarding.mode }, set: { onboarding.mode = $0 })
        ) {
          ForEach(ProcessingMode.allCases) { mode in
            Text(mode.title).tag(mode)
          }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("onboarding.mode")
        Text(onboarding.mode.detail(accurate: onboarding.accurateSelection))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  // MARK: - Шаг 3: модели

  private var modelsStep: some View {
    Form {
      Section("Нужные модели") {
        ForEach(onboarding.modelStatuses, id: \.id) { status in
          LabeledContent {
            Text(modelStateText(status))
              .font(.caption)
              .monospacedDigit()
              .foregroundStyle(status.isPresent ? Color.secondary : Color.primary)
          } label: {
            Label {
              Text(status.id.title)
            } icon: {
              Image(systemName: status.isPresent ? "checkmark.circle" : "arrow.down.circle")
                .foregroundStyle(status.isPresent ? Color.green : Color.accentColor)
            }
          }
          .accessibilityElement(children: .combine)
        }
        LabeledContent(
          "Всего скачать",
          value: onboarding.missingModels.isEmpty
            ? String(localized: "ничего — модели на месте")
            : ByteText.short(onboarding.missingBytes))
      }
      Section {
        downloadControls
      }
      if onboarding.hasLegacyCache {
        Section("Модели уже есть на этом Mac") {
          Button("Перенести из кэша") {
            Task { await onboarding.importFromLegacyCache() }
          }
          .disabled(onboarding.isImportingLegacyCache)
          .accessibilityIdentifier("onboarding.import")
          if let text = onboarding.legacyImportText {
            Text(text).font(.caption).foregroundStyle(.secondary)
          } else {
            Text(
              "Нашлись папки прошлых загрузок (Hugging Face, FluidAudio) — модели можно перенести без интернета."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
        }
      }
    }
    .formStyle(.grouped)
  }

  @ViewBuilder private var downloadControls: some View {
    let downloads = model.modelDownloads
    if downloads.isActive {
      ProgressView(value: downloads.fraction) {
        Text("Скачивание моделей")
      } currentValueLabel: {
        Text("\(Int(downloads.fraction * 100)) %").monospacedDigit()
      }
      .progressViewStyle(.linear)
      .accessibilityIdentifier("onboarding.download.progress")
      .accessibilityLabel("Прогресс скачивания моделей")
      .accessibilityValue("\(Int(downloads.fraction * 100)) %")
      Text(downloads.statusText)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .accessibilityIdentifier("onboarding.download.status")
      HStack {
        if downloads.isPaused {
          Button("Продолжить") { downloads.resume() }
            .accessibilityIdentifier("onboarding.download.resume")
        } else {
          Button("Пауза") { downloads.pause() }
            .accessibilityIdentifier("onboarding.download.pause")
        }
        Button("Свернуть") { onboarding.minimize() }
          .accessibilityIdentifier("onboarding.minimize")
        Text("Загрузка продолжится, даже если закрыть это окно.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    } else if onboarding.missingModels.isEmpty {
      Label("Модели на месте — можно идти дальше", systemImage: "checkmark.circle")
        .foregroundStyle(.green)
        .accessibilityIdentifier("onboarding.download.status")
    } else {
      Button("Скачать") { model.startModelDownload() }
        .keyboardShortcut(.return, modifiers: [.command])
        .accessibilityIdentifier("onboarding.download.start")
      Text(
        "Модели скачиваются с Hugging Face в папку приложения. Загрузку можно поставить на паузу и продолжить позже."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .accessibilityIdentifier("onboarding.download.status")
    }
    if let error = model.modelDownloads.errorText {
      Label(error, systemImage: "exclamationmark.triangle")
        .font(.caption)
        .foregroundStyle(.orange)
      Button("Повторить") { model.modelDownloads.retry() }
        .accessibilityIdentifier("onboarding.download.retry")
    }
  }

  private func modelStateText(_ status: ModelStatus) -> String {
    status.isPresent
      ? String(localized: "скачано") : "\(ByteText.short(status.id.downloadSpec.approximateBytes))"
  }

  // MARK: - Шаг 4: самопроверка

  private var selfTestStep: some View {
    Form {
      Section("Проверка на встроенном сэмпле") {
        if model.selfTest.isRunning {
          ProgressView(value: model.selfTest.barValue) {
            Text(model.selfTest.line1)
          } currentValueLabel: {
            Text("\(model.selfTest.percent) %").monospacedDigit()
          }
          .progressViewStyle(.linear)
          .accessibilityIdentifier("onboarding.selftest.progress")
          .accessibilityLabel("Прогресс самопроверки")
          .accessibilityValue("\(model.selfTest.percent) %")
          Text(model.selfTest.line2)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.head)
          Button("Остановить") { model.selfTest.cancel() }
            .disabled(model.selfTest.isStopping)
            .accessibilityIdentifier("onboarding.selftest.cancel")
        } else {
          Button(
            model.selfTest.hasResult
              ? String(localized: "Повторить") : String(localized: "Запустить проверку")
          ) {
            model.startSelfTest()
          }
          .accessibilityIdentifier("onboarding.selftest.run")
        }
        SelfTestStageList(checks: model.selfTest.stageChecks)
      }
      if let result = model.selfTest.resultText {
        Section("Результат") {
          Label {
            Text(result)
          } icon: {
            Image(systemName: resultIcon)
              .foregroundStyle(resultColor)
          }
          .accessibilityIdentifier("onboarding.selftest.result")
          ForEach(model.selfTest.report?.problems ?? [], id: \.self) { problem in
            Label(problem, systemImage: "exclamationmark.triangle")
              .font(.caption)
              .foregroundStyle(.orange)
          }
          ForEach(model.selfTest.report?.preview ?? [], id: \.self) { line in
            Text(line)
              .font(.caption)
              .monospacedDigit()
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
          if model.selfTest.report?.passed != true {
            Button("Собрать отчёт") { model.collectProblemReport() }
              .disabled(model.isCollectingProblemReport)
              .accessibilityIdentifier("onboarding.selftest.report")
          }
        }
      }
    }
    .formStyle(.grouped)
  }

  private var resultIcon: String {
    if model.selfTest.errorText != nil { return "xmark.octagon" }
    guard let report = model.selfTest.report else { return "exclamationmark.triangle" }
    if !report.passed { return "xmark.octagon" }
    return report.problems.isEmpty ? "checkmark.circle" : "exclamationmark.triangle"
  }

  private var resultColor: Color {
    switch resultIcon {
    case "checkmark.circle": .green
    case "exclamationmark.triangle": .orange
    default: .red
    }
  }

  // MARK: - Шаг 5: готово

  private var doneStep: some View {
    Form {
      Section("Как получить лучший результат") {
        Label(
          "В Zoom включите «Record a separate audio file for each participant» — тогда имена участников берутся из имён файлов, а точность разделения по голосам почти стопроцентная.",
          systemImage: "person.2.badge.gearshape"
        )
        .fixedSize(horizontal: false, vertical: true)
        Label(
          "Перетащите папку записи Zoom целиком: приложение найдёт аудио, видео, chat.txt и раздельные дорожки.",
          systemImage: "folder"
        )
        .fixedSize(horizontal: false, vertical: true)
        Label(
          "Первый прогон дольше остальных: macOS компилирует модели под Neural Engine.",
          systemImage: "clock"
        )
        .fixedSize(horizontal: false, vertical: true)
      }
      Section {
        Text("Первый запуск можно открыть заново: меню «Справка» → «Первый запуск…».")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  // MARK: - Оформление вердиктов

  static func icon(for verdict: HardwareCheck.Verdict) -> String {
    switch verdict {
    case .ok: "checkmark.circle"
    case .warning: "exclamationmark.triangle"
    case .failure: "xmark.octagon"
    }
  }

  static func color(for verdict: HardwareCheck.Verdict) -> Color {
    switch verdict {
    case .ok: .green
    case .warning: .orange
    case .failure: .red
    }
  }

  static func verdictTitle(_ verdict: HardwareCheck.Verdict) -> String {
    switch verdict {
    case .ok: String(localized: "в порядке")
    case .warning: String(localized: "предупреждение")
    case .failure: String(localized: "не подходит")
    }
  }

  static func languageTitle(_ language: Language) -> String {
    switch language {
    case .ru: String(localized: "Русский")
    case .uk: String(localized: "Українська")
    case .en: "English"
    default: language.code
    }
  }
}

/// Список стадий самопроверки с фактическим временем — тот же вид, что на карточке встречи (DESIGN.md §3b).
struct SelfTestStageList: View {
  let checks: [StageCheck]

  var body: some View {
    ForEach(checks) { check in
      HStack(spacing: 8) {
        Image(systemName: icon(for: check.state))
          .foregroundStyle(color(for: check.state))
        Text(check.stage.title)
          .foregroundStyle(check.state == .pending ? .secondary : .primary)
        Spacer()
        if let seconds = check.seconds {
          Text(ProgressPresentation.stageDuration(seconds))
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        } else if check.state == .skipped {
          Text("пропущено").font(.caption).foregroundStyle(.secondary)
        }
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("\(check.stage.title): \(stateTitle(check.state))")
    }
  }

  private func icon(for state: StageCheck.State) -> String {
    switch state {
    case .done: "checkmark.circle.fill"
    case .active: "circle.dotted"
    case .pending: "circle"
    case .skipped: "minus.circle"
    }
  }

  private func color(for state: StageCheck.State) -> Color {
    switch state {
    case .done: .green
    case .active: .accentColor
    case .pending, .skipped: .secondary
    }
  }

  private func stateTitle(_ state: StageCheck.State) -> String {
    switch state {
    case .done: String(localized: "готово")
    case .active: String(localized: "идёт")
    case .pending: String(localized: "ожидает")
    case .skipped: String(localized: "пропущено")
    }
  }
}
