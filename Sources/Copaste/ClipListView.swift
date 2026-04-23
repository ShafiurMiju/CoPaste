import SwiftUI
import AppKit

final class ClipStore: ObservableObject {
    @Published var clips: [Clip] = []
    @Published var query: String = ""
    @Published var selectedID: Int64?

    func reload() {
        let fresh = Database.shared.all()
        let apply: () -> Void = { [weak self] in
            guard let self else { return }
            self.clips = fresh
            // Keep current selection if still present; otherwise pick the first visible row.
            if let id = self.selectedID, fresh.contains(where: { $0.id == id }) {
                // keep
            } else {
                self.selectedID = self.filtered.first?.id
            }
            NSLog("[Copaste] ClipStore.reload clips=\(fresh.count) selected=\(String(describing: self.selectedID))")
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    var filtered: [Clip] {
        guard !query.isEmpty else { return clips }
        let q = query.lowercased()
        return clips.filter { $0.text.lowercased().contains(q) }
    }

    func togglePin(_ clip: Clip) {
        NSLog("[Copaste] togglePin id=\(clip.id) currentlyPinned=\(clip.pinned)")
        Database.shared.togglePin(id: clip.id)
        reload()
    }

    func delete(_ clip: Clip) {
        guard !clip.pinned else {
            NSLog("[Copaste] delete ignored, pinned id=\(clip.id)")
            return
        }
        NSLog("[Copaste] delete id=\(clip.id)")
        Database.shared.delete(id: clip.id)
        reload()
    }

    func move(_ clip: Clip, _ dir: Database.MoveDirection) {
        NSLog("[Copaste] move id=\(clip.id) dir=\(dir)")
        if Database.shared.move(id: clip.id, direction: dir) {
            reload()
        }
    }
}

struct ClipListView: View {
    @ObservedObject var store: ClipStore
    let onPick: (Clip) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SearchField(text: $store.query, onSubmit: pickCurrent, onCancel: onClose,
                        onArrowDown: { move(1) }, onArrowUp: { move(-1) })
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.filtered) { clip in
                            Row(
                                clip: clip,
                                selected: store.selectedID == clip.id,
                                onClick: { onPick(clip) },
                                onPin: { store.togglePin(clip) },
                                onDelete: { store.delete(clip) }
                            )
                            .id(clip.id)
                        }
                    }
                }
                .onChange(of: store.selectedID) { new in
                    guard let new else { return }
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(new, anchor: .center)
                    }
                }
            }

            Divider()
            HStack(spacing: 12) {
                Label("↩ paste", systemImage: "return").labelStyle(.titleOnly)
                Label("⌘P pin", systemImage: "pin").labelStyle(.titleOnly)
                Label("⌘⌫ delete", systemImage: "delete.left").labelStyle(.titleOnly)
                Label("⌥↑↓ reorder", systemImage: "arrow.up.arrow.down").labelStyle(.titleOnly)
                Spacer()
                Text("\(store.filtered.count) items").foregroundStyle(.secondary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(KeyCatcher(
            onEnter: pickCurrent,
            onEscape: onClose,
            onUp: { move(-1) },
            onDown: { move(1) },
            onPin: pinCurrent,
            onDelete: deleteCurrent,
            onMoveUp: { moveCurrentItem(.up) },
            onMoveDown: { moveCurrentItem(.down) }
        ))
    }

    private func moveCurrentItem(_ dir: Database.MoveDirection) {
        guard let idx = currentIndex() else { return }
        store.move(store.filtered[idx], dir)
    }

    private func currentIndex() -> Int? {
        let items = store.filtered
        guard let id = store.selectedID else { return items.isEmpty ? nil : 0 }
        return items.firstIndex(where: { $0.id == id })
    }

    private func move(_ delta: Int) {
        let items = store.filtered
        guard !items.isEmpty else { return }
        let n = items.count
        let cur = currentIndex() ?? 0
        let next = ((cur + delta) % n + n) % n
        store.selectedID = items[next].id
    }

    private func pickCurrent() {
        guard let idx = currentIndex() else { return }
        onPick(store.filtered[idx])
    }

    private func pinCurrent() {
        guard let idx = currentIndex() else { return }
        store.togglePin(store.filtered[idx])
    }

    private func deleteCurrent() {
        guard let idx = currentIndex() else { return }
        let items = store.filtered
        let nextID: Int64? = idx + 1 < items.count ? items[idx + 1].id
            : (idx > 0 ? items[idx - 1].id : nil)
        store.delete(items[idx])
        store.selectedID = nextID
    }
}

