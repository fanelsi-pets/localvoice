import fs from "node:fs/promises";

const catalogPath = new URL("../LocalVoice/Localizable.xcstrings", import.meta.url);
const catalog = JSON.parse(await fs.readFile(catalogPath, "utf8"));
const targets = ["ru", "uk"];
const cachePath = new URL("./translation-cache.json", import.meta.url);
let cache = {};
try { cache = JSON.parse(await fs.readFile(cachePath, "utf8")); } catch {}

const placeholders = /%(?:\d+\$)?(?:@|d|i|u|ld|lld|f|\.\d+f)|\\[nrt]|\{[^}]+\}|\$\{[^}]+\}/g;

function protect(text) {
  const values = [];
  return {
    text: text.replace(placeholders, value => {
      const token = `ZXQPH${values.length}QXZ`;
      values.push(value);
      return token;
    }),
    values,
  };
}

function restore(text, values) {
  let result = text;
  values.forEach((value, index) => {
    result = result.replaceAll(`ZXQPH${index}QXZ`, value)
      .replaceAll(`ZXQPH ${index} QXZ`, value);
  });
  return result;
}

function needsTranslation(text) {
  const stripped = text.replace(placeholders, "").replace(/[\d\s\p{P}\p{S}]/gu, "");
  return /[A-Za-z]/.test(stripped);
}

async function translate(text, language) {
  if (!needsTranslation(text)) return text;
  const cacheKey = `${language}\u0000${text}`;
  if (cache[cacheKey]) return cache[cacheKey];
  const protectedValue = protect(text);
  const url = new URL("https://translate.googleapis.com/translate_a/single");
  url.searchParams.set("client", "gtx");
  url.searchParams.set("sl", "en");
  url.searchParams.set("tl", language);
  url.searchParams.set("dt", "t");
  url.searchParams.set("q", protectedValue.text);
  for (let attempt = 0; attempt < 4; attempt++) {
    try {
      const response = await fetch(url);
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const payload = await response.json();
      const translated = restore(payload[0].map(part => part[0]).join(""), protectedValue.values);
      cache[cacheKey] = translated;
      return translated;
    } catch (error) {
      if (attempt === 3) throw error;
      await new Promise(resolve => setTimeout(resolve, 500 * (attempt + 1)));
    }
  }
}

function sourceUnits(key, entry) {
  const english = entry.localizations?.en;
  if (english?.stringUnit?.value) return [{ path: [], value: english.stringUnit.value }];
  const plural = english?.variations?.plural;
  if (plural) {
    return Object.entries(plural).map(([form, value]) => ({
      path: ["variations", "plural", form],
      value: value.stringUnit.value,
    }));
  }
  return [{ path: [], value: key }];
}

function makeLocalization(units, translations) {
  if (units.length === 1 && units[0].path.length === 0) {
    return { stringUnit: { state: "translated", value: translations[0] } };
  }
  const plural = {};
  units.forEach((unit, index) => {
    plural[unit.path[2]] = { stringUnit: { state: "translated", value: translations[index] } };
  });
  return { variations: { plural } };
}

const jobs = [];
for (const [key, entry] of Object.entries(catalog.strings)) {
  entry.localizations ??= {};
  for (const language of targets) {
    if (entry.localizations[language]) continue;
    jobs.push({ key, entry, language, units: sourceUnits(key, entry) });
  }
}

let cursor = 0;
async function worker() {
  while (cursor < jobs.length) {
    const job = jobs[cursor++];
    const translated = [];
    for (const unit of job.units) translated.push(await translate(unit.value, job.language));
    job.entry.localizations[job.language] = makeLocalization(job.units, translated);
    if (cursor % 50 === 0) {
      process.stdout.write(`\r${cursor}/${jobs.length}`);
      await fs.writeFile(cachePath, JSON.stringify(cache));
    }
  }
}

await Promise.all(Array.from({ length: 10 }, worker));
await fs.writeFile(cachePath, JSON.stringify(cache, null, 2) + "\n");
await fs.writeFile(catalogPath, JSON.stringify(catalog, null, 2) + "\n");
console.log(`\nLocalized ${jobs.length} entries.`);
