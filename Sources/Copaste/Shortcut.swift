import AppKit
import Carbon.HIToolbox

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32      // virtual key code (Carbon / kVK_*)
    var modifiers: UInt32    // Carbon modifier mask
    var display: String      // rendered label, e.g. "⌘⇧V"

    static let `default` = Shortcut(
        keyCode: UInt32(kVK_ANSI_V),
        modifiers: UInt32(cmdKey | shiftKey),
        display: "⌘⇧V"
    )

    static func fromEvent(_ event: NSEvent) -> Shortcut? {
        var carbon: UInt32 = 0
        let f = event.modifierFlags
        if f.contains(.command) { carbon |= UInt32(cmdKey) }
        if f.contains(.shift)   { carbon |= UInt32(shiftKey) }
        if f.contains(.option)  { carbon |= UInt32(optionKey) }
        if f.contains(.control) { carbon |= UInt32(controlKey) }

        // Require at least one modifier to avoid hijacking plain keys
        guard carbon != 0 else { return nil }

        var label = ""
        if f.contains(.control) { label += "⌃" }
        if f.contains(.option)  { label += "⌥" }
        if f.contains(.shift)   { label += "⇧" }
        if f.contains(.command) { label += "⌘" }

        let keyChar = keyLabel(for: event)
        guard !keyChar.isEmpty else { return nil }
        label += keyChar

        return Shortcut(
            keyCode: UInt32(event.keyCode),
            modifiers: carbon,
            display: label
        )
    }
}

enum ShortcutStorage {
    private static let key = "Copaste.hotkey.v1"

    static func load() -> Shortcut {
        guard
            let data = UserDefaults.standard.data(forKey: key),
            let s = try? JSONDecoder().decode(Shortcut.self, from: data)
        else { return .default }
        return s
    }

    static func save(_ s: Shortcut) {
        if let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

private func keyLabel(for event: NSEvent) -> String {
    if let named = specialKeyNames[Int(event.keyCode)] {
        return named
    }
    // Use the uppercase character the key produces without modifiers
    if let c = event.charactersIgnoringModifiers, !c.isEmpty {
        return c.uppercased()
    }
    return ""
}

private let specialKeyNames: [Int: String] = [
    kVK_Return:       "↩",
    kVK_Tab:          "⇥",
    kVK_Space:        "Space",
    kVK_Delete:       "⌫",
    kVK_Escape:       "⎋",
    kVK_ForwardDelete:"⌦",
    kVK_LeftArrow:    "←",
    kVK_RightArrow:   "→",
    kVK_UpArrow:      "↑",
    kVK_DownArrow:    "↓",
    kVK_Home:         "↖",
    kVK_End:          "↘",
    kVK_PageUp:       "⇞",
    kVK_PageDown:     "⇟",
    kVK_F1:  "F1",  kVK_F2:  "F2",  kVK_F3:  "F3",  kVK_F4:  "F4",
    kVK_F5:  "F5",  kVK_F6:  "F6",  kVK_F7:  "F7",  kVK_F8:  "F8",
    kVK_F9:  "F9",  kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
]
