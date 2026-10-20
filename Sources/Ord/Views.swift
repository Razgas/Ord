import SwiftUI

private struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
private struct ResultHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct RootView: View {
    @EnvironmentObject var s: Session
    var onHeight: (CGFloat) -> Void
    @State private var resultHeight: CGFloat = 0
    static let width: CGFloat = 600

    private var showsResult: Bool { !s.query.isEmpty }
    private var showsRecent: Bool { s.query.isEmpty && !s.history.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            InputBar()
            if showsResult || showsRecent {
                Divider().opacity(0.5)
                ScrollView {
                    Group {
                        if showsResult { ResultView() } else { RecentView() }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GeometryReader { Color.clear.preference(key: ResultHeightKey.self, value: $0.size.height) })
                }
                .scrollIndicators(.never)
                .frame(height: min(resultHeight, 520))
                .onPreferenceChange(ResultHeightKey.self) { resultHeight = $0 }
            }
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { Color.clear.preference(key: HeightKey.self, value: $0.size.height) })
        .onPreferenceChange(HeightKey.self) { onHeight($0) }
    }
}

struct InputBar: View {
    @EnvironmentObject var s: Session
    @FocusState private var focused: Bool
    @AppStorage(Pref.learning) private var learning = "da"  // redraws the placeholder when languages change
    @AppStorage(Pref.native) private var native = "en"

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "character.book.closed")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.secondary)
            TextField("\(Language.learning.name) or \(Language.native.name)", text: $s.input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 21, weight: .regular))
                .lineLimit(1...4)
                .focused($focused)
                .onSubmit { s.run(s.input) }
            if s.busy {
                ProgressView().controlSize(.small)
            } else if let src = s.source, !s.query.isEmpty {
                ActionButtons(text: s.input.isEmpty ? s.query : s.input, lang: src)
            }
            if let src = s.source, !s.query.isEmpty {
                DirectionTag(source: src) { s.switchDirection() }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .onAppear { focused = true }
        .onChange(of: s.focusRequest) { focused = true }
    }
}

// "DA → EN". Clicking it reads the text as the other language and looks it up again.
struct DirectionTag: View {
    let source: Language
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(source.short)
                Image(systemName: hover ? "arrow.left.arrow.right" : "arrow.right")
                    .font(.system(size: 9, weight: .bold))
                Text(source.other.short)
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(hover ? .primary : .secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.quaternary.opacity(hover ? 1 : 0.6), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Read it as \(source.other.name) instead")
        .onHover { hover = $0 }
    }
}

struct ResultView: View {
    @EnvironmentObject var s: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if s.answer.isEmpty && s.loading.contains(.ai) {
                Placeholder()
            } else if !s.answer.isEmpty {
                AnswerView(markdown: s.answer, target: s.source?.other)
            }
            if let e = s.error {
                Notice(text: e, needsSettings: e.contains("Settings"))
            }
            if Service.enabled.isEmpty {
                Notice(text: "All services are turned off. Turn one on in Settings.", needsSettings: true)
            }
            ServiceRows()
            ExtraRow()
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 18)
    }
}

struct AnswerView: View {
    let markdown: String
    let target: Language?

