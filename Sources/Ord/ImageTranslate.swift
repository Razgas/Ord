import Cocoa
import SwiftUI
import Vision

// ⌥⇧S: translate a screen area in place, like Google Lens. The text is read with Vision, grouped into
// paragraphs, translated, painted out with the colour around it and drawn again in the other language.
// The result floats exactly over the area it came from.
enum ImageTranslate {
    static func capture() {
        guard ScreenText.allowed() else { return }
        ScreenSelect.shared.start(hint: "Drag over the area to translate in place") { rect in
            Task { @MainActor in
                guard let image = await ScreenShot.take(rect) else { NSSound.beep(); return }
                LensWindow.show(image, at: rect)
            }
        }
    }
}

// MARK: - Reading, translating and redrawing

private struct TextLine {
    var text: String
    var rect: CGRect  // pixels, top-left origin
}

private struct TextBlock {
    var lines: [TextLine]
    var rect: CGRect { lines.dropFirst().reduce(lines[0].rect) { $0.union($1.rect) } }
    var text: String { ScreenText.join(lines.map(\.text)) }
    var lineHeight: CGFloat { lines.map(\.rect.height).sorted()[lines.count / 2] }
    // Distance from one line to the next; for one line a usual 1.25.
    var pitch: CGFloat {
        lines.count > 1 ? (lines.last!.rect.minY - lines[0].rect.minY) / CGFloat(lines.count - 1) : lineHeight * 1.25
    }
    var alignment: NSTextAlignment {
        guard lines.count > 1 else { return .natural }
        func spread(_ f: (CGRect) -> CGFloat) -> CGFloat { let v = lines.map { f($0.rect) }; return v.max()! - v.min()! }
        let tolerance = lineHeight * 0.5
        if spread(\.minX) < tolerance { return .natural }
        if spread(\.midX) < tolerance { return .center }
        if spread(\.maxX) < tolerance { return .right }
        return .natural
    }
}

enum ImageTranslator {
    struct Result { var image: CGImage; var source: Language; var target: Language }

    static func translate(_ image: CGImage) async throws -> Result {
        let blocks = paragraphs(lines(in: image))
        let todo = blocks.indices.filter { blocks[$0].text.contains(where: \.isLetter) }
        guard !todo.isEmpty else { throw ServiceError(message: "No text found here") }

        // One call for everything, a paragraph per line: Google sees the context and decides the direction once.
        let joined = todo.map { blocks[$0].text }.joined(separator: "\n")
        let first: Translation
        do { first = try await Translators.translate(.google, joined) }
        catch { first = try await Translators.translate(.bing, joined) }
        var outs = first.text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if outs.count != todo.count {
            // The lines didn't come back one for one: translate each paragraph by itself.
            outs = try await withThrowingTaskGroup(of: (Int, String).self) { group in
                for (n, i) in todo.enumerated() {
                    group.addTask { (n, try await Translators.translate(.google, blocks[i].text, from: first.source).text) }
                }
                var r = [String](repeating: "", count: todo.count)
                for try await (n, t) in group { r[n] = t }
                return r
            }
        }
        var texts: [Int: String] = [:]
        for (n, i) in todo.enumerated() where outs[n] != blocks[i].text { texts[i] = outs[n] }

        let target = first.source.other
        guard let out = render(image, blocks, texts, rightToLeft: ["ar", "fa", "iw", "ur"].contains(target.code)) else {
            throw ServiceError(message: "Couldn't draw the translation")
        }
        return Result(image: out, source: first.source, target: target)
    }

