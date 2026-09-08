import Core
import CryptoKit
import Foundation

/// Контрольные суммы файлов модели: sha256 содержимого (так Hugging Face хранит `lfs.oid`) и git-oid —
/// sha1 от «blob <размер>\0<содержимое>» для обычных файлов репозитория. Читается потоково: 1.6 GB
/// модели не должны оказаться в памяти целиком.
enum FileHash {
  enum Kind: Sendable {
    case sha256
    case gitBlobSHA1
  }

  static let chunkBytes = 1 << 20

  /// - Parameter onChunk: вызывается после каждого прочитанного куска — прогресс проверки и отмена
  ///   (бросьте из него ошибку, чтобы прервать чтение).
  static func compute(
    _ kind: Kind, ofFileAt url: URL, onChunk: (Int64) throws -> Void = { _ in }
  ) throws -> String {
    let handle: FileHandle
    do {
      handle = try FileHandle(forReadingFrom: url)
    } catch {
      throw ModelDownloadError.file(error, path: url.lastPathComponent)
    }
    defer { try? handle.close() }

    var sha256 = SHA256()
    var sha1 = Insecure.SHA1()
    if case .gitBlobSHA1 = kind {
      let size = (try? handle.seekToEnd()) ?? 0
      do { try handle.seek(toOffset: 0) } catch {
        throw ModelDownloadError.file(error, path: url.lastPathComponent)
      }
      sha1.update(data: Data("blob \(size)\u{0}".utf8))
    }

    while true {
      let chunk: Data?
      do {
        chunk = try handle.read(upToCount: chunkBytes)
      } catch {
        throw ModelDownloadError.file(error, path: url.lastPathComponent)
      }
      guard let chunk, !chunk.isEmpty else { break }
      switch kind {
      case .sha256: sha256.update(data: chunk)
      case .gitBlobSHA1: sha1.update(data: chunk)
      }
      try onChunk(Int64(chunk.count))
    }
    switch kind {
    case .sha256: return hex(sha256.finalize())
    case .gitBlobSHA1: return hex(sha1.finalize())
    }
  }

  /// Какую сумму знает листинг: у файлов LFS — sha256, у остальных — git-oid; `nil` — проверять нечем.
  static func kind(for file: ModelFile) -> (kind: Kind, expected: String)? {
    if let sha256 = file.sha256, !sha256.isEmpty { return (.sha256, sha256.lowercased()) }
    if let sha1 = file.blobSHA1, !sha1.isEmpty { return (.gitBlobSHA1, sha1.lowercased()) }
    return nil
  }

  static func hex(_ digest: some Sequence<UInt8>) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
  }
}
