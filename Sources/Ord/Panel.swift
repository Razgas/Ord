import Cocoa
import SwiftUI

// A Spotlight-style floating panel. It takes keyboard input without activating Ord,
// so the app you were in stays in front, and it closes on Esc or when you click elsewhere.
final class TranslatorPanel: NSPanel {
    enum Placement { case center, pointer }

    private let effect = NSVisualEffectView()
    private var placement = Placement.center
    private var anchor = NSPoint.zero  // top-left corner that stays put while the height changes

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: RootView.width, height: 60),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true

        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.separatorColor.cgColor
        effect.maskImage = .roundedMask(radius: 16)

        let host = NSHostingView(rootView: RootView { [weak self] h in self?.fit(height: h) }
            .environmentObject(Session.shared))
        host.sizingOptions = []
        host.frame = effect.bounds
        host.autoresizingMask = [.width, .height]
        effect.addSubview(host)
        contentView = effect
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // The panel takes typing without making Ord the active app, so the Edit menu's shortcuts never
    // reach it. Handle ⌘A ⌘C ⌘V ⌘X ⌘Z ⇧⌘Z here, and ⌘W to close.
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        let flags = e.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags == .command || flags == [.command, .shift], let key = e.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: e)
        }
        let action: Selector?
        switch (key, flags.contains(.shift)) {
        case ("a", false): action = #selector(NSText.selectAll(_:))
        case ("c", false): action = #selector(NSText.copy(_:))
        case ("v", false): action = #selector(NSText.paste(_:))
        case ("x", false): action = #selector(NSText.cut(_:))
        case ("z", false): action = Selector(("undo:"))
        case ("z", true): action = Selector(("redo:"))
        case ("w", false): hide(); return true
        default: action = nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: e)
    }
    override func cancelOperation(_ sender: Any?) { hide() }

    override func resignKey() {
        super.resignKey()
        hide()
    }

    func show(_ where: Placement) {
        placement = `where`
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        let f = screen.visibleFrame
        let w = RootView.width
        switch placement {
        case .center:
            anchor = NSPoint(x: f.midX - w / 2, y: f.maxY - f.height * 0.16)
        case .pointer:
            let m = NSEvent.mouseLocation
            let x = min(max(m.x - w / 2, f.minX + 12), f.maxX - w - 12)
            // Below the pointer if there is room for a full answer, otherwise above it.
            let y = m.y - 18 - 420 > f.minY ? m.y - 18 : min(m.y + 440, f.maxY - 12)
            anchor = NSPoint(x: x, y: y)
        }
        fit(height: frame.height)
        if !isVisible {
            alphaValue = 0
            makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { c in
                c.duration = 0.15
                animator().alphaValue = 1
            }
        } else {
            makeKeyAndOrderFront(nil)
        }
        Session.shared.focusRequest += 1
    }

    func toggle() {
        if isVisible { hide() } else { Session.shared.clear(); show(.center) }
    }

    func hide() {
        guard isVisible else { return }
        Speaker.shared.stop()
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.12
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            self?.alphaValue = 1
        })
    }

    private func fit(height: CGFloat) {
        guard height > 0 else { return }
        let h = ceil(height)
        var y = anchor.y - h
        if let s = screen?.visibleFrame ?? NSScreen.main?.visibleFrame, y < s.minY + 8 { y = s.minY + 8 }
        setFrame(NSRect(x: anchor.x, y: y, width: RootView.width, height: h), display: true)
        invalidateShadow()
    }

    // Moving the panel by dragging changes where it grows from.
    override func setFrameOrigin(_ point: NSPoint) {
        super.setFrameOrigin(point)
        anchor = NSPoint(x: frame.minX, y: frame.maxY)
    }
}

extension NSImage {
    // A stretchable rounded-rectangle mask. NSVisualEffectView clips its blur only with a mask image;
    // a layer corner radius alone leaves square (white) corners.
    static func roundedMask(radius r: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: r * 2 + 1, height: r * 2 + 1), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }
}
