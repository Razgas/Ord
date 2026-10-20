import Foundation

enum GeminiError: LocalizedError {
    case noKey, http(Int, String)
    var errorDescription: String? {
        switch self {
        case .noKey: return "Add your Gemini API key in Settings."
        case .http(429, _): return "Gemini is busy right now (rate limit). Try again in a minute."
        case .http(401, _), .http(403, _): return "Gemini didn't accept the API key. Check it in Settings."
        case .http(400, let m) where m.localizedCaseInsensitiveContains("key"):
            return "Gemini didn't accept the API key. Check it in Settings."
        case .http(404, _): return "Gemini doesn't know the model “\(Pref.model)”. Check it in Settings."
        case .http(503, _): return "Gemini is overloaded right now. Try again in a moment."
        case .http(let c, let m): return "Gemini error \(c): \(m)"
        }
    }
}

enum Gemini {
    struct Model: Hashable { var id, name: String }

    // The text models this key may use, newest first. Image, speech, music, agent and research models are left out.
    static func models(key: String) async throws -> [Model] {
        var req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000")!)
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let list = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["models"] as? [[String: Any]] else {
            throw GeminiError.http((response as? HTTPURLResponse)?.statusCode ?? 0, "")
        }
        let skip = ["tts", "image", "banana", "transcribe", "robotics", "computer-use", "customtools", "omni", "embedding", "aqa", "live", "audio"]
        let models = list.compactMap { m -> Model? in
            guard let name = m["name"] as? String, (m["supportedGenerationMethods"] as? [String])?.contains("generateContent") == true else { return nil }
            let id = name.replacingOccurrences(of: "models/", with: "")
            guard id.hasPrefix("gemini-"), !skip.contains(where: id.contains) else { return nil }
            return Model(id: id, name: m["displayName"] as? String ?? id)
        }
        // "gemini-3.5-flash-lite" → 3.5; the "-latest" aliases go last.
        func version(_ id: String) -> Double { Double(id.split(separator: "-").dropFirst().first ?? "") ?? 0 }
        return models.sorted { a, b in
            let (va, vb) = (version(a.id), version(b.id))
            if va != vb { return va > vb }
            if a.id.contains("preview") != b.id.contains("preview") { return !a.id.contains("preview") }
            return a.id < b.id
        }
    }

    // Streams the answer piece by piece so the first line appears quickly.
    // `language`: the user chose the input language by hand; Gemini must not decide it again.
    static func stream(_ text: String, language: Language? = nil) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    let key = Pref.key
                    guard !key.isEmpty else { throw GeminiError.noKey }
                    let model = Pref.model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? Pref.model
                    var req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?alt=sse")!)
                    req.httpMethod = "POST"
                    req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.timeoutInterval = 60
                    req.httpBody = try JSONSerialization.data(withJSONObject: [
                        "systemInstruction": ["parts": [["text": Prompts.current(forcing: language)]]],
                        "contents": [["role": "user", "parts": [["text": text]]]],
                        // A cap so a model stuck repeating itself stops on its own; real answers are far shorter.
                        "generationConfig": ["maxOutputTokens": 2048],
                    ])
                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if status != 200 {
                        var data = Data()
                        for try await b in bytes { data.append(b) }
                        let err = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
                        throw GeminiError.http(status, err?["message"] as? String ?? "")
                    }
                    for try await line in bytes.lines where line.hasPrefix("data:") {
                        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any],
                              let cand = (obj["candidates"] as? [[String: Any]])?.first,
                              let parts = (cand["content"] as? [String: Any])?["parts"] as? [[String: Any]] else { continue }
                        for p in parts where p["thought"] as? Bool != true {
                            if let t = p["text"] as? String { cont.yield(t) }
                        }
                    }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    // Small models sometimes get stuck writing the same thing over and over ("**at** **at** **at**…",
    // "hos hos hos…"). True when the same line comes three times or a word comes six times in a row.
    static func isLooping(_ answer: String) -> Bool {
        var seen: [String: Int] = [:]
        for line in answer.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard l.count > 1 else { continue }
            seen[l, default: 0] += 1
            if seen[l]! >= 3 { return true }
        }
        return answer.range(of: #"(?i)(\b\S+)(\s+\1\b){5,}"#, options: .regularExpression) != nil
    }
}

