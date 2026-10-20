import Cocoa
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let panel = TranslatorPanel()
    private var statusItem: NSStatusItem!

    func applicationWillFinishLaunching(_ n: Notification) {
        // ord://translate?text=…, ord://voice, ord://screenshot, ord://image, ord://selection (for scripts and Shortcuts)
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        Pref.register()
        installMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "character.book.closed", accessibilityDescription: "Ord")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        Input.shared.start()

        if !UserDefaults.standard.bool(forKey: "launchedBefore") {
            UserDefaults.standard.set(true, forKey: "launchedBefore")
            try? SMAppService.mainApp.register()
            if Pref.key.isEmpty { SettingsWindow.shared.show() }
        }
    }

    // Show the translator with some text, e.g. from a shortcut or the three-finger click.
    func lookup(_ text: String, at placement: TranslatorPanel.Placement = .pointer) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { Session.shared.clear() }
        panel.show(placement)
        if !t.isEmpty { Session.shared.run(t) }
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu() } else { panel.toggle() }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Ord", action: #selector(openPanel), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Quit Ord", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // Ord shows no menu bar of its own, but the menu's shortcuts (⌘C, ⌘V, ⌘A, ⌘Z, ⌘W, ⌘Q) still work in Settings.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: "Quit Ord", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        windowItem.submenu = NSMenu(title: "Window")
        windowItem.submenu?.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }

    @objc private func openPanel() { Session.shared.clear(); panel.show(.center) }
    @objc private func openSettings() { SettingsWindow.shared.show() }

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let c = URLComponents(string: s) else { return }
        switch c.host {
        case "voice": VoiceLookup.shared.toggle()        // ord://voice
        case "screenshot": ScreenText.capture()           // ord://screenshot
        case "image": ImageTranslate.capture()            // ord://image
        case "selection": Selection.translate()           // ord://selection
        default:                                          // ord://translate?text=…
            lookup(c.queryItems?.first { $0.name == "text" }?.value ?? "", at: .center)
        }
    }
}

// Called from shortcuts, the trackpad and voice; all of them run on the main thread.
func lookup(_ text: String, at placement: TranslatorPanel.Placement = .pointer) {
    MainActor.assumeIsolated { (NSApp.delegate as? AppDelegate)?.lookup(text, at: placement) }
}