    private static func lines(in image: CGImage) -> [TextLine] {
        let req = ScreenText.request()
        try? VNImageRequestHandler(cgImage: image).perform([req])
        let w = CGFloat(image.width), h = CGFloat(image.height)
        return (req.results ?? []).compactMap { o in
            guard let c = o.topCandidates(1).first, c.confidence >= 0.3 else { return nil }
            let t = c.string.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return nil }
            let b = o.boundingBox  // normalised, bottom-left origin
            return TextLine(text: t, rect: CGRect(x: b.minX * w, y: (1 - b.maxY) * h, width: b.width * w, height: b.height * h))
        }
    }

    // Lines that wrap into each other become one paragraph, so a sentence is translated as a whole.
    // Short labels, list items and side-by-side columns each stay on their own.
    private static func paragraphs(_ lines: [TextLine]) -> [TextBlock] {
        var blocks: [TextBlock] = []
        for line in lines.sorted(by: { $0.rect.minY < $1.rect.minY }) {
            if let i = blocks.lastIndex(where: { continues($0, with: line) }) { blocks[i].lines.append(line) }
            else { blocks.append(TextBlock(lines: [line])) }
        }
        return blocks
    }

    private static func continues(_ block: TextBlock, with line: TextLine) -> Bool {
        let prev = block.lines.last!, a = prev.rect, b = line.rect
        let gap = b.minY - a.maxY
        let overlap = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        let widest = block.lines.map(\.rect.width).max()!
        let bullet = line.text.range(of: #"^([•·▪◦‣*–—-]|\d{1,2}[.)])\s"#, options: .regularExpression) != nil
        return gap < b.height * 0.75 && gap > -b.height * 0.5
            && max(a.height, b.height) / min(a.height, b.height) < 1.35
            && overlap > min(a.width, b.width) * 0.3
            && prev.text.count >= 12               // a wrapped line is a full one
            && a.width >= max(widest, b.width) * 0.7
            && !bullet
    }

    // MARK: Drawing

    private struct Layout { var block: TextBlock; var text: NSAttributedString; var textRect: CGRect }

    private static func render(_ image: CGImage, _ blocks: [TextBlock], _ texts: [Int: String], rightToLeft: Bool) -> CGImage? {
        let w = image.width, h = image.height
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let px = Pixels(data: Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: w * h * 4)), width: w, height: h)

        let allHeights = blocks.flatMap { $0.lines.map(\.rect.height) }.sorted()
        let usual = allHeights.isEmpty ? 0 : allHeights[allHeights.count / 2]
        let layouts = texts.keys.sorted().map { i -> (Layout, Colors) in
            let b = blocks[i]
            let colors = px.colors(for: b)
            let bold = colors.stroke > 0.135 || b.lineHeight > usual * 1.5
            let l = layout(texts[i]!, in: b, align: px.alignment(of: b, background: colors.background),
                           color: px.cg(colors.ink), shadow: colors.busy ? px.contrast(to: colors.ink) : nil, bold: bold, rightToLeft: rightToLeft)
            return (l, colors)
        }

        // Paint every paragraph out first, then write, so no eraser covers a neighbour's text.
        let out = data.assumingMemoryBound(to: UInt8.self)
        for (l, colors) in layouts { px.erase(l.block, colors, into: out) }

        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        for (l, _) in layouts { l.text.draw(with: l.textRect, options: [.usesLineFragmentOrigin, .usesFontLeading]) }
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
        return ctx.makeImage()
    }

    // The largest size, starting from the original's, at which the translation fits the original's place.
    // `shadow`: on a photo, a soft shadow keeps the letters readable.
    private static func layout(_ text: String, in b: TextBlock, align: NSTextAlignment, color: CGColor, shadow: CGColor?,
                               bold: Bool, rightToLeft: Bool) -> Layout {
        let rect = b.rect, pad = b.lineHeight * 0.18
        let start = b.lineHeight * 0.82
        let spacing = min(max(b.pitch / start, 1.05), 1.8)
        let maxW = rect.width + pad * 2, maxH = rect.height + pad * 2
        let para = NSMutableParagraphStyle()
        para.alignment = align
        para.lineBreakMode = .byWordWrapping

        var size = start, s = NSAttributedString(), measured = CGSize.zero
        repeat {
            let font = NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
            para.lineSpacing = b.lines.count > 1 ? max(0, size * spacing - (font.ascender - font.descender + font.leading)) : 0
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(cgColor: color) ?? .black, .paragraphStyle: para]
            if let shadow {
                let glow = NSShadow()
                glow.shadowColor = NSColor(cgColor: shadow)
                glow.shadowBlurRadius = size * 0.2
                attributes[.shadow] = glow
            }
            s = NSAttributedString(string: text, attributes: attributes)
            measured = s.boundingRect(with: CGSize(width: maxW, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).size
            size *= 0.94
        } while measured.height > maxH && size > start * 0.5

        // Where the text sits: on the original's left, centre or right edge, vertically centred.
        let anchorRight = align == .right || (align == .natural && rightToLeft)
        let x = align == .center ? rect.midX - maxW / 2 : anchorRight ? rect.maxX - maxW : rect.minX
        let textRect = CGRect(x: x, y: rect.midY - measured.height / 2, width: maxW, height: measured.height)
        return Layout(block: b, text: s, textRect: textRect)
    }
}

