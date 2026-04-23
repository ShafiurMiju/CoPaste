import Cocoa
import Carbon.HIToolbox

final class HotKeyManager {
    static let shared = HotKeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var handlerInstalled = false
    var onHotKey: (() -> Void)?

    private(set) var current: Shortcut = .default

    private init() {}

    func register(_ shortcut: Shortcut) {
        if !handlerInstalled {
            var spec = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            let status = InstallEventHandler(
                GetApplicationEventTarget(),
                { (_, _, userData) -> OSStatus in
                    guard let userData else { return OSStatus(eventNotHandledErr) }
                    let mgr = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                    DispatchQueue.main.async { mgr.onHotKey?() }
                    return noErr
                },
                1,
                &spec,
                Unmanaged.passUnretained(self).toOpaque(),
                nil
            )
            NSLog("[Copaste] InstallEventHandler status=\(status)")
            handlerInstalled = true
        }

        unregister()

        let hotKeyID = EventHotKeyID(signature: OSType(0x43505354), id: 1) // 'CPST'
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        NSLog("[Copaste] RegisterEventHotKey status=\(status) keyCode=\(shortcut.keyCode) mods=\(shortcut.modifiers) display=\(shortcut.display)")
        current = shortcut
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }
}