struct Entry: Codable, Identifiable, Equatable {
    var text: String
    var answer: String
    var google: String?
    var source: String?  // language code
    var pair: String?    // "learning-native" at the time; nil = da-en (older entries)
    var date = Date()
    var v: Int? = nil    // Prompts.version that wrote the answer; older answers are asked again
    var id: String { text }
    var headline: String { Markdown.headline(answer) ?? google ?? "" }
}

@MainActor
final class Session: ObservableObject {
    static let shared = Session()

    @Published var input = ""
    @Published private(set) var query = ""
    @Published private(set) var source: Language?
    @Published private(set) var answer = ""                        // Gemini's Markdown
    @Published private(set) var results: [Service: ServiceResult] = [:]
    @Published private(set) var loading: Set<Service> = []
    @Published private(set) var error: String?                    // Gemini's error
    @Published private(set) var extra: ServiceResult?             // Google's translation into the extra language
    @Published private(set) var history: [Entry] = []

    @Published var focusRequest = 0
    var busy: Bool { !loading.isEmpty }

    private var work: Task<Void, Never>?
    private var spoken = false
    private var aiSource: Language?          // Gemini's reading of the input language: the one that counts
    private var geminiDone = true
    private let historyKey = "history"

    init() {
        if let data = UserDefaults.standard.data(forKey: historyKey),
           let h = try? JSONDecoder().decode([Entry].self, from: data) {
            // Older answers may still hold a leftover language tag such as "****" from "**[[da]]**".
            history = h.map { var e = $0; e.answer = Prompts.splitTag(e.answer).answer; return e }
        }
    }

    func clear() {
        work?.cancel(); Speaker.shared.stop()
        input = ""; query = ""; answer = ""; results = [:]; loading = []; source = nil; error = nil; extra = nil
    }

    // `language`: the input language chosen by hand (the direction tag was clicked).
    func run(_ raw: String, as language: Language? = nil) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        work?.cancel(); Speaker.shared.stop()
        input = text; query = text; error = nil; results = [:]; source = language; spoken = false; aiSource = language; extra = nil

        var services = Service.enabled
        let singleWord = !text.contains(where: \.isWhitespace) && text.count <= 40
        if !singleWord { services.removeAll(where: \.isDictionary) }

        // Gemini's answer was saved before: show it at once; the quick services still run.
        let pair = Self.pair
        let old = history.first {
            $0.text == text && ($0.pair ?? "da-en") == pair && !$0.answer.isEmpty && $0.v == Prompts.version && (language == nil || $0.source == language?.code)
                && !Gemini.isLooping($0.answer)
        }
        if let old, services.contains(.gemini) {
            answer = old.answer
            services.removeAll { $0 == .gemini }
            aiSource = Language.find(old.source)
            source = aiSource
            speakInput()
            remember(old)
        } else {
            answer = ""
        }
        geminiDone = !services.contains(.gemini)
        if language != nil { speakInput() }
        loading = Set(services)