private struct Colors {
    var background: SIMD3<Float>
    var ink: SIMD3<Float>
    var busy: Bool       // a photo or pattern behind the text rather than one plain colour
    var stroke: CGFloat  // how thick the letters' strokes are, as a share of the line's height
}

// The screenshot's pixels (RGBA, top row first), for picking the colours around and inside the text.
private struct Pixels {
    let data: [UInt8]
    let width: Int, height: Int

    func at(_ x: Int, _ y: Int) -> SIMD3<Float>? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let i = (y * width + x) * 4
        return SIMD3(Float(data[i]), Float(data[i + 1]), Float(data[i + 2]))
    }

    func colors(for b: TextBlock) -> Colors {
        let r = b.rect, pad = b.lineHeight * 0.18 + 2
        // The background: the middle colour of a thin ring just outside the paragraph.
        let ring = r.insetBy(dx: -pad, dy: -pad)
        var around: [SIMD3<Float>] = []
        let step = max(1, Int((ring.width + ring.height) * 2 / 400))
        for x in stride(from: Int(ring.minX), through: Int(ring.maxX), by: step) {
            for y in [Int(ring.minY), Int(ring.maxY)] { if let p = at(x, y) { around.append(p) } }
        }
        for y in stride(from: Int(ring.minY), through: Int(ring.maxY), by: step) {
            for x in [Int(ring.minX), Int(ring.maxX)] { if let p = at(x, y) { around.append(p) } }
        }
        var inside: [SIMD3<Float>] = []
        for line in b.lines {
            let s = max(1, Int(line.rect.height / 14))
            for y in stride(from: Int(line.rect.minY), to: Int(line.rect.maxY), by: s) {
                for x in stride(from: Int(line.rect.minX), to: Int(line.rect.maxX), by: s) { if let p = at(x, y) { inside.append(p) } }
            }
        }
        let bg = median(around.isEmpty ? inside : around)
        let busy = !around.isEmpty && Float(around.filter { distance($0, bg) > 25 }.count) / Float(around.count) > 0.2

        // The text: the pixels inside that differ most from the background (the cores of the strokes).
        let far = inside.sorted { distance($0, bg) > distance($1, bg) }.prefix(max(1, inside.count / 12))
        var ink = far.isEmpty ? bg : far.reduce(SIMD3<Float>(), +) / Float(far.count)
        if distance(ink, bg) < 60 { ink = luminance(bg) > 140 ? SIMD3(20, 20, 20) : SIMD3(245, 245, 245) }
        return Colors(background: bg, ink: ink, busy: busy, stroke: stroke(b, ink: ink, background: bg))
    }

    // The typical width of a run of ink across the middle of the letters: their stems.
    private func stroke(_ b: TextBlock, ink: SIMD3<Float>, background: SIMD3<Float>) -> CGFloat {
        var runs: [Int] = []
        for line in b.lines {
            let r = line.rect
            for y in stride(from: Int(r.minY + r.height * 0.4), to: Int(r.minY + r.height * 0.7), by: max(1, Int(r.height / 12))) {
                var run = 0
                for x in Int(r.minX)...Int(r.maxX) {
                    if let p = at(x, y), distance(p, ink) < distance(p, background) { run += 1 }
                    else { if run > 0 { runs.append(run) }; run = 0 }
                }
            }
        }
        guard !runs.isEmpty else { return 0 }
        return CGFloat(runs.sorted()[runs.count / 2]) / b.lineHeight
    }

    // Lines that line up decide for a paragraph. A single line is centred when it sits in the middle of
    // what holds it (a button, a banner): walking out from it, the edges come at the same distance.
    func alignment(of b: TextBlock, background: SIMD3<Float>) -> NSTextAlignment {
        guard b.lines.count == 1 else { return b.alignment }
        let r = b.rect, y = Int(r.midY)
        func edge(from x0: Int, by dx: Int) -> Int {
            var x = x0, prev = at(x0, y) ?? background
            while let p = at(x + dx, y) {
                if distance(p, prev) > 30 { break }  // a sharp change; a gradient changes slowly
                prev = p; x += dx
            }
            return abs(x - x0)
        }
        let pad = Int(r.height * 0.3)
        let left = edge(from: Int(r.minX) - pad, by: -1), right = edge(from: Int(r.maxX) + pad, by: 1)
        let room = CGFloat(min(left, right) + pad)
        return room > r.height * 0.3 && CGFloat(abs(left - right)) < max(r.height * 0.6, room * 0.15) ? .center : .natural
    }

    // Paints the letters out and leaves everything else as it was. A pixel belongs to a letter when it differs
    // from a plain background, or, on a photo, when it has the text's colour; the mask grows a little to take
    // the soft edges too. Each masked pixel becomes the average of the nearest unmasked pixels (the smallest
    // square around it that is mostly clean), so photos and gradients carry on underneath and no colour
    // leaks across an edge. `out` is the bitmap being drawn, in the same layout.
    func erase(_ b: TextBlock, _ c: Colors, into out: UnsafeMutablePointer<UInt8>) {
        let lh = b.lineHeight
        // On a photo only text-coloured pixels are taken, so the search can reach further out for tall letters.
        let pad = Int(lh * (c.busy ? 0.32 : 0.18)), grow = max(2, Int(lh * 0.12)), radius = max(8, Int(lh * 1.5))
        let boxes = b.lines.map { $0.rect.insetBy(dx: -CGFloat(pad), dy: -CGFloat(pad)).integral }
        let area = b.rect.insetBy(dx: -CGFloat(pad + grow + radius), dy: -CGFloat(pad + grow + radius)).integral
        let x0 = max(0, Int(area.minX)), y0 = max(0, Int(area.minY))
        let x1 = min(width, Int(area.maxX)), y1 = min(height, Int(area.maxY))
        let w = x1 - x0, h = y1 - y0
        guard w > 0, h > 0 else { return }

        let contrast = distance(c.ink, c.background)
        var letter = [Int32](repeating: 0, count: w * h)
        for box in boxes {
            for y in max(y0, Int(box.minY))..<min(y1, Int(box.maxY)) {
                for x in max(x0, Int(box.minX))..<min(x1, Int(box.maxX)) {
                    let p = at(x, y)!
                    let isLetter = c.busy ? distance(p, c.ink) < contrast * 0.7 : distance(p, c.background) > 18
                    if isLetter { letter[(y - y0) * w + x - x0] = 1 }
                }
            }
        }
        // Sums over any rectangle in constant time (summed-area tables): first to grow the mask, then to average.
        func table(_ v: (Int) -> Double) -> [Double] {
            var t = [Double](repeating: 0, count: (w + 1) * (h + 1))
            for y in 0..<h {
                var row = 0.0
                for x in 0..<w { row += v(y * w + x); t[(y + 1) * (w + 1) + x + 1] = t[y * (w + 1) + x + 1] + row }
            }
            return t
        }
        func sum(_ t: [Double], _ x: Int, _ y: Int, _ r: Int) -> Double {
            let ax = max(0, x - r), ay = max(0, y - r), bx = min(w, x + r + 1), by = min(h, y + r + 1)
            return t[by * (w + 1) + bx] - t[ay * (w + 1) + bx] - t[by * (w + 1) + ax] + t[ay * (w + 1) + ax]
        }
        let letters = table { Double(letter[$0]) }
        var masked = [Bool](repeating: false, count: w * h)
        for y in 0..<h { for x in 0..<w { masked[y * w + x] = sum(letters, x, y, grow) > 0 } }

        func channel(_ k: Int) -> [Double] {
            table { i in masked[i] ? 0 : Double(data[((y0 + i / w) * width + x0 + i % w) * 4 + k]) }
        }
        let known = table { masked[$0] ? 0 : 1 }, red = channel(0), green = channel(1), blue = channel(2)
        for y in 0..<h {
            for x in 0..<w where masked[y * w + x] {
                var r = 2, n = 0.0
                while true {
                    n = sum(known, x, y, r)
                    if n >= Double((2 * r + 1) * (2 * r + 1)) * 0.3 || r >= radius { break }
                    r = r * 3 / 2 + 1
                }
                let col = n > 0 ? SIMD3(Float(sum(red, x, y, r) / n), Float(sum(green, x, y, r) / n), Float(sum(blue, x, y, r) / n)) : c.background
                let p = ((y0 + y) * width + x0 + x) * 4
                out[p] = UInt8(min(max(col.x, 0), 255).rounded())
                out[p + 1] = UInt8(min(max(col.y, 0), 255).rounded())
                out[p + 2] = UInt8(min(max(col.z, 0), 255).rounded())
                out[p + 3] = 255
            }
        }
    }

    private func median(_ ps: [SIMD3<Float>]) -> SIMD3<Float> {
        guard !ps.isEmpty else { return SIMD3(255, 255, 255) }
        func m(_ c: Int) -> Float { ps.map { $0[c] }.sorted()[ps.count / 2] }
        return SIMD3(m(0), m(1), m(2))
    }
    private func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { let d = a - b; return (d * d).sum().squareRoot() }
    private func luminance(_ c: SIMD3<Float>) -> Float { 0.299 * c.x + 0.587 * c.y + 0.114 * c.z }
    func contrast(to c: SIMD3<Float>) -> CGColor { luminance(c) > 128 ? CGColor(gray: 0, alpha: 0.45) : CGColor(gray: 1, alpha: 0.45) }
    func cg(_ c: SIMD3<Float>) -> CGColor { CGColor(srgbRed: CGFloat(c.x / 255), green: CGFloat(c.y / 255), blue: CGFloat(c.z / 255), alpha: 1) }
}

