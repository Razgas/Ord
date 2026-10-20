import Cocoa
import Carbon
import Vision
import ScreenCaptureKit

func ordLog(_ msg: String) {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Ord.log")
    let line = "\(Date()) \(msg)\n"
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile() }
    else { try? line.write(to: url, atomically: true, encoding: .utf8) }
}

// Global shortcuts and the three-finger click, set up from the current settings.
final class Input: ObservableObject {
    static let shared = Input()
    @Published private(set) var taken: Set<ShortcutAction> = []  // shortcuts another app already owns
    var paused = false { didSet { lastSettings = ""; apply() } }
    private var lastSettings = ""

    func start() {
        HotKeys.shared.install()
        apply()
        // Re-apply when the settings change.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.apply()
        }
    }

    private func apply() {
        let shortcuts = ShortcutAction.allCases.map { ($0, $0.shortcut) }
        let three = UserDefaults.standard.bool(forKey: Pref.threeFinger)
        let settings = "\(paused) \(three) " + shortcuts.map { "\($0.1?.keyCode ?? 0):\($0.1?.modifiers ?? 0)" }.joined(separator: ",")
        guard settings != lastSettings else { return }
        lastSettings = settings

        HotKeys.shared.removeAll()
        var failed: Set<ShortcutAction> = []
        if !paused {
            for (action, s) in shortcuts {
                guard let s else { continue }
                if !HotKeys.shared.add(s.keyCode, s.modifiers, { action.perform() }) { failed.insert(action) }
            }
        }
        if taken != failed { taken = failed }
        if ShortcutAction.voice.shortcut != nil { VoiceLookup.shared.requestPermissions() }
        if three { Touch.shared.enable() } else { Touch.shared.disable() }
    }
}

// Carbon hot keys: work in every app and need no special permission.
final class HotKeys {
    static let shared = HotKeys()
    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1

    func install() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            DispatchQueue.main.async { HotKeys.shared.actions[id.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    @discardableResult
    func add(_ key: UInt32, _ modifiers: UInt32, _ action: @escaping () -> Void) -> Bool {
        let id = nextID; nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(key, modifiers, EventHotKeyID(signature: OSType(0x4F524421), id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { refs.append(ref); actions[id] = action; return true }
        ordLog("hot key \(key) is taken by another app (\(status))")
        return false
    }

    func removeAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []; actions = [:]
    }
}

// MARK: - Selected text

enum Selection {
    // Events we post ourselves carry this tag so our own event tap ignores them.
    static let tag: Int64 = 0x0D0D
    static let source = CGEventSource(stateID: .hidSystemState)

    static func trusted(prompt: Bool) -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): prompt] as CFDictionary)
    }

    static func translate() {
        guard trusted(prompt: true) else { lookup("", at: .center); return }
        if let s = axSelectedText() { lookup(s); return }
        copySelection { text in lookup(text ?? "", at: text == nil ? .center : .pointer) }
    }

    static func ax(_ el: AXUIElement, _ attr: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
    }

    // Is the frontmost app's Edit ▸ Copy enabled? false means nothing is selected, so pressing ⌘C would
    // only make the app beep. nil: the app's menu can't be read.
    static func copyEnabled() -> Bool? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let bar = ax(AXUIElementCreateApplication(pid), kAXMenuBarAttribute) else { return nil }
        for top in (ax(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            for menu in (ax(top, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                for item in (ax(menu, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                    guard (ax(item, kAXMenuItemCmdCharAttribute) as? String)?.uppercased() == "C",
                          (ax(item, kAXMenuItemCmdModifiersAttribute) as? Int) == 0 else { continue }  // 0 = ⌘ only
                    return ax(item, kAXEnabledAttribute) as? Bool
                }
            }
        }
        return nil
    }

    static func axSelectedText() -> String? {
        guard let f = ax(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute) else { return nil }
        let s = (ax(f as! AXUIElement, kAXSelectedTextAttribute) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return s?.isEmpty == false ? s : nil
    }

    static func post(_ e: CGEvent?) {
        e?.setIntegerValueField(.eventSourceUserData, value: tag)
        e?.post(tap: .cghidEventTap)
    }

    // For apps that don't expose the selection (many web views): press ⌘C, read it, then put the clipboard back.
    static func copySelection(_ done: @escaping (String?) -> Void) {
        if copyEnabled() == false { done(nil); return }
        let pb = NSPasteboard.general
        let saved = (pb.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
            return copy
        }
        let before = pb.changeCount
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: down)
            e?.flags = .maskCommand
            post(e)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            guard pb.changeCount != before else { done(nil); return }
            let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
            pb.clearContents(); pb.writeObjects(saved)
            done(text?.isEmpty == false ? text : nil)
        }
    }
}

