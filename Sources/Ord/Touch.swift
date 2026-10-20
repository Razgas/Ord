import Cocoa

// Three-finger click on the trackpad: translate the selection, or the word under the pointer.
// Finger counts come from the private MultitouchSupport framework; clicks from an event tap.

private typealias MTCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
private typealias MTCreateList = @convention(c) () -> Unmanaged<CFArray>
private typealias MTRegister = @convention(c) (UnsafeMutableRawPointer?, MTCallback) -> Void
private typealias MTStart = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void
private typealias MTStop = @convention(c) (UnsafeMutableRawPointer?) -> Void

private let mt = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW)
private let mtCreateList = unsafeBitCast(dlsym(mt, "MTDeviceCreateList"), to: MTCreateList.self)
private let mtRegister = unsafeBitCast(dlsym(mt, "MTRegisterContactFrameCallback"), to: MTRegister.self)
private let mtUnregister = unsafeBitCast(dlsym(mt, "MTUnregisterContactFrameCallback"), to: MTRegister.self)
private let mtStart = unsafeBitCast(dlsym(mt, "MTDeviceStart"), to: MTStart.self)
private let mtStop = unsafeBitCast(dlsym(mt, "MTDeviceStop"), to: MTStop.self)

// Fingers often land a moment before or after the click registers, or one lifts early,
// so look at the most fingers seen in the last 0.3 s instead of one instant.
private let lock = NSLock()
private var recent: [(Date, Int32)] = []
private var lastFrame = Date.distantPast
private let onTouches: MTCallback = { _, _, n, _, _ in
    let now = Date()
    lock.lock()
    lastFrame = now
    recent.append((now, n))
    recent.removeAll { now.timeIntervalSince($0.0) > 0.3 }
    lock.unlock()
    return 0
}

final class Touch {
    static let shared = Touch()
    private var devices: [AnyObject] = []  // must stay alive, or macOS stops sending touches
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var watchdog: Timer?
    private var swallowMouseUp = false
    private var enabled = false

