import Foundation

enum TranscriptionLanguageSupport {
    static func languages(for model: any TranscriptionModel, realtimeEnabled: Bool? = nil) -> [String: String] {
        model.supportedLanguages
    }

    static func validLanguageOrFallback(
        _ language: String?, for model: any TranscriptionModel, realtimeEnabled: Bool? = nil
    ) -> String {
        let languages = languages(for: model, realtimeEnabled: realtimeEnabled)

        if let language, languages[language] != nil {
            return language
        }

        if languages["auto"] != nil {
            return "auto"
        }

        if languages["en-US"] != nil {
            return "en-US"
        }

        if languages["en"] != nil {
            return "en"
        }

        return languages.keys.sorted { lhs, rhs in
            languages[lhs, default: lhs] < languages[rhs, default: rhs]
        }.first ?? "en"
    }

}

struct TranscriptionLanguageOption: Identifiable, Equatable {
    let code: String
    let name: String

    var id: String { code }
}

enum TranscriptionLanguageCatalog {
    private static let recentLanguagesKey = "RecentTranscriptionLanguages"
    private static let maximumRecentLanguageCount = 5

    /// A compact, stable list for quick-pick menus. The complete model-specific
    /// list remains available separately.
    private static let popularLanguageCodes = [
        "auto",
        "uk", "en", "ru", "es", "fr", "de", "it", "pt", "pl",
        "nl", "cs", "ro", "tr", "ar", "he", "fa", "hi", "bn",
        "zh", "yue", "ja", "ko", "id", "ms", "vi", "th", "el",
        "sv", "no", "da", "fi",
    ]

    private static let preferredRegionalCodes: [String: [String]] = [
        "uk": ["uk-UA"],
        "en": ["en-US", "en-GB"],
        "ru": ["ru-RU"],
        "es": ["es-ES", "es-MX", "es-US"],
        "fr": ["fr-FR", "fr-CA"],
        "de": ["de-DE", "de-AT", "de-CH"],
        "it": ["it-IT"],
        "pt": ["pt-BR", "pt-PT"],
        "zh": ["zh-CN", "zh-TW", "zh-HK"],
        "yue": ["yue-CN"],
        "ja": ["ja-JP"],
        "ko": ["ko-KR"],
        "no": ["nb-NO", "nn-NO"],
    ]

    static func allOptions(from languages: [String: String], locale: Locale = .current)
        -> [TranscriptionLanguageOption]
    {
        languages.map { code, fallbackName in
            TranscriptionLanguageOption(
                code: code,
                name: localizedName(for: code, fallback: fallbackName, locale: locale)
            )
        }
        .sorted(by: optionSort)
    }

    static func popularOptions(from languages: [String: String], locale: Locale = .current)
        -> [TranscriptionLanguageOption]
    {
        var usedCodes = Set<String>()
        return popularLanguageCodes.compactMap { baseCode in
            guard let code = bestAvailableCode(for: baseCode, in: languages),
                usedCodes.insert(code).inserted,
                let fallbackName = languages[code]
            else {
                return nil
            }
            return TranscriptionLanguageOption(
                code: code,
                name: localizedName(for: code, fallback: fallbackName, locale: locale)
            )
        }
    }

    static func remainingOptions(from languages: [String: String], locale: Locale = .current)
        -> [TranscriptionLanguageOption]
    {
        let popularCodes = Set(popularOptions(from: languages, locale: locale).map(\.code))
        return allOptions(from: languages, locale: locale).filter { !popularCodes.contains($0.code) }
    }

    static func recentOptions(from languages: [String: String], locale: Locale = .current)
        -> [TranscriptionLanguageOption]
    {
        recentLanguageCodes.compactMap { code in
            guard let fallbackName = languages[code] else { return nil }
            return TranscriptionLanguageOption(
                code: code,
                name: localizedName(for: code, fallback: fallbackName, locale: locale)
            )
        }
    }

    static func recordSelection(_ code: String) {
        var codes = recentLanguageCodes.filter { $0 != code }
        codes.insert(code, at: 0)
        UserDefaults.standard.set(
            Array(codes.prefix(maximumRecentLanguageCount)),
            forKey: recentLanguagesKey
        )
    }

    static func localizedName(
        for code: String,
        fallback: String,
        locale: Locale = .current
    ) -> String {
        guard code != "auto" else { return String(localized: "Auto-detect") }

        let canonicalCode = code.replacingOccurrences(of: "_", with: "-")
        return locale.localizedString(forIdentifier: canonicalCode)
            ?? locale.localizedString(forLanguageCode: canonicalCode.split(separator: "-").first.map(String.init) ?? canonicalCode)
            ?? fallback
    }

    private static var recentLanguageCodes: [String] {
        UserDefaults.standard.stringArray(forKey: recentLanguagesKey) ?? []
    }

