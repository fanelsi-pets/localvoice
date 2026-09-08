import Core
import Foundation

// Голосовые профили (SPEC.md §3.4): центроид эмбеддингов человека с накопительным средним, сопоставление
// спикеров встречи с людьми по cosine с двумя порогами, обновление после подтверждения.

/// Пороги сопоставления (SPEC.md §3.4): ≥ `autoAssign` — имя присваивается автоматически,
/// `suggest`…`autoAssign` — предложение с подтверждением, ниже — «Неизвестный N». Калибруются в Settings.
public struct VoiceThresholds: Hashable, Codable, Sendable {
  public var autoAssign: Double
  public var suggest: Double

  public init(autoAssign: Double = 0.70, suggest: Double = 0.55) {
    self.autoAssign = max(autoAssign, suggest)
    self.suggest = min(autoAssign, suggest)
  }

  public static let standard = VoiceThresholds()
}

/// Профиль голоса человека: центроид как накопительное среднее по подтверждённым образцам.
/// `space` — пространство эмбеддингов (движок и модель диаризатора, `Transcript.embeddingSpace`):
/// векторы разных движков не сравниваются.
public struct VoiceProfile: Hashable, Codable, Sendable {
  public var centroid: [Float]
  public var space: String
  /// Сколько образцов (спикеров разных встреч) вошло в центроид.
  public var sampleCount: Int
  /// Суммарная речь образцов, с.
  public var speechSeconds: Double

  public init(centroid: [Float], space: String, sampleCount: Int = 1, speechSeconds: Double = 0) {
    self.centroid = centroid
    self.space = space
    self.sampleCount = max(sampleCount, 0)
    self.speechSeconds = max(speechSeconds, 0)
  }

  /// Накопительное среднее: новый образец входит с весом 1 / (n + 1) — старые подтверждения не затираются.
  public func adding(_ vector: [Float], speechSeconds seconds: Double = 0) -> VoiceProfile {
    guard vector.count == centroid.count, !vector.isEmpty else { return self }
    let count = Double(sampleCount)
    let updated = zip(centroid, vector).map { old, new in
      Float((Double(old) * count + Double(new)) / (count + 1))
    }
    return VoiceProfile(
      centroid: updated, space: space, sampleCount: sampleCount + 1,
      speechSeconds: speechSeconds + max(seconds, 0))
  }

  public func similarity(to vector: [Float]) -> Double? {
    VoiceMath.cosineSimilarity(centroid, vector)
  }
}

public enum VoiceMath {
  /// Косинусное сходство в диапазоне [-1, 1]; `nil` — разные размерности, пустой или нулевой вектор.
  public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double? {
    guard a.count == b.count, !a.isEmpty else { return nil }
    var dot = 0.0
    var normA = 0.0
    var normB = 0.0
    for (x, y) in zip(a, b) {
      dot += Double(x) * Double(y)
      normA += Double(x) * Double(x)
      normB += Double(y) * Double(y)
    }
    guard normA > 0, normB > 0 else { return nil }
    return min(max(dot / (normA.squareRoot() * normB.squareRoot()), -1), 1)
  }

  /// Взвешенное среднее векторов (веса — секунды речи): объединение двух спикеров в одного.
  public static func weightedMean(_ vectors: [(vector: [Float], weight: Double)]) -> [Float]? {
    let usable = vectors.filter { !$0.vector.isEmpty }
    guard let first = usable.first else { return nil }
    let dimension = first.vector.count
    guard usable.allSatisfy({ $0.vector.count == dimension }) else { return nil }
    let total = usable.reduce(0) { $0 + max($1.weight, 0) }
    var sum = [Double](repeating: 0, count: dimension)
    for entry in usable {
      let weight = total > 0 ? max(entry.weight, 0) / total : 1 / Double(usable.count)
      for index in 0..<dimension { sum[index] += Double(entry.vector[index]) * weight }
    }
    return sum.map(Float.init)
  }
}

/// Кандидат для сопоставления: человек с профилем.
public struct VoiceCandidate: Hashable, Sendable {
  public var personID: UUID
  public var name: String
  public var profile: VoiceProfile

  public init(personID: UUID, name: String, profile: VoiceProfile) {
    self.personID = personID
    self.name = name
    self.profile = profile
  }
}

/// Итог сопоставления одного спикера.
public struct VoiceMatch: Hashable, Sendable {
  public enum Level: Hashable, Sendable {
    /// ≥ порога автоприсвоения — имя ставится сразу (зелёный `checkmark.seal`).
    case assigned
    /// Между порогами — предложение с подтверждением (жёлтый `questionmark.circle`).
    case suggested
    /// Ниже порога предложения — «Неизвестный N».
    case unknown
  }