    var body: some View {
        let blocks = Markdown.blocks(markdown)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, b in
                block(b, after: i > 0 ? blocks[i - 1] : nil)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func block(_ b: Block, after prev: Block?) -> some View {
        switch b {
        case .correction(let t):
            CorrectionBanner(markdown: t)

        case .headline(let t):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(Markdown.attributed(t))
                    .font(.system(size: 26, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                ActionButtons(text: Markdown.plain(t), lang: target ?? Language.guess(Markdown.plain(t)))
            }

        case .subtitle(let t):
            Text(Markdown.attributed(t)).font(.system(size: 15)).foregroundStyle(.secondary)
                .padding(.top, -6)

        case .meaning(let n, let t):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(n)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(.quaternary.opacity(0.7), in: Circle())
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                Text(Markdown.attributed(t)).font(.system(size: 16))
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .field(let icon, let label, let t):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(tint(icon))
                    .frame(width: 18)
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 82, alignment: .leading)
                Text(Markdown.attributed(t)).font(.system(size: 14))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, isField(prev) ? 0 : 8)

        case .section(let t):
            Text(t.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
                .padding(.top, 10)

        case .pairs(let list):
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 9) {
                ForEach(Array(list.enumerated()), id: \.offset) { _, p in
                    GridRow {
                        Text(Markdown.attributed(p.word.replacingOccurrences(of: "**", with: "")))
                            .font(.system(size: 14, weight: .semibold))
                            .fixedSize()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Markdown.attributed(p.meaning)).font(.system(size: 14))
                            if let g = p.general, Markdown.adds(g, to: p) {
                                Text(Markdown.attributed(g)).font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .examples(let list):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(list.enumerated()), id: \.offset) { _, p in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Markdown.attributed(p.word)).font(.system(size: 14))
                        if !p.meaning.isEmpty {
                            Text(Markdown.attributed(p.meaning)).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

        case .text(let t):
            Text(Markdown.attributed(t)).font(.system(size: 14)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func isField(_ b: Block?) -> Bool {
        if case .field? = b { return true }
        return false
    }

    private func tint(_ icon: String) -> Color {
        switch icon {
        case "lightbulb": return .yellow
        case "puzzlepiece.extension": return .blue
        case "textformat.abc": return .purple
        default: return .secondary
        }
    }
}

// "✏️ klassekammerater — double k …". Clicking it puts the corrected text in the box and looks it up.
struct CorrectionBanner: View {
    let markdown: String
    @EnvironmentObject var s: Session
    @State private var hover = false

    private var corrected: String {
        Markdown.plain(markdown.components(separatedBy: " — ").first ?? markdown)
            .trimmingCharacters(in: CharacterSet(charactersIn: " .:"))
    }

    // The model sometimes writes the line anyway for correct input ("✏️ Correct: <the same sentence>" or
    // "the sentence is correct"). Show it only when it really is a small fix of what was typed.
    private var isRealFix: Bool {
        // Lower case, letters and digits only, single spaces: "Hej, Med dig!" → "hej med dig"
        func norm(_ t: String) -> [Character] {
            let kept = String(String.UnicodeScalarView(t.lowercased().unicodeScalars.filter {
                CharacterSet.alphanumerics.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
            }))
            return Array(kept.split(whereSeparator: \.isWhitespace).joined(separator: " "))
        }
        let a = norm(s.query), b = norm(corrected)
        guard !a.isEmpty, !b.isEmpty, a != b else { return false }
        return Double(Self.distance(a, b)) <= Double(max(a.count, b.count)) * 0.5
    }

    // Edit distance: how many letters must change to turn one text into the other.
    private static func distance(_ a: [Character], _ b: [Character]) -> Int {
        var row = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var diagonal = row[0]
            row[0] = i + 1
            for (j, y) in b.enumerated() {
                let above = row[j + 1]
                row[j + 1] = min(above + 1, row[j] + 1, diagonal + (x == y ? 0 : 1))
                diagonal = above
            }
        }
        return row[b.count]
    }

    var body: some View {
        if isRealFix { banner }
    }

    private var banner: some View {
        Button { s.run(corrected) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "pencil.line").foregroundStyle(.orange)
                Text(Markdown.attributed(markdown)).font(.system(size: 14))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "return")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                    .opacity(hover ? 1 : 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(hover ? 0.2 : 0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Use “\(corrected)”")
        .onHover { hover = $0 }
        .padding(.bottom, 4)
    }
}

struct ActionButtons: View {
    let text: String
    let lang: Language
    @State private var copied = false

    var body: some View {
        HStack(spacing: 2) {
            IconButton(symbol: "speaker.wave.2", help: "Listen") { Speaker.shared.speak(text, lang) }
            IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            }
        }
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hover ? .primary : .secondary)
                .frame(width: 26, height: 26)
                .background(hover ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hover = $0 }
    }
}

// Short answers from the other translators and dictionaries, under the AI's explanation.
struct ServiceRows: View {
    @EnvironmentObject var s: Session

    private var rows: [(Service, ServiceResult?)] {
        Service.enabled.compactMap { service in
            guard service != .ai else { return nil }
            // Dictionaries describe words of the language being learned only.
            if service.isDictionary && s.source != Language.learning { return nil }
            if let r = s.results[service] { return (service, r) }
            return s.loading.contains(service) ? (service, nil) : nil  // still on its way
        }
    }

    var body: some View {
        let rows = rows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 11) {
                if !s.answer.isEmpty || s.error != nil || s.loading.contains(.ai) {
                    Divider().opacity(0.5).padding(.bottom, 2)
                }
                ForEach(rows, id: \.0) { service, result in
                    if let result {
                        ServiceRow(service: service, result: result, lang: s.source?.other)
                    } else {
                        LoadingRow(service: service)
                    }
                }
            }
            .padding(.top, 2)
        }
    }
}

// One more language, chosen from the menu on the left ("Translate into…"). The choice is remembered,
// so every lookup is also translated into it until "None" is picked.
struct ExtraRow: View {
    @EnvironmentObject var s: Session
    @AppStorage(Pref.extra) private var code = ""
    @State private var hover = false

    private var language: Language? { Language.find(code) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Menu {
                ForEach(Language.all) { l in
                    Button(l.name) { s.setExtra(l) }
                }
                if language != nil {
                    Divider()
                    Button("None") { s.setExtra(nil) }
                }
            } label: {
                Text(language?.name ?? "Translate into…")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hover ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: language == nil ? nil : 70, alignment: .leading)
            .help("Also translate into another language")
            .onHover { hover = $0 }

            if let language {
                switch s.extra {
                case .text(let t, let more)?:
                    VStack(alignment: .leading, spacing: 3) {
                        Text(t).font(.system(size: 14)).foregroundStyle(.secondary)
                        ForEach(Array(more.enumerated()), id: \.offset) { _, sense in
                            (Text(ServiceRow.short(sense.partOfSpeech) + "  ").italic().foregroundStyle(.tertiary)
                             + Text(sense.definitions.prefix(4).joined(separator: " · ")).foregroundStyle(.secondary))
                                .font(.system(size: 12))
                        }
                    }
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    IconButton(symbol: "speaker.wave.2", help: "Listen") { Speaker.shared.speak(t, language) }
                        .padding(.vertical, -6)
                case .failed(let m)?:
                    Text(m).font(.system(size: 13)).foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                default:
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(.quaternary)
                        .frame(width: 150, height: 9)
                    Spacer(minLength: 0)
                }
            } else {
                Spacer(minLength: 0)
            }
        }
    }
}

struct LoadingRow: View {
    let service: Service
    @State private var dim = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(service.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 70, alignment: .leading)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(.quaternary)
                .frame(width: 150, height: 9)
                .opacity(dim ? 0.4 : 1)
                .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever()) { dim = true } }
            Spacer(minLength: 0)
        }
        .frame(height: 18)
        .help("\(service.name) is still looking this up")
    }
}

