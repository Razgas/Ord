import AVFoundation

// Reads text aloud with Google's voices (much more natural Danish than the built-in one);
// falls back to the system voice when offline.
final class Speaker {
    static let shared = Speaker()
    private var player: AVAudioPlayer?
    private let synth = AVSpeechSynthesizer()
    private var task: Task<Void, Never>?

    // Only words, phrases and single sentences are read aloud, never paragraphs.
    static func shortEnough(_ text: String) -> Bool {
        let t = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if t.split(separator: " ").count > 30 { return false }
        return t.range(of: #"[.!?]["')»”]?\s+[A-ZÆØÅ]"#, options: .regularExpression) == nil
    }

    func speak(_ raw: String, _ lang: Language) {
        stop()
        let text = String(Markdown.plain(raw).split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(190))
        guard !text.isEmpty else { return }
        task = Task { @MainActor in
            var c = URLComponents(string: "https://translate.google.com/translate_tts")!
            c.queryItems = [.init(name: "ie", value: "UTF-8"), .init(name: "client", value: "gtx"),
                            .init(name: "tl", value: lang.code), .init(name: "q", value: text)]
            var req = URLRequest(url: c.url!)
            req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 8
            do {
                let (data, _) = try await URLSession.shared.data(for: req)
                guard !Task.isCancelled else { return }
                player = try AVAudioPlayer(data: data)
                player?.play()
            } catch {
                guard !Task.isCancelled else { return }
                let u = AVSpeechUtterance(string: text)
                u.voice = AVSpeechSynthesisVoice(language: lang.locale)
                synth.speak(u)
            }
        }
    }

    func stop() {
        task?.cancel(); task = nil
        player?.stop(); player = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }
}
