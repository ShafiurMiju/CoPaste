import SwiftUI
import AppKit

enum SortOrder: String, CaseIterable, Identifiable {
    case newest = "Newest first"
    case oldest = "Oldest first"
    case largest = "Largest first"
    case smallest = "Smallest first"
    var id: String { rawValue }
}

final class ClipStore: ObservableObject {
    @Published var clips: [Clip] = []
    @Published var query: String = ""
    @Published var selectedID: Int64?
    @Published var selectedKind: ClipKind = .text
    @Published var sortOrder: SortOrder = .newest

    func reload() {
        let fresh = Database.shared.all()
        let apply: () -> Void = { [weak self] in
            guard let self else { return }
            self.clips = fresh
            // Keep current selection if still visible; otherwise pick the first row in the active tab.
            if let id = self.selectedID, self.filtered.contains(where: { $0.id == id }) {
                // keep
            } else {
                self.selectedID = self.filtered.first?.id
            }
            NSLog("[Copaste] ClipStore.reload clips=\(fresh.count) selected=\(String(describing: self.selectedID))")
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    var textCount: Int { clips.lazy.filter { $0.kind == .text }.count }
    var imageCount: Int { clips.lazy.filter { $0.kind == .image }.count }

    var filtered: [Clip] {
        let inTab = clips.filter { $0.kind == selectedKind }
        let searched: [Clip]
        if query.isEmpty {
            searched = inTab
        } else {
            let q = query.lowercased()
            searched = inTab.filter { clip in
                switch clip.kind {
                case .text:
                    return clip.text.lowercased().contains(q)
                case .image:
                    return "image".contains(q)
                }
            }
        }
        return searched.sorted { a, b in
            // Pinned items always float to the top, regardless of sort.
            if a.pinned != b.pinned { return a.pinned }
            switch sortOrder {
            case .newest:   return a.createdAt > b.createdAt
            case .oldest:   return a.createdAt < b.createdAt
            case .largest:  return sortSize(a) > sortSize(b)
            case .smallest: return sortSize(a) < sortSize(b)
            }
        }
    }

    private func sortSize(_ c: Clip) -> Int64 {
        c.kind == .image ? c.imageBytes : Int64(c.text.count)
    }

    func selectTab(_ kind: ClipKind) {
        guard kind != selectedKind else { return }
        selectedKind = kind
        selectedID = filtered.first?.id
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
    let onScreenshot: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            TabStrip(
                selected: store.selectedKind,
                textCount: store.textCount,
                imageCount: store.imageCount,
                onSelect: { store.selectTab($0) }
            )

            HStack(spacing: 8) {
                SearchField(text: $store.query, onSubmit: pickCurrent, onCancel: onClose,
                            onArrowDown: { move(1) }, onArrowUp: { move(-1) })

                Button(action: onScreenshot) {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Take Screenshot")

                Menu {
                    ForEach(SortOrder.allCases) { order in
                        Button {
                            store.sortOrder = order
                        } label: {
                            if store.sortOrder == order {
                                Label(order.rawValue, systemImage: "checkmark")
                            } else {
                                Text(order.rawValue)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Sort: \(store.sortOrder.rawValue)")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 8)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    if store.selectedKind == .text {
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
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 150), spacing: 10)],
                            spacing: 10
                        ) {
                            ForEach(store.filtered) { clip in
                                ImageTile(
                                    clip: clip,
                                    selected: store.selectedID == clip.id,
                                    onSelect: { store.selectedID = clip.id },
                                    onPick: { onPick(clip) },
                                    onPin: { store.togglePin(clip) },
                                    onDelete: { store.delete(clip) }
                                )
                                .id(clip.id)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
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
                leadingIcon

                VStack(alignment: .leading, spacing: 2) {
                    switch clip.kind {
                    case .text:
                        Text(clip.text.prefix(240).trimmingCharacters(in: .whitespacesAndNewlines))
                            .lineLimit(2)
                            .font(.system(size: 13))
                    case .image:
                        ImagePreview(clip: clip)
                    }
                    Text(subtitle)
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

    @ViewBuilder
    private var leadingIcon: some View {
        if clip.pinned {
            Image(systemName: "pin.fill")
                .foregroundStyle(.orange)
                .font(.caption)
                .padding(.top, 2)
        } else if clip.kind == .image {
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
                .font(.caption)
                .padding(.top, 2)
        } else {
            Image(systemName: "doc.on.doc")
                .foregroundStyle(.secondary)
                .font(.caption)
                .padding(.top, 2)
        }
    }

    private var subtitle: String {
        let when = relativeDate(clip.createdAt)
        switch clip.kind {
        case .text:
            return when
        case .image:
            return "\(imageMeta) • \(when)"
        }
    }

    private var imageMeta: String {
        let dims = (clip.imageWidth > 0 && clip.imageHeight > 0)
            ? "\(clip.imageWidth)×\(clip.imageHeight)"
            : "Image"
        let size = ByteCountFormatter.string(fromByteCount: clip.imageBytes, countStyle: .file)
        return "\(dims) • \(size)"
    }

    private func relativeDate(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }
}

private struct TabStrip: View {
    let selected: ClipKind
    let textCount: Int
    let imageCount: Int
    let onSelect: (ClipKind) -> Void

    var body: some View {
        HStack(spacing: 0) {
            // Left padding clears the traffic-light buttons.
            Color.clear.frame(width: 70, height: 1)

            HStack(spacing: 24) {
                tabButton(.text, label: "Text", count: textCount)
                tabButton(.image, label: "Images", count: imageCount)
            }

            Spacer()
        }
        .padding(.top, 6)
        .padding(.bottom, 0)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.secondary.opacity(0.18))
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private func tabButton(_ kind: ClipKind, label: String, count: Int) -> some View {
        let isActive = (selected == kind)
        Button(action: { onSelect(kind) }) {
            VStack(spacing: 4) {
                HStack(spacing: 5) {
                    Text(label)
                        .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                        .foregroundStyle(isActive ? Color.primary : Color.secondary)
                    Text("\(count)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(Color.secondary.opacity(0.15))
                        )
                }
                .padding(.bottom, 6)
                Rectangle()
                    .fill(isActive ? Color.accentColor : Color.clear)
                    .frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ImagePreview: View {
    let clip: Clip

    var body: some View {
        Group {
            if let data = clip.thumbnail, let img = NSImage(data: data) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 220, maxHeight: 80, alignment: .leading)
                    .cornerRadius(4)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 80, height: 60)
                    .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            }
        }
    }
}

private struct ImageTile: View {
    let clip: Clip
    let selected: Bool
    let onSelect: () -> Void
    let onPick: () -> Void
    let onPin: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Thumbnail surface — neutral checker-ish background so small
            // images don't look like they're floating.
            ZStack(alignment: .topTrailing) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.08))

                thumbnail
                    .padding(6)

                // Floating action buttons in the top-right of the thumbnail.
                HStack(spacing: 4) {
                    Button(action: onPin) {
                        Image(systemName: clip.pinned ? "pin.fill" : "pin")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(clip.pinned ? .orange : .white)
                            .frame(width: 22, height: 22)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help(clip.pinned ? "Unpin" : "Pin")

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .opacity(clip.pinned ? 0.35 : 1)
                    .disabled(clip.pinned)
                    .help(clip.pinned ? "Unpin first to delete" : "Delete")
                }
                .padding(6)
            }
            .frame(height: 110)
            .clipped()

            // Footer with dimensions + age, no inline buttons (use right-click).
            HStack(spacing: 6) {
                Text(dimensionsText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(relativeDate(clip.createdAt))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(Color(NSColor.controlBackgroundColor))
        }
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    selected ? Color.accentColor : Color.secondary.opacity(0.22),
                    lineWidth: selected ? 2 : 0.5
                )
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onPick() }
        .onTapGesture(count: 1) { onSelect() }
        .contextMenu {
            Button("Paste", action: onPick)
            Button(clip.pinned ? "Unpin" : "Pin", action: onPin)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
                .disabled(clip.pinned)
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let data = clip.thumbnail, let img = NSImage(data: data) {
            Image(nsImage: img)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Image(systemName: "photo")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var dimensionsText: String {
        if clip.imageWidth > 0 && clip.imageHeight > 0 {
            return "\(clip.imageWidth)×\(clip.imageHeight)"
        }
        return "Image"
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
