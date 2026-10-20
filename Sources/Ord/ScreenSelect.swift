import Cocoa

// Ord's own screen-area picker: the screen dims, you drag over some text, the area you pick stays clear.
// Esc or a right-click cancels.
final class ScreenSelect {
    static let shared = ScreenSelect()
    private var windows: [OverlayWindow] = []
    private var previousApp: NSRunningApplication?
    private var done: ((CGRect) -> Void)?

    // Calls back with the picked area in global screen coordinates (top-left origin, points).
    func start(hint: String = "Drag over the text you want to translate", _ done: @escaping (CGRect) -> Void) {
        guard windows.isEmpty else { return }
        self.done = done
        previousApp = NSWorkspace.shared.frontmostApplication
        let mouseScreen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
        for screen in NSScreen.screens {
            let w = OverlayWindow(screen: screen, hint: screen == mouseScreen ? hint : nil)
            w.selectionView.onFinish = { [weak self] rect in self?.finish(rect, on: screen) }
            w.selectionView.onCancel = { [weak self] in self?.finish(nil, on: screen) }
            windows.append(w)
            w.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
        windows.first { $0.screen == mouseScreen }?.makeKey()
        NSCursor.crosshair.set()
    }

    private func finish(_ rect: NSRect?, on screen: NSScreen) {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        NSCursor.arrow.set()
        previousApp?.activate()
        guard let rect, let done else { return }
        self.done = nil
        // Cocoa uses a bottom-left origin; screencapture wants top-left, measured from the main screen.
        let onScreen = rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        let mainHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let global = CGRect(x: onScreen.minX, y: mainHeight - onScreen.maxY, width: onScreen.width, height: onScreen.height)
        // Let the overlay disappear from the screen before the picture is taken.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { done(global) }
    }
}

final class OverlayWindow: NSWindow {
    let selectionView: SelectionView

    init(screen: NSScreen, hint: String?) {
        selectionView = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size), hint: hint)
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = selectionView
        acceptsMouseMovedEvents = true
        makeFirstResponder(selectionView)
    }

    override var canBecomeKey: Bool { true }
}

final class SelectionView: NSView {
    var onFinish: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?

    private var start: NSPoint?
    private var current: NSPoint?
    private let hint: NSView?

    init(frame: NSRect, hint: String?) {
        self.hint = hint.map(Self.makeHint)
        super.init(frame: frame)
        if let hint = self.hint {
            addSubview(hint)
            hint.setFrameOrigin(NSPoint(x: (frame.width - hint.frame.width) / 2, y: frame.height - hint.frame.height - 64))
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    private var selection: NSRect? {
        guard let start, let current else { return nil }
        return NSRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(current.x - start.x), height: abs(current.y - start.y)).integral
    }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSBezierPath(rect: bounds)
        if let r = selection, r.width > 0, r.height > 0 {
            dim.append(NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6))
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.32).setFill()
        dim.fill()

        guard let r = selection, r.width > 2, r.height > 2 else { return }
        let border = NSBezierPath(roundedRect: r.insetBy(dx: -0.5, dy: -0.5), xRadius: 6.5, yRadius: 6.5)
        border.lineWidth = 1.5
        NSColor.white.withAlphaComponent(0.95).setStroke()
        border.stroke()
        drawSize(of: r)
    }

    // A small "240 × 80" tag under the bottom-right corner, like a measuring tool.
    private func drawSize(of r: NSRect) {
        let label = NSAttributedString(string: "\(Int(r.width)) × \(Int(r.height))", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
        let size = label.size()
        var tag = NSRect(x: r.maxX - size.width - 16, y: r.minY - size.height - 14, width: size.width + 16, height: size.height + 6)
        if tag.minY < 4 { tag.origin.y = r.minY + 8; tag.origin.x = r.maxX - tag.width - 8 }
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: tag, xRadius: tag.height / 2, yRadius: tag.height / 2).fill()
        label.draw(at: NSPoint(x: tag.minX + 8, y: tag.minY + 3))
    }

    override func mouseDown(with e: NSEvent) {
        start = convert(e.locationInWindow, from: nil)
        current = start
        if let hint {
            NSAnimationContext.runAnimationGroup { c in c.duration = 0.15; hint.animator().alphaValue = 0 }
        }
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        current = convert(e.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        current = convert(e.locationInWindow, from: nil)
        if let r = selection, r.width >= 6, r.height >= 6 { onFinish?(r) } else { onCancel?() }
    }

    override func rightMouseDown(with e: NSEvent) { onCancel?() }

    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { onCancel?() } else { super.keyDown(with: e) }  // Esc
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    // A floating capsule like the other Ord HUDs: icon, instruction, and the Esc key.
    private static func makeHint(_ message: String) -> NSView {
        let height: CGFloat = 40
        let icon = NSImageView(image: NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 15, weight: .medium)
        icon.contentTintColor = .white
        let text = NSTextField(labelWithString: message)
        text.font = .systemFont(ofSize: 13, weight: .medium)
        text.textColor = .white
        let esc = NSTextField(labelWithString: "esc")
        esc.font = .systemFont(ofSize: 11, weight: .semibold)
        esc.textColor = NSColor(white: 1, alpha: 0.7)
        esc.alignment = .center
        let escBg = NSView()
        escBg.wantsLayer = true
        escBg.layer?.backgroundColor = NSColor(white: 1, alpha: 0.16).cgColor
        escBg.layer?.cornerRadius = 6
        escBg.layer?.cornerCurve = .continuous

        let pad: CGFloat = 16, gap: CGFloat = 9
        let textW = ceil(text.fittingSize.width), escW: CGFloat = 32
        let width = pad + 18 + gap + textW + gap + 4 + escW + pad - 4
        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.appearance = NSAppearance(named: .vibrantDark)
        bg.wantsLayer = true
        bg.layer?.cornerRadius = height / 2
        bg.layer?.cornerCurve = .continuous
        bg.layer?.masksToBounds = true
        bg.layer?.borderWidth = 0.5
        bg.layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
        bg.maskImage = .roundedMask(radius: height / 2)

        icon.frame = NSRect(x: pad, y: (height - 18) / 2, width: 18, height: 18)
        text.frame = NSRect(x: icon.frame.maxX + gap, y: (height - 17) / 2, width: textW, height: 17)
        escBg.frame = NSRect(x: text.frame.maxX + gap + 4, y: (height - 20) / 2, width: escW, height: 20)
        esc.frame = NSRect(x: 0, y: 3, width: escW, height: 14)
        escBg.addSubview(esc)
        [icon, text, escBg].forEach { bg.addSubview($0) }
        return bg
    }
}