        work = Task {
            await withTaskGroup(of: Void.self) { group in
                for service in services {
                    group.addTask { await self.load(service, text) }
                }
                group.addTask { await self.loadExtra(text) }
            }
            guard !Task.isCancelled, query == text else { return }
            if source == nil { source = Language.guess(text); speakInput() }
            let fallback: String? = { if case .text(let t, _)? = results[.google] ?? results[.bing] { return t }; return nil }()
            if !answer.isEmpty || fallback != nil, old == nil || !services.isEmpty {
                remember(Entry(text: text, answer: Gemini.isLooping(answer) ? "" : answer, google: fallback, source: source?.code, pair: pair, v: Prompts.version))
            }
        }
    }

    private func load(_ service: Service, _ text: String) async {
        defer { if query == text { loading.remove(service) } }
        switch service {
        case .gemini:
            await loadGemini(text)
        case .google, .bing, .deepl:
            do {
                var t = try await Translators.translate(service, text, from: aiSource)
                guard !Task.isCancelled, query == text else { return }
                results[service] = .text(t.text, more: t.more)
                if aiSource == nil {
                    if source == nil { source = t.source }
                    if geminiDone { speakInput() }
                    // Gemini reads misspelled text better than the translators' detectors. Wait for its verdict
                    // and translate again if the direction was wrong.
                    while !geminiDone && aiSource == nil && query == text && !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                    if let ai = aiSource, ai != t.source, query == text {
                        results[service] = nil
                        t = try await Translators.translate(service, text, from: ai)
                        guard !Task.isCancelled, query == text else { return }
                        results[service] = .text(t.text, more: t.more)
                    }
                }
            } catch {
                guard !Task.isCancelled, query == text else { return }
                results[service] = .failed((error as? ServiceError)?.message ?? "Not available right now")
            }
        case .wiktionary:
            if let senses = try? await Wiktionary.lookup(text), query == text { results[service] = .senses(senses) }
        case .dictionary:
            if let def = try? AppleDictionary.lookup(text) { results[service] = .text(def) }
        }
    }

    private func loadGemini(_ text: String) async {
        var raw = ""
        defer {
            if query == text {
                geminiDone = true
                speakInput()  // if Gemini gave no language, fall back to the translators' guess
            }
        }
        do {
            // A looping answer is stopped as soon as it is seen and asked once more; the second try is almost always fine.
            for attempt in 1...2 {
                raw = ""
                var looped = false
                for try await piece in Gemini.stream(text, language: aiSource) {
                    guard !Task.isCancelled, query == text else { return }
                    raw += piece
                    let (lang, body, waiting) = Prompts.splitTag(raw)
                    if waiting { continue }
                    if aiSource == nil, let lang, let l = Language.find(lang), l == .learning || l == .native {
                        aiSource = l
                        source = l
                        speakInput()
                    }
                    if Gemini.isLooping(body) { looped = true; break }
                    answer = body
                }
                guard looped else { return }
                answer = ""
                if attempt == 2 { self.error = "Gemini got stuck repeating itself. Try again in a moment." }
            }
        } catch {
            guard !Task.isCancelled, query == text, !(error is CancellationError) else { return }
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // The extra language chosen under the result ("Translate into…"), if any.
    static var extraLanguage: Language? { Language.find(UserDefaults.standard.string(forKey: Pref.extra)) }

    func setExtra(_ language: Language?) {
        UserDefaults.standard.set(language?.code ?? "", forKey: Pref.extra)
        extra = nil
        guard !query.isEmpty else { return }
        let text = query
        Task { await loadExtra(text) }
    }

    // Google translates straight into the extra language; it detects the input language itself.
    private func loadExtra(_ text: String) async {
        guard let target = Self.extraLanguage else { return }
        do {
            let t = try await Google.call(text, to: target, from: nil)
            guard !Task.isCancelled, query == text, Self.extraLanguage == target else { return }
            extra = .text(t.text, more: t.more.prefix(3).map { $0 })
        } catch {
            guard !Task.isCancelled, query == text else { return }
            extra = .failed("Not available right now")
        }
    }

    // Look the same text up again, read as the other language.
    func switchDirection() {
        guard let source, !query.isEmpty else { return }
        run(query, as: source.other)
    }

    private func speakInput() {
        guard !spoken, aiSource != nil || geminiDone, UserDefaults.standard.bool(forKey: Pref.autoSpeak), let source, Speaker.shortEnough(query) else { return }
        spoken = true
        Speaker.shared.speak(query, source)
    }

    static var pair: String { "\(Language.learning.code)-\(Language.native.code)" }

    private func remember(_ e: Entry) {
        var e = e
        e.date = Date()
        history.removeAll { $0.text == e.text && $0.pair == e.pair }
        history.insert(e, at: 0)
        if history.count > 300 { history.removeLast(history.count - 300) }
        if let data = try? JSONEncoder().encode(history) { UserDefaults.standard.set(data, forKey: historyKey) }
    }

    func clearHistory() {
        history = []
        UserDefaults.standard.removeObject(forKey: historyKey)
    }
}
