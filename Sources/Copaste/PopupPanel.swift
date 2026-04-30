import Cocoa
import SwiftUI

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class PopupController {
    private static let alwaysOnTopKey = "Copaste.alwaysOnTop"

    private var panel: KeyablePanel?
    private var hostingView: NSHostingView<ClipListView>?
    private var previousApp: NSRunningApplication?
    private let store: ClipStore

    var alwaysOnTop: Bool {
        get {
            if UserDefaults.standard.object(forKey: Self.alwaysOnTopKey) == nil {
                return true // default on
            }
            return UserDefaults.standard.bool(forKey: Self.alwaysOnTopKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.alwaysOnTopKey)
            applyAlwaysOnTop()
        }
    }

    init(store: ClipStore) {
        self.store = store
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

    private func show() {
        previousApp = NSWorkspace.shared.frontmostApplication
        NSLog("[Copaste] popup.show() previousApp=\(previousApp?.localizedName ?? "nil")")

        store.query = ""
        store.reload()
        store.selectedID = store.filtered.first?.id

        if panel == nil { buildPanel() }

        let screen = NSScreen.main ?? NSScreen.screens.first
        if let screen {
            let size = NSSize(width: 520, height: 520)
            let origin = NSPoint(
                x: screen.visibleFrame.midX - size.width / 2,
                y: screen.visibleFrame.midY - size.height / 2
            )
            panel?.setFrame(NSRect(origin: origin, size: size), display: true)
        }

        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        NSLog("[Copaste] panel visible=\(panel?.isVisible ?? false) key=\(panel?.isKeyWindow ?? false)")
    }

    private func buildPanel() {
        let view = ClipListView(
            store: store,
            onPick: { [weak self] clip in self?.pick(clip) },
            onClose: { [weak self] in self?.close() },
            onScreenshot: { [weak self] in
                self?.close()
                Screenshot.captureInteractive()
            }
        )
        let host = NSHostingView(rootView: view)
        let p = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.isReleasedWhenClosed = false
        p.contentView = host
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        p.backgroundColor = .windowBackgroundColor
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
