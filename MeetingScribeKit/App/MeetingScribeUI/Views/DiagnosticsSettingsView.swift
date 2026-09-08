import Core
import SwiftUI

/// Settings → «Диагностика» (SPEC.md §3.8): машина и ANE/GPU, версии моделей, самопроверка на встроенном
/// сэмпле со временем стадий, «Собрать отчёт о проблеме», папки и версия приложения.
struct DiagnosticsSettings: View {
  @Bindable var model: AppModel
  @State private var system = SystemInfo.current()
  @State private var statuses: [ModelStatus] = []
  @State private var manifests: [ModelID: ModelManifest] = [:]

  var body: some View {
    Form {
      machineSection
      modelsSection
      selfTestSection
      problemReportSection
      foldersSection
      applicationSection
    }
    .formStyle(.grouped)
    .accessibilityIdentifier("settings.diagnostics")
    .task {
      await reloadModels()
      await model.loadLastSelfTestReport()
    }
    .onChange(of: model.modelDownloads.finishedText) { _, _ in
      Task { await reloadModels() }
    }
  }

  // MARK: - Машина

  private var machineSection: some View {
    Section("Машина") {
      LabeledContent("Процессор", value: system.chip ?? system.architecture)
      if let identifier = system.modelIdentifier {
        LabeledContent("Модель", value: identifier)
      }
      LabeledContent("Ядра", value: "\(system.activeProcessorCount)")
      LabeledContent("Память", value: ProcessMemory.format(system.physicalMemoryBytes))
      LabeledContent("macOS", value: osText)
      LabeledContent(
        "Графический процессор", value: system.gpuName ?? String(localized: "Metal недоступен"))
      LabeledContent(
        "Neural Engine",
        value: system.hasNeuralEngine
          ? String(localized: "доступен (Apple Silicon)")
          : String(localized: "нет — нужен Apple Silicon"))
    }
  }

  private var osText: String {
    guard let build = system.osBuild else { return system.osVersion }
    return "\(system.osVersion) (\(build))"
  }

  // MARK: - Модели

