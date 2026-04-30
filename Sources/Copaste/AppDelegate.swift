import Cocoa
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let watcher = ClipboardWatcher()
    private let store = ClipStore()
    private var popup: PopupController!
    private var showItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = Database.shared
        store.reload()

        popup = PopupController(store: store)

        watcher.onNewClip = { [weak self] payload in
            switch payload {
            case .text(let s):
                Database.shared.insert(s)
            case .image(let data):
                Database.shared.insertImage(data)
            }
            self?.store.reload()
        }
        watcher.start()

        HotKeyManager.shared.onHotKey = { [weak self] in
            NSLog("[Copaste] onHotKey callback, toggling popup")
            self?.popup.toggle()
        }
        HotKeyManager.shared.register(ShortcutStorage.load())

        ShortcutRecorderController.shared.onChange = { [weak self] sc in
            HotKeyManager.shared.register(sc)
            self?.refreshShortcutLabel()
        }

        ClipEditorController.shared.onSave = { [weak self] id, newText in
            self?.store.updateText(id: id, newText: newText)
        }

        SettingsController.shared.onApply = { [weak self] in
            self?.store.reload()
        }

        NSLog("[Copaste] app launched, hotkey registered")

        buildMenuBar()
    }

    private func refreshShortcutLabel() {
        let sc = HotKeyManager.shared.current
        showItem?.title = "Show Copaste  (\(sc.display))"
    }

    private func buildMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Copaste")
        }

        let menu = NSMenu()
        let show = NSMenuItem(
            title: "Show Copaste  (\(HotKeyManager.shared.current.display))",
            action: #selector(showPopup),
            keyEquivalent: ""
        )
        menu.addItem(show)
        self.showItem = show

        menu.addItem(withTitle: "Change Shortcut…", action: #selector(openShortcutRecorder), keyEquivalent: "")
        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(loginItem)

        let aotItem = NSMenuItem(title: "Always on Top", action: #selector(toggleAlwaysOnTop), keyEquivalent: "")
        aotItem.state = popup.alwaysOnTop ? .on : .off
        menu.addItem(aotItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Take Screenshot…", action: #selector(takeScreenshot), keyEquivalent: "")
        menu.addItem(withTitle: "Storage Limits…", action: #selector(openStorageLimits), keyEquivalent: "")
        menu.addItem(withTitle: "Clear Unpinned History", action: #selector(clearHistory), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Copaste", action: #selector(quit), keyEquivalent: "q")

        for item in menu.items where item.action != nil {
            item.target = self
        }
        statusItem.menu = menu
    }

    @objc private func showPopup() { popup.toggle() }

    @objc private func openShortcutRecorder() {
        ShortcutRecorderController.shared.show()
    }

    @objc private func takeScreenshot() {
        popup.close()
        Screenshot.captureInteractive()
    }

    @objc private func openStorageLimits() {
        SettingsController.shared.show()
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear all unpinned clips?"
        alert.informativeText = "Pinned items will be kept."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            Database.shared.clearUnpinned()
            store.reload()
        }
    }

    @objc private func toggleAlwaysOnTop(_ sender: NSMenuItem) {
        popup.alwaysOnTop.toggle()
        sender.state = popup.alwaysOnTop ? .on : .off
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                sender.state = .off
            } else {
                try SMAppService.mainApp.register()
                sender.state = .on
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
