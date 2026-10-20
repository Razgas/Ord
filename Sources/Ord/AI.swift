import Foundation

// The AI that writes the explanation: Gemini, ChatGPT or Claude, each with the user's own key.
// All three get the same instructions (Prompt.swift) and stream their answer back piece by piece.
enum Provider: String, CaseIterable, Identifiable {
    case gemini, openai, claude

    var id: String { rawValue }
    static let pref = "aiProvider"
    static var current: Provider { Provider(rawValue: UserDefaults.standard.string(forKey: pref) ?? "") ?? .gemini }

    var name: String {
        switch self {
        case .gemini: return "Gemini"
        case .openai: return "ChatGPT"
        case .claude: return "Claude"
        }
    }

    var keyPref: String { self == .gemini ? Pref.geminiKey : "\(rawValue)Key" }
    var modelPref: String { self == .gemini ? Pref.geminiModel : "\(rawValue)Model" }

    var defaultModel: String {
        switch self {
        case .gemini: return Pref.defaultModel
        case .openai: return "gpt-5.4-mini"
        case .claude: return "claude-opus-5-5"
        }
    }

    var key: String { UserDefaults.standard.string(forKey: keyPref)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    var model: String {
        let m = UserDefaults.standard.string(forKey: modelPref)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return m.isEmpty ? defaultModel : m
    }

    var keyPage: URL {
        switch self {
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")!
        case .openai: return URL(string: "https://platform.openai.com/api-keys")!
        case .claude: return URL(string: "https://platform.claude.com/settings/keys")!
        }
    }

    var keyHint: String {
        switch self {
        case .gemini: return "A Gemini API key is free at Google AI Studio."
        case .openai: return "Uses an OpenAI API key, paid per use. A ChatGPT subscription doesn't include API access."
        case .claude: return "Uses an Anthropic API key, paid per use. A Claude subscription doesn't include API access."
        }
    }
}

enum AIError: LocalizedError {
    case noKey, refused, http(Int, String)
    var errorDescription: String? {
        let ai = Provider.current.name
        switch self {
        case .noKey: return "Add your \(ai) API key in Settings."
        case .refused: return "\(ai) declined to answer this one."
        case .http(429, _): return "\(ai) is busy right now (rate limit). Try again in a minute."
        case .http(401, _), .http(403, _): return "\(ai) didn't accept the API key. Check it in Settings."
        case .http(400, let m) where m.localizedCaseInsensitiveContains("key"):
            return "\(ai) didn't accept the API key. Check it in Settings."
        case .http(404, _): return "\(ai) doesn't know the model “\(Provider.current.model)”. Check it in Settings."
        case .http(503, _), .http(529, _): return "\(ai) is overloaded right now. Try again in a moment."
        case .http(let c, let m): return "\(ai) error \(c): \(m)"
        }
    }
}

enum AI {
    struct Model: Hashable { var id, name: String }

