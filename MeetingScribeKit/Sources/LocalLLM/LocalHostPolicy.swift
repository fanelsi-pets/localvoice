import Darwin
import Foundation

/// Приватность как проверяемое свойство (SPEC.md §2, docs/DESIGN.md §1: «нет ни одного сетевого запроса кроме
/// скачивания моделей»): транскрипт уходит только на машину пользователя или в его локальную сеть.
///
/// Проверка синтаксическая и не делает DNS-запросов: имя резолвить нельзя — это уже обращение в сеть, а результат
/// резолва можно подменить. Локальными считаются:
/// - loopback: `localhost`, зона `.localhost` (RFC 6761), `127.0.0.0/8`, `::1`;
/// - имена Bonjour в зоне `.local` (RFC 6762);
/// - частные сети IPv4: `10/8`, `172.16/12`, `192.168/16`, `169.254/16` (link-local);
/// - частные сети IPv6: `fc00::/7` (ULA) и `fe80::/10` (link-local), а также IPv4-mapped адреса этих диапазонов.
///
/// Схема — только `http` или `https`. Чужая схема и адрес без хоста — это `invalidURL` (пользователю подсказывают
/// правильный вид адреса), внешний хост — `notLocalHost`.
public enum LocalHostPolicy {
  /// Бросает, если адрес нельзя использовать: вызывается до любого сетевого обращения.
  public static func validate(_ url: URL) throws(LocalLLMError) {
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
      let host = url.host(percentEncoded: false), !host.isEmpty
    else {
      throw .invalidURL(url.absoluteString)
    }
    guard isLocal(host: host) else { throw .notLocalHost(host) }
  }

  /// `true`, если по адресу можно обращаться: локальный хост и допустимая схема.
  public static func isLocal(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
      let host = url.host(percentEncoded: false), !host.isEmpty
    else {
      return false
    }
    return isLocal(host: host)
  }

  /// Проверка одного имени или IP-литерала (без схемы и скобок IPv6).
  static func isLocal(host rawHost: String) -> Bool {
    var host = rawHost.lowercased()
    if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
    // Корневая точка FQDN («mac.local.») и зона IPv6 («fe80::1%en0») к принадлежности сети не относятся.
    while host.hasSuffix("."), host.count > 1 { host.removeLast() }
    if let percent = host.firstIndex(of: "%") { host = String(host[host.startIndex..<percent]) }
    guard !host.isEmpty else { return false }

    if host == "localhost" || host.hasSuffix(".localhost") { return true }
    if host.hasSuffix(".local") { return true }
    if let address = ipv4(host) { return isPrivate(ipv4: address) }
    if let address = ipv6(host) { return isPrivate(ipv6: address) }
    return false
  }

  // MARK: - Разбор литералов

  private static func ipv4(_ host: String) -> [UInt8]? {
    var address = in_addr()
    guard inet_pton(AF_INET, host, &address) == 1 else { return nil }
    // s_addr лежит в сетевом порядке байт — берём представление в памяти как есть.
    return withUnsafeBytes(of: address.s_addr) { Array($0) }
  }

  private static func ipv6(_ host: String) -> [UInt8]? {
    var address = in6_addr()
    guard inet_pton(AF_INET6, host, &address) == 1 else { return nil }
    return withUnsafeBytes(of: address) { Array($0) }
  }

  private static func isPrivate(ipv4 bytes: [UInt8]) -> Bool {
    guard bytes.count == 4 else { return false }
    switch (bytes[0], bytes[1]) {
    case (127, _): return true  // loopback 127.0.0.0/8
    case (10, _): return true  // частная 10.0.0.0/8
    case (172, let second) where (second & 0xF0) == 16: return true  // 172.16.0.0/12
    case (192, 168): return true  // 192.168.0.0/16
    case (169, 254): return true  // link-local 169.254.0.0/16
    default: return false
    }
  }

  private static func isPrivate(ipv6 bytes: [UInt8]) -> Bool {
    guard bytes.count == 16 else { return false }
    if bytes[0..<15].allSatisfy({ $0 == 0 }), bytes[15] == 1 { return true }  // ::1
    if (bytes[0] & 0xFE) == 0xFC { return true }  // ULA fc00::/7
    if bytes[0] == 0xFE, (bytes[1] & 0xC0) == 0x80 { return true }  // link-local fe80::/10
    // IPv4-mapped ::ffff:a.b.c.d — тот же адрес, что и IPv4, судим по нему.
    if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
      return isPrivate(ipv4: Array(bytes[12..<16]))
    }
    return false
  }
}
