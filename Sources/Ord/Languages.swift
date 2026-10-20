import Foundation
import NaturalLanguage

// A language Ord can translate. `code` is what Google Translate uses; `locale` is for speech and text recognition.
struct Language: Hashable, Identifiable {
    let code: String
    let name: String
    let locale: String
    var id: String { code }
    var short: String { code.split(separator: "-").first.map { $0.uppercased() } ?? code.uppercased() }

    static let all: [Language] = [
        .init(code: "ar", name: "Arabic", locale: "ar-SA"),
        .init(code: "bn", name: "Bengali", locale: "bn-IN"),
        .init(code: "bg", name: "Bulgarian", locale: "bg-BG"),
        .init(code: "zh-CN", name: "Chinese (Simplified)", locale: "zh-CN"),
        .init(code: "zh-TW", name: "Chinese (Traditional)", locale: "zh-TW"),
        .init(code: "hr", name: "Croatian", locale: "hr-HR"),
        .init(code: "cs", name: "Czech", locale: "cs-CZ"),
        .init(code: "da", name: "Danish", locale: "da-DK"),
        .init(code: "nl", name: "Dutch", locale: "nl-NL"),
        .init(code: "en", name: "English", locale: "en-US"),
        .init(code: "et", name: "Estonian", locale: "et-EE"),
        .init(code: "tl", name: "Filipino", locale: "fil-PH"),
        .init(code: "fi", name: "Finnish", locale: "fi-FI"),
        .init(code: "fr", name: "French", locale: "fr-FR"),
        .init(code: "de", name: "German", locale: "de-DE"),
        .init(code: "el", name: "Greek", locale: "el-GR"),
        .init(code: "iw", name: "Hebrew", locale: "he-IL"),
        .init(code: "hi", name: "Hindi", locale: "hi-IN"),
        .init(code: "hu", name: "Hungarian", locale: "hu-HU"),
        .init(code: "is", name: "Icelandic", locale: "is-IS"),
        .init(code: "id", name: "Indonesian", locale: "id-ID"),
        .init(code: "it", name: "Italian", locale: "it-IT"),
        .init(code: "ja", name: "Japanese", locale: "ja-JP"),
        .init(code: "ko", name: "Korean", locale: "ko-KR"),
        .init(code: "lv", name: "Latvian", locale: "lv-LV"),
        .init(code: "lt", name: "Lithuanian", locale: "lt-LT"),
        .init(code: "ms", name: "Malay", locale: "ms-MY"),
        .init(code: "no", name: "Norwegian", locale: "nb-NO"),
        .init(code: "fa", name: "Persian", locale: "fa-IR"),
        .init(code: "pl", name: "Polish", locale: "pl-PL"),
        .init(code: "pt", name: "Portuguese", locale: "pt-PT"),
        .init(code: "ro", name: "Romanian", locale: "ro-RO"),
        .init(code: "ru", name: "Russian", locale: "ru-RU"),
        .init(code: "sr", name: "Serbian", locale: "sr-RS"),
        .init(code: "sk", name: "Slovak", locale: "sk-SK"),
        .init(code: "sl", name: "Slovenian", locale: "sl-SI"),
        .init(code: "es", name: "Spanish", locale: "es-ES"),
        .init(code: "sw", name: "Swahili", locale: "sw-KE"),
        .init(code: "sv", name: "Swedish", locale: "sv-SE"),
        .init(code: "th", name: "Thai", locale: "th-TH"),
        .init(code: "tr", name: "Turkish", locale: "tr-TR"),
        .init(code: "uk", name: "Ukrainian", locale: "uk-UA"),
        .init(code: "ur", name: "Urdu", locale: "ur-PK"),
        .init(code: "vi", name: "Vietnamese", locale: "vi-VN"),
    ]

    static func find(_ code: String?) -> Language? {
        guard let code else { return nil }
        return all.first { $0.code == code } ?? all.first { $0.matches(code) }
    }

    // Google reports Hebrew as "iw" or "he", Norwegian as "no", "nb" or "nn", Chinese as "zh-CN" or "zh".
    func matches(_ google: String) -> Bool {
        let a = Self.base(code), b = Self.base(google)
        return a == b || (code.hasPrefix("zh") && google.hasPrefix("zh"))
    }

    private static func base(_ c: String) -> String {
        let b = c.lowercased().split(separator: "-").first.map(String.init) ?? c.lowercased()
        switch b {
        case "he": return "iw"
        case "nb", "nn": return "no"
        case "fil": return "tl"
        default: return b
        }
    }

    var nl: NLLanguage {
        switch code {
        case "no": return .norwegian
        case "iw": return .hebrew
        case "zh-CN": return .simplifiedChinese
        case "zh-TW": return .traditionalChinese
        case "tl": return NLLanguage("tl")
        default: return NLLanguage(code)
        }
    }

    static var learning: Language { find(UserDefaults.standard.string(forKey: Pref.learning)) ?? find("da")! }
    static var native: Language { find(UserDefaults.standard.string(forKey: Pref.native)) ?? find("en")! }

    // Which of the two languages is this text in? No bias towards either.
    static func guess(_ text: String) -> Language {
        let r = NLLanguageRecognizer()
        r.languageConstraints = [learning.nl, native.nl]
        r.processString(text)
        return r.dominantLanguage == native.nl ? native : learning
    }

    // The language a text in this language gets translated into.
    var other: Language { self == Language.learning ? Language.native : Language.learning }
}
