// Локальная языковая модель через OpenAI-совместимый endpoint (фаза 4, SPEC.md §3.6):
// LM Studio (http://localhost:1234/v1) и Ollama (http://localhost:11434/v1). По умолчанию выключено,
// адрес и модель задаёт пользователь. Модуль ничего не знает про транскрипты — он передаёт готовый промпт
// и отдаёт текст ответа; сборка промпта и разбор блока meeting-followup живут в Store/Export.
import Foundation

public enum LocalLLMInfo {
  public static let version = "0.5.0-phase4"
}