struct ServiceRow: View {
    let service: Service
    let result: ServiceResult
    let lang: Language?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(service.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 70, alignment: .leading)
            switch result {
            case .text(let t, let more):
                VStack(alignment: .leading, spacing: 3) {
                    Text(t)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                    // Other meanings of a single word, one quiet line per word type: "adj. firm · permanent"
                    ForEach(Array(more.enumerated()), id: \.offset) { _, sense in
                        (Text(Self.short(sense.partOfSpeech) + "  ").italic().foregroundStyle(.tertiary)
                         + Text(sense.definitions.joined(separator: " · ")).foregroundStyle(.secondary))
                            .font(.system(size: 12))
                    }
                }
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let lang, !service.isDictionary {
                    IconButton(symbol: "speaker.wave.2", help: "Listen") { Speaker.shared.speak(t, lang) }
                        .padding(.vertical, -6)
                }
            case .senses(let senses):
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(senses.enumerated()), id: \.offset) { _, sense in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sense.partOfSpeech).font(.system(size: 12)).italic().foregroundStyle(.tertiary)
                            ForEach(Array(sense.definitions.enumerated()), id: \.offset) { i, d in
                                Text(sense.definitions.count > 1 ? "\(i + 1). \(d)" : d)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .textSelection(.enabled)
                Spacer(minLength: 0)
            case .failed(let m):
                Text(m).font(.system(size: 13)).foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
        }
    }
}

extension ServiceRow {
    static func short(_ partOfSpeech: String) -> String {
        switch partOfSpeech.lowercased() {
        case "adjective": return "adj."
        case "adverb": return "adv."
        case "preposition": return "prep."
        case "conjunction": return "conj."
        case "pronoun": return "pron."
        case "interjection": return "interj."
        case "determiner": return "det."
        case "abbreviation": return "abbr."
        default: return partOfSpeech.lowercased()
        }
    }
}

struct Notice: View {
    let text: String
    let needsSettings: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
            Text(text).font(.system(size: 13)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if needsSettings { Button("Settings") { SettingsWindow.shared.show() }.controlSize(.small) }
        }
    }
}

// Soft pulsing bars while the first words of the answer are on their way.
struct Placeholder: View {
    @State private var dim = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            bar(180, 24)
            bar(340, 12).padding(.top, 6)
            bar(280, 12)
        }
        .opacity(dim ? 0.45 : 1)
        .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever()) { dim = true } }
    }

    private func bar(_ w: CGFloat, _ h: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: h / 2.5, style: .continuous).fill(.quaternary).frame(width: w, height: h)
    }
}

struct RecentView: View {
    @EnvironmentObject var s: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("RECENT")
                    .font(.system(size: 11, weight: .semibold)).tracking(0.6)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Clear") { s.clearHistory() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
            ForEach(s.history.prefix(7)) { e in
                RecentRow(entry: e) { s.run(e.text) }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
    }
}

struct RecentRow: View {
    let entry: Entry
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(entry.text)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 16)
                Text(entry.headline)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(hover ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
