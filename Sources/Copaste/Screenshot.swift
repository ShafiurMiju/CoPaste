import Foundation
import Carbon.HIToolbox
import CoreGraphics

enum Screenshot {
    /// Triggers macOS's built-in interactive screenshot-to-clipboard
    /// (⌘⇧⌃4) by posting the keystroke instead of launching
    /// `/usr/sbin/screencapture` as a child process. TCC attributes child
    /// processes to their parent, so spawning screencapture makes macOS
    /// demand Screen Recording permission from Copaste — and that grant
    /// breaks on every signature change. Routing through the system
    /// shortcut lets the OS handle the capture itself, so no Screen
    /// Recording prompt is ever attributed to us. We already require
    /// Accessibility for paste, which is also what lets us post this
    /// keystroke.
    static func captureInteractive() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let key4 = CGKeyCode(kVK_ANSI_4)
        let flags: CGEventFlags = [.maskCommand, .maskShift, .maskControl]
        let down = CGEvent(keyboardEventSource: src, virtualKey: key4, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: key4, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        NSLog("[Copaste] posted ⌘⇧⌃4 for interactive screenshot")
    }
}
