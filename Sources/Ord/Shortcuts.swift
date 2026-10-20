import Cocoa
import Carbon
import SwiftUI

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32  // Carbon flags (optionKey, cmdKey, …)
    var key: String        // what is printed on the key, e.g. "D"

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + key
    }

    init(keyCode: Int, _ modifiers: Int, _ key: String) {
        self.keyCode = UInt32(keyCode); self.modifiers = UInt32(modifiers); self.key = key
    }

    init?(event e: NSEvent) {
        let f = e.modifierFlags
        var m = 0
        if f.contains(.control) { m |= controlKey }
        if f.contains(.option) { m |= optionKey }
        if f.contains(.shift) { m |= shiftKey }
        if f.contains(.command) { m |= cmdKey }
        let fKey = Self.names[Int(e.keyCode)]?.hasPrefix("F") == true
        // Plain letters (or only ⇧ + letter) would fire while typing, so require ⌃, ⌥ or ⌘ unless it is an F-key.
        guard m & ~shiftKey != 0 || fKey else { return nil }
        let key = Self.names[Int(e.keyCode)] ?? e.charactersIgnoringModifiers?.uppercased() ?? "?"
        self.init(keyCode: Int(e.keyCode), m, key)
    }

    private static let names: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
        kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        // Letters by key position, so ⌥ combinations show "A" rather than "å".
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
        kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
        kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
    ]
}

enum ShortcutAction: String, CaseIterable {
    case selection, screenshot, image, voice, open

    var title: String {
        switch self {
        case .selection: return "Translate selected text"
        case .screenshot: return "Translate text on screen"
        case .image: return "Translate screen area in place"
        case .voice: return "Say a word or sentence"
        case .open: return "Open Ord"
        }
    }

    private var key: String { "shortcut.\(rawValue)" }

    private var defaultValue: Shortcut? {
        switch self {
        case .selection: return Shortcut(keyCode: kVK_ANSI_D, optionKey, "D")
        case .screenshot: return Shortcut(keyCode: kVK_ANSI_S, optionKey, "S")
        case .image: return Shortcut(keyCode: kVK_ANSI_S, optionKey | shiftKey, "S")
        case .voice: return Shortcut(keyCode: kVK_ANSI_A, optionKey, "A")
        case .open: return nil
        }
    }

    // Not set → the default; set to empty → turned off by the user.
    var shortcut: Shortcut? {
        get {
            guard let data = UserDefaults.standard.data(forKey: key) else { return defaultValue }
            return try? JSONDecoder().decode(Shortcut.self, from: data)
        }
        nonmutating set {
            UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) } ?? Data(), forKey: key)
        }
    }

    func perform() {
        switch self {
        case .selection: Selection.translate()
        case .screenshot: ScreenText.capture()
        case .image: ImageTranslate.capture()
        case .voice: VoiceLookup.shared.toggle()
        case .open: lookup("", at: .center)
        }
    }
}

// A button that shows a shortcut; click it, then press the new keys. Esc cancels, ⌫ clears.
struct ShortcutField: View {
    let action: ShortcutAction
    @ObservedObject private var input = Input.shared
    @State private var current: Shortcut?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            if input.taken.contains(action), !recording {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Another app already uses this shortcut. Choose a different one.")
            }
            Button(action: { recording ? stop() : start() }) {
                Text(recording ? "Press keys…" : current?.display ?? "None")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(recording ? AnyShapeStyle(.tint) : current == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .frame(minWidth: 84)
            }
            if current != nil, !recording {
                Button(action: { save(nil) }) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Remove shortcut")
            }
        }
        .onAppear { current = action.shortcut }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            if !recording { current = action.shortcut }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        Input.shared.paused = true  // so pressing the current shortcut doesn't trigger it
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            switch Int(e.keyCode) {
            case kVK_Escape: stop()
            case kVK_Delete where e.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty: save(nil); stop()
            default:
                if let s = Shortcut(event: e) { save(s); stop() } else { NSSound.beep() }
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        Input.shared.paused = false
    }

    private func save(_ s: Shortcut?) {
        // One shortcut can only do one thing: take it away from any other action.
        if let s { for other in ShortcutAction.allCases where other != action && other.shortcut == s { other.shortcut = nil } }
        action.shortcut = s
        current = s
    }
}
