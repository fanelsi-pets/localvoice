import Core
import Foundation

/// Запись дерева репозитория Hugging Face (`GET /api/models/<repo>/tree/<revision>?recursive=true`):
/// файл или папка, размер, git-oid и, для файлов LFS, sha256 содержимого (`lfs.oid`).
struct HubTreeEntry: Sendable, Decodable, Hashable {
  struct LFSInfo: Sendable, Decodable, Hashable {
    var oid: String
    var size: Int64?
  }

  var type: String
  var path: String
  var size: Int64
  /// git-oid: sha1 от «blob <размер>\0<содержимое>»; у файлов LFS это сумма указателя, а не содержимого.
  var oid: String?
  var lfs: LFSInfo?

  var isFile: Bool { type == "file" }
}

/// Клиент открытого API Hugging Face: листинг дерева с пагинацией, sha ревизии и адрес файла.
/// Токенов и cookies нет — репозитории моделей не gated (CLAUDE.md: сеть только за моделями).
struct HubClient: Sendable {
  /// Защита от бесконечной ленты `Link: rel="next"`.
  static let maxPages = 100
  static let host = URL(string: "https://huggingface.co")!
  static let timeout: TimeInterval = 30

  var session: URLSession

  // MARK: - Адреса

  static func treeURL(repo: String, revision: String, subpath: String?) -> URL {
    var url = host.appending(path: "api/models").appending(path: repo)
      .appending(path: "tree").appending(path: revision)
    if let subpath, !subpath.isEmpty {
      url.append(path: subpath)
    }
    url.append(queryItems: [URLQueryItem(name: "recursive", value: "true")])
    return url
  }

  static func revisionURL(repo: String, revision: String) -> URL {
    host.appending(path: "api/models").appending(path: repo)
      .appending(path: "revision").appending(path: revision)
  }

  /// Адрес файла: LFS уходит редиректом на CDN, `URLSession` идёт за ним сама и сохраняет `Range`.
  static func fileURL(repo: String, revision: String, path: String) -> URL {
    host.appending(path: repo).appending(path: "resolve").appending(path: revision)
      .appending(path: path)
  }

  // MARK: - Запросы

  /// Коммит ветки: файлы качаются по нему, чтобы совпадать с листингом. `nil` — сервер ответил без sha.
  func revisionSHA(repo: String, revision: String) async throws -> String? {
    struct Payload: Decodable { var sha: String? }
    let (data, http) = try await get(Self.revisionURL(repo: repo, revision: revision), repo: repo)
    guard http.statusCode == 200 else { return nil }
    let sha = try? JSONDecoder().decode(Payload.self, from: data).sha
    guard let sha, !sha.isEmpty else { return nil }
    return sha
  }

  /// Все записи дерева (подпапки — тоже, пути от корня репозитория), включая следующие страницы.
  func tree(repo: String, revision: String, subpath: String?) async throws -> [HubTreeEntry] {
    var url = Self.treeURL(repo: repo, revision: revision, subpath: subpath)
    var entries: [HubTreeEntry] = []
    var visited: Set<URL> = []
    for _ in 0..<Self.maxPages {
      guard visited.insert(url).inserted else { break }
      let (data, http) = try await get(url, repo: repo)
      guard http.statusCode == 200 else {
        throw ModelDownloadError.listingFailed(
          repo: repo, reason: String(localized: "сервер ответил \(http.statusCode)"))
      }
      do {
        entries.append(contentsOf: try JSONDecoder().decode([HubTreeEntry].self, from: data))
      } catch {
        throw ModelDownloadError.listingFailed(
          repo: repo, reason: String(localized: "неожиданный ответ (\(error.localizedDescription))")
        )
      }
      guard let next = Self.nextPage(http) else { break }
      url = next
    }
    return entries
  }

  private func get(_ url: URL, repo: String) async throws -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: url)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.httpShouldHandleCookies = false
    request.timeoutInterval = Self.timeout
    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        throw ModelDownloadError.listingFailed(
          repo: repo, reason: String(localized: "ответ не по HTTP"))
      }
      return (data, http)
    } catch let error as ModelDownloadError {
      throw error
    } catch {
      throw ModelDownloadError.network(error)
    }
  }

  /// `Link: <https://…&cursor=…>; rel="next"` — следующая страница листинга.
  static func nextPage(_ response: HTTPURLResponse) -> URL? {
    guard let header = response.value(forHTTPHeaderField: "Link") else { return nil }
    for link in header.split(separator: ",") {
      let parts = link.split(separator: ";")
      guard let target = parts.first?.trimmingCharacters(in: .whitespaces),
        target.hasPrefix("<"), target.hasSuffix(">")
      else { continue }
      let isNext = parts.dropFirst().contains {
        $0.replacingOccurrences(of: "\"", with: "")
          .trimmingCharacters(in: .whitespaces) == "rel=next"
      }
      guard isNext else { continue }
      return URL(string: String(target.dropFirst().dropLast()))
    }
    return nil
  }
}

extension ModelDownloadError {
  /// Сетевые сбои: нет соединения, таймаут, неизвестный хост — всё это «нет связи с Hugging Face»;
  /// отмена задачи остаётся отменой.
  static func network(_ error: Error) -> ModelDownloadError {
    if let known = error as? ModelDownloadError { return known }
    if error is CancellationError { return .cancelled }
    if let urlError = error as? URLError {
      if urlError.code == .cancelled { return .cancelled }
      return .offline(urlError.localizedDescription)
    }
    return .offline(error.localizedDescription)
  }

  /// Сбои файловой системы: не создалась папка, не записался файл, не переименовался `.part`.
  static func file(_ error: Error, path: String) -> ModelDownloadError {
    if let known = error as? ModelDownloadError { return known }
    if error is CancellationError { return .cancelled }
    if let urlError = error as? URLError, urlError.code == .cancelled { return .cancelled }
    return .fileSystem("\(path): \(error.localizedDescription)")
  }
}
