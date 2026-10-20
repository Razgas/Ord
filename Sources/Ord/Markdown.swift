import Foundation

// Gemini answers in a few fixed Markdown layouts (see Prompt.swift). This turns them into blocks
// that AnswerView draws natively, instead of showing raw Markdown.
enum Block: Equatable {
    case correction(String)                  // ✏️ Correct: … — reason
    case headline(String)                    // the translation
    case subtitle(String)                    // a second meaning, in italics
    case meaning(Int, String)                // numbered meanings of an ambiguous word
    case field(icon: String, label: String, text: String)  // 🧩 Parts / 🔤 Base form / 💡 Remember
    case section(String)                     // 📝 Word by word
    case pairs([Pair])                       // word-by-word list
    case examples([Pair])                    // 💬 Examples: a sentence and its translation
    case text(String)
}

struct Pair: Equatable {
    var word: String
    var meaning: String
    var general: String?
}

enum Markdown {
    static func blocks(_ md: String) -> [Block] {
        var out: [Block] = []
        var sawHeadline = false
        var inExamples = false
        for raw in md.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if let (emoji, label, rest) = labelled(line) {
                inExamples = emoji.unicodeScalars.first?.value == 0x1F4AC  // 💬
                if emoji.unicodeScalars.first?.value == 0x270F { out.append(.correction(rest)); continue }
                if rest.isEmpty { out.append(.section(label)); continue }
                out.append(.field(icon: symbol(for: emoji), label: label, text: rest)); continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                let p = pair(String(line.dropFirst(2)))
                if inExamples {
                    if case .examples(var list)? = out.last { list.append(p); out[out.count - 1] = .examples(list) }
                    else { out.append(.examples([p])) }
                    continue
                }
                if case .pairs(var list)? = out.last { list.append(p); out[out.count - 1] = .pairs(list) }
                else { out.append(.pairs([p])) }
                continue
            }
            if let m = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                let n = Int(line[m].filter(\.isNumber)) ?? out.count + 1
                out.append(.meaning(n, String(line[m.upperBound...])))
                sawHeadline = true
                continue
            }
            if !sawHeadline { out.append(.headline(line)); sawHeadline = true; continue }
            if line.hasPrefix("*"), !line.hasPrefix("**"), case .headline? = out.last { out.append(.subtitle(line)); continue }
            out.append(.text(line))
        }
        return out
    }

    // "**💡 Remember:** text" → ("💡", "Remember", "text"); "**📝 Word by word**" → ("📝", "Word by word", "")
    private static func labelled(_ line: String) -> (String, String, String)? {
        guard line.hasPrefix("**"), let end = line.range(of: "**", range: line.index(line.startIndex, offsetBy: 2)..<line.endIndex) else { return nil }
        let inside = line[line.index(line.startIndex, offsetBy: 2)..<end.lowerBound].trimmingCharacters(in: .whitespaces)
        guard let first = inside.first, isEmoji(first) else { return nil }
        let label = inside.dropFirst().trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        let rest = line[end.upperBound...].trimmingCharacters(in: .whitespaces)
        return (String(first), label, rest)
    }

    private static func isEmoji(_ c: Character) -> Bool {
        c.unicodeScalars.contains { $0.properties.isEmojiPresentation || $0.value == 0xFE0F || $0.value >= 0x2700 && $0.value <= 0x27BF }
    }

    private static func symbol(for emoji: String) -> String {
        switch emoji.unicodeScalars.first?.value {
        case 0x1F9E9: return "puzzlepiece.extension"  // 🧩
        case 0x1F524: return "textformat.abc"         // 🔤
        case 0x1F4A1: return "lightbulb"              // 💡
        case 0x1F4DD: return "list.bullet"            // 📝
        default: return "info.circle"
        }
    }

    // "**glæder mig til** — look forward to · *in general:* glæde = to please"
    private static func pair(_ s: String) -> Pair {
        guard let dash = s.range(of: " — ") ?? s.range(of: " - ") else { return Pair(word: s, meaning: "") }
        let word = String(s[..<dash.lowerBound])
        var meaning = String(s[dash.upperBound...])
        var general: String?
        if let dot = meaning.range(of: " · ") {
            general = String(meaning[dot.upperBound...])
                .replacingOccurrences(of: "*in general:*", with: "")
                .replacingOccurrences(of: "in general:", with: "")
                .trimmingCharacters(in: .whitespaces)
            meaning = String(meaning[..<dot.lowerBound])
        }
        return Pair(word: word, meaning: meaning, general: general)
    }

    // "weekend = weekend" or a repeat of the meaning tells the learner nothing new.
    static func adds(_ general: String, to p: Pair) -> Bool {
        let g = plain(general).lowercased()
        guard !g.isEmpty, g != plain(p.meaning).lowercased() else { return false }
        let sides = g.components(separatedBy: "=").map { $0.trimmingCharacters(in: .whitespaces) }
        return !(sides.count == 2 && sides[0] == sides[1])
    }

    static func headline(_ md: String) -> String? {
        for b in blocks(md) {
            if case .headline(let h) = b { return plain(h) }
            if case .meaning(_, let m) = b { return plain(m.components(separatedBy: " — ").first ?? m) }
        }
        return nil
    }

    static func plain(_ s: String) -> String {
        s.replacingOccurrences(of: #"[*_`#]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func attributed(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(plain(s))
    }
}
