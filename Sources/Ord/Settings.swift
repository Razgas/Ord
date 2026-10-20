import Cocoa
import SwiftUI
import ServiceManagement
import Carbon

// All preferences live in UserDefaults; SettingsView edits the same keys with @AppStorage.
enum Pref {
    static let geminiKey = "geminiKey"
    static let geminiModel = "geminiModel"
    static let autoSpeak = "autoSpeak"
    static let threeFinger = "threeFinger"
    static let learning = "learning"  // language code, e.g. "da"
    static let native = "native"      // language code, e.g. "en"
    static let extra = "extra"        // one more language every lookup is also translated into, e.g. "fa"; "" = none

    static let defaultModel = "gemini-3.5-flash-lite"

    static func register() {
        UserDefaults.standard.register(defaults: [
            geminiModel: defaultModel, autoSpeak: true, threeFinger: true, learning: "da", native: "en",
        ])
        // Version 0.1 had one setting for all three shortcuts.
        if let old = d.string(forKey: "shortcuts") {
            for (a, key) in [(ShortcutAction.voice, "A"), (.screenshot, "S"), (.selection, "D")] {
                let code = [ "A": 0, "S": 1, "D": 2 ][key]!
                a.shortcut = old == "off" ? nil
                    : Shortcut(keyCode: code, old == "control+option" ? optionKey | controlKey : optionKey, key)
            }
            d.removeObject(forKey: "shortcuts")
        }
    }

    static var d: UserDefaults { .standard }
    static var key: String { d.string(forKey: geminiKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    static var model: String {
        let m = d.string(forKey: geminiModel)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return m.isEmpty ? defaultModel : m
    }
}

struct SettingsView: View {
    @AppStorage(Pref.geminiKey) private var key = ""
    @AppStorage(Pref.geminiModel) private var model = Pref.defaultModel
    @AppStorage(Pref.autoSpeak) private var autoSpeak = true
    @AppStorage(Pref.threeFinger) private var threeFinger = true
    @AppStorage(Pref.learning) private var learning = "da"
    @AppStorage(Pref.native) private var native = "en"
    @AppStorage(Pref.extra) private var extra = ""
    @AppStorage(DeepL.keyPref) private var deeplKey = ""
    @AppStorage(Service.deepl.prefKey) private var deeplOn = false
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        TabView {
            Form {
                Section {
                    languagePicker("I'm learning", $learning)
                    languagePicker("My language", $native)
                    Picker("Also translate into", selection: $extra) {
                        Text("None").tag("")
                        Divider()
                        ForEach(Language.all) { Text($0.name).tag($0.code) }
                    }
                } header: {
                    Text("Languages")
                } footer: {
                    Text("Ord translates both ways and works out by itself which language you typed. "
                         + "With another language chosen, every lookup also shows a translation into it.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .onChange(of: learning) { old, new in if new == native { native = old } }
                .onChange(of: native) { old, new in if new == learning { learning = old } }

                Section("General") {
                    Toggle("Read words and short sentences aloud", isOn: $autoSpeak)
                    Toggle("Open at login", isOn: $openAtLogin)
                        .onChange(of: openAtLogin) { _, on in
                            try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                        }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Section {
                    SecureField("API key", text: $key)
                    ModelPicker(key: key, model: $model)
                } header: {
                    Text("Gemini")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if key.isEmpty {
                            Text("Ord needs your own Gemini API key. It is free and stays on this Mac.")
                                .foregroundStyle(.secondary)
                        }
                        Link("Get a free API key at Google AI Studio",
                             destination: URL(string: "https://aistudio.google.com/apikey")!)
                    }
                    .font(.footnote)
                }

                Section {
                    ForEach(Service.allCases) { ServiceToggle(service: $0) }
                    if deeplOn {
                        SecureField("DeepL API key", text: $deeplKey)
                    }
                } header: {
                    Text("Services")
                } footer: {
                    if deeplOn {
                        Link("Get a free DeepL API key", destination: URL(string: "https://www.deepl.com/pro-api")!)
                            .font(.footnote)
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Services", systemImage: "globe") }

            Form {
                Section {
                    ForEach(ShortcutAction.allCases, id: \.self) { a in
                        LabeledContent(a.title) { ShortcutField(action: a) }
                    }
                    Toggle("Three-finger click translates the word under the pointer", isOn: $threeFinger)
                } header: {
                    Text("Shortcuts")
                } footer: {
                    Text("Click a shortcut, then press the new keys. Esc cancels, ⌫ removes it.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        // A fixed size that fits small screens; a tab with more in it scrolls.
        .frame(width: 520, height: 460)
    }

    private func languagePicker(_ title: String, _ value: Binding<String>) -> some View {
        Picker(title, selection: value) {
            ForEach(Language.all) { Text($0.name).tag($0.code) }
        }
    }
}

struct ServiceToggle: View {
    let service: Service
    @AppStorage private var on: Bool

    init(service: Service) {
        self.service = service
        _on = AppStorage(wrappedValue: service.defaultOn, service.prefKey)
    }

    var body: some View {
        Toggle(isOn: $on) {
            Text(service.name)
            Text(service.detail)
        }
    }
}

final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "Ord Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// The models come from Google for the key that is entered, so the list is always current.
// Without a key, or when the list can't be fetched, the model name can still be typed.
struct ModelPicker: View {
    let key: String
    @Binding var model: String
    @State private var models: [Gemini.Model] = []
    @State private var failed = false

    var body: some View {
        Group {
            if failed || key.isEmpty {
                TextField("Model", text: $model)
            } else {
                Picker("Model", selection: $model) {
                    ForEach(models, id: \.id) { m in
                        Text(m.id == Pref.defaultModel ? "\(m.name) (default)" : m.name).tag(m.id)
                    }
                    if !models.contains(where: { $0.id == model }) { Text(model).tag(model) }  // still loading, or not listed
                }
            }
        }
        .task(id: key) {
            let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !k.isEmpty else { return }
            try? await Task.sleep(nanoseconds: 400_000_000)  // wait until the key is typed or pasted completely
            do { models = try await Gemini.models(key: k); failed = models.isEmpty }
            catch { if !Task.isCancelled { failed = true } }
        }
    }
}
