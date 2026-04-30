import AppKit
import SwiftUI

final class ClipEditorController {
    static let shared = ClipEditorController()

    private var window: NSWindow?
    var onSave: ((Int64, String) -> Void)?

    func show(clip: Clip) {
        if window == nil { build() }
        guard let w = window else { return }

        let view = ClipEditorView(
            clip: clip,
            onSave: { [weak self] newText in
                self?.onSave?(clip.id, newText)
                w.close()
            },
            onCancel: { w.close() }
        )
        let host = NSHostingController(rootView: view)
        w.contentViewController = host
        w.title = "Edit Clip"

        NSApp.activate(ignoringOtherApps: true)
        w.center()
        w.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.isReleasedWhenClosed = false
        self.window = w
    }
}

private struct ClipEditorView: View {
    let clip: Clip
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var text: String

    init(clip: Clip, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.clip = clip
        self.onSave = onSave
        self.onCancel = onCancel
        _text = State(initialValue: clip.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit clip")
                .font(.headline)

            TextEditor(text: $text)
                .font(.system(size: 13, design: clip.isPassword ? .monospaced : .default))
                .padding(6)
                .frame(minHeight: 220)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )

            HStack {
                Text("\(text.count) characters")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(text)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || text == clip.text
                )
            }
        }
        .padding(16)
        .frame(width: 520, height: 360)
    }
}