    // The text models this key may use, newest first, so the list in Settings is always current.
    static func models(_ provider: Provider, key: String) async throws -> [Model] {
        var req: URLRequest
        switch provider {
        case .gemini:
            req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000")!)
            req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        case .openai:
            req = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .claude:
            req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=100")!)
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        req.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (response as? HTTPURLResponse)?.statusCode == 200, let json else {
            throw AIError.http((response as? HTTPURLResponse)?.statusCode ?? 0, "")
        }
        switch provider {
        case .gemini: return geminiModels(json["models"] as? [[String: Any]] ?? [])
        case .openai:
            // Chat models only: no speech, image, embedding or search models.
            let skip = ["audio", "realtime", "tts", "transcribe", "image", "search", "embedding", "moderation", "instruct", "dall-e", "whisper"]
            let ids = (json["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
                .filter { ($0.hasPrefix("gpt-") || $0.range(of: #"^o\d"#, options: .regularExpression) != nil) && !skip.contains(where: $0.contains) }
            return ids.sorted(by: >).map { Model(id: $0, name: $0) }
        case .claude:
            // Anthropic lists the newest first.
            return (json["data"] as? [[String: Any]] ?? []).compactMap { m in
                guard let id = m["id"] as? String else { return nil }
                return Model(id: id, name: m["display_name"] as? String ?? id)
            }
        }
    }

    private static func geminiModels(_ list: [[String: Any]]) -> [Model] {
        // Image, speech, music, agent and research models are left out.
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
    // `language`: the user chose the input language by hand; the AI must not decide it again.
    static func stream(_ text: String, language: Language? = nil) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    let provider = Provider.current
                    guard !provider.key.isEmpty else { throw AIError.noKey }
                    let (req, piece) = try request(provider, system: Prompts.current(forcing: language), text: text)
                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if status != 200 {
                        var data = Data()
                        for try await b in bytes { data.append(b) }
                        // All three answer {"error": {"message": …}}.
                        let err = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
                        throw AIError.http(status, err?["message"] as? String ?? "")
                    }
                    for try await line in bytes.lines where line.hasPrefix("data:") {
                        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any] else { continue }
                        if let t = try piece(obj) { cont.yield(t) }
                    }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    // A cap so a model stuck repeating itself stops on its own; real answers are far shorter.
    private static let maxOutput = 2048

    // The request for one lookup, and how to take the text out of each streamed event.
    private static func request(_ p: Provider, system: String, text: String) throws -> (URLRequest, ([String: Any]) throws -> String?) {
        let model = p.model
        var req: URLRequest
        var body: [String: Any]
        let piece: ([String: Any]) throws -> String?
        switch p {
        case .gemini:
            let path = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
            req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(path):streamGenerateContent?alt=sse")!)
            req.setValue(p.key, forHTTPHeaderField: "x-goog-api-key")
            body = [
                "systemInstruction": ["parts": [["text": system]]],
                "contents": [["role": "user", "parts": [["text": text]]]],
                "generationConfig": ["maxOutputTokens": maxOutput],
            ]
            piece = { obj in
                guard let cand = (obj["candidates"] as? [[String: Any]])?.first,
                      let parts = (cand["content"] as? [String: Any])?["parts"] as? [[String: Any]] else { return nil }
                let t = parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
                return t.isEmpty ? nil : t
            }

        case .openai:
            req = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
            req.setValue("Bearer \(p.key)", forHTTPHeaderField: "Authorization")
            body = ["model": model, "instructions": system, "input": text, "stream": true, "max_output_tokens": maxOutput * 4]
            // Reasoning models think before answering; a dictionary entry needs little of it.
            if model.hasPrefix("gpt-5") || model.range(of: #"^o\d"#, options: .regularExpression) != nil {
                body["reasoning"] = ["effort": "low"]
            }
            piece = { obj in
                switch obj["type"] as? String {
                case "response.output_text.delta": return obj["delta"] as? String
                case "response.failed", "error":
                    let err = (obj["response"] as? [String: Any])?["error"] as? [String: Any] ?? obj
                    throw AIError.http(0, err["message"] as? String ?? "the answer failed")
                default: return nil
                }
            }

        case .claude:
            req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            req.setValue(p.key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            // Thinking tokens count towards max_tokens on the current models, so leave room for them.
            body = ["model": model, "max_tokens": maxOutput * 4, "system": system, "stream": true,
                    "messages": [["role": "user", "content": text]]]
            // Current models think adaptively; low effort keeps a dictionary lookup quick.
            if model.range(of: #"^claude-(opus|sonnet|haiku|fable|mythos)-(5|4-[678])"#, options: .regularExpression) != nil {
                body["output_config"] = ["effort": "low"]
            }
            // If a safety check declines on these models, the API answers with a fallback model instead.
            if ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"].contains(model) {
                req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
                body["fallbacks"] = "default"
            }
            piece = { obj in
                switch obj["type"] as? String {
                case "content_block_delta":
                    let d = obj["delta"] as? [String: Any]
                    return d?["type"] as? String == "text_delta" ? d?["text"] as? String : nil
                case "message_delta":
                    if (obj["delta"] as? [String: Any])?["stop_reason"] as? String == "refusal" { throw AIError.refused }
                    return nil
                case "error":
                    let err = obj["error"] as? [String: Any]
                    throw AIError.http(err?["type"] as? String == "overloaded_error" ? 529 : 0, err?["message"] as? String ?? "")
                default: return nil
                }
            }
        }
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return (req, piece)
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