// MARK: - Screenshots

enum ScreenShot {
    // The area (global coordinates, top-left origin, points) at the screen's full resolution, taken in-process
    // with ScreenCaptureKit. Ord's own windows (the dimmed picker) are left out. nil: not allowed or failed.
    static func take(_ rect: CGRect) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            func overlap(_ d: SCDisplay) -> CGFloat { let i = d.frame.intersection(rect); return i.isNull ? 0 : i.width * i.height }
            guard let display = content.displays.max(by: { overlap($0) < overlap($1) }), overlap(display) > 0 else { return nil }
            let scale = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
            }?.backingScaleFactor ?? 2
            let own = content.windows.filter { $0.owningApplication?.processID == getpid() }
            let area = rect.intersection(display.frame).offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            let config = SCStreamConfiguration()
            config.sourceRect = area
            config.width = Int(area.width * scale)
            config.height = Int(area.height * scale)
            config.showsCursor = false
            config.captureResolution = .best
            return try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: own),
                                                              configuration: config)
        } catch {
            ordLog("screenshot failed: \(error)")
            return nil
        }
    }
}

// MARK: - Screenshot text (OCR)

enum ScreenText {
    // macOS ties Screen Recording to the app's signature and ID, so a rebuild can lose it.
    // macOS lists an app under Screen Recording only once it has tried to capture, so try first
    // (that also brings up macOS's own prompt), then open the right page of System Settings.
    static func allowed() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        ordLog("screen recording: not allowed")
        Task {
            _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if !CGRequestScreenCaptureAccess() {
                try? await Task.sleep(nanoseconds: 600_000_000)
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
        }
        return false
    }

    static func capture() {
        guard allowed() else { return }
        ScreenSelect.shared.start { rect in
            Task {
                guard let image = await ScreenShot.take(rect) else { NSSound.beep(); return }
                DispatchQueue.global(qos: .userInitiated).async { recognize(image) }
            }
        }
    }

    private static func recognize(_ image: CGImage) {
        let req = request()
        try? VNImageRequestHandler(cgImage: image).perform([req])
        let lines = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let text = join(lines)
        DispatchQueue.main.async {
            if text.isEmpty { NSSound.beep() } else { lookup(text) }
        }
    }

    // Accurate text recognition, tuned to the two languages in Settings.
    static func request() -> VNRecognizeTextRequest {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        let supported = (try? req.supportedRecognitionLanguages()) ?? []
        let wanted = [Language.learning.locale, Language.native.locale].filter { supported.contains($0) }
        if !wanted.isEmpty { req.recognitionLanguages = wanted }
        return req
    }

    // Lines from a paragraph become one text again; "for-\nsikring" becomes "forsikring".
    static func join(_ lines: [String]) -> String {
        var out = ""
        for l in lines.map({ $0.trimmingCharacters(in: .whitespaces) }) where !l.isEmpty {
            if out.hasSuffix("-"), let f = l.first, f.isLowercase { out.removeLast(); out += l }
            else { out += (out.isEmpty ? "" : " ") + l }
        }
        return out
    }
}
