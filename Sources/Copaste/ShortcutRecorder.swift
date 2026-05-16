import AppKit
import SwiftUI
import Carbon.HIToolbox

final class ShortcutRecorderController {
    static let shared = ShortcutRecorderController()

    private var window: NSWindow?
    var onChange: ((Shortcut) -> Void)?

    func show() {
        if window == nil { build() }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let root = ShortcutRecorderView(
            onSave: { [weak self] sc in
                ShortcutStorage.save(sc)
                self?.onChange?(sc)
            },
            onReset: { [weak self] in
                ShortcutStorage.save(.default)
                self?.onChange?(.default)
            }
        )
        let host = NSHostingController(rootView: root)
        let w = NSWindow(contentViewController: host)
        w.title = "Copaste Shortcut"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.setContentSize(NSSize(width: 380, height: 210))
        // Sits above the popup's `.floating` level so the dialog stays
        // visible even when "Always on Top" is on for the popup.
        w.level = .modalPanel
        self.window = w
    }
}

struct ShortcutRecorderView: View {
    @State private var current: Shortcut = ShortcutStorage.load()
    @State private var recording: Bool = false
    @State private var monitor: Any?

    let onSave: (Shortcut) -> Void
    let onReset: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Text("Global Shortcut")
                .font(.headline)

            Button(action: startRecording) {
                Text(recording ? "Press keys…  (Esc to cancel)" : current.display)
                    .font(.system(size: 20, weight: .semibold, design: .monospaced))
                    .frame(minWidth: 220, minHeight: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(recording ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.10))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(recording ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            Text("Hold one or more modifier keys (⌘ ⇧ ⌥ ⌃) plus one letter or symbol.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

            HStack {
                Button("Reset to ⌘⇧V") {
                    current = .default
                    onReset()
                }
                Spacer()
                Button("Done") {
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        guard !recording else { return }
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Escape cancels recording
            if event.keyCode == UInt16(kVK_Escape) && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                stopRecording()
                return nil
            }
            if let sc = Shortcut.fromEvent(event) {
                current = sc
                onSave(sc)
                stopRecording()
                return nil
            }
            // Swallow modifier-only / invalid combos
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }
}