  public var speakerID: Int
  public var personID: UUID?
  public var name: String?
  public var similarity: Double?
  /// Сходство со вторым кандидатом — запас решения.
  public var runnerUpSimilarity: Double?
  public var level: Level

  public init(
    speakerID: Int, personID: UUID? = nil, name: String? = nil, similarity: Double? = nil,
    runnerUpSimilarity: Double? = nil, level: Level
  ) {
    self.speakerID = speakerID
    self.personID = personID
    self.name = name
    self.similarity = similarity
    self.runnerUpSimilarity = runnerUpSimilarity
    self.level = level
  }
}

/// Сопоставление спикеров встречи с людьми (SPEC.md §3.4): для каждого спикера — ближайший профиль того же
/// пространства по cosine; один человек не присваивается двум спикерам (жадно по убыванию сходства,
/// проигравший спикер получает следующего кандидата или остаётся неизвестным).
public enum VoiceMatcher {
  public static func match(
    embeddings: [SpeakerEmbedding],
    space: String?,
    candidates: [VoiceCandidate],
    thresholds: VoiceThresholds = .standard
  ) -> [VoiceMatch] {
    let usable = candidates.filter { space == nil || $0.profile.space == space }
    guard !usable.isEmpty, !embeddings.isEmpty else {
      return embeddings.map { VoiceMatch(speakerID: $0.speakerID, level: .unknown) }
    }
    // Все пары (спикер, человек) по убыванию сходства; каждый спикер и каждый человек — не больше раза.
    var pairs: [(speaker: Int, candidate: VoiceCandidate, similarity: Double)] = []
    for embedding in embeddings {
      for candidate in usable {
        guard let similarity = candidate.profile.similarity(to: embedding.vector) else { continue }
        pairs.append((embedding.speakerID, candidate, similarity))
      }
    }
    pairs.sort {
      $0.similarity == $1.similarity
        ? ($0.speaker, $0.candidate.name) < ($1.speaker, $1.candidate.name)
        : $0.similarity > $1.similarity
    }
    var bySpeaker: [Int: VoiceMatch] = [:]
    var takenPeople: Set<UUID> = []
    for pair in pairs where pair.similarity >= thresholds.suggest {
      guard bySpeaker[pair.speaker] == nil, !takenPeople.contains(pair.candidate.personID) else {
        continue
      }
      let runnerUp = pairs.first {
        $0.speaker == pair.speaker && $0.candidate.personID != pair.candidate.personID
      }?.similarity
      bySpeaker[pair.speaker] = VoiceMatch(
        speakerID: pair.speaker, personID: pair.candidate.personID, name: pair.candidate.name,
        similarity: pair.similarity, runnerUpSimilarity: runnerUp,
        level: pair.similarity >= thresholds.autoAssign ? .assigned : .suggested)
      takenPeople.insert(pair.candidate.personID)
    }
    return embeddings.map { embedding in
      if let match = bySpeaker[embedding.speakerID] { return match }
      let best = pairs.first { $0.speaker == embedding.speakerID }
      return VoiceMatch(
        speakerID: embedding.speakerID, personID: nil, name: nil, similarity: best?.similarity,
        runnerUpSimilarity: nil, level: .unknown)
    }
  }
}

/// Отбор речи для отпечатка голоса (SPEC.md §3.4). Эмбеддинг снимается не со всей дорожки, а с нескольких
/// длинных кусков речи спикера: так центроид не смещается фоном, обрывками и чужими репликами.
public enum VoiceSampling {
  /// Речь спикера для отпечатка: тот же отбор, что у `LanguageRouter.probes` (длинные turn'ы первыми,
  /// куски из середины turn'а), но окно длиннее — до `targetSeconds` всего и до `perTurnCap` с одного turn'а.
  /// Возвращает склеенное аудио (его длительность — `PCMAudio.duration`); `nil` — речи спикера нет.
  public static func probeAudio(
    for speakerID: Int,
    turns: [Turn],
    audio: PCMAudio,
    targetSeconds: Double = 60,
    perTurnCap: Double = 12
  ) -> PCMAudio? {
    let speakerTurns = turns.filter { $0.speakerID == speakerID && $0.duration > 0 }
    guard !speakerTurns.isEmpty, !audio.isEmpty else { return nil }
    // Порог длины turn'а ниже, чем при определении языка: отпечаток нужен и тому, кто сказал пару фраз.
    let options = LanguageRouter.Options(
      probeTargetSeconds: targetSeconds,
      probeTurnCapSeconds: perTurnCap,
      probeMinimumTurnSeconds: 0.5,
      minimumSpeechSeconds: 0.5)
    guard
      let probe = LanguageRouter.probes(
        for: DiarizationResult(turns: speakerTurns), options: options
      ).first(where: { $0.speakerID == speakerID })
    else { return nil }
    let sampled = probe.audio(from: audio)
    return sampled.isEmpty ? nil : sampled
  }
}