  private var modelsSection: some View {
    Section("Модели") {
      ForEach(statuses, id: \.id) { status in
        VStack(alignment: .leading, spacing: 2) {
          HStack {
            Label {
              Text(status.id.title)
            } icon: {
              Image(systemName: status.isPresent ? "checkmark.circle" : "circle")
                .foregroundStyle(status.isPresent ? Color.green : Color.secondary)
            }
            Spacer()
            Text(sizeText(status))
              .font(.caption)
              .monospacedDigit()
              .foregroundStyle(status.isPresent ? Color.secondary : Color.orange)
          }
          Text(versionText(status))
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
      }
      HStack {
        Button("Проверить файлы") { model.verifyModels() }
          .disabled(model.isVerifyingModels)
          .accessibilityIdentifier("settings.verifyModels")
        if model.isVerifyingModels {
          Button("Остановить") { model.cancelModelVerification() }
            .accessibilityIdentifier("settings.verifyModels.cancel")
        }
      }
      if model.isVerifyingModels {
        VStack(alignment: .leading, spacing: 4) {
          ProgressView(value: model.modelVerificationFraction)
            .progressViewStyle(.linear)
            .accessibilityIdentifier("settings.verifyProgress")
            .accessibilityValue("\(Int(model.modelVerificationFraction * 100)) %")
          Text(model.modelVerificationStatus ?? "")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      if let text = model.modelVerificationText {
        Text(text)
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .accessibilityIdentifier("settings.verifyResult")
      }
    }
  }

  private func sizeText(_ status: ModelStatus) -> String {
    guard status.isPresent else {
      return String(
        localized: "не скачано · ~\(ByteText.short(status.id.downloadSpec.approximateBytes))")
    }
    guard let bytes = status.sizeBytes else { return String(localized: "скачано") }
    return String(localized: "скачано · \(ByteText.short(Int64(bytes)))")
  }

  /// Ревизия и дата из манифеста; у моделей, перенесённых из старых кэшей, манифеста нет.
  private func versionText(_ status: ModelStatus) -> String {
    guard status.isPresent else { return status.id.license }
    guard let manifest = manifests[status.id] else {
      return String(localized: "\(status.id.license) · из старого кэша")
    }
    let date = manifest.downloadedAt.formatted(.dateTime.day().month(.abbreviated).year())
    return String(localized: "\(status.id.license) · ревизия \(manifest.shortRevision) · \(date)")
  }

  // MARK: - Самопроверка

  private var selfTestSection: some View {
    Section("Самопроверка") {
      if model.selfTest.isRunning {
        ProgressView(value: model.selfTest.barValue) {
          Text(model.selfTest.line1)
        } currentValueLabel: {
          Text("\(model.selfTest.percent) %").monospacedDigit()
        }
        .progressViewStyle(.linear)
        .accessibilityIdentifier("settings.selftest.progress")
        .accessibilityValue("\(model.selfTest.percent) %")
        Text(model.selfTest.line2)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.head)
        Button("Остановить") { model.selfTest.cancel() }
          .disabled(model.selfTest.isStopping)
      } else {
        Button(
          model.selfTest.hasResult
            ? String(localized: "Запустить снова") : String(localized: "Запустить")
        ) {
          model.startSelfTest()
        }
        .accessibilityIdentifier("settings.selftest.run")
      }
      SelfTestStageList(checks: model.selfTest.stageChecks)
      if let result = model.selfTest.resultText {
        Text(result)
          .font(.callout)
          .accessibilityIdentifier("settings.selftest.result")
        ForEach(model.selfTest.report?.problems ?? [], id: \.self) { problem in
          Label(problem, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
        }
        ForEach(model.selfTest.report?.preview ?? [], id: \.self) { line in
          Text(line)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
        if let report = model.selfTest.report {
          Text(
            "Ключевые слова: \(report.keywordSummary) · движки: \(report.enginesTitle)"
          )
          .font(.caption2)
          .foregroundStyle(.secondary)
        }
      } else {
        Text(
          "Проверка прогоняет встроенный сэмпл (около 30 секунд, русская и украинская речь) через тот же путь, что и настоящую встречу."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: - Отчёт о проблеме

  private var problemReportSection: some View {
    Section("Отчёт о проблеме") {
      HStack {
        Button("Собрать отчёт") { model.collectProblemReport() }
          .disabled(model.isCollectingProblemReport)
          .accessibilityIdentifier("settings.problemReport")
        if model.isCollectingProblemReport {
          Text("Собираю отчёт…").font(.caption).foregroundStyle(.secondary)
        }
        if let url = model.problemReportURL {
          Button("Показать в Finder") { model.revealInFinder(url) }
            .accessibilityIdentifier("settings.problemReport.reveal")
        }
      }
      if let url = model.problemReportURL {
        Text(url.lastPathComponent)
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .accessibilityIdentifier("settings.problemReport.file")
      }
      Text(
        "В отчёт попадают машина, версия, настройки, состояние моделей, последняя самопроверка, статусы встреч и журнал приложения. Аудио, текста реплик и названий встреч в нём нет."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  // MARK: - Папки и версия

  private var foldersSection: some View {
    Section("Папки") {
      LabeledContent("Модели") {
        HStack {
          Text(model.modelStore.root.path(percentEncoded: false))
            .lineLimit(1)
            .truncationMode(.middle)
          Button("Показать в Finder") { model.revealInFinder(model.modelStore.root) }
            .accessibilityIdentifier("settings.revealModels")
        }
      }
      LabeledContent("Отчёты диагностики") {
        HStack {
          Text(model.store.diagnosticsDirectory.path(percentEncoded: false))
            .lineLimit(1)
            .truncationMode(.middle)
          Button("Показать в Finder") { model.revealInFinder(model.store.diagnosticsDirectory) }
            .accessibilityIdentifier("settings.revealDiagnostics")
        }
      }
    }
  }

  private var applicationSection: some View {
    Section("Приложение") {
      LabeledContent("Версия", value: Self.appVersion)
      LabeledContent("Модуль интерфейса", value: MeetingScribeUIInfo.version)
      Button("Первый запуск…") {
        model.onboarding.go(to: .welcome)
        model.onboarding.present()
      }
      .accessibilityIdentifier("settings.onboarding")
    }
  }

  private func reloadModels() async {
    let store = model.modelStore
    let snapshot = await Task.detached { () -> ([ModelStatus], [ModelID: ModelManifest]) in
      let statuses = store.status()
      var manifests: [ModelID: ModelManifest] = [:]
      for status in statuses where status.isPresent {
        if let manifest = store.manifest(for: status.id) { manifests[status.id] = manifest }
      }
      return (statuses, manifests)
    }.value
    statuses = snapshot.0
    manifests = snapshot.1
  }

  static var appVersion: String {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String
    let build = info?["CFBundleVersion"] as? String
    switch (short, build) {
    case (let short?, let build?): return "\(short) (\(build))"
    case (let short?, nil): return short
    default: return MeetingScribeUIInfo.version
    }
  }
}
