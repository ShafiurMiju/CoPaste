import SwiftUI
import AppKit

enum SortOrder: String, CaseIterable, Identifiable {
    case newest = "Newest first"
    case oldest = "Oldest first"
    case largest = "Largest first"
    case smallest = "Smallest first"
    var id: String { rawValue }
}

enum DateFilter: String, CaseIterable, Identifiable {
    case all = "All time"
    case today = "Today"
    case yesterday = "Yesterday"
    case last7 = "Last 7 days"
    case last30 = "Last 30 days"
    case specific = "Specific date"
    var id: String { rawValue }

    static var presets: [DateFilter] { [.all, .today, .yesterday, .last7, .last30] }
}

enum AppTab: Hashable { case text, image, groups }

final class ClipStore: ObservableObject {
    @Published var clips: [Clip] = []
    @Published var groups: [ClipGroup] = []
    @Published var query: String = ""
    @Published var selectedID: Int64?
    @Published var selectedKind: ClipKind = .text
    @Published var selectedTab: AppTab = .text
    @Published var openedGroup: ClipGroup?
    @Published var sortOrder: SortOrder = .newest
    @Published var dateFilter: DateFilter = .all
    @Published var specificDate: Date = Date()

    func reload() {
        let freshClips = Database.shared.all()
        let freshGroups = Database.shared.listGroups()
        let apply: () -> Void = { [weak self] in
            guard let self else { return }
            self.clips = freshClips
            self.groups = freshGroups
            // Refresh openedGroup snapshot so itemCount stays current.
            if let g = self.openedGroup, let updated = freshGroups.first(where: { $0.id == g.id }) {
                self.openedGroup = updated
            } else if self.openedGroup != nil {
                // Group was deleted while opened — bounce back to group list.
                self.openedGroup = nil
            }
            if let id = self.selectedID, self.filtered.contains(where: { $0.id == id }) {
                // keep
            } else {
                self.selectedID = self.filtered.first?.id
            }
            NSLog("[Copaste] ClipStore.reload clips=\(freshClips.count) groups=\(freshGroups.count)")
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    var textCount: Int { clips.lazy.filter { $0.kind == .text }.count }
    var imageCount: Int { clips.lazy.filter { $0.kind == .image }.count }

    var filtered: [Clip] {
        let pool: [Clip]
        switch selectedTab {
        case .text:
            pool = clips.filter { $0.kind == .text }
        case .image:
            pool = clips.filter { $0.kind == .image }
        case .groups:
            if let g = openedGroup {
                pool = Database.shared.clipsInGroup(g.id)
            } else {
                return []  // group list view doesn't show clips
            }
        }
        let searched: [Clip]
        if query.isEmpty {
            searched = pool
        } else {
            let q = query.lowercased()
            searched = pool.filter { clip in
                switch clip.kind {
                case .text:
                    return clip.text.lowercased().contains(q)
                case .image:
                    return "image".contains(q)
                }
            }
        }
        let dated = searched.filter(matchesDateFilter)
        return dated.sorted { a, b in
            // Pinned items always float to the top, regardless of sort.
            if a.pinned != b.pinned { return a.pinned }
            switch sortOrder {
            case .newest:   return orderingDate(a) > orderingDate(b)
            case .oldest:   return orderingDate(a) < orderingDate(b)
            case .largest:  return sortSize(a) > sortSize(b)
            case .smallest: return sortSize(a) < sortSize(b)
            }
        }
    }

    /// Pinned items reorder via `pinned_at` (when they were pinned), unpinned
    /// via `created_at`. This matches what `Database.swapOrdering` writes, so
    /// reorder produces a visible result.
    private func orderingDate(_ c: Clip) -> Date {
        if c.pinned, let p = c.pinnedAt { return p }
        return c.createdAt
    }

    private func sortSize(_ c: Clip) -> Int64 {
        c.kind == .image ? c.imageBytes : Int64(c.text.count)
    }

    private func matchesDateFilter(_ c: Clip) -> Bool {
        let cal = Calendar.current
        switch dateFilter {
        case .all:
            return true
        case .today:
            return cal.isDateInToday(c.createdAt)
        case .yesterday:
            return cal.isDateInYesterday(c.createdAt)
        case .last7:
            return c.createdAt > Date().addingTimeInterval(-7 * 86400)
        case .last30:
            return c.createdAt > Date().addingTimeInterval(-30 * 86400)
        case .specific:
            return cal.isDate(c.createdAt, inSameDayAs: specificDate)
        }
    }

    /// Human-readable label shown in the date filter button tooltip and below
    /// the popover trigger when a specific date is selected.
    var dateFilterDisplay: String {
        if dateFilter == .specific {
            let f = DateFormatter()
            f.dateStyle = .medium
            return f.string(from: specificDate)
        }
        return dateFilter.rawValue
    }

    func selectTab(_ tab: AppTab) {
        guard tab != selectedTab else {
            // Re-tapping Groups while inside a group bounces back to the list.
            if tab == .groups, openedGroup != nil {
                openedGroup = nil
                selectedID = nil
            }
            return
        }
        selectedTab = tab
        if tab == .text { selectedKind = .text }
        if tab == .image { selectedKind = .image }
        // Reset opened-group when leaving Groups tab.
        if tab != .groups { openedGroup = nil }
        selectedID = filtered.first?.id
    }

    func openGroup(_ group: ClipGroup) {
        openedGroup = group
        selectedID = filtered.first?.id
    }

    @discardableResult
    func createGroup(name: String) -> ClipGroup? {
        guard let id = Database.shared.createGroup(name: name) else { return nil }
        reload()
        return groups.first(where: { $0.id == id })
    }

    func renameGroup(_ group: ClipGroup, to newName: String) {
        if Database.shared.renameGroup(id: group.id, newName: newName) {
            reload()
        }
    }

    func deleteGroup(_ group: ClipGroup) {
        Database.shared.deleteGroup(id: group.id)
        reload()
    }

    func addClip(_ clip: Clip, toGroup group: ClipGroup) {
        Database.shared.addClipToGroup(clipID: clip.id, groupID: group.id)
        reload()
    }

    func removeClip(_ clip: Clip, fromGroup group: ClipGroup) {
        Database.shared.removeClipFromGroup(clipID: clip.id, groupID: group.id)
        reload()
    }

    func togglePin(_ clip: Clip) {
        NSLog("[Copaste] togglePin id=\(clip.id) currentlyPinned=\(clip.pinned)")
        Database.shared.togglePin(id: clip.id)
        reload()
    }

    func togglePassword(_ clip: Clip) {
        NSLog("[Copaste] togglePassword id=\(clip.id) currentlyPassword=\(clip.isPassword)")
        Database.shared.togglePassword(id: clip.id)
        reload()
    }

    @discardableResult
    func updateText(id: Int64, newText: String) -> Bool {
        let ok = Database.shared.updateText(id: id, newText: newText)
        NSLog("[Copaste] updateText id=\(id) ok=\(ok)")
        if ok { reload() }
        return ok
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
        // Reorder operates on the *visible* filtered list, so the user always
        // swaps with the neighbor they actually see (regardless of tab,
        // search, or sort).
        let items = filtered
        guard let idx = items.firstIndex(where: { $0.id == clip.id }) else { return }
        let neighborIdx = dir == .up ? idx - 1 : idx + 1
        guard neighborIdx >= 0, neighborIdx < items.count else { return }
        let neighbor = items[neighborIdx]
        guard clip.pinned == neighbor.pinned else { return }

        // Reordering is only meaningful for time-based sorts (we swap
        // created_at / pinned_at). Bail out otherwise so we don't silently
        // corrupt timestamps with no visible effect.
        guard sortOrder == .newest || sortOrder == .oldest else {
            NSLog("[Copaste] reorder skipped — sort=\(sortOrder.rawValue)")
            return
        }

        NSLog("[Copaste] move id=\(clip.id) dir=\(dir) neighbor=\(neighbor.id)")
        Database.shared.swapOrdering(a: clip.id, b: neighbor.id, pinned: clip.pinned)
        reload()
    }
}

struct ClipListView: View {
    @ObservedObject var store: ClipStore
    let onPick: (Clip) -> Void
    let onClose: () -> Void
    let onScreenshot: () -> Void
    let onEdit: (Clip) -> Void

    @State private var showDatePopover = false

    var body: some View {
        VStack(spacing: 0) {
            TabStrip(
                selected: store.selectedTab,
                textCount: store.textCount,
                imageCount: store.imageCount,
                groupCount: store.groups.count,
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

                Button {
                    showDatePopover.toggle()
                } label: {
                    Image(systemName: "calendar")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(store.dateFilter == .all ? .secondary : Color.accentColor)
                        .frame(width: 28, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Date filter: \(store.dateFilterDisplay)")
                .popover(isPresented: $showDatePopover, arrowEdge: .bottom) {
                    DateFilterPopover(
                        selected: store.dateFilter,
                        specificDate: store.specificDate,
                        onPickPreset: { preset in
                            store.dateFilter = preset
                            showDatePopover = false
                        },
                        onPickSpecific: { date in
                            store.specificDate = date
                            store.dateFilter = .specific
                            showDatePopover = false
                        }
                    )
                }

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

            // Breadcrumb when inside a group.
            if store.selectedTab == .groups, let group = store.openedGroup {
                HStack(spacing: 6) {
                    Button {
                        store.openedGroup = nil
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Groups")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)

                    Text("/")
                        .foregroundStyle(.secondary.opacity(0.6))
                    Text(group.name)
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("\(group.itemCount) items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                Divider()
            }

            ScrollViewReader { proxy in
                ScrollView {
                    if store.selectedTab == .groups, store.openedGroup == nil {
                        // Group list view
                        GroupsListView(
                            groups: store.groups,
                            onOpen: { store.openGroup($0) },
                            onCreate: { name in store.createGroup(name: name) },
                            onRename: { g, n in store.renameGroup(g, to: n) },
                            onDelete: { store.deleteGroup($0) }
                        )
                    } else if (store.selectedTab == .image) ||
                              (store.selectedTab == .groups && store.openedGroup != nil &&
                               store.filtered.allSatisfy { $0.kind == .image }
                               && !store.filtered.isEmpty) {
                        // Image grid view (Image tab, OR a group containing only images)
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
                                    onDelete: { store.delete(clip) },
                                    groups: store.groups,
                                    membershipFor: { _ in
                                        store.openedGroup.map { [$0] } ?? []
                                    },
                                    onAddToGroup: { g in store.addClip(clip, toGroup: g) },
                                    onRemoveFromGroup: { g in store.removeClip(clip, fromGroup: g) },
                                    onCreateGroupAndAdd: { name in
                                        if let g = store.createGroup(name: name) {
                                            store.addClip(clip, toGroup: g)
                                        }
                                    }
                                )
                                .id(clip.id)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    } else {
                        // Row list view (Text tab, OR group with mixed/text content)
                        LazyVStack(spacing: 0) {
                            ForEach(store.filtered) { clip in
                                Row(
                                    clip: clip,
                                    selected: store.selectedID == clip.id,
                                    onSelect: { store.selectedID = clip.id },
                                    onClick: { onPick(clip) },
                                    onPin: { store.togglePin(clip) },
                                    onTogglePassword: { store.togglePassword(clip) },
                                    onEdit: { onEdit(clip) },
                                    onDelete: { store.delete(clip) },
                                    groups: store.groups,
                                    membershipFor: { clip in
                                        store.openedGroup.map { [$0] } ?? []
                                    },
                                    onAddToGroup: { g in store.addClip(clip, toGroup: g) },
                                    onRemoveFromGroup: { g in store.removeClip(clip, fromGroup: g) },
                                    onCreateGroupAndAdd: { name in
                                        if let g = store.createGroup(name: name) {
                                            store.addClip(clip, toGroup: g)
                                        }
                                    }
                                )
                                .id(clip.id)
                            }
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
    let onSelect: () -> Void
    let onClick: () -> Void
    let onPin: () -> Void
    let onTogglePassword: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let groups: [ClipGroup]
    let membershipFor: (Clip) -> [ClipGroup]
    let onAddToGroup: (ClipGroup) -> Void
    let onRemoveFromGroup: (ClipGroup) -> Void
    let onCreateGroupAndAdd: (String) -> Void

    @State private var showCreateGroupAlert = false
    @State private var newGroupName = ""

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                leadingIcon

                VStack(alignment: .leading, spacing: 2) {
                    switch clip.kind {
                    case .text:
                        Text(displayText)
                            .lineLimit(2)
                            .font(.system(size: 13, design: clip.isPassword ? .monospaced : .default))
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
            .onTapGesture(count: 1) { onSelect() }

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
        .contextMenu {
            Button("Paste", action: onClick)
            if clip.kind == .text {
                Button("Edit…", action: onEdit)
            }
            Button(clip.pinned ? "Unpin" : "Pin", action: onPin)
            if clip.kind == .text {
                Button(clip.isPassword ? "Unmark as Password" : "Mark as Password",
                       action: onTogglePassword)
            }

            Menu("Add to Group") {
                ForEach(groups) { g in
                    Button(g.name) { onAddToGroup(g) }
                }
                if !groups.isEmpty { Divider() }
                Button("New Group…") {
                    newGroupName = ""
                    showCreateGroupAlert = true
                }
            }

            let memberships = membershipFor(clip)
            if !memberships.isEmpty {
                Menu("Remove from Group") {
                    ForEach(memberships) { g in
                        Button(g.name) { onRemoveFromGroup(g) }
                    }
                }
            }

            Divider()
            Button("Delete", role: .destructive, action: onDelete)
                .disabled(clip.pinned)
        }
        .alert("New Group", isPresented: $showCreateGroupAlert) {
            TextField("Group name", text: $newGroupName)
            Button("Create") {
                onCreateGroupAndAdd(newGroupName)
            }
            .disabled(newGroupName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a name for the new group. The clip will be added to it.")
        }
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if clip.pinned {
            Image(systemName: "pin.fill")
                .foregroundStyle(.orange)
                .font(.caption)
                .padding(.top, 2)
        } else if clip.isPassword {
            Image(systemName: "key.fill")
                .foregroundStyle(.purple)
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

    private var displayText: String {
        let raw = clip.text.prefix(240).trimmingCharacters(in: .whitespacesAndNewlines)
        return clip.isPassword ? maskPassword(String(raw)) : raw
    }

    private func maskPassword(_ s: String) -> String {
        let chars = Array(s)
        // Short strings reveal nothing; longer ones keep first 3 / last 2 as in
        // a typical "ab****yz" credit-card / token mask.
        guard chars.count > 5 else {
            return String(repeating: "•", count: chars.count)
        }
        let head = String(chars.prefix(3))
        let tail = String(chars.suffix(2))
        let mid = String(repeating: "•", count: max(4, chars.count - 5))
        return head + mid + tail
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

private struct DateFilterPopover: View {
    let selected: DateFilter
    let specificDate: Date
    let onPickPreset: (DateFilter) -> Void
    let onPickSpecific: (Date) -> Void

    @State private var pickerDate: Date

    init(
        selected: DateFilter,
        specificDate: Date,
        onPickPreset: @escaping (DateFilter) -> Void,
        onPickSpecific: @escaping (Date) -> Void
    ) {
        self.selected = selected
        self.specificDate = specificDate
        self.onPickPreset = onPickPreset
        self.onPickSpecific = onPickSpecific
        _pickerDate = State(initialValue: specificDate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            VStack(spacing: 0) {
                ForEach(DateFilter.presets) { preset in
                    DateFilterRow(
                        label: preset.rawValue,
                        isActive: selected == preset,
                        onTap: { onPickPreset(preset) }
                    )
                }
            }
            .padding(.bottom, 4)

            Divider().padding(.horizontal, 14).padding(.vertical, 6)

            sectionLabel("Pick a specific date")

            MiniCalendar(selection: $pickerDate)
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .padding(.bottom, 8)

            HStack {
                if selected == .specific {
                    HStack(spacing: 4) {
                        Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                        Text("Showing: \(formattedDate(specificDate))")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                } else {
                    Text(formattedDate(pickerDate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    onPickSpecific(pickerDate)
                } label: {
                    Text("Apply")
                        .frame(minWidth: 60)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 12)
        }
        .frame(width: 300)
    }

    private var header: some View {
        HStack {
            sectionLabel("Filter by date")
                .padding(.leading, 0)
            Spacer()
            if selected != .all {
                Button {
                    onPickPreset(.all)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "xmark.circle.fill")
                        Text("Clear")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 14)
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private func sectionLabel(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.4)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
    }

    private func formattedDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f.string(from: d)
    }
}

private struct MiniCalendar: View {
    @Binding var selection: Date
    @State private var displayedMonth: Date

    private let calendar = Calendar.current

    init(selection: Binding<Date>) {
        self._selection = selection
        self._displayedMonth = State(initialValue: selection.wrappedValue)
    }

    var body: some View {
        VStack(spacing: 8) {
            header
            weekdayRow
            daysGrid
        }
    }

    private var monthLabel: String {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f.string(from: displayedMonth)
    }

    private var header: some View {
        HStack(spacing: 0) {
            navButton(systemName: "chevron.left") { shift(-1) }
            Spacer()
            Text(monthLabel)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            navButton(systemName: "chevron.right") { shift(1) }
        }
        .frame(height: 26)
    }

    private func navButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var weekdayRow: some View {
        HStack(spacing: 0) {
            ForEach(orderedWeekdaySymbols, id: \.self) { sym in
                Text(sym)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var orderedWeekdaySymbols: [String] {
        // veryShortWeekdaySymbols starts on Sunday — reorder for the user's
        // first-weekday preference.
        let symbols = calendar.veryShortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...]) + Array(symbols[..<first])
    }

    private var daysGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
        return LazyVGrid(columns: columns, spacing: 4) {
            ForEach(daysToDisplay(), id: \.self) { date in
                cell(for: date)
            }
        }
    }

    private func cell(for date: Date) -> some View {
        let inMonth = calendar.isDate(date, equalTo: displayedMonth, toGranularity: .month)
        let isSelected = calendar.isDate(date, inSameDayAs: selection)
        let isToday = calendar.isDateInToday(date)
        let day = calendar.component(.day, from: date)

        let bg: Color = isSelected ? Color.accentColor : .clear
        let fg: Color = isSelected
            ? .white
            : (inMonth ? .primary : Color.secondary.opacity(0.4))

        return Button {
            selection = date
        } label: {
            ZStack {
                Circle()
                    .fill(bg)
                if isToday && !isSelected {
                    Circle()
                        .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.2)
                }
                Text("\(day)")
                    .font(.system(size: 12, weight: isSelected || isToday ? .semibold : .regular))
                    .foregroundStyle(fg)
            }
            .frame(width: 28, height: 28)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func shift(_ delta: Int) {
        if let next = calendar.date(byAdding: .month, value: delta, to: displayedMonth) {
            withAnimation(.easeOut(duration: 0.12)) {
                displayedMonth = next
            }
        }
    }

    private func daysToDisplay() -> [Date] {
        guard let monthStart = calendar.date(
            from: calendar.dateComponents([.year, .month], from: displayedMonth)
        ) else { return [] }
        let weekdayOfFirst = calendar.component(.weekday, from: monthStart)
        var offset = weekdayOfFirst - calendar.firstWeekday
        if offset < 0 { offset += 7 }
        let gridStart = calendar.date(byAdding: .day, value: -offset, to: monthStart) ?? monthStart

        return (0..<42).compactMap { i in
            calendar.date(byAdding: .day, value: i, to: gridStart)
        }
    }
}

private struct DateFilterRow: View {
    let label: String
    let isActive: Bool
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .strokeBorder(
                            isActive ? Color.accentColor : Color.secondary.opacity(0.45),
                            lineWidth: 1.5
                        )
                        .frame(width: 14, height: 14)
                    if isActive {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 7, height: 7)
                    }
                }
                Text(label)
                    .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                hovering ? Color.secondary.opacity(0.10) : Color.clear
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct GroupsListView: View {
    let groups: [ClipGroup]
    let onOpen: (ClipGroup) -> Void
    let onCreate: (String) -> Void
    let onRename: (ClipGroup, String) -> Void
    let onDelete: (ClipGroup) -> Void

    @State private var showCreate = false
    @State private var newName = ""
    @State private var renaming: ClipGroup?
    @State private var renameText = ""

    var body: some View {
        VStack(spacing: 0) {
            Button {
                newName = ""
                showCreate = true
            } label: {
                HStack {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(Color.accentColor)
                    Text("New Group")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider()

            if groups.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("No groups yet")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Create a group to organize clips into collections.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.vertical, 40)
                .frame(maxWidth: .infinity)
            } else {
                ForEach(groups) { g in
                    GroupRow(
                        group: g,
                        onOpen: { onOpen(g) },
                        onRename: {
                            renameText = g.name
                            renaming = g
                        },
                        onDelete: { onDelete(g) }
                    )
                }
            }
        }
        .alert("New Group", isPresented: $showCreate) {
            TextField("Group name", text: $newName)
            Button("Create") {
                onCreate(newName)
            }
            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Group", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Group name", text: $renameText)
            Button("Rename") {
                if let g = renaming { onRename(g, renameText) }
                renaming = nil
            }
            .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }
}

private struct GroupRow: View {
    let group: ClipGroup
    let onOpen: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(Color.accentColor)
                    .font(.system(size: 14))
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    Text("\(group.itemCount) item\(group.itemCount == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open", action: onOpen)
            Button("Rename…", action: onRename)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }
}

private struct TabStrip: View {
    let selected: AppTab
    let textCount: Int
    let imageCount: Int
    let groupCount: Int
    let onSelect: (AppTab) -> Void

    var body: some View {
        HStack(spacing: 0) {
            // Left padding clears the traffic-light buttons.
            Color.clear.frame(width: 70, height: 1)

            HStack(spacing: 24) {
                tabButton(.text, label: "Text", count: textCount)
                tabButton(.image, label: "Images", count: imageCount)
                tabButton(.groups, label: "Groups", count: groupCount)
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
    private func tabButton(_ tab: AppTab, label: String, count: Int) -> some View {
        let isActive = (selected == tab)
        Button(action: { onSelect(tab) }) {
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
    let groups: [ClipGroup]
    let membershipFor: (Clip) -> [ClipGroup]
    let onAddToGroup: (ClipGroup) -> Void
    let onRemoveFromGroup: (ClipGroup) -> Void
    let onCreateGroupAndAdd: (String) -> Void

    @State private var showCreateGroupAlert = false
    @State private var newGroupName = ""

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

            Menu("Add to Group") {
                ForEach(groups) { g in
                    Button(g.name) { onAddToGroup(g) }
                }
                if !groups.isEmpty { Divider() }
                Button("New Group…") {
                    newGroupName = ""
                    showCreateGroupAlert = true
                }
            }

            let memberships = membershipFor(clip)
            if !memberships.isEmpty {
                Menu("Remove from Group") {
                    ForEach(memberships) { g in
                        Button(g.name) { onRemoveFromGroup(g) }
                    }
                }
            }

            Divider()
            Button("Delete", role: .destructive, action: onDelete)
                .disabled(clip.pinned)
        }
        .alert("New Group", isPresented: $showCreateGroupAlert) {
            TextField("Group name", text: $newGroupName)
            Button("Create") {
                onCreateGroupAndAdd(newGroupName)
            }
            .disabled(newGroupName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a name for the new group. The image will be added to it.")
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
