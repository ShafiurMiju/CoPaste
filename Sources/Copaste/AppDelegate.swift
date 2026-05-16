import Cocoa
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let watcher = ClipboardWatcher()
    let store = ClipStore()
    var popup: PopupController!
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
        statusItem.menu = buildAppMenu()
    }

    /// Builds a fresh app menu — used by the status-bar item and by the
    /// gear button in the popup. Rebuilt on each call so toggle states
    /// (Launch at Login, Always on Top) reflect current values.
    private func buildAppMenu() -> NSMenu {
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
        menu.addItem(withTitle: "Reset Accessibility Permission…", action: #selector(resetAccessibility), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Copaste", action: #selector(quit), keyEquivalent: "q")

        for item in menu.items where item.action != nil {
            item.target = self
        }
        return menu
    }

    @objc private func showPopup() { popup.toggle() }

    @objc func openShortcutRecorder() {
        ShortcutRecorderController.shared.show()
    }

    @objc private func takeScreenshot() {
        popup.close()
        Screenshot.captureInteractive()
    }

    @objc private func openStorageLimits() {
        SettingsController.shared.show()
    }

    @objc func resetAccessibility() {
        let alert = NSAlert()
        alert.messageText = "Reset Accessibility permission?"
        alert.informativeText = """
            This wipes Copaste's saved permission and quits the app.

            Use this if Accessibility shows Copaste as enabled but pasting still doesn't work — that means macOS has a stale grant tied to an older build. After Copaste reopens, paste once and click Allow when macOS prompts you fresh.
            """
        alert.addButton(withTitle: "Reset & Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let bundleID = Bundle.main.bundleIdentifier ?? "com.copaste.app"
        let reset = Process()
        reset.launchPath = "/usr/bin/tccutil"
        reset.arguments = ["reset", "Accessibility", bundleID]
        do {
            try reset.run()
            reset.waitUntilExit()
            NSLog("[Copaste] tccutil reset Accessibility \(bundleID) → \(reset.terminationStatus)")
        } catch {
            NSLog("[Copaste] tccutil reset failed: \(error)")
        }

        // Fork a fresh instance, then exit. macOS only honours the new (clean)
        // TCC state in a process started after the reset.
        let appURL = Bundle.main.bundleURL
        let relaunch = Process()
        relaunch.launchPath = "/usr/bin/open"
        relaunch.arguments = ["-n", appURL.path]
        try? relaunch.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.terminate(nil)
        }
    }

    @objc func resetScreenRecording() {
        let alert = NSAlert()
        alert.messageText = "Reset Screen Recording permission?"
        alert.informativeText = """
            This wipes Copaste's saved Screen Recording permission and quits the app.

            Use this if macOS keeps prompting for Screen Recording even though you've already allowed it — that means the saved grant is tied to an older build. After Copaste reopens, copy a screenshot to trigger the prompt and click Allow when macOS asks.
            """
        alert.addButton(withTitle: "Reset & Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let bundleID = Bundle.main.bundleIdentifier ?? "com.copaste.app"
        let reset = Process()
        reset.launchPath = "/usr/bin/tccutil"
        reset.arguments = ["reset", "ScreenCapture", bundleID]
        do {
            try reset.run()
            reset.waitUntilExit()
            NSLog("[Copaste] tccutil reset ScreenCapture \(bundleID) → \(reset.terminationStatus)")
        } catch {
            NSLog("[Copaste] tccutil reset failed: \(error)")
        }

        let appURL = Bundle.main.bundleURL
        let relaunch = Process()
        relaunch.launchPath = "/usr/bin/open"
        relaunch.arguments = ["-n", appURL.path]
        try? relaunch.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.terminate(nil)
        }
    }

    @objc func clearHistory() {
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