    private static func bestAvailableCode(for baseCode: String, in languages: [String: String]) -> String? {
        if languages[baseCode] != nil { return baseCode }

        if let preferredCode = preferredRegionalCodes[baseCode]?.first(where: { languages[$0] != nil }) {
            return preferredCode
        }

        return languages.keys.sorted().first {
            $0.lowercased().hasPrefix(baseCode.lowercased() + "-")
        }
    }

    private static func optionSort(
        _ lhs: TranscriptionLanguageOption,
        _ rhs: TranscriptionLanguageOption
    ) -> Bool {
        if lhs.code == "auto" { return true }
        if rhs.code == "auto" { return false }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

enum LanguageDictionary {
    private static let whisperLanguageCodes: Set<String> = [
        "auto",
        "af", "am", "ar", "as", "az", "ba", "be", "bg", "bn", "bo",
        "br", "bs", "ca", "cs", "cy", "da", "de", "el", "en", "es",
        "et", "eu", "fa", "fi", "fo", "fr", "gl", "gu", "ha", "haw",
        "he", "hi", "hr", "ht", "hu", "hy", "id", "is", "it", "ja",
        "jw", "ka", "kk", "km", "kn", "ko", "la", "lb", "ln", "lo",
        "lt", "lv", "mg", "mi", "mk", "ml", "mn", "mr", "ms", "mt",
        "my", "ne", "nl", "nn", "no", "oc", "pa", "pl", "ps", "pt",
        "ro", "ru", "sa", "sd", "si", "sk", "sl", "sn", "so", "sq",
        "sr", "su", "sv", "sw", "ta", "te", "tg", "th", "tk", "tl",
        "tr", "tt", "uk", "ur", "uz", "vi", "yi", "yo", "yue", "zh",
    ]

    static func forProvider(isMultilingual: Bool, provider: ModelProvider = .whisper) -> [String: String] {
        if !isMultilingual {
            return ["en": "English"]
        }

        if let cloudProvider = CloudProviderRegistry.provider(for: provider) {
            guard let codes = cloudProvider.languageCodes else {
                return all
            }
            return forCodes(codes, includesAutoDetect: cloudProvider.includesAutoDetect)
        }

        switch provider {
        case .whisper:
            return languages(matching: whisperLanguageCodes)

        case .nativeApple:
            return appleNative

        case .fluidAudio:
            let codes = [
                "bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr",
                "hr", "hu", "it", "lt", "lv", "mt", "nl", "pl", "pt", "ro",
                "ru", "sk", "sl", "sv", "uk",
            ]
            var filtered = all.filter { codes.contains($0.key) }
            filtered["auto"] = "Auto-detect"
            return filtered

        default:
            return all
        }
    }

    static func forCodes(_ codes: [String], includesAutoDetect: Bool = false) -> [String: String] {
        var filtered = all.filter { codes.contains($0.key) }
        if includesAutoDetect { filtered["auto"] = "Auto-detect" }
        return filtered
    }

    static let nemotronLatin: [String: String] = [
        "auto": "Auto-detect",
        "de-DE": "German",
        "en-US": "English",
        "es-US": "Spanish",
        "fr-FR": "French",
        "it-IT": "Italian",
        "pt-BR": "Portuguese",
    ]

    static let nemotronMultilingual: [String: String] = [
        "auto": "Auto-detect",
        "ar-AR": "Arabic",
        "bg-BG": "Bulgarian",
        "cs-CZ": "Czech",
        "da-DK": "Danish",
        "de-DE": "German",
        "en-US": "English",
        "es-US": "Spanish",
        "et-EE": "Estonian",
        "fi-FI": "Finnish",
        "fr-FR": "French",
        "hi-IN": "Hindi",
        "hr-HR": "Croatian",
        "hu-HU": "Hungarian",
        "it-IT": "Italian",
        "ja-JP": "Japanese",
        "ko-KR": "Korean",
        "nb-NO": "Norwegian Bokmal",
        "nl-NL": "Dutch",
        "pl-PL": "Polish",
        "pt-BR": "Portuguese",
        "ro-RO": "Romanian",
        "ru-RU": "Russian",
        "sk-SK": "Slovak",
        "sv-SE": "Swedish",
        "tr-TR": "Turkish",
        "uk-UA": "Ukrainian",
        "vi-VN": "Vietnamese",
        "zh-CN": "Mandarin Chinese",
    ]

    private static func languages(matching codes: Set<String>) -> [String: String] {
        all.filter { codes.contains($0.key) }
    }

    // Apple Native Speech languages in BCP-47 format.
    // Queried from SpeechTranscriber.supportedLocales on macOS 26.4.
    static let appleNative: [String: String] = [
        "de-DE": "German (Germany)",
        "de-AT": "German (Austria)",
        "de-CH": "German (Switzerland)",
        "en-AU": "English (Australia)",
        "en-CA": "English (Canada)",
        "en-GB": "English (United Kingdom)",
        "en-IE": "English (Ireland)",
        "en-IN": "English (India)",
        "en-NZ": "English (New Zealand)",
        "en-SG": "English (Singapore)",
        "en-US": "English (United States)",
        "en-ZA": "English (South Africa)",
        "es-CL": "Spanish (Chile)",
        "es-ES": "Spanish (Spain)",
        "es-MX": "Spanish (Mexico)",
        "es-US": "Spanish (United States)",
        "fr-BE": "French (Belgium)",
        "fr-CA": "French (Canada)",
        "fr-CH": "French (Switzerland)",
        "fr-FR": "French (France)",
        "it-CH": "Italian (Switzerland)",
        "it-IT": "Italian (Italy)",
        "ja-JP": "Japanese (Japan)",
        "ko-KR": "Korean (South Korea)",
        "pt-BR": "Portuguese (Brazil)",
        "pt-PT": "Portuguese (Portugal)",
        "yue-CN": "Cantonese (China mainland)",
        "zh-CN": "Chinese (China mainland)",
        "zh-HK": "Chinese (Hong Kong)",
        "zh-TW": "Chinese (Taiwan)",
    ]

    static let all: [String: String] = [
        "auto": "Auto-detect",
        "af": "Afrikaans",
        "am": "Amharic",
        "ar": "Arabic",
        "as": "Assamese",
        "az": "Azerbaijani",
        "ba": "Bashkir",
        "be": "Belarusian",
        "bg": "Bulgarian",
        "bn": "Bengali",
        "bo": "Tibetan",
        "br": "Breton",
        "bs": "Bosnian",
        "ca": "Catalan",
        "cs": "Czech",
        "cy": "Welsh",
        "da": "Danish",
        "de": "German",
        "de_ch": "Swiss German",
        "el": "Greek",
        "en": "English",
        "en-AU": "English (Australia)",
        "en-GB": "English (United Kingdom)",
        "en-IN": "English (India)",
        "en-NZ": "English (New Zealand)",
        "en-US": "English (United States)",
        "en_au": "Australian English",
        "en_uk": "British English",
        "en_us": "US English",
        "es": "Spanish",
        "et": "Estonian",
        "eu": "Basque",
        "fa": "Persian",
        "fi": "Finnish",
        "fil": "Filipino",
        "fo": "Faroese",
        "fr": "French",
        "ga": "Irish",
        "gl": "Galician",
        "gu": "Gujarati",
        "ha": "Hausa",
        "haw": "Hawaiian",
        "he": "Hebrew",
        "hi": "Hindi",
        "hr": "Croatian",
        "ht": "Haitian Creole",
        "hu": "Hungarian",
        "hy": "Armenian",
        "id": "Indonesian",
        "ig": "Igbo",
        "is": "Icelandic",
        "it": "Italian",
        "ja": "Japanese",
        "jw": "Javanese",
        "ka": "Georgian",
        "kk": "Kazakh",
        "km": "Khmer",
        "kn": "Kannada",
        "ko": "Korean",
        "ku": "Kurdish",
        "ky": "Kyrgyz",
        "la": "Latin",
        "lb": "Luxembourgish",
        "ln": "Lingala",
        "lo": "Lao",
        "lt": "Lithuanian",
        "lv": "Latvian",
        "mg": "Malagasy",
        "mi": "Maori",
        "mk": "Macedonian",
        "ml": "Malayalam",
        "mn": "Mongolian",
        "mr": "Marathi",
        "ms": "Malay",
        "mt": "Maltese",
        "my": "Myanmar",
        "ne": "Nepali",
        "nl": "Dutch",
        "nn": "Norwegian Nynorsk",
        "no": "Norwegian",
        "oc": "Occitan",
        "or": "Odia",
        "pa": "Punjabi",
        "pl": "Polish",
        "ps": "Pashto",
        "pt": "Portuguese",
        "ro": "Romanian",
        "ru": "Russian",
        "sa": "Sanskrit",
        "sd": "Sindhi",
        "si": "Sinhala",
        "sk": "Slovak",
        "sl": "Slovenian",
        "sn": "Shona",
        "so": "Somali",
        "sq": "Albanian",
        "sr": "Serbian",
        "su": "Sundanese",
        "sv": "Swedish",
        "sw": "Swahili",
        "ta": "Tamil",
        "te": "Telugu",
        "tg": "Tajik",
        "th": "Thai",
        "tk": "Turkmen",
        "tl": "Tagalog",
        "tr": "Turkish",
        "tt": "Tatar",
        "uk": "Ukrainian",
        "ur": "Urdu",
        "uz": "Uzbek",
        "vi": "Vietnamese",
        "wo": "Wolof",
        "xh": "Xhosa",
        "yi": "Yiddish",
        "yo": "Yoruba",
        "yue": "Cantonese",
        "zh": "Chinese",
        "zu": "Zulu",
    ]
}
