// Voice lookup: say a word or sentence (Danish or English) and see it translated.
import Cocoa
import Speech
import AVFoundation

final class VoiceLookup {
    static let shared = VoiceLookup()

    private var engine = AVAudioEngine()
    private var locales: [String] { [Language.learning.locale, Language.native.locale] }
    private var requests: [String: SFSpeechAudioBufferRecognitionRequest] = [:]
    private var tasks: [String: SFSpeechRecognitionTask] = [:]
    private var latest: [String: SFSpeechRecognitionResult] = [:]
    private var finished = Set<String>()
    private var silenceTimer: Timer?
    private var maxTimer: Timer?
    private(set) var listening = false
    private var stopping = false
    private let hud = Hud()

    func toggle() { listening ? stop() : start() }

    // Ask for microphone and speech recognition access up front, so the prompts appear once.
    func requestPermissions(_ done: @escaping (Bool) -> Void = { _ in }) {
        SFSpeechRecognizer.requestAuthorization { status in
            AVCaptureDevice.requestAccess(for: .audio) { mic in
                DispatchQueue.main.async { done(status == .authorized && mic) }
            }
        }
    }

    private func start() {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            ordLog("voice: no permission yet, asking")
            requestPermissions { ok in if ok { self.start() } else { NSSound.beep() } }
            return
        }
        // A fresh engine every time: a long-lived one keeps the microphone setup from when it was made, and after
        // sleep or a headset change that setup is stale. Installing a tap on it then throws and takes the app down.
        engine.stop(); engine.inputNode.removeTap(onBus: 0)
        engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            ordLog("voice: no usable microphone (\(format))"); NSSound.beep(); return
        }
        listening = true; stopping = false
        requests = [:]; tasks = [:]; latest = [:]; finished = []

        for id in locales {
            guard let rec = SFSpeechRecognizer(locale: Locale(identifier: id)), rec.isAvailable else { continue }
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            requests[id] = req
            tasks[id] = rec.recognitionTask(with: req) { [weak self] result, error in
                DispatchQueue.main.async { self?.handle(id, result, error) }
            }
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            self?.requests.values.forEach { $0.append(buf) }
            let level = Hud.level(of: buf)
            DispatchQueue.main.async { self?.hud.level = level }
        }
        do { engine.prepare(); try engine.start() } catch {
            ordLog("voice: mic failed \(error)"); cleanUp(); NSSound.beep(); return
        }
        NSSound(named: "Tink")?.play()
        hud.listen()
        maxTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in self?.stop() }
        // Nothing said within 6 s: give up quietly.
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in self?.stop() }
        ordLog("voice: listening")
    }

    private func handle(_ id: String, _ result: SFSpeechRecognitionResult?, _ error: Error?) {
        if let result {
            latest[id] = result
            if result.isFinal { finished.insert(id) }
            if !stopping {
                let b = best(); hud.update(b.text, lang: b.lang)
                // Stop 1.3 s after the last new word.
                silenceTimer?.invalidate()
                silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.3, repeats: false) { [weak self] _ in self?.stop() }
            }
        }
        if error != nil { finished.insert(id) }
        if stopping && finished.count >= requests.count { finish() }
    }

    private func stop() {
        guard listening, !stopping else { return }
        stopping = true
        silenceTimer?.invalidate(); maxTimer?.invalidate()
        engine.stop(); engine.inputNode.removeTap(onBus: 0)
        requests.values.forEach { $0.endAudio() }
        NSSound(named: "Pop")?.play()
        hud.processing()
        // Give the recognisers a moment to deliver their final text.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.finish() }
    }

    // Both recognisers hear the same audio; keep the one that is more sure of itself.
    private func best() -> (text: String, lang: String) {
        var pick = (text: "", lang: "", score: -1.0)
        for id in locales {
            guard let r = latest[id] else { continue }
            let t = r.bestTranscription
            let segs = t.segments
            var score = segs.isEmpty ? 0 : segs.map { Double($0.confidence) }.reduce(0, +) / Double(segs.count)
            if id == locales[0] { score += 0.02 }  // tie → the language being learned
            if !t.formattedString.isEmpty && score > pick.score { pick = (t.formattedString, id, score) }
        }
        return (pick.text, pick.lang)
    }

    private func finish() {
        guard listening else { return }
        let (text, lang) = best()
        ordLog("voice: [\(lang)] \(text)")
        cleanUp()
        hud.hide()
        if text.isEmpty { NSSound.beep(); return }
        lookup(text, at: .center)
    }

    private func cleanUp() {
        engine.stop(); engine.inputNode.removeTap(onBus: 0)
        tasks.values.forEach { $0.cancel() }
        tasks = [:]; requests = [:]
        listening = false; stopping = false
    }
}

// A floating capsule at the top of the screen while listening, in the style of macOS system HUDs:
// live waveform on the left, transcript in the middle, language tag on the right.
final class Hud {
    private let height: CGFloat = 46
    private var panel: NSPanel?
    private let wave = WaveformView(frame: NSRect(x: 0, y: 0, width: 27, height: 22))
    private let label = NSTextField(labelWithString: "")
    private let tag = NSTextField(labelWithString: "")
    private let tagBg = NSView()
    private var width: CGFloat = 170
    private var visible = false

    var level: Float = 0 { didSet { wave.level = CGFloat(level) } }