private struct Row: View {
    let clip: Clip
    let selected: Bool
    let onClick: () -> Void
    let onPin: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                if clip.pinned {
                    Image(systemName: "pin.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                        .padding(.top, 2)
                } else {
                    Image(systemName: "doc.on.doc")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .padding(.top, 2)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(clip.text.prefix(240).trimmingCharacters(in: .whitespacesAndNewlines))
                        .lineLimit(2)
                        .font(.system(size: 13))
                    Text(relativeDate(clip.createdAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { onClick() }

            HStack(spacing: 4) {
                Button {
                    NSLog("[Copaste] pin button tapped id=\(clip.id)")
                    onPin()
                } label: {
                    Image(systemName: clip.pinned ? "pin.slash.fill" : "pin")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(clip.pinned ? .orange : .secondary)
                .help(clip.pinned ? "Unpin" : "Pin")

                Button {
                    NSLog("[Copaste] delete button tapped id=\(clip.id) pinned=\(clip.pinned)")
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(clip.pinned ? Color.secondary.opacity(0.35) : .red.opacity(0.75))
                .disabled(clip.pinned)
                .help(clip.pinned ? "Unpin first to delete" : "Delete")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(selected ? Color.accentColor.opacity(0.18) : Color.clear)
    }

    private func relativeDate(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }
}

// MARK: - Search field (SwiftUI doesn't handle arrow keys on TextField nicely)

private struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    let onCancel: () -> Void
    let onArrowDown: () -> Void
    let onArrowUp: () -> Void

    func makeNSView(context: Context) -> NSSearchField {
        let f = NSSearchField()
        f.placeholderString = "Search clipboard history…"
        f.delegate = context.coordinator
        f.bezelStyle = .roundedBezel
        f.focusRingType = .none
        DispatchQueue.main.async { f.window?.makeFirstResponder(f) }
        return f
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
    }

    func makeCoordinator() -> Coord { Coord(self) }

    final class Coord: NSObject, NSSearchFieldDelegate {
        let parent: SearchField
        init(_ p: SearchField) { self.parent = p }

        func controlTextDidChange(_ obj: Notification) {
            if let f = obj.object as? NSSearchField {
                parent.text = f.stringValue
            }
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit(); return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel(); return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onArrowDown(); return true
            case #selector(NSResponder.moveUp(_:)):
                parent.onArrowUp(); return true
            default:
                return false
            }
        }
    }
}

// MARK: - Global key catcher (for Cmd+P pin, Backspace delete)

private struct KeyCatcher: NSViewRepresentable {
    let onEnter: () -> Void
    let onEscape: () -> Void
    let onUp: () -> Void
    let onDown: () -> Void
    let onPin: () -> Void
    let onDelete: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    func makeNSView(context: Context) -> NSView {
        let v = KeyView()
        v.onEnter = onEnter
        v.onEscape = onEscape
        v.onUp = onUp
        v.onDown = onDown
        v.onPin = onPin
        v.onDelete = onDelete
        v.onMoveUp = onMoveUp
        v.onMoveDown = onMoveDown
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class KeyView: NSView {
        var onEnter: (() -> Void)?
        var onEscape: (() -> Void)?
        var onUp: (() -> Void)?
        var onDown: (() -> Void)?
        var onPin: (() -> Void)?
        var onDelete: (() -> Void)?
        var onMoveUp: (() -> Void)?
        var onMoveDown: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let w = self.window, w.isKeyWindow else { return event }
                let mods = event.modifierFlags
                let code = Int(event.keyCode)

                // Option+Up / Option+Down → reorder selected clip
                if mods.contains(.option), !mods.contains(.command) {
                    if code == 126 { self.onMoveUp?(); return nil }    // ↑
                    if code == 125 { self.onMoveDown?(); return nil }  // ↓
                }

                if mods.contains(.command),
                   event.charactersIgnoringModifiers?.lowercased() == "p" {
                    self.onPin?()
                    return nil
                }
                if code == 51, mods.contains(.command) { // Cmd+Backspace
                    self.onDelete?()
                    return nil
                }
                return event
            }
        }
    }
}
