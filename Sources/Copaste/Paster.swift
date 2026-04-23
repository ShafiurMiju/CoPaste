import Cocoa
import Carbon.HIToolbox

enum Paster {
    static func copyAndPaste(_ text: String, into targetApp: NSRunningApplication?) {
        let pb = NSPasteboard.general
        pb.clearContents()
        // Mark as internal so ClipboardWatcher ignores it.
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("com.copaste.internal"))
        pb.setString(text, forType: .string)

        // Give the target app focus, then send Cmd+V.
        if let app = targetApp {
            app.activate(options: [])
        }

        // Tiny delay so the frontmost app is ready to receive the paste.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            simulateCmdV()
        }
    }

    private static func simulateCmdV() {
        guard AXIsProcessTrusted() else {
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
    }

    private static func promptForAccessibility() {
        let alert = NSAlert()
        alert.messageText = "Enable Accessibility for Copaste"
        alert.informativeText = """
            To paste automatically, Copaste needs Accessibility permission.

            Open System Settings → Privacy & Security → Accessibility,
            then enable Copaste.
            """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(url)
        }
    }
}