// MARK: - The floating result

@MainActor
final class LensModel: ObservableObject {
    let original: NSImage
    @Published var translated: NSImage?
    @Published var showOriginal = false
    @Published var working = true
    @Published var status = "Translating…"
    @Published var copied = false
    var close: () -> Void = {}

    init(_ image: NSImage) { original = image }
    var shown: NSImage { showOriginal ? original : translated ?? original }

    func copy() {
        guard let img = translated else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.copied = false }
    }

    func save() {
        guard let img = translated, let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Translation.png"
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { try? png.write(to: url) }
    }
}

final class LensWindow: NSPanel {
    private static var open: [LensWindow] = []
    private static let margin: CGFloat = 14, bar: CGFloat = 40, gap: CGFloat = 8, minWidth: CGFloat = 330
    let model: LensModel

    // `rect`: the captured area in global coordinates (top-left origin, points), as ScreenSelect hands it out.
    @MainActor
    static func show(_ image: CGImage, at rect: CGRect) {
        let model = LensModel(NSImage(cgImage: image, size: rect.size))
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let area = CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
        let visible = NSScreen.screens.first { $0.frame.intersects(area) }?.visibleFrame ?? .infinite
        // The bar goes under the picture, or over it when there is no room underneath.
        let below = area.minY - gap - bar - margin >= visible.minY
        let width = max(area.width, minWidth) + margin * 2
        let frame = CGRect(x: area.midX - width / 2, y: below ? area.minY - gap - bar - margin : area.minY - margin,
                           width: width, height: area.height + gap + bar + margin * 2)

        let w = LensWindow(model: model, frame: frame, barBelow: below)
        model.close = { [weak w] in w?.dismiss() }
        open.append(w)
        w.makeKeyAndOrderFront(nil)

        Task {
            do {
                let r = try await Task.detached(priority: .userInitiated) { try await ImageTranslator.translate(image) }.value
                withAnimation(.easeOut(duration: 0.25)) {
                    model.translated = NSImage(cgImage: r.image, size: rect.size)
                    model.status = "\(r.source.name) → \(r.target.name)"
                    model.working = false
                }
            } catch {
                model.status = error.localizedDescription
                model.working = false
            }
        }
    }

