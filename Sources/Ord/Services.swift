import Foundation
import CoreServices

// Everything Ord can ask. The AI gives the main explanation; the others are shown as short rows under it.
enum Service: String, CaseIterable, Identifiable {
    case ai = "gemini"  // the AI chosen in Settings; the old name keeps the setting
    case google, bing, deepl, wiktionary, dictionary

    var id: String { rawValue }

    var name: String {
        switch self {
        case .ai: return Provider.current.name
        case .google: return "Google"
        case .bing: return "Bing"
        case .deepl: return "DeepL"
        case .wiktionary: return "Wiktionary"
        case .dictionary: return "Dictionary"
        }
    }

    var detail: String {
        switch self {
        case .ai: return "Explanations, memory tricks and corrections"
        case .google: return "Google Translate"
        case .bing: return "Microsoft Bing Translator"
        case .deepl: return "Needs a free DeepL API key"
        case .wiktionary: return "Meanings of single words"
        case .dictionary: return "The macOS Dictionary app, for single words"
        }
    }

    var prefKey: String { "service.\(rawValue)" }
    var defaultOn: Bool { self != .deepl && self != .dictionary }
    var isOn: Bool { UserDefaults.standard.object(forKey: prefKey) as? Bool ?? defaultOn }
    var isDictionary: Bool { self == .wiktionary || self == .dictionary }

    static var enabled: [Service] { allCases.filter(\.isOn) }
}

enum ServiceResult: Equatable {
    case text(String, more: [Sense] = [])  // `more`: other meanings of a single word, by word type
    case senses([Sense])
    case failed(String)
}

struct Sense: Equatable {
    var partOfSpeech: String
    var definitions: [String]
}

struct ServiceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Translators

struct Translation {
    var text: String
    var source: Language
    var more: [Sense] = []
}

typealias Call = (text: String, detected: String, more: [Sense])

enum Translators {
    // Every translator detects the language itself: text in the language being learned goes into the user's
    // language, anything else into the language being learned.
    // With `from` (the AI's reading of the input) there is no guessing: one call in the right direction.
    static func translate(_ service: Service, _ text: String, from: Language? = nil) async throws -> Translation {
        let call: (Language, Language?) async throws -> Call
        switch service {
        case .google: call = { try await Google.call(text, to: $0, from: $1) }
        case .bing: call = { try await Bing.call(text, to: $0, from: $1) }
        case .deepl: call = { try await DeepL.call(text, to: $0, from: $1) }
        default: throw ServiceError(message: "not a translator")
        }
        let result: Call, source: Language
        if let from {
            (result, source) = (try await call(from.other, from), from)
        } else {
            let learning = Language.learning, native = Language.native
            let first = try await call(learning, nil)
            if learning.matches(first.detected) { source = learning }
            else if native.matches(first.detected) { source = native }
            else { source = Language.guess(text) }  // e.g. "Norwegian" for a short Danish word: decide between our two
            result = source == learning ? try await call(native, nil) : first
        }
        var more = result.more
        if service == .bing, more.isEmpty, isWord(text) {
            more = (try? await Bing.lookup(text, from: source, to: source.other)) ?? []
        }
        return Translation(text: result.text, source: source, more: tidy(more, without: result.text))
    }

    static func isWord(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && t.split(whereSeparator: \.isWhitespace).count <= 2 && t.count <= 30
    }

    // At most three word types with four meanings each, leaving out the main translation and repeats.
    private static func tidy(_ senses: [Sense], without main: String) -> [Sense] {
        func key(_ w: String) -> String { w.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines)) }
        var seen: Set<String> = [key(main)]
        return senses.compactMap { sense -> Sense? in
            let words = sense.definitions.filter { seen.insert(key($0)).inserted }.prefix(4)
            return words.isEmpty ? nil : Sense(partOfSpeech: sense.partOfSpeech, definitions: Array(words))
        }.prefix(3).map { $0 }
    }
}

