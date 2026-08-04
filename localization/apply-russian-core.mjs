import fs from "node:fs/promises";

const catalogPath = new URL("../LocalVoice/Localizable.xcstrings", import.meta.url);
const corePath = new URL("./core-translations.json", import.meta.url);

const catalog = JSON.parse(await fs.readFile(catalogPath, "utf8"));
const core = JSON.parse(await fs.readFile(corePath, "utf8")).ru ?? {};

const marketingScreens = {
  "AI Models": "AI-модели",
  "Accuracy": "Точность",
  "Audio": "Аудио",
  "Audio is processed according to the selected local or cloud model.":
    "Аудио обрабатывается выбранной локальной или облачной моделью.",
  "Base model, good balance between speed and accuracy, supports multiple languages":
    "Базовая модель с хорошим балансом скорости и точности, поддерживает несколько языков",
  "Cloud": "Облако",
  "Dashboard": "Обзор",
  "Dictate a short phrase to make sure everything works.":
    "Продиктуйте короткую фразу, чтобы убедиться, что всё работает.",
  "Dictionary": "Словарь",
  "Dictionary Settings": "Настройки словаря",
  "Done": "Готово",
  "Download": "Загрузить",
  "Filler Words": "Слова-паразиты",
  "History": "История",
  "Import Local Model…": "Импортировать локальную модель…",
  "Large model v2, slower than Medium but more accurate":
    "Большая модель v2, медленнее Medium, но точнее",
  "Large model v3 Turbo, faster than v3 with similar accuracy":
    "Большая модель v3 Turbo, быстрее v3 при сопоставимой точности",
  "Large model v3, very slow but most accurate":
    "Большая модель v3, очень медленная, но максимально точная",
  "Local": "Локально",
  "Model": "Модель",
  "Model Catalog": "Каталог моделей",
  "More accurate multilingual Whisper model; downloaded on demand":
    "Более точная многоязычная модель Whisper; загружается по запросу",
  "Multilingual": "Многоязычная",
  "Original text (use commas for multiple)":
    "Исходный текст (несколько вариантов через запятую)",
  "Quantized version of Large v3 Turbo, faster with slightly lower accuracy":
    "Квантованная Large v3 Turbo: быстрее при немного меньшей точности",
  "Record": "Запись",
  "Replacement text": "Текст замены",
  "Select a compatible .bin file already stored on this Mac.":
    "Выберите совместимый файл .bin, уже сохранённый на этом Mac.",
  "Selected": "Выбрано",
  "Settings": "Настройки",
  "Start dictation": "Начать диктовку",
  "Test your dictation": "Проверьте диктовку",
  "Tiny model, fastest, least accurate":
    "Самая маленькая и быстрая модель с базовой точностью",
  "Transcribe": "Расшифровать",
  "Vocabulary": "Словарный запас",
  "Vocabulary is used only with AI enhancement to preserve important names, technical terms, and unique spellings in the final output.":
    "Словарный запас используется вместе с AI-улучшением, чтобы сохранять важные имена, технические термины и уникальное написание.",
  "Word Replacements": "Замены слов",
  "Word Replacements run after transcription to replace misheard words, phrases, abbreviations, or boilerplate text.":
    "Замены применяются после транскрипции и исправляют неверно распознанные слова, фразы, сокращения и шаблонный текст.",
};

const translations = { ...core, ...marketingScreens };
let applied = 0;

for (const [key, value] of Object.entries(translations)) {
  const entry = catalog.strings[key];
  if (!entry) continue;
  entry.localizations ??= {};
  entry.localizations.ru = {
    stringUnit: {
      state: "translated",
      value,
    },
  };
  applied += 1;
}

await fs.writeFile(catalogPath, `${JSON.stringify(catalog, null, 2)}\n`);
console.log(`Applied ${applied} Russian core localizations.`);