    private init(model: LensModel, frame: CGRect, barBelow: Bool) {
        self.model = model
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        let host = NSHostingView(rootView: LensView(barBelow: barBelow).environmentObject(model))
        host.sizingOptions = []
        contentView = host
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { dismiss() }

    // Space shows the original; ⌘C copies the translation, ⌘S saves it, ⌘W closes.
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 49 { model.showOriginal.toggle() } else { super.keyDown(with: e) }
    }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard e.modifierFlags.intersection([.command, .shift, .option, .control]) == .command else { return super.performKeyEquivalent(with: e) }
        switch e.charactersIgnoringModifiers?.lowercased() {
        case "c": model.copy()
        case "s": model.save()
        case "w": dismiss()
        default: return super.performKeyEquivalent(with: e)
        }
        return true
    }

    func dismiss() {
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.12
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            Self.open.removeAll { $0 === self }
        })
    }
}

private struct LensView: View {
    let barBelow: Bool
    @EnvironmentObject private var model: LensModel

    var body: some View {
        VStack(spacing: 8) {
            if !barBelow { bar }
            picture
            if barBelow { bar }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var picture: some View {
        Image(nsImage: model.shown)
            .resizable()
            .frame(width: model.original.size.width, height: model.original.size.height)
            .overlay { if model.working { Scanning() } }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .shadow(color: .black.opacity(0.28), radius: 9, y: 2)
            .onDrag { NSItemProvider(object: model.translated ?? model.original) }  // drag the picture into another app
    }

    private var bar: some View {
        HStack(spacing: 4) {
            HStack(spacing: 7) {
                if model.working { ProgressView().controlSize(.small) }
                else if model.translated == nil { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                Text(model.status).lineLimit(1)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.leading, 12)
            .padding(.trailing, 6)
            Spacer(minLength: 0)
            if model.translated != nil {
                button(model.showOriginal ? "eye.slash" : "eye", model.showOriginal ? "Show the translation (Space)" : "Show the original (Space)") {
                    model.showOriginal.toggle()
                }
                button(model.copied ? "checkmark" : "doc.on.doc", "Copy (⌘C)") { model.copy() }
                button("square.and.arrow.down", "Save (⌘S)") { model.save() }
            }
            button("xmark", "Close (Esc)") { model.close() }
        }
        .padding(.horizontal, 4)
        .frame(height: 40)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .environment(\.colorScheme, .dark)
    }

    private func button(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// A soft band of light sweeping over the picture while it is being translated.
private struct Scanning: View {
    @State private var phase: CGFloat = -0.4

    var body: some View {
        GeometryReader { g in
            LinearGradient(colors: [.clear, .white.opacity(0.22), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: max(g.size.width * 0.4, 60))
                .offset(x: phase * g.size.width)
                .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
        .onAppear { withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) { phase = 1.1 } }
    }
}