// Google Translate's free web endpoint.
enum Google {
    static func call(_ text: String, to target: Language, from: Language?) async throws -> Call {
        // dt=bd adds Google's dictionary: the other meanings of a single word, grouped by word type.
        var req = URLRequest(url: URL(string: "https://translate.googleapis.com/translate_a/single?client=gtx&sl=\(from?.code ?? "auto")&dt=t&dt=bd&tl=\(target.code)")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded;charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = FormData.encode(["q": text])
        req.timeoutInterval = 10
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [Any]
        let parts = (json?.first as? [Any])?.compactMap { ($0 as? [Any])?.first as? String } ?? []
        let dictionary = (json?.count ?? 0) > 1 ? (json?[1] as? [[Any]] ?? []) : []
        let more = dictionary.compactMap { entry -> Sense? in
            guard entry.count > 1, let pos = entry[0] as? String, let words = entry[1] as? [String] else { return nil }
            return Sense(partOfSpeech: pos, definitions: words)
        }
        return (parts.joined(), (json?.count ?? 0) > 2 ? (json?[2] as? String ?? "") : "", more)
    }
}

// Bing Translator's web page API. It needs the session values the translator page hands out (valid for an hour).
enum Bing {
    private struct Session { var ig, iid, key, token: String; var expires: Date }
    private static var session: Session?
    private static let agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"

    static func call(_ text: String, to target: Language, from: Language?) async throws -> Call {
        do { return try await request(text, target, from, try await currentSession()) }
        catch { session = nil; return try await request(text, target, from, try await currentSession()) }  // stale session: once more
    }

