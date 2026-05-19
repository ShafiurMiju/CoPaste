import Cocoa
import SwiftUI

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class PopupController: NSObject {
    // UserDefaults keys
    private static let alwaysOnTopKey      = "Copaste.alwaysOnTop"
    private static let widthKey            = "Copaste.windowWidth"
    private static let heightKey           = "Copaste.windowHeight"
    private static let xKey                = "Copaste.windowX"
    private static let yKey                = "Copaste.windowY"
    private static let rememberPositionKey = "Copaste.rememberPosition"

    // Size bounds — small enough to be usable in a corner, big enough that
    // a user with a 4K display can read clips comfortably.
    static let defaultWidth: CGFloat  = 500
    static let defaultHeight: CGFloat = 450
    static let minWidth: CGFloat      = 400
    static let minHeight: CGFloat     = 250
    static let maxWidth: CGFloat      = 1600
    static let maxHeight: CGFloat     = 1600

    private var panel: KeyablePanel?
    private var hostingView: NSHostingView<ClipListView>?
    private var previousApp: NSRunningApplication?
    private let store: ClipStore

    // MARK: - Persisted properties

    var alwaysOnTop: Bool {
        get {
            if UserDefaults.standard.object(forKey: Self.alwaysOnTopKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: Self.alwaysOnTopKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.alwaysOnTopKey)
            applyAlwaysOnTop()
        }
    }

    var windowWidth: CGFloat {
        get {
            let v = UserDefaults.standard.double(forKey: Self.widthKey)
            return v > 0 ? clampWidth(v) : Self.defaultWidth
        }
        set {
            UserDefaults.standard.set(Double(clampWidth(newValue)), forKey: Self.widthKey)
            applyDesiredSize()
        }
    }

    var windowHeight: CGFloat {
        get {
            let v = UserDefaults.standard.double(forKey: Self.heightKey)
            return v > 0 ? clampHeight(v) : Self.defaultHeight
        }
        set {
            UserDefaults.standard.set(Double(clampHeight(newValue)), forKey: Self.heightKey)
            applyDesiredSize()
        }
    }

    /// If true, the popup reopens at the spot the user last moved it to,
    /// instead of recentering on every show().
    var rememberPosition: Bool {
        get { UserDefaults.standard.bool(forKey: Self.rememberPositionKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.rememberPositionKey) }
    }

    private func clampWidth(_ v: CGFloat) -> CGFloat {
        max(Self.minWidth, min(Self.maxWidth, v))
    }
    private func clampHeight(_ v: CGFloat) -> CGFloat {
        max(Self.minHeight, min(Self.maxHeight, v))
    }

    private func savedOrigin() -> NSPoint? {
        guard
            let x = UserDefaults.standard.object(forKey: Self.xKey) as? Double,
            let y = UserDefaults.standard.object(forKey: Self.yKey) as? Double
        else { return nil }
        return NSPoint(x: x, y: y)
    }

    private func saveOrigin(_ p: NSPoint) {
        UserDefaults.standard.set(Double(p.x), forKey: Self.xKey)
        UserDefaults.standard.set(Double(p.y), forKey: Self.yKey)
    }

    // MARK: - Lifecycle

    init(store: ClipStore) {
        self.store = store
        super.init()
    }

    private func applyAlwaysOnTop() {
        guard let panel else { return }
        if alwaysOnTop {
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
        } else {
            panel.level = .normal
            panel.collectionBehavior = [.moveToActiveSpace]
            panel.hidesOnDeactivate = true
        }
    }

    /// One-shot migration: after a fresh install / first launch of a
    /// build that ships new defaults, wipe the stored window prefs so
    /// the user sees the new defaults instead of the values their
    /// previous build saved. The version sentinel key (`windowDefaultsV2`)
    /// only ever runs the migration once per upgrade.
    static func migrateDefaultsIfNeeded() {
        let key = "Copaste.windowDefaultsV2"
        if UserDefaults.standard.bool(forKey: key) { return }
        UserDefaults.standard.removeObject(forKey: widthKey)
        UserDefaults.standard.removeObject(forKey: heightKey)
        UserDefaults.standard.removeObject(forKey: xKey)
        UserDefaults.standard.removeObject(forKey: yKey)
        UserDefaults.standard.removeObject(forKey: rememberPositionKey)
        UserDefaults.standard.set(true, forKey: key)
    }

    /// Wipes window size, position, and "remember position" back to the
    /// shipping defaults and re-centers the panel on the active display.
    func resetWindowToDefaults() {
        UserDefaults.standard.removeObject(forKey: Self.widthKey)
        UserDefaults.standard.removeObject(forKey: Self.heightKey)
        UserDefaults.standard.removeObject(forKey: Self.xKey)
        UserDefaults.standard.removeObject(forKey: Self.yKey)
        UserDefaults.standard.removeObject(forKey: Self.rememberPositionKey)
        guard let panel else { return }
        let size = NSSize(width: Self.defaultWidth, height: Self.defaultHeight)
        let origin: NSPoint
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            origin = NSPoint(
                x: screen.visibleFrame.midX - size.width / 2,
                y: screen.visibleFrame.midY - size.height / 2
            )
        } else {
            origin = panel.frame.origin
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
    }

    /// Push the user's saved width/height into the live panel without
    /// changing its origin. Used when the settings page edits the size.
    private func applyDesiredSize() {
        guard let panel else { return }
        var frame = panel.frame
        let newSize = NSSize(width: windowWidth, height: windowHeight)
        // Keep the panel anchored at its top-left so a height change
        // doesn't visually shift it upward (AppKit origins are bottom-left).
        let top = frame.origin.y + frame.size.height
        frame.size = newSize
        frame.origin.y = top - newSize.height
        panel.setFrame(frame, display: true, animate: false)
    }

    func toggle() {
        if let panel, panel.isVisible {
            close()
        } else {
            show()
        }
    }

    func close() {
        panel?.orderOut(nil)
    }

    func show() {
        let candidate = NSWorkspace.shared.frontmostApplication
        if candidate?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = candidate
        }
        NSLog("[Copaste] popup.show() previousApp=\(previousApp?.localizedName ?? "nil")")

        store.query = ""
        store.reload()
        store.selectedID = store.filtered.first?.id

        if panel == nil { buildPanel() }

        let size = NSSize(width: windowWidth, height: windowHeight)
        let origin: NSPoint
        if rememberPosition, let saved = savedOrigin() {
            origin = clampToVisibleScreen(NSRect(origin: saved, size: size)).origin
        } else if let screen = NSScreen.main ?? NSScreen.screens.first {
            origin = NSPoint(
                x: screen.visibleFrame.midX - size.width / 2,
                y: screen.visibleFrame.midY - size.height / 2
            )
        } else {
            origin = NSPoint(x: 100, y: 100)
        }
        panel?.setFrame(NSRect(origin: origin, size: size), display: true)

        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        NSLog("[Copaste] panel visible=\(panel?.isVisible ?? false) key=\(panel?.isKeyWindow ?? false)")
    }

    /// Keep the saved origin from landing the panel partially off-screen
    /// when the user reconnects an external display or rotates the dock.
    private func clampToVisibleScreen(_ frame: NSRect) -> NSRect {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return frame }
        let vf = screen.visibleFrame
        var f = frame
        if f.maxX > vf.maxX { f.origin.x = vf.maxX - f.size.width }
        if f.minX < vf.minX { f.origin.x = vf.minX }
        if f.maxY > vf.maxY { f.origin.y = vf.maxY - f.size.height }
        if f.minY < vf.minY { f.origin.y = vf.minY }
        return f
    }

    private func buildPanel() {
        let view = ClipListView(
            store: store,
            onPick: { [weak self] clip in self?.pick(clip) },
            onClose: { [weak self] in self?.close() },
            onScreenshot: { [weak self] in
                self?.close()
                Screenshot.captureInteractive()
            },
            onEdit: { [weak self] clip in
                self?.close()
                ClipEditorController.shared.show(clip: clip, onClose: { [weak self] in
                    self?.show()
                })
            }
        )
        let host = NSHostingView(rootView: view)
        let p = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        // Disabled so SwiftUI .draggable on rows/tiles isn't hijacked by
        // window-drag. The user can still drag the panel via the title bar
        // strip at the top.
        p.isMovableByWindowBackground = false
        p.isReleasedWhenClosed = false
        p.contentView = host
        p.minSize = NSSize(width: Self.minWidth, height: Self.minHeight)
        p.maxSize = NSSize(width: Self.maxWidth, height: Self.maxHeight)
        // Belt-and-braces — with `.fullSizeContentView`, contentMinSize
        // is what the drag-resize handle actually checks against.
        p.contentMinSize = NSSize(width: Self.minWidth, height: Self.minHeight)
        p.contentMaxSize = NSSize(width: Self.maxWidth, height: Self.maxHeight)
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        p.backgroundColor = .windowBackgroundColor
        p.delegate = self
        self.panel = p
        self.hostingView = host
        applyAlwaysOnTop()
    }

    private func pick(_ clip: Clip) {
        close()
        switch clip.kind {
        case .text:
            Paster.copyAndPaste(clip.text, into: previousApp)
        case .image:
            if let data = Database.shared.imageData(for: clip) {
                Paster.copyAndPasteImage(data, into: previousApp)
            } else {
                NSLog("[Copaste] missing image data for clip id=\(clip.id)")
            }
        }
    }
}

// MARK: - NSWindowDelegate

extension PopupController: NSWindowDelegate {
    /// Authoritative bound on drag-resize. macOS's `minSize`/`maxSize`
    /// can be overridden by SwiftUI's intrinsic sizing or by full-size
    /// content-view edge cases — implementing the delegate method makes
    /// the clamp absolute.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(
            width: max(Self.minWidth, min(Self.maxWidth, frameSize.width)),
            height: max(Self.minHeight, min(Self.maxHeight, frameSize.height))
        )
    }

    func windowDidResize(_ notification: Notification) {
        guard let panel else { return }
        UserDefaults.standard.set(Double(panel.frame.size.width), forKey: Self.widthKey)
        UserDefaults.standard.set(Double(panel.frame.size.height), forKey: Self.heightKey)
        if rememberPosition {
            saveOrigin(panel.frame.origin)
        }
    }

    func windowDidMove(_ notification: Notification) {
        guard let panel else { return }
        // We always store the origin so that turning the "remember
        // position" toggle on later picks up the most recent move
        // without requiring the user to re-drag the window first.
        saveOrigin(panel.frame.origin)
    }
}
