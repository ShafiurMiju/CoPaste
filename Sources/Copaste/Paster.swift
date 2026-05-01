import Cocoa
import Carbon.HIToolbox

enum Paster {
    static func copyAndPaste(_ text: String, into targetApp: NSRunningApplication?) {
        let pb = NSPasteboard.general
        pb.clearContents()
        // Mark as internal so ClipboardWatcher ignores it.
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("com.copaste.internal"))
        pb.setString(text, forType: .string)
        focusAndPaste(targetApp)
    }

    static func copyAndPasteImage(_ data: Data, into targetApp: NSRunningApplication?) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("com.copaste.internal"))
        pb.setData(data, forType: .png)
        // Some apps prefer TIFF; provide both so paste works in the widest range of targets.
        if let img = NSImage(data: data), let tiff = img.tiffRepresentation {
            pb.setData(tiff, forType: .tiff)
        }
        focusAndPaste(targetApp)
    }

    private static func focusAndPaste(_ targetApp: NSRunningApplication?) {
        // Hand focus back to the app the user was in. macOS Sonoma+ requires
        // this call to come from an app with user-initiated focus — that's us
        // right now because the user just hit the global shortcut.
        if let app = targetApp {
            app.activate(options: [.activateAllWindows])
        }
        // 50 ms isn't always enough for the previous app to regain keyboard
        // focus before we post ⌘V — especially under load or with apps that
        // restore many windows. 150 ms is reliable in practice without being
        // perceptible.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            simulateCmdV()
        }
    }

    private static func simulateCmdV() {
        guard AXIsProcessTrusted() else {
            // The clip is already on the system pasteboard, so the user can
            // press ⌘V manually right now. We just can't post the keystroke
            // for them. Show the standard "grant Accessibility" prompt.
            promptForAccessibility()
            return
        }
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        NSLog("[Copaste] posted ⌘V")
    }

    private static func promptForAccessibility() {
        let alert = NSAlert()
        alert.messageText = "Enable Accessibility for Copaste"
        alert.informativeText = """
            Copaste needs Accessibility permission to paste into other apps for you.

            Open System Settings → Privacy & Security → Accessibility, then toggle Copaste ON.

            (Your clip is already on the clipboard — press ⌘V to paste manually in the meantime.)
            """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(url)
        }
    }
}