    // Bing's dictionary: other meanings of a word with their word type. It only knows pairs with English.
    static func lookup(_ word: String, from: Language, to target: Language) async throws -> [Sense] {
        let s = try await currentSession()
        let data = try await post("tlookupv3", ["from": code(from), "to": code(target), "text": word, "token": s.token, "key": s.key], s)
        guard let first = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]])?.first,
              let list = first["translations"] as? [[String: Any]] else { return [] }
        var senses: [Sense] = []
        for t in list {
            // Skip the weak tail and the occasional garbled entry ("kÃ¸re").
            guard let word = t["displayTarget"] as? String, (t["confidence"] as? Double ?? 0) >= 0.05, !word.contains("Ã") else { continue }
            let pos = partOfSpeech(t["posTag"] as? String ?? "")
            if let i = senses.firstIndex(where: { $0.partOfSpeech == pos }) { senses[i].definitions.append(word) }
            else { senses.append(Sense(partOfSpeech: pos, definitions: [word])) }
        }
        return senses
    }

    private static func partOfSpeech(_ tag: String) -> String {
        switch tag {
        case "ADJ": return "adjective"
        case "ADV": return "adverb"
        case "NOUN": return "noun"
        case "VERB": return "verb"
        case "PREP": return "preposition"
        case "CONJ": return "conjunction"
        case "PRON": return "pronoun"
        case "DET": return "determiner"
        default: return "other"
        }
    }

    private static func post(_ path: String, _ fields: [String: String], _ s: Session) async throws -> Data {
        var req = URLRequest(url: URL(string: "https://www.bing.com/\(path)?isVertical=1&IG=\(s.ig)&IID=\(s.iid)")!)
        req.httpMethod = "POST"
        req.setValue(agent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.bing.com/translator", forHTTPHeaderField: "Referer")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = FormData.encode(fields)
        req.timeoutInterval = 6
        return try await URLSession.shared.data(for: req).0
    }

    private static func request(_ text: String, _ target: Language, _ from: Language?, _ s: Session) async throws -> Call {
        let data = try await post("ttranslatev3", ["fromLang": from.map(code) ?? "auto-detect", "to": code(target), "text": text, "token": s.token, "key": s.key], s)
        guard let first = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]])?.first,
              let out = ((first["translations"] as? [[String: Any]])?.first)?["text"] as? String else {
            throw ServiceError(message: "Bing didn't answer")
        }
        return (out, (first["detectedLanguage"] as? [String: Any])?["language"] as? String ?? "", [])
    }

    private static func currentSession() async throws -> Session {
        if let s = session, s.expires > Date() { return s }
        var req = URLRequest(url: URL(string: "https://www.bing.com/translator")!)
        req.setValue(agent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        let (data, _) = try await URLSession.shared.data(for: req)
        let html = String(decoding: data, as: UTF8.self)
        func find(_ pattern: String) -> String? {
            guard let r = html.range(of: pattern, options: .regularExpression) else { return nil }
            let m = String(html[r])
            guard let q = m.range(of: #""[^"]*"$"#, options: .regularExpression) ?? m.range(of: #"\d+$"#, options: .regularExpression) else { return nil }
            return m[q].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        guard let ig = find(#"IG:"[A-F0-9]+""#),
              let iid = find(#"data-iid="translator\.\d+""#),
              let key = find(#"params_AbusePreventionHelper = \[\d+"#),
              let token = find(#"params_AbusePreventionHelper = \[\d+,"[^"]+""#) else {
            throw ServiceError(message: "Bing didn't answer")
        }
        let s = Session(ig: ig, iid: iid, key: key, token: token, expires: Date().addingTimeInterval(50 * 60))
        session = s
        return s
    }

    private static func code(_ l: Language) -> String {
        switch l.code {
        case "no": return "nb"
        case "iw": return "he"
        case "zh-CN": return "zh-Hans"
        case "zh-TW": return "zh-Hant"
        case "tl": return "fil"
        case "sr": return "sr-Cyrl"
        case "pt": return "pt-pt"
        default: return l.code
        }
    }
}

// DeepL's official API (free plan keys end in ":fx").
enum DeepL {
    static let keyPref = "deeplKey"

    static func call(_ text: String, to target: Language, from: Language?) async throws -> Call {
        let key = (UserDefaults.standard.string(forKey: keyPref) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ServiceError(message: "Add a DeepL API key in Settings") }
        let host = key.hasSuffix(":fx") ? "api-free.deepl.com" : "api.deepl.com"
        var req = URLRequest(url: URL(string: "https://\(host)/v2/translate")!)
        req.httpMethod = "POST"
        req.setValue("DeepL-Auth-Key \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var fields = ["text": text, "target_lang": code(target)]
        if let from { fields["source_lang"] = String(code(from).prefix(2)) }  // source takes no variant: EN, PT, ZH
        req.httpBody = FormData.encode(fields)
        req.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: break
        case 400: throw ServiceError(message: "DeepL doesn't translate \(target.name)")
        case 403: throw ServiceError(message: "DeepL didn't accept the API key")
        case 456: throw ServiceError(message: "DeepL's monthly limit is used up")
        default: throw ServiceError(message: "DeepL error \(status)")
        }
        let t = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["translations"] as? [[String: Any]])?.first
        return (t?["text"] as? String ?? "", (t?["detected_source_language"] as? String ?? "").lowercased(), [])
    }

    private static func code(_ l: Language) -> String {
        switch l.code {
        case "en": return "EN-US"
        case "pt": return "PT-PT"
        case "no": return "NB"
        case "zh-CN": return "ZH-HANS"
        case "zh-TW": return "ZH-HANT"
        default: return l.code.uppercased()
        }
    }
}

// MARK: - Dictionaries (single words in the language being learned)

enum Wiktionary {
    static func lookup(_ word: String) async throws -> [Sense] {
        let code = wiktCode(Language.learning)
        for w in Set([word, word.lowercased()]).sorted(by: >) {
            guard let path = w.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { continue }
            var req = URLRequest(url: URL(string: "https://en.wiktionary.org/api/rest_v1/page/definition/\(path)")!)
            req.setValue("Ord/0.1 (macOS dictionary app)", forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 6
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entries = json[code] as? [[String: Any]] else { continue }
            let senses = entries.prefix(3).compactMap { e -> Sense? in
                let defs = (e["definitions"] as? [[String: Any]] ?? [])
                    .compactMap { ($0["definition"] as? String).map(clean) }
                    .filter { !$0.isEmpty }
                    .prefix(3)
                return defs.isEmpty ? nil : Sense(partOfSpeech: (e["partOfSpeech"] as? String ?? "").lowercased(), definitions: Array(defs))
            }
            if !senses.isEmpty { return senses }
        }
        throw ServiceError(message: "No entry")
    }

    // Definitions come as HTML; keep the text only.
    private static func clean(_ html: String) -> String {
        var s = html.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (e, c) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&nbsp;": " "] {
            s = s.replacingOccurrences(of: e, with: c)
        }
        return s.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    private static func wiktCode(_ l: Language) -> String {
        switch l.code {
        case "iw": return "he"
        case "no": return "nb"
        case "zh-CN", "zh-TW": return "zh"
        default: return l.code
        }
    }
}

enum AppleDictionary {
    static func lookup(_ word: String) throws -> String {
        let range = CFRange(location: 0, length: (word as NSString).length)
        guard let def = DCSCopyTextDefinition(nil, word as CFString, range)?.takeRetainedValue() as String?, !def.isEmpty else {
            throw ServiceError(message: "No entry")
        }
        let flat = def.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > 320 ? String(flat.prefix(320)) + "…" : flat
    }
}

enum FormData {
    static func encode(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)!
    }
}
