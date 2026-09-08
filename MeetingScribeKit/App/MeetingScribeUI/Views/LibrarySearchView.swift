import Core
import Export
import Store
import SwiftUI

/// Выдача поиска по библиотеке (SPEC.md §2 п. 6, §3.6): реплики, решения, задачи и вопросы всех встреч,
/// сгруппированные по встречам. Клик ведёт к реплике или к контексту проекта.
struct LibrarySearchView: View {
  @Bindable var model: AppModel

  var body: some View {
    let numbered = Array(model.libraryResults.enumerated())
    if numbered.isEmpty {
      ContentUnavailableView {
        Label(
          model.isSearchingLibrary
            ? String(localized: "Ищу…") : String(localized: "Ничего не найдено"),
          systemImage: "magnifyingglass")
      } description: {
        Text(
          model.isSearchingLibrary
            ? "Ищу «\(model.searchText)» по репликам, решениям, задачам и вопросам."
            : "Проверьте запрос или поищите по другой формулировке: ищутся начала слов.")
      }
      .accessibilityIdentifier("search.results")
    } else {
      VStack(alignment: .leading, spacing: 0) {
        HStack {
          Text(
            String(localized: "Найдено \(numbered.count) совпадений")
          )
          .font(.headline)
          if model.isSearchingLibrary {
            Text("Ищу…")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
        }
        .padding([.horizontal, .top])
        List {
          ForEach(groups(numbered), id: \.key) { group in
            Section(group.title) {
              ForEach(group.items, id: \.result.id) { item in
                row(item.result, position: item.position)
              }
            }
          }
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("search.results")
    }
  }

  private func row(_ result: LibrarySearchResult, position: Int) -> some View {
    Button {
      model.open(result)
    } label: {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: result.systemImage)
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        if let start = result.hit.start {
          Text(Timecode.hhmmss(start))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        if let speaker = result.speakerName {
          Text(speaker)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Text(result.highlightedText)
          .lineLimit(3)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("search.result.\(position)")
    .accessibilityLabel(label(for: result))
  }

  private func label(for result: LibrarySearchResult) -> String {
    var parts = [result.kindTitle, result.meetingTitle]
    if let start = result.hit.start { parts.append(Timecode.hhmmss(start)) }
    if let speaker = result.speakerName { parts.append(speaker) }
    parts.append(result.hit.text)
    return parts.joined(separator: ", ")
  }

  /// Группы по встречам в порядке лучшего совпадения; записи без встречи — в конце.
  private func groups(_ numbered: [(offset: Int, element: LibrarySearchResult)]) -> [Group] {
    var order: [String] = []
    var buckets: [String: Group] = [:]
    for (position, result) in numbered {
      let key = result.hit.meetingID?.uuidString ?? "—"
      if buckets[key] == nil {
        order.append(key)
        buckets[key] = Group(key: key, title: title(for: result), items: [])
      }
      buckets[key]?.items.append(Item(position: position, result: result))
    }
    return order.compactMap { buckets[$0] }
  }

  private func title(for result: LibrarySearchResult) -> String {
    guard let date = result.meetingDate else { return result.meetingTitle }
    return "\(result.meetingTitle) · \(date.formatted(.dateTime.day().month(.abbreviated).year()))"
  }

  private struct Group {
    var key: String
    var title: String
    var items: [Item]
  }

  private struct Item {
    var position: Int
    var result: LibrarySearchResult
  }
}
