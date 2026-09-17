import Core
import SwiftUI

/// Разовый вопрос после обновления: распознавание встреч умеет уходить в облако, а обещание «всё на этом
/// Mac» менять молча нельзя (DESIGN.md §9). Ответ запоминается в настройках (`cloudDefaultAnswered`),
/// второй раз sheet не появляется; передумать можно в настройках встреч.
struct ProcessingPlaceSheet: View {
  @Bindable var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Где обрабатывать встречи?")
        .font(.title3)
      Text(
        "Распознавание речи теперь умеет работать в облаке Microsoft Azure. Ключ спросим один раз, перед первой обработкой. Разделение по голосам, имена, память проекта и экспорт в любом случае остаются на этом Mac."
      )
      .fixedSize(horizontal: false, vertical: true)
      GroupBox {
        Text(
          "Минуты вместо десятков минут и лучше на смешанной русско-украинской речи. Аудио встречи уходит в Azure; по условиям Azure отправленное не сохраняется. Нужен ключ Azure Speech — его спросят перед первой обработкой. Модели распознавания скачивать не нужно."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      } label: {
        Label("В облаке", systemImage: "cloud")
      }
      GroupBox {
        Text(
          "Запись не покидает компьютер. Нужны модели WhisperKit (около 1,6 ГБ) и заметно больше времени на обработку."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      } label: {
        Label("На этом Mac", systemImage: "lock.laptopcomputer")
      }
      HStack {
        Spacer()
        // Escape оставляет всё как было: обработка на этом Mac — текущее поведение приложения.
        Button("На этом Mac") { model.answerProcessingPlace(.local) }
          .keyboardShortcut(.cancelAction)
          .accessibilityIdentifier("processingPlace.local")
        Button("В облаке") { model.answerProcessingPlace(.cloud) }
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("processingPlace.cloud")
      }
    }
    .padding()
    .frame(minWidth: 460)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("processingPlace.sheet")
  }
}