    func enable() {
        guard !enabled else { return }
        enabled = true
        guard Selection.trusted(prompt: true) else {
            // Wait until Accessibility access is granted in System Settings.
            Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] t in
                guard let self, self.enabled else { t.invalidate(); return }
                if Selection.trusted(prompt: false) { t.invalidate(); self.enabled = false; self.enable() }
            }
            return
        }
        connect()
        installTap()
        for n in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(reconnect), name: n, object: nil)
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(reconnect), name: .init("com.apple.screenIsUnlocked"), object: nil)
    }

    func disable() {
        guard enabled else { return }
        enabled = false
        watchdog?.invalidate()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
        for d in devices { let p = Unmanaged.passUnretained(d).toOpaque(); mtUnregister(p, onTouches); mtStop(p) }
        devices = []
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func reconnect() { if enabled { connect() } }

    private func connect() {
        for d in devices { let p = Unmanaged.passUnretained(d).toOpaque(); mtUnregister(p, onTouches); mtStop(p) }
        devices = mtCreateList().takeRetainedValue() as [AnyObject]
        for d in devices { let p = Unmanaged.passUnretained(d).toOpaque(); mtRegister(p, onTouches); mtStart(p, 0) }
    }

    private func fingers() -> (count: Int32, fresh: Bool) {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        let n = recent.filter { now.timeIntervalSince($0.0) <= 0.3 }.map(\.1).max() ?? 0
        return (n, now.timeIntervalSince(lastFrame) < 0.5)
    }

    private func installTap() {
        // macOS sometimes turns a three-finger click into a right-click, so watch both buttons.
        let mask = [CGEventType.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]
            .reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: mask, callback: { _, type, event, _ in
            Touch.shared.handle(type, event)
        }, userInfo: nil)
        guard let tap else { ordLog("could not create the click watcher"); return }
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        // macOS switches a tap off if it is ever slow; switch it back on.
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            if let t = self?.tap, !CGEvent.tapIsEnabled(tap: t) { CGEvent.tapEnable(tap: t, enable: true) }
        }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Selection.tag { return Unmanaged.passUnretained(event) }
        let isDown = type == .leftMouseDown || type == .rightMouseDown
        let isUp = type == .leftMouseUp || type == .rightMouseUp
        let (n, fresh) = fingers()
        if isDown && fresh && n >= 3 {
            swallowMouseUp = true
            let p = event.location
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { Touch.translate(at: p) }
            return nil
        }
        if isUp && swallowMouseUp { swallowMouseUp = false; return nil }
        if isDown && !fresh { DispatchQueue.main.async { self.reconnect() } }  // touches stopped arriving
        return Unmanaged.passUnretained(event)
    }

    // MARK: what to translate

    static func translate(at p: CGPoint) {
        if let s = Selection.axSelectedText() { lookup(s); return }
        let el = element(at: p)
        if let el, let w = word(in: el, at: p) { lookup(w); return }
        guard pointerIsTextCursor(), safeToDoubleClick(el) else {
            Selection.copySelection { if let t = $0 { lookup(t) } }
            return
        }
        Selection.copySelection { selected in
            if let selected { lookup(selected); return }
            doubleClick(at: p)  // select the word under the pointer, then read it
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                if let s = Selection.axSelectedText() { lookup(s); return }
                Selection.copySelection { if let t = $0 { lookup(t) } }
            }
        }
    }

    private static func element(at p: CGPoint) -> AXUIElement? {
        var el: AXUIElement?
        return AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &el) == .success ? el : nil
    }

    // Read the word under the pointer straight from the app's accessibility text, if the app offers it.
    private static func word(in el: AXUIElement, at p: CGPoint) -> String? {
        var pt = p
        guard let pv = AXValueCreate(.cgPoint, &pt) else { return nil }
        var rv: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXRangeForPositionParameterizedAttribute as CFString, pv, &rv) == .success,
              let rangeValue = rv else { return nil }
        var r = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &r), r.location >= 0 else { return nil }
        let total = (Selection.ax(el, kAXNumberOfCharactersAttribute) as? Int) ?? (r.location + 60)
        var window = CFRange(location: max(0, r.location - 60), length: 0)
        window.length = min(120, total - window.location)
        guard window.length > 0, let wv = AXValueCreate(.cfRange, &window) else { return nil }
        var sv: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXStringForRangeParameterizedAttribute as CFString, wv, &sv) == .success,
              let text = sv as? String else { return nil }
        let chars = Array(text)
        let i = r.location - window.location
        func inWord(_ c: Character) -> Bool { c.isLetter || c == "-" }
        guard i >= 0, i < chars.count, chars[i].isLetter else { return nil }
        var a = i, b = i
        while a > 0 && inWord(chars[a - 1]) { a -= 1 }
        while b < chars.count - 1 && inWord(chars[b + 1]) { b += 1 }
        let w = String(chars[a...b]).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return w.isEmpty ? nil : w
    }

    // The text cursor (I-beam) means the pointer is over selectable text. Its hot spot is in the middle
    // of the image; the arrow's and the hand's are near the top. Proportions work at any cursor size.
    private static func pointerIsTextCursor() -> Bool {
        guard let c = NSCursor.currentSystem else { return false }
        let size = c.image.size
        guard size.width > 0, size.height > 0 else { return false }
        return abs(c.hotSpot.y / size.height - 0.5) < 0.15 && abs(c.hotSpot.x / size.width - 0.5) < 0.15
    }

    // Places where a double-click could open or launch something instead of selecting a word.
    private static let unsafeApps: Set<String> = ["com.apple.finder", "com.apple.dock", "com.apple.systemuiserver"]
    private static let unsafeRoles: Set<String> = ["AXButton", "AXLink", "AXImage", "AXMenuItem", "AXMenuBarItem", "AXCheckBox",
                                                   "AXRadioButton", "AXPopUpButton", "AXCell", "AXRow", "AXOutline", "AXList",
                                                   "AXIcon", "AXDockItem", "AXTab"]
    private static func safeToDoubleClick(_ el: AXUIElement?) -> Bool {
        guard let el else { return true }
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        if pid == getpid() { return false }
        if let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, unsafeApps.contains(id) { return false }
        var cur: AXUIElement? = el
        for _ in 0..<4 {
            guard let c = cur else { break }
            if let role = Selection.ax(c, kAXRoleAttribute) as? String, unsafeRoles.contains(role) { return false }
            cur = Selection.ax(c, kAXParentAttribute) as! AXUIElement?
        }
        return true
    }

    private static func doubleClick(at p: CGPoint) {
        for clickState in [1, 2] as [Int64] {
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                let e = CGEvent(mouseEventSource: Selection.source, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
                e?.setIntegerValueField(.mouseEventClickState, value: clickState)
                Selection.post(e)
            }
        }
    }
}
