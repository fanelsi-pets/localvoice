#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Merge the MeetingScribe core string catalog into LocalVoice's Localizable.xcstrings.

The core (MeetingScribeKit) looks its strings up in Bundle.main, so its keys (Russian source text with
uk/en translations) must live in this app's catalog. Keys already present in LocalVoice are left untouched;
imported keys are marked extractionState=manual so Xcode never prunes them. Re-run after updating the core.

Usage: scripts/merge-meetingscribe-strings.py [--kit PATH] [--catalog PATH]
"""
import argparse
import json
from collections import OrderedDict
from pathlib import Path

NATIVE_KEYS = {
    "Meetings": "Зустрічі",
    "Meetings…": "Зустрічі…",
    "Open Meetings": "Відкрити зустрічі",
    "Import Recording…": "Імпортувати запис…",
    "Cancel Processing": "Скасувати обробку",
    "Recent Meetings": "Останні зустрічі",
    "No meetings yet. Import a Zoom recording to get a transcript with speakers.":
        "Зустрічей ще немає. Імпортуйте запис Zoom, щоб отримати транскрипт зі спікерами.",
    "Drop a Zoom recording or its folder here": "Перетягніть сюди запис Zoom або папку запису",
    "Meeting Settings": "Налаштування зустрічей",
    "Meetings are transcribed on this Mac: speakers, timecodes, project memory and export. The full workspace opens in its own window.":
        "Зустрічі транскрибуються на цьому Mac: спікери, таймкоди, пам'ять проєкту й експорт. Повний робочий простір відкривається в окремому вікні.",
    "Models are not set up yet — open Meetings to download them and run the self-test.":
        "Моделі ще не налаштовано — відкрийте «Зустрічі», щоб завантажити їх і пройти самоперевірку.",
    "Ready: models are downloaded. Processing keeps running in the background even with the window closed.":
        "Готово: моделі завантажено. Обробка триває у фоні навіть із закритим вікном.",
}


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f, object_pairs_hook=OrderedDict)


def save(path, data):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2, separators=(",", " : "))
        f.write("\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--kit", default="../Транскрибация/App/MeetingScribe/Localizable.xcstrings")
    parser.add_argument("--catalog", default="LocalVoice/Localizable.xcstrings")
    args = parser.parse_args()

    kit = load(Path(args.kit))
    catalog = load(Path(args.catalog))
    strings = catalog["strings"]
    added, skipped = 0, 0
    new_keys = set()

    for key, entry in kit["strings"].items():
        if key in strings:
            skipped += 1
            continue
        localizations = entry.get("localizations", {})
        merged = OrderedDict()
        for lang in ("en", "uk"):
            if lang in localizations:
                merged[lang] = localizations[lang]
        if "en" not in merged:
            # Source-language value is the key itself in the core; without an English unit the
            # Russian key would be shown to English users.
            merged["en"] = {"stringUnit": {"state": "translated", "value": key}}
        new_entry = OrderedDict()
        new_entry["extractionState"] = "manual"
        if entry.get("shouldTranslate") is False:
            new_entry["shouldTranslate"] = False
        new_entry["localizations"] = merged
        strings[key] = new_entry
        new_keys.add(key)
        added += 1

    for key, uk in NATIVE_KEYS.items():
        if key in strings:
            continue
        strings[key] = OrderedDict([
            ("localizations", OrderedDict([("uk", {"stringUnit": {"state": "translated", "value": uk}})])),
        ])
        new_keys.add(key)
        added += 1

    # Existing keys keep their order (Xcode preserves insertion order); new keys go to the end, sorted.
    existing = [k for k in strings if k not in new_keys]
    catalog["strings"] = OrderedDict(
        [(k, strings[k]) for k in existing] + [(k, strings[k]) for k in sorted(new_keys)])
    save(Path(args.catalog), catalog)
    print(f"added {added}, kept {skipped} existing keys, total {len(strings)}")


if __name__ == "__main__":
    main()
