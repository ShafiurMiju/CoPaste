import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers

struct ClipDragID: Codable, Transferable {
    let id: Int64

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}

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
    @Published var multiSelected: Set<Int64> = []
    /// Set by keyboard navigation only. The view watches this to scroll;
    /// mouse clicks and deletes leave it nil so the scroll position stays put.
    @Published var scrollTargetID: Int64?
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
                multiSelected.removeAll()
            }
            return
        }
        selectedTab = tab
        if tab == .text { selectedKind = .text }
        if tab == .image { selectedKind = .image }
        // Reset opened-group when leaving Groups tab.
        if tab != .groups { openedGroup = nil }
        selectedID = filtered.first?.id
        multiSelected.removeAll()
    }

    func openGroup(_ group: ClipGroup) {
        openedGroup = group
        selectedID = filtered.first?.id
        multiSelected.removeAll()
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

    // MARK: - Selection

    func selectSingle(_ id: Int64) {
        selectedID = id
        multiSelected = [id]
    }

    func toggleMultiSelection(_ id: Int64) {
        if multiSelected.contains(id) {
            multiSelected.remove(id)
            if selectedID == id {
                selectedID = multiSelected.first
            }
        } else {
            multiSelected.insert(id)
            selectedID = id
        }
    }

    func selectAllVisible() {
        let ids = filtered.map { $0.id }
        multiSelected = Set(ids)
        selectedID = ids.first
    }

    func clearMultiSelection() {
        multiSelected = selectedID.map { [$0] } ?? []
    }

    /// Bulk delete: removes every clip currently in the multi-selection set
    /// (skipping pinned items). Falls back to the cursor row if multi is
    /// empty. Called from Cmd+Backspace and the right-click menu.
    func deleteSelected() {
        let ids: Set<Int64>
        if !multiSelected.isEmpty {
            ids = multiSelected
        } else if let s = selectedID {
            ids = [s]
        } else {
            return
        }
        var removed = 0
        for id in ids {
            if let clip = clips.first(where: { $0.id == id }), !clip.pinned {
                Database.shared.delete(id: id)
                removed += 1
            }
        }
        NSLog("[Copaste] bulk delete removed=\(removed) of \(ids.count)")
        multiSelected.removeAll()
        selectedID = nil
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

    /// Drag-to-reorder: removes the source from its current position and
    /// inserts it where the target sits. The clips between them shift over
    /// (true reorder, not a swap).
    ///
    /// Implementation: redistribute the existing timestamps of the visible
    /// same-pinned section onto the clips in their new order. Since the
    /// timestamps came from that exact section, sort order is preserved
    /// for any clips not part of this filter — only the visible ones get
    /// their relative order changed.
    func swapByDrag(sourceID: Int64, targetID: Int64) {
        guard sourceID != targetID else { return }
        let items = filtered
        guard let from = items.firstIndex(where: { $0.id == sourceID }),
              let to = items.firstIndex(where: { $0.id == targetID }),
              from != to else { return }
        let source = items[from]
        let target = items[to]
        guard source.pinned == target.pinned else {
            NSLog("[Copaste] reorder skipped — pinned mismatch")
            return
        }
        guard sortOrder == .newest || sortOrder == .oldest else {
            NSLog("[Copaste] reorder skipped — sort=\(sortOrder.rawValue)")
            return
        }

        let pinnedFlag = source.pinned
        let originalSection = items.filter { $0.pinned == pinnedFlag }

        // Build the new order within the section.
        var newSection = originalSection
        guard let srcIdx = newSection.firstIndex(where: { $0.id == source.id }),
              let tgtIdx = originalSection.firstIndex(where: { $0.id == target.id })
        else { return }
        let moved = newSection.remove(at: srcIdx)
        // After remove, indices >= srcIdx shifted by -1. Recompute insertion
        // index from the original positions to land "where target was".
        let insertIdx = (tgtIdx > srcIdx) ? tgtIdx : tgtIdx
        newSection.insert(moved, at: min(insertIdx, newSection.count))

        // Existing timestamps from the section, in their current display order.
        let times: [Int64] = originalSection.map { c in
            let date = pinnedFlag ? (c.pinnedAt ?? c.createdAt) : c.createdAt
            return Int64(date.timeIntervalSince1970 * 1000)
        }

        // Reassign the same set of timestamps to the new order.
        for (i, clip) in newSection.enumerated() where i < times.count {
            Database.shared.setOrdering(id: clip.id, value: times[i], pinned: pinnedFlag)
        }

        NSLog("[Copaste] reorder source=\(sourceID) -> position of target=\(targetID)")
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
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            TabStrip(
                selected: store.selectedTab,
                textCount: store.textCount,
                imageCount: store.imageCount,
                groupCount: store.groups.count,
                settingsActive: showingSettings,
                onSelect: { tab in
                    showingSettings = false
                    store.selectTab(tab)
                },
                onSettings: { showingSettings.toggle() }
            )

            if showingSettings {
                SettingsPageView(
                    onCloseWindow: onClose,
                    onReloadStore: { store.reload() }
                )
            } else {
            HStack(spacing: 8) {
                SearchField(text: $store.query, onSubmit: pickCurrent, onCancel: onClose,
                            onArrowDown: { move(1) }, onArrowUp: { move(-1) },
                            onArrowLeft: { cycleTab(-1) },
                            onArrowRight: { cycleTab(1) })

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
                    } else {
                        // Row list view (Text, Image, or group content)
                        LazyVStack(spacing: 0) {
                            ForEach(store.filtered) { clip in
                                Row(
                                    clip: clip,
                                    selected: store.multiSelected.contains(clip.id) || store.selectedID == clip.id,
                                    onSelect: { selectClip(clip) },
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
                                    },
                                    onDropFrom: { sourceID in
                                        store.swapByDrag(sourceID: sourceID, targetID: clip.id)
                                    }
                                )
                                .id(clip.id)
                            }
                        }
                    }
                }
                .onChange(of: store.scrollTargetID) { new in
                    guard let new else { return }
                    // Long, soft spring with high damping — successive scrolls
                    // blend into one continuous glide instead of stuttering.
                    withAnimation(.interactiveSpring(response: 0.55, dampingFraction: 0.92, blendDuration: 0.55)) {
                        proxy.scrollTo(new, anchor: .center)
                    }
                    DispatchQueue.main.async { store.scrollTargetID = nil }
                }
            }

            Divider()
            HStack(spacing: 10) {
                if store.multiSelected.count > 1 {
                    Text("\(store.multiSelected.count) selected")
                        .foregroundStyle(Color.accentColor)
                        .font(.caption)
                    Button {
                        deleteCurrent()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash.fill")
                            Text("Delete \(deletableCount)")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.red)
                    .disabled(deletableCount == 0)
                    Button("Cancel") {
                        store.clearMultiSelection()
                        if let id = store.filtered.first?.id {
                            store.selectSingle(id)
                        }
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                } else {
                    Label("↩ paste", systemImage: "return").labelStyle(.titleOnly)
                    Label("⌘P pin", systemImage: "pin").labelStyle(.titleOnly)
                    Label("⌘⌫ delete", systemImage: "delete.left").labelStyle(.titleOnly)
                    Label("⌘A all", systemImage: "checkmark").labelStyle(.titleOnly)
                    Label("⌥↑↓ reorder", systemImage: "arrow.up.arrow.down").labelStyle(.titleOnly)
                }
                Spacer()
                if store.multiSelected.count <= 1 {
                    Text("\(store.filtered.count) items")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            }
        }
        .background(KeyCatcher(
            onEnter: pickCurrent,
            onEscape: onClose,
            onUp: { move(-1) },
            onDown: { move(1) },
            onPin: pinCurrent,
            onDelete: deleteCurrent,
            onMoveUp: { moveCurrentItem(.up) },
            onMoveDown: { moveCurrentItem(.down) },
            onSelectAll: { store.selectAllVisible() }
        ))
    }

    private func moveCurrentItem(_ dir: Database.MoveDirection) {
        guard let idx = currentIndex() else { return }
        let clip = store.filtered[idx]
        store.move(clip, dir)
        // Follow the reordered clip — keep it visible as it moves.
        store.scrollTargetID = clip.id
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
        store.selectSingle(items[next].id)
        // Keyboard nav: ensure the new selection is visible.
        store.scrollTargetID = items[next].id
    }

    /// Cycle ←/→ across the Text / Images / Groups tabs. Used by the
    /// SearchField when its text is empty, so left/right are free.
    private func cycleTab(_ delta: Int) {
        let tabs: [AppTab] = [.text, .image, .groups]
        let idx = tabs.firstIndex(of: store.selectedTab) ?? 0
        let next = (idx + delta + tabs.count) % tabs.count
        store.selectTab(tabs[next])
    }

    private var deletableCount: Int {
        // Pinned clips are skipped by deleteSelected — show the user how many
        // will actually be removed.
        store.clips.filter { store.multiSelected.contains($0.id) && !$0.pinned }.count
    }

    /// Click handler used by Row. Cmd+click toggles a clip in
    /// the multi-selection set; a plain click clears multi, selects the
    /// clicked clip, and copies it to the system clipboard (so it becomes
    /// the current pasteboard item without auto-pasting — double-click /
    /// Enter still does the auto-paste).
    private func selectClip(_ clip: Clip) {
        let cmd = NSEvent.modifierFlags.contains(.command)
        if cmd {
            store.toggleMultiSelection(clip.id)
        } else {
            store.selectSingle(clip.id)
            copyClipToClipboard(clip)
        }
    }

    private func copyClipToClipboard(_ clip: Clip) {
        switch clip.kind {
        case .text:
            Paster.copyText(clip.text)
        case .image:
            if let data = Database.shared.imageData(for: clip) {
                Paster.copyImage(data)
            }
        }
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
        // If the user has a multi-selection, bulk-delete; otherwise the
        // store falls back to the cursor row.
        let nextIDAfterCursor: Int64? = {
            guard store.multiSelected.count <= 1, let idx = currentIndex() else { return nil }
            let items = store.filtered
            return idx + 1 < items.count ? items[idx + 1].id
                : (idx > 0 ? items[idx - 1].id : nil)
        }()
        store.deleteSelected()
        if let next = nextIDAfterCursor {
            store.selectSingle(next)
        }
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
    let onDropFrom: (Int64) -> Void

    @State private var showCreateGroupAlert = false
    @State private var newGroupName = ""
    @State private var isDropTarget = false

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
                        ImagePreview(clip: clip, selected: selected)
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
        .background(
            isDropTarget
                ? Color.accentColor.opacity(0.28)
                : (selected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .overlay(alignment: .top) {
            if isDropTarget {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
            }
        }
        .draggable(ClipDragID(id: clip.id)) {
            dragPreview
        }
        .dropDestination(for: ClipDragID.self) { items, _ in
            guard let item = items.first else { return false }
            onDropFrom(item.id)
            return true
        } isTargeted: { isDropTarget = $0 }
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

    @ViewBuilder
    private var dragPreview: some View {
        HStack(spacing: 8) {
            leadingIcon
            Group {
                switch clip.kind {
                case .text:
                    Text(displayText)
                        .lineLimit(1)
                        .font(.system(size: 12, design: clip.isPassword ? .monospaced : .default))
                case .image:
                    if let data = clip.thumbnail, let img = NSImage(data: data) {
                        Image(nsImage: img)
                            .resizable()
                            .interpolation(.medium)
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 80, maxHeight: 40)
                            .cornerRadius(3)
                    } else {
                        Text("Image")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
            }
            .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: 280, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor.opacity(0.6), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 3)
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
            .padding(.bottom, 2)

            Divider().padding(.horizontal, 12).padding(.vertical, 3)

            sectionLabel("Pick a specific date")

            MiniCalendar(selection: $pickerDate)
                .padding(.horizontal, 10)
                .padding(.top, 2)
                .padding(.bottom, 2)

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
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
        .frame(width: 200)
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
                    HStack(spacing: 2) {
                        Image(systemName: "xmark.circle.fill")
                        Text("Clear")
                    }
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 12)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private func sectionLabel(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.4)
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
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
        VStack(spacing: 2) {
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
                .font(.system(size: 11, weight: .semibold))
            Spacer()
            navButton(systemName: "chevron.right") { shift(1) }
        }
        .frame(height: 18)
    }

    private func navButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var weekdayRow: some View {
        HStack(spacing: 0) {
            ForEach(orderedWeekdaySymbols, id: \.self) { sym in
                Text(sym)
                    .font(.system(size: 8, weight: .semibold))
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
        return LazyVGrid(columns: columns, spacing: 1) {
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
                    .font(.system(size: 9.5, weight: isSelected || isToday ? .semibold : .regular))
                    .foregroundStyle(fg)
            }
            .frame(width: 18, height: 18)
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
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .strokeBorder(
                            isActive ? Color.accentColor : Color.secondary.opacity(0.45),
                            lineWidth: 1.2
                        )
                        .frame(width: 11, height: 11)
                    if isActive {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 5.5, height: 5.5)
                    }
                }
                Text(label)
                    .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
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
    let settingsActive: Bool
    let onSelect: (AppTab) -> Void
    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            // Left padding clears the close button, then a gear button sits
            // beside it for quick access to settings.
            HStack(spacing: 0) {
                Color.clear.frame(width: 30, height: 1)
                Button(action: onSettings) {
                    Image(systemName: settingsActive ? "gearshape.fill" : "gearshape")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(settingsActive ? Color.accentColor : .secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(settingsActive ? "Close Settings" : "Settings")
                Spacer(minLength: 0)
            }
            .frame(width: 70)

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
    let selected: Bool

    @State private var showLargePreview = false
    @State private var hoverTask: DispatchWorkItem?

    var body: some View {
        thumbnail
            .onHover { hovering in
                hoverTask?.cancel()
                if hovering {
                    // Short delay so the popover doesn't flicker open
                    // just because the cursor crossed the thumbnail.
                    let task = DispatchWorkItem { showLargePreview = true }
                    hoverTask = task
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: task)
                } else if !selected {
                    showLargePreview = false
                }
            }
            // Keyboard navigation: whenever this row becomes the cursor
            // selection (arrow keys, mouse click, etc.), pop the preview
            // immediately. When the cursor moves away, dismiss it.
            .onChange(of: selected) { isSelected in
                if isSelected {
                    showLargePreview = true
                } else {
                    showLargePreview = false
                    hoverTask?.cancel()
                }
            }
            // onChange only fires on transitions, so the very first row
            // (already selected when its ImagePreview appears) wouldn't
            // open its popover. Cover that case explicitly.
            .onAppear {
                if selected {
                    DispatchQueue.main.async { showLargePreview = true }
                }
            }
            .popover(isPresented: $showLargePreview, arrowEdge: .trailing) {
                largePreview
            }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let data = clip.thumbnail, let img = NSImage(data: data) {
            Image(nsImage: img)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fill)
                .frame(width: 40, height: 40)
                .clipped()
                .cornerRadius(4)
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 40, height: 40)
                .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
        }
    }

    @ViewBuilder
    private var largePreview: some View {
        Group {
            if let data = Database.shared.imageData(for: clip),
               let img = NSImage(data: data) {
                imageView(img)
            } else if let data = clip.thumbnail, let img = NSImage(data: data) {
                imageView(img)
            } else {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .padding(40)
            }
        }
    }

    private func imageView(_ img: NSImage) -> some View {
        Image(nsImage: img)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(maxHeight: 600)
            .padding(8)
    }
}


// MARK: - Search field (SwiftUI doesn't handle arrow keys on TextField nicely)

private struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    let onCancel: () -> Void
    let onArrowDown: () -> Void
    let onArrowUp: () -> Void
    let onArrowLeft: () -> Void
    let onArrowRight: () -> Void

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
            case #selector(NSResponder.moveLeft(_:)):
                // Only cycle tabs when the search field is empty — when
                // the user is actually typing, ←/→ stay as text-cursor
                // movement so editing still works normally.
                if parent.text.isEmpty {
                    parent.onArrowLeft(); return true
                }
                return false
            case #selector(NSResponder.moveRight(_:)):
                if parent.text.isEmpty {
                    parent.onArrowRight(); return true
                }
                return false
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
    let onSelectAll: () -> Void

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
        v.onSelectAll = onSelectAll
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
        var onSelectAll: (() -> Void)?

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
                if mods.contains(.command),
                   event.charactersIgnoringModifiers?.lowercased() == "a" {
                    self.onSelectAll?()
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

// MARK: - Settings page (in-popup tab)

private struct SettingsPageView: View {
    let onCloseWindow: () -> Void
    let onReloadStore: () -> Void

    @State private var launchAtLogin: Bool = (SMAppService.mainApp.status == .enabled)
    @AppStorage("Copaste.alwaysOnTop") private var alwaysOnTop: Bool = true
    @AppStorage("Copaste.rememberPosition") private var rememberPosition: Bool = false
    @AppStorage("Copaste.windowWidth") private var windowWidthStored: Double = 520
    @AppStorage("Copaste.windowHeight") private var windowHeightStored: Double = 520
    @State private var widthText: String = ""
    @State private var heightText: String = ""
    @State private var showClearAlert = false

    // Live status of the local sync server. Polled every 1s so the user
    // sees a phone connect/disconnect — and the pairing countdown tick —
    // without having to leave + re-enter the settings page.
    @State private var syncRunning: Bool = false
    @State private var syncPort: UInt16 = 0
    @State private var syncPeerCount: Int = 0
    @State private var pairingCode: String? = nil
    @State private var pairingRemaining: Int = 0
    @State private var pairedDevices: [SyncStorage.PairedDevice] = []
    private let syncTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader("Sync")
                infoRow(
                    icon: syncRunning ? "wifi" : "wifi.slash",
                    title: "Local Network",
                    trailing: syncRunning ? "Port \(syncPort)" : "Off"
                )
                infoRow(
                    icon: "iphone",
                    title: "Connected devices",
                    trailing: "\(syncPeerCount)"
                )

                if let code = pairingCode {
                    pairingCard(code: code, remaining: pairingRemaining)
                } else {
                    actionRow(icon: "plus.circle", title: "Pair New Device") {
                        let _ = (NSApp.delegate as? AppDelegate)?.syncServer.beginPairing()
                        refreshSyncStatus()
                    }
                }

                if !pairedDevices.isEmpty {
                    Text("PAIRED")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .tracking(0.5)
                        .padding(.horizontal, 14)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                    ForEach(pairedDevices) { device in
                        pairedDeviceRow(device)
                    }
                }

                sectionHeader("Keyboard")
                infoRow(
                    icon: "command",
                    title: "Show Copaste",
                    trailing: HotKeyManager.shared.current.display
                )
                actionRow(icon: "pencil", title: "Change Shortcut…") {
                    ShortcutRecorderController.shared.show()
                }

                sectionHeader("Behavior")
                toggleRow(icon: "power", title: "Launch at Login", isOn: $launchAtLogin) { newValue in
                    do {
                        if newValue {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        launchAtLogin = !newValue
                        NSAlert(error: error).runModal()
                    }
                }
                toggleRow(icon: "pin.fill", title: "Always on Top", isOn: $alwaysOnTop) { newValue in
                    (NSApp.delegate as? AppDelegate)?.popup.alwaysOnTop = newValue
                }

                sectionHeader("Window")
                dimensionRow(
                    icon: "arrow.left.and.right",
                    title: "Width",
                    text: $widthText
                ) {
                    if let v = Double(widthText), v > 0 {
                        (NSApp.delegate as? AppDelegate)?.popup.windowWidth = CGFloat(v)
                    }
                    widthText = "\(Int(windowWidthStored))"
                }
                dimensionRow(
                    icon: "arrow.up.and.down",
                    title: "Height",
                    text: $heightText
                ) {
                    if let v = Double(heightText), v > 0 {
                        (NSApp.delegate as? AppDelegate)?.popup.windowHeight = CGFloat(v)
                    }
                    heightText = "\(Int(windowHeightStored))"
                }
                toggleRow(
                    icon: "mappin.and.ellipse",
                    title: "Remember last position",
                    isOn: $rememberPosition
                ) { _ in /* AppStorage already wrote the new value */ }
                actionRow(icon: "arrow.counterclockwise", title: "Reset to default") {
                    (NSApp.delegate as? AppDelegate)?.popup.resetWindowToDefaults()
                    // Refresh the local field text now that the stored
                    // values just changed — onChange picks this up but the
                    // remove-then-default isn't a "change" in @AppStorage's
                    // eyes if the value was already the default.
                    widthText = "\(Int(windowWidthStored))"
                    heightText = "\(Int(windowHeightStored))"
                }

                sectionHeader("Clipboard")
                actionRow(icon: "camera.viewfinder", title: "Take Screenshot…") {
                    onCloseWindow()
                    Screenshot.captureInteractive()
                }
                actionRow(icon: "internaldrive", title: "Storage Limits…") {
                    SettingsController.shared.show()
                }
                actionRow(
                    icon: "trash",
                    title: "Clear Unpinned History",
                    destructive: true
                ) {
                    showClearAlert = true
                }

                sectionHeader("Permissions")
                actionRow(icon: "lock.shield", title: "Reset Accessibility Permission…") {
                    (NSApp.delegate as? AppDelegate)?.resetAccessibility()
                }
                actionRow(icon: "rectangle.on.rectangle", title: "Reset Screen Recording Permission…") {
                    (NSApp.delegate as? AppDelegate)?.resetScreenRecording()
                }

                Divider().padding(.vertical, 8)

                actionRow(
                    icon: "power",
                    title: "Quit Copaste",
                    destructive: true
                ) {
                    NSApp.terminate(nil)
                }
                .padding(.bottom, 12)
            }
        }
        .alert("Clear all unpinned clips?", isPresented: $showClearAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                Database.shared.clearUnpinned()
                onReloadStore()
            }
        } message: {
            Text("Pinned items will be kept.")
        }
        .onAppear {
            refreshSyncStatus()
            widthText = "\(Int(windowWidthStored))"
            heightText = "\(Int(windowHeightStored))"
        }
        .onReceive(syncTimer) { _ in refreshSyncStatus() }
        // Reflect drag-resizes done with the mouse so the text field
        // doesn't drift out of sync with the live panel size.
        .onChange(of: windowWidthStored) { new in widthText = "\(Int(new))" }
        .onChange(of: windowHeightStored) { new in heightText = "\(Int(new))" }
    }

    private func refreshSyncStatus() {
        guard let server = (NSApp.delegate as? AppDelegate)?.syncServer else { return }
        syncRunning = server.isRunning
        syncPort = server.port
        syncPeerCount = server.peerCount
        pairingCode = server.pairingCode
        if let exp = server.pairingExpiresAt {
            pairingRemaining = max(0, Int(exp.timeIntervalSinceNow))
        } else {
            pairingRemaining = 0
        }
        pairedDevices = SyncStorage.listPairedDevices()
            .sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
    }

    private func pairingCard(code: String, remaining: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Enter this code on your phone")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(Array(code.enumerated()), id: \.offset) { _, ch in
                    Text(String(ch))
                        .font(.system(size: 22, weight: .semibold, design: .monospaced))
                        .frame(width: 28, height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.accentColor.opacity(0.12))
                        )
                }
                Spacer()
                Text("\(remaining)s")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(remaining <= 10 ? Color.red : .secondary)
            }
            Button("Cancel") {
                (NSApp.delegate as? AppDelegate)?.syncServer.cancelPairing()
                refreshSyncStatus()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor.opacity(0.4), lineWidth: 1)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(0.04))
                )
        )
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func pairedDeviceRow(_ device: SyncStorage.PairedDevice) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "iphone")
                .frame(width: 22)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                    .font(.system(size: 13))
                if let seen = device.lastSeen {
                    Text("Last seen \(relativeShort(seen))")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                SyncStorage.removePairedDevice(id: device.id)
                refreshSyncStatus()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Unpair this device")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func relativeShort(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.5)
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 6)
    }

    private func infoRow(icon: String, title: String, trailing: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 22)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 13))
            Spacer()
            Text(trailing)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.12))
                )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func actionRow(
        icon: String,
        title: String,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .frame(width: 22)
                    .foregroundStyle(destructive ? Color.red.opacity(0.85) : .secondary)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(destructive ? Color.red.opacity(0.95) : .primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary.opacity(0.5))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggleRow(
        icon: String,
        title: String,
        isOn: Binding<Bool>,
        onChange: @escaping (Bool) -> Void
    ) -> some View {
        // Wraps `isOn` so the side effect fires inside the setter — more
        // reliable than `.onChange(of:)`, which can miss rapid toggles or
        // run on a later tick than the underlying state write.
        let wrapped = Binding<Bool>(
            get: { isOn.wrappedValue },
            set: { newValue in
                isOn.wrappedValue = newValue
                onChange(newValue)
            }
        )
        return HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 22)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 13))
            Spacer()
            Toggle("", isOn: wrapped)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    /// Numeric input row used for Window width/height. The TextField
    /// commits its value when the user presses Enter; `onCommit` is
    /// responsible for both applying it and refreshing the text from the
    /// clamped/persisted stored value (so out-of-range entries snap back).
    private func dimensionRow(
        icon: String,
        title: String,
        text: Binding<String>,
        onCommit: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 22)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 13))
            Spacer()
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 72)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .onSubmit { onCommit() }
            Text("px")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }
}
