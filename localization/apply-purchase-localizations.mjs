import fs from "node:fs";

const file = new URL("../LocalVoice/Localizable.xcstrings", import.meta.url);
const catalog = JSON.parse(fs.readFileSync(file, "utf8"));

const translations = {
  "The App Store could not verify this purchase.": ["App Store не вдалося перевірити цю покупку.", "App Store не удалось проверить эту покупку."],
  "The lifetime purchase is temporarily unavailable.": ["Довічна покупка тимчасово недоступна.", "Пожизненная покупка временно недоступна."],
  "No previous lifetime purchase was found for this Apple Account.": ["Для цього Apple Account не знайдено попередньої довічної покупки.", "Для этого Apple Account не найдена предыдущая пожизненная покупка."],
  "Close": ["Закрити", "Закрыть"],
  "Keep speaking. Keep LocalVoice forever.": ["Продовжуйте говорити. Залиште LocalVoice назавжди.", "Продолжайте говорить. Оставьте LocalVoice навсегда."],
  "You still have %lld trial days. Unlock lifetime access now for %@.": ["У вас залишилося %lld днів пробного періоду. Відкрийте довічний доступ зараз за %@.", "У вас осталось %lld дней пробного периода. Откройте пожизненный доступ сейчас за %@."],
  "Lifetime access is active on this Apple Account.": ["Для цього Apple Account активовано довічний доступ.", "Для этого Apple Account активирован пожизненный доступ."],
  "Your 7-day trial has ended. Pay %@ once and keep every feature forever.": ["Ваш 7-денний пробний період завершився. Сплатіть %@ один раз і залиште всі функції назавжди.", "Ваш 7-дневный пробный период завершился. Заплатите %@ один раз и оставьте все функции навсегда."],
  "7 days free. Then one lifetime purchase. No subscription.": ["7 днів безкоштовно. Потім одна довічна покупка. Без підписки.", "7 дней бесплатно. Затем одна пожизненная покупка. Без подписки."],
  "Voice typing in any app": ["Голосове введення в будь-якій програмі", "Голосовой ввод в любом приложении"],
  "Local models and privacy controls": ["Локальні моделі та контроль приватності", "Локальные модели и контроль приватности"],
  "History, cleanup, and text improvement": ["Історія, очищення та покращення тексту", "История, очистка и улучшение текста"],
  "One purchase. No subscription.": ["Одна покупка. Без підписки.", "Одна покупка. Без подписки."],
  "Buy Once for %@": ["Купити назавжди за %@", "Купить навсегда за %@"],
  "Restore Purchase": ["Відновити покупку", "Восстановить покупку"],
  "Payment is charged only when you confirm the purchase with Apple. The 7-day trial does not renew or charge automatically.": ["Оплата стягується лише після підтвердження покупки в Apple. 7-денний пробний період не поновлюється й не списує кошти автоматично.", "Оплата списывается только после подтверждения покупки в Apple. 7-дневный пробный период не продлевается и не списывает деньги автоматически."],
  "Lifetime access": ["Довічний доступ", "Пожизненный доступ"],
  "7-day free trial": ["7-денний безкоштовний пробний період", "7-дневный бесплатный пробный период"],
  "Trial ended": ["Пробний період завершився", "Пробный период завершился"],
  "Checking purchase…": ["Перевіряємо покупку…", "Проверяем покупку…"],
  "LocalVoice is yours forever.": ["LocalVoice назавжди ваш.", "LocalVoice навсегда ваш."],
  "This direct-download edition includes full access.": ["Ця версія з прямим завантаженням містить повний доступ.", "Эта версия с прямой загрузкой включает полный доступ."],
  "%lld days remaining. Then %@ once — no subscription.": ["Залишилося %lld днів. Потім %@ один раз — без підписки.", "Осталось %lld дней. Затем %@ один раз — без подписки."],
  "Unlock forever for %@ — no subscription.": ["Відкрийте назавжди за %@ — без підписки.", "Откройте навсегда за %@ — без подписки."],
  "Connecting securely to the App Store.": ["Безпечно підключаємося до App Store.", "Безопасно подключаемся к App Store."],
  "Buy Once": ["Купити назавжди", "Купить навсегда"],
  "Unlock": ["Відкрити", "Открыть"],
  "Access": ["Доступ", "Доступ"],
  "Free trial": ["Безкоштовний пробний період", "Бесплатный пробный период"],
  "Unlock LocalVoice": ["Відкрити LocalVoice", "Открыть LocalVoice"],
  "%lld days left · %@ once": ["Залишилося %lld днів · %@ один раз", "Осталось %lld дней · %@ один раз"],
  "%@ once · yours forever": ["%@ один раз · назавжди ваше", "%@ один раз · навсегда ваше"],
  "Yours forever": ["Назавжди ваше", "Навсегда ваше"],
  "App Store": ["App Store", "App Store"],
  "7 days free. Then $4.99 once — yours forever. No subscription.": ["7 днів безкоштовно. Потім $4.99 один раз — назавжди. Без підписки.", "7 дней бесплатно. Затем $4.99 один раз — навсегда. Без подписки."]
};

for (const [key, [uk, ru]] of Object.entries(translations)) {
  const entry = catalog.strings[key] ?? {};
  entry.localizations ??= {};
  entry.localizations.uk = { stringUnit: { state: "translated", value: uk } };
  entry.localizations.ru = { stringUnit: { state: "translated", value: ru } };
  delete entry.extractionState;
  catalog.strings[key] = entry;
}

fs.writeFileSync(file, `${JSON.stringify(catalog, null, 2)}\n`);