    static func level(of buf: AVAudioPCMBuffer) -> Float {
        guard let ch = buf.floatChannelData?[0], buf.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buf.frameLength) { sum += ch[i] * ch[i] }
        let db = 20 * log10(max(sqrt(sum / Float(buf.frameLength)), 1e-6))
        return min(max((db + 50) / 38, 0), 1)
    }

    func listen() {
        build()
        wave.mode = .listening
        setText("Listening", placeholder: true, lang: "")
        present()
    }

    func update(_ text: String, lang: String) {
        guard !text.isEmpty else { return }
        setText(text, placeholder: false, lang: String(lang.prefix(2)).uppercased())
    }

    func processing() {
        wave.mode = .thinking
        label.animator().alphaValue = 0.6
    }

    func hide() {
        guard let p = panel, visible else { return }
        visible = false
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.18
            p.animator().alphaValue = 0
            p.animator().setFrame(frameFor(width: width, scale: 0.92), display: true)
        }, completionHandler: { [weak self] in
            if self?.visible == false { p.orderOut(nil); self?.wave.mode = .idle }
        })
    }

    private func build() {
        guard panel == nil else { return }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar; p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]; p.ignoresMouseEvents = true
        p.appearance = NSAppearance(named: .vibrantDark)

        let bg = NSVisualEffectView()
        bg.material = .hudWindow; bg.blendingMode = .behindWindow; bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = height / 2; bg.layer?.cornerCurve = .continuous; bg.layer?.masksToBounds = true
        bg.layer?.borderWidth = 0.5; bg.layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
        bg.maskImage = .roundedMask(radius: height / 2)
        p.contentView = bg

        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.lineBreakMode = .byTruncatingHead
        label.maximumNumberOfLines = 1
        tag.font = .systemFont(ofSize: 10, weight: .semibold)
        tag.textColor = NSColor(white: 1, alpha: 0.75); tag.alignment = .center
        tagBg.wantsLayer = true
        tagBg.layer?.backgroundColor = NSColor(white: 1, alpha: 0.14).cgColor
        tagBg.layer?.cornerRadius = 8; tagBg.layer?.cornerCurve = .continuous
        tagBg.addSubview(tag)
        [wave, label, tagBg].forEach { bg.addSubview($0) }
        panel = p
    }

    private func setText(_ text: String, placeholder: Bool, lang: String) {
        label.stringValue = text
        label.textColor = placeholder ? NSColor(white: 1, alpha: 0.55) : .white
        label.alphaValue = 1
        tag.stringValue = lang
        tagBg.isHidden = lang.isEmpty

        let pad: CGFloat = 17, gap: CGFloat = 11, tagW: CGFloat = 26
        let textW = min(ceil(label.fittingSize.width), 440)
        wave.setFrameOrigin(NSPoint(x: pad, y: (height - wave.frame.height) / 2))
        label.frame = NSRect(x: wave.frame.maxX + gap, y: (height - 20) / 2, width: textW, height: 20)
        tagBg.frame = NSRect(x: label.frame.maxX + 9, y: (height - 16) / 2, width: tagW, height: 16)
        tag.frame = NSRect(x: 0, y: 1, width: tagW, height: 14)
        width = max((lang.isEmpty ? label.frame.maxX : tagBg.frame.maxX) + pad + 2, 170)

        guard let p = panel, visible else { return }
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.22; c.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().setFrame(frameFor(width: width), display: true)
        }
    }

    private func present() {
        guard let p = panel else { return }
        visible = true
        p.alphaValue = 0
        p.setFrame(frameFor(width: width, scale: 0.9), display: false)
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.28; c.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1.3, 0.4, 1)
            p.animator().alphaValue = 1
            p.animator().setFrame(frameFor(width: width), display: true)
        }
    }

    // Centred just below the menu bar of the screen the mouse is on.
    private func frameFor(width: CGFloat, scale: CGFloat = 1) -> NSRect {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        let s = screen.visibleFrame
        let w = width * scale, h = height * scale
        return NSRect(x: s.midX - w / 2, y: s.maxY - 10 - height + (height - h) / 2, width: w, height: h)
    }
}

// Five rounded bars that follow the microphone level; a soft travelling wave while thinking.
final class WaveformView: NSView {
    enum Mode { case idle, listening, thinking }
    var mode = Mode.idle { didSet { mode == .idle ? stopTimer() : startTimer() } }
    var level: CGFloat = 0

    private var bars: [CALayer] = []
    private var smooth: CGFloat = 0
    private var t: CGFloat = 0
    private var timer: Timer?
    private let shape: [CGFloat] = [0.45, 0.75, 1.0, 0.75, 0.45]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let w: CGFloat = 3, gap = (frame.width - w * 5) / 4
        for i in 0..<5 {
            let b = CALayer()
            b.backgroundColor = NSColor.white.cgColor
            b.cornerRadius = w / 2
            b.frame = NSRect(x: CGFloat(i) * (w + gap), y: (frame.height - w) / 2, width: w, height: w)
            layer?.addSublayer(b); bars.append(b)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func startTimer() {
        guard timer == nil else { return }
        let tm = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(tm, forMode: .common)
        timer = tm
    }

    private func stopTimer() { timer?.invalidate(); timer = nil; tick() }

    private func tick() {
        t += 1.0 / 60
        smooth += (level - smooth) * (level > smooth ? 0.45 : 0.12)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (i, b) in bars.enumerated() {
            let wobble = 0.5 + 0.5 * sin(t * 9 + CGFloat(i) * 1.3)
            let h: CGFloat
            switch mode {
            case .listening: h = 3 + (bounds.height - 3) * shape[i] * min(1, smooth * (0.7 + 0.3 * wobble) + 0.06 * wobble)
            case .thinking:  h = 3 + 7 * max(0, sin(t * 6 - CGFloat(i) * 0.8))
            case .idle:      h = 3
            }
            b.frame = NSRect(x: b.frame.minX, y: (bounds.height - h) / 2, width: b.frame.width, height: h)
            b.opacity = mode == .thinking ? 0.75 : 1
        }
        CATransaction.commit()
    }
}
