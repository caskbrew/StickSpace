import Foundation
import Combine

struct Toast: Equatable {
    let id = UUID()
    let message: String
}

/// Single source of truth. UI-free: windows and views observe it, never own state.
final class AppStore: ObservableObject {
    @Published var state = AppState()
    /// Transient UI state; never persisted, so a revealed secret cannot survive a relaunch.
    @Published private(set) var revealed: Set<UUID> = []
    /// Spaces currently listing their hidden groups and entities. Transient, like `revealed`.
    @Published private(set) var showingHidden: Set<UUID> = []
    @Published var editingBlock: UUID?
    @Published var toast: Toast?

    var activeGroupID: UUID?

    private struct UndoEntry { let undo: () -> Void }
    private var undoStack: [UndoEntry] = []

    // MARK: Lookup

    func groupIndex(_ id: UUID) -> Int? { state.groups.firstIndex { $0.id == id } }

    func locate(stick id: UUID) -> (group: Int, stick: Int)? {
        for (g, group) in state.groups.enumerated() {
            if let s = group.sticks.firstIndex(where: { $0.id == id }) { return (g, s) }
        }
        return nil
    }

    func locate(block id: UUID) -> (group: Int, stick: Int, block: Int)? {
        for (g, group) in state.groups.enumerated() {
            for (s, stick) in group.sticks.enumerated() {
                if let b = stick.blocks.firstIndex(where: { $0.id == id }) { return (g, s, b) }
            }
        }
        return nil
    }

    func stick(_ id: UUID) -> Stick? { locate(stick: id).map { state.groups[$0.group].sticks[$0.stick] } }
    func block(_ id: UUID) -> Block? { locate(block: id).map { state.groups[$0.group].sticks[$0.stick].blocks[$0.block] } }
    func groupID(ofStick id: UUID) -> UUID? { locate(stick: id).map { state.groups[$0.group].id } }

    /// Group that zoom and similar commands apply to: the one with the active stick, else the first visible.
    var commandGroupID: UUID? {
        if let id = activeGroupID, groupIndex(id) != nil { return id }
        return state.groups.first { $0.showsWindow }?.id ?? state.groups.first?.id
    }

    // MARK: Loading / seeding

    func load(_ newState: AppState) {
        state = newState
        revealed = []
        showingHidden = []
        editingBlock = nil
        undoStack = []
    }

    func seedIfNeeded() {
        guard state.groups.isEmpty else { return }
        var workspace = Stick(name: "Workspace", blocks: [
            Block(type: .text, text: "Keep useful things close."),
            Block(type: .link, text: "https://github.com"),
            Block(type: .text, text: "npm run dev"),
        ])
        workspace.isExpanded = true
        state.groups = [StickGroup(sticks: [workspace, Stick(name: "Links"), Stick(name: "Personal")], name: "Space")]
    }

    // MARK: Theme / group settings

    func setTheme(_ theme: ThemeChoice) { state.theme = theme }

    func setPinned(_ pinned: Bool, group id: UUID) {
        guard let g = groupIndex(id) else { return }
        state.groups[g].isPinned = pinned
    }

    func renameSpace(_ id: UUID, to name: String) {
        guard let g = groupIndex(id) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        state.groups[g].name = trimmed
    }

    func setWidth(_ width: Double, space id: UUID) {
        guard let g = groupIndex(id) else { return }
        let w = SpaceWidth.clamp(width.rounded())
        if state.groups[g].width != w { state.groups[g].width = w }
    }

    func setShowingHidden(_ on: Bool, space id: UUID) {
        if on { showingHidden.insert(id) } else { showingHidden.remove(id) }
    }

    /// Hidden groups plus hidden entities in a space.
    func hiddenCount(space id: UUID) -> Int {
        guard let g = groupIndex(id) else { return 0 }
        return state.groups[g].sticks.reduce(0) { $0 + ($1.isHidden ? 1 : 0) + $1.blocks.filter(\.isHidden).count }
    }

    func setCollapsed(_ collapsed: Bool, space id: UUID) {
        guard let g = groupIndex(id) else { return }
        state.groups[g].isCollapsed = collapsed
        if collapsed { hideRevealed(inGroup: id); if editingBlock != nil { editingBlock = nil } }
    }

    @discardableResult
    func addSpace(name: String, groups: [Stick] = []) -> UUID {
        let space = StickGroup(sticks: groups, name: name)
        state.groups.append(space)
        activeGroupID = space.id
        return space.id
    }

    func deleteSpace(_ id: UUID) {
        guard let g = groupIndex(id) else { return }
        let space = state.groups[g]
        hideRevealed(inGroup: id)
        state.groups.remove(at: g)
        pushUndo("Space deleted") { [unowned self] in
            state.groups.insert(space, at: min(g, state.groups.count))
        }
    }

    func setGroupHidden(_ hidden: Bool, group id: UUID) {
        guard let g = groupIndex(id) else { return }
        state.groups[g].isHidden = hidden
        if hidden { hideRevealed(inGroup: id); if editingBlock != nil { editingBlock = nil } }
    }

    func setOrigin(group id: UUID, x: Double, topY: Double) {
        guard let g = groupIndex(id) else { return }
        state.groups[g].originX = x
        state.groups[g].topY = topY
    }

    func zoomIn(group id: UUID) { setZoom(Zoom.next(zoom(of: id)), group: id) }
    func zoomOut(group id: UUID) { setZoom(Zoom.previous(zoom(of: id)), group: id) }
    func resetZoom(group id: UUID) { setZoom(1.0, group: id) }

    func zoom(of id: UUID) -> Double { groupIndex(id).map { state.groups[$0].zoom } ?? 1.0 }

    private func setZoom(_ z: Double, group id: UUID) {
        guard let g = groupIndex(id), state.groups[g].zoom != z else { return }
        state.groups[g].zoom = z
    }

    // MARK: Sticks

    /// Index into the group's visible sticks → index into all sticks (hidden ones keep their slots).
    private func absoluteIndex(forVisible visible: Int?, in group: StickGroup) -> Int {
        let vis = group.visibleSticks
        guard let visible, visible < vis.count, let idx = group.sticks.firstIndex(where: { $0.id == vis[visible].id }) else {
            return group.sticks.count
        }
        return idx
    }

    @discardableResult
    func addStick(name: String, group id: UUID?, atVisible index: Int? = nil) -> (group: UUID, stick: UUID) {
        var stick = Stick(name: name)
        stick.isExpanded = true
        let result = insert([stick], group: id, atVisible: index).first.map { (groupOf($0), $0) } ?? (UUID(), stick.id)
        setExpanded(true, stick: result.1)   // closes the others in a one-at-a-time space
        return result
    }

    private func groupOf(_ stick: UUID) -> UUID { groupID(ofStick: stick) ?? UUID() }

    /// Inserts copies with fresh identifiers; never overwrites anything existing.
    @discardableResult
    func insert(_ sticks: [Stick], group id: UUID?, atVisible index: Int? = nil, spaceName: String = "Space") -> [UUID] {
        var fresh = sticks.map { s -> Stick in
            var c = s
            c.id = UUID()
            c.blocks = s.blocks.map { var b = $0; b.id = UUID(); return b }
            return c
        }
        if fresh.isEmpty { return [] }
        let ids = fresh.map(\.id)
        if let id, let g = groupIndex(id) {
            let at = absoluteIndex(forVisible: index, in: state.groups[g])
            state.groups[g].sticks.insert(contentsOf: fresh, at: at)
        } else {
            for i in fresh.indices { fresh[i].isHidden = false }
            addSpace(name: spaceName, groups: fresh)
        }
        return ids
    }

    func renameStick(_ id: UUID, to name: String) {
        guard let l = locate(stick: id) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        state.groups[l.group].sticks[l.stick].name = trimmed
    }

    func setExpanded(_ expanded: Bool, stick id: UUID) {
        guard let l = locate(stick: id) else { return }
        state.groups[l.group].sticks[l.stick].isExpanded = expanded
        if !expanded { hideRevealed(inStick: id) }
        else if state.groups[l.group].isExclusive { collapseOthers(except: id, inSpace: l.group) }
    }

    private func collapseOthers(except id: UUID, inSpace g: Int) {
        for s in state.groups[g].sticks.indices where state.groups[g].sticks[s].id != id && state.groups[g].sticks[s].isExpanded {
            state.groups[g].sticks[s].isExpanded = false
            hideRevealed(inStick: state.groups[g].sticks[s].id)
        }
    }

    /// Turning it on keeps the first open group open and closes the rest.
    func setExclusive(_ on: Bool, space id: UUID) {
        guard let g = groupIndex(id) else { return }
        state.groups[g].isExclusive = on
        if on, let keep = state.groups[g].sticks.first(where: \.isExpanded) { collapseOthers(except: keep.id, inSpace: g) }
    }

    func setHidden(_ hidden: Bool, stick id: UUID) {
        guard let l = locate(stick: id) else { return }
        state.groups[l.group].sticks[l.stick].isHidden = hidden
        if hidden { hideRevealed(inStick: id) }
    }

    /// Applies a new order. `ids` is either every group (hidden ones listed too) or just the visible ones,
    /// in which case hidden groups keep their positions. Anything else is ignored.
    func setVisibleOrder(_ ids: [UUID], group id: UUID) {
        guard let g = groupIndex(id), let result = Self.reordered(state.groups[g].sticks, by: ids, isHidden: \.isHidden) else { return }
        state.groups[g].sticks = result
    }

    private static func reordered<T: Identifiable>(_ items: [T], by ids: [UUID], isHidden: (T) -> Bool) -> [T]? where T.ID == UUID {
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let ordered = ids.compactMap { byID[$0] }
        guard ordered.count == ids.count else { return nil }
        let slots: [Int]
        if ordered.count == items.count {
            slots = Array(items.indices)
        } else if ordered.count == items.filter({ !isHidden($0) }).count, ordered.allSatisfy({ !isHidden($0) }) {
            slots = items.indices.filter { !isHidden(items[$0]) }
        } else {
            return nil
        }
        var result = items
        for (slot, item) in zip(slots, ordered) { result[slot] = item }
        return result
    }

    func deleteStick(_ id: UUID) {
        guard let l = locate(stick: id) else { return }
        let group = state.groups[l.group]
        let stick = group.sticks[l.stick]
        hideRevealed(inStick: id)
        state.groups[l.group].sticks.remove(at: l.stick)
        pushUndo("Group deleted") { [unowned self] in
            if let g = groupIndex(group.id) {
                state.groups[g].sticks.insert(stick, at: min(l.stick, state.groups[g].sticks.count))
            }
        }
    }

    // MARK: Blocks

    @discardableResult
    func addBlock(to stick: UUID, edit: Bool = true) -> UUID? {
        guard let l = locate(stick: stick) else { return nil }
        let block = Block()
        state.groups[l.group].sticks[l.stick].blocks.append(block)
        setExpanded(true, stick: stick)
        if edit { editingBlock = block.id }
        return block.id
    }

    func updateBlock(_ id: UUID, _ change: (inout Block) -> Void) {
        guard let l = locate(block: id) else { return }
        change(&state.groups[l.group].sticks[l.stick].blocks[l.block])
    }

    func setText(_ text: String, block id: UUID) {
        updateBlock(id) {
            guard $0.text != text else { return }
            $0.text = text
        }
    }

    func setTitle(_ title: String, block id: UUID) { updateBlock(id) { $0.title = title } }
    func setTags(_ tags: [String], block id: UUID) { updateBlock(id) { $0.tags = Tags.clean(tags) } }

    /// Every tag in use, for suggestions: most used first.
    var knownTags: [String] {
        var count: [String: Int] = [:]
        for b in state.groups.flatMap(\.sticks).flatMap(\.blocks) { for t in b.tags { count[t, default: 0] += 1 } }
        return count.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.map(\.key)
    }

    func setType(_ type: BlockType, block id: UUID) { updateBlock(id) { $0.type = type } }

    func setMasked(_ masked: Bool, block id: UUID) {
        updateBlock(id) { $0.isMasked = masked }
        if masked { hideReveal(id) }
    }

    func setHidden(_ hidden: Bool, block id: UUID) {
        updateBlock(id) { $0.isHidden = hidden }
        if hidden { hideReveal(id); if editingBlock == id { editingBlock = nil } }
    }

    /// Reorders the entities of a group (all of them, or only the visible ones; see `setVisibleOrder`).
    func setBlockOrder(_ ids: [UUID], stick id: UUID) {
        guard let l = locate(stick: id),
              let result = Self.reordered(state.groups[l.group].sticks[l.stick].blocks, by: ids, isHidden: \.isHidden) else { return }
        state.groups[l.group].sticks[l.stick].blocks = result
    }

    func deleteBlock(_ id: UUID) {
        guard let l = locate(block: id) else { return }
        let stickID = state.groups[l.group].sticks[l.stick].id
        let block = state.groups[l.group].sticks[l.stick].blocks[l.block]
        hideReveal(id)
        if editingBlock == id { editingBlock = nil }
        state.groups[l.group].sticks[l.stick].blocks.remove(at: l.block)
        pushUndo("Entity deleted") { [unowned self] in
            guard let s = locate(stick: stickID) else { return }
            let count = state.groups[s.group].sticks[s.stick].blocks.count
            state.groups[s.group].sticks[s.stick].blocks.insert(block, at: min(l.block, count))
        }
    }

    // MARK: Reveal (temporary, never persisted)

    func toggleReveal(_ id: UUID) {
        if revealed.contains(id) { revealed.remove(id) } else { revealed.insert(id) }
    }

    func hideReveal(_ id: UUID) { revealed.remove(id) }

    func hideRevealed(inStick id: UUID) {
        guard let s = stick(id) else { return }
        revealed.subtract(s.blocks.map(\.id))
    }

    func hideRevealed(inGroup id: UUID) {
        guard let g = groupIndex(id) else { return }
        revealed.subtract(state.groups[g].sticks.flatMap(\.blocks).map(\.id))
    }

    // MARK: Undo

    var canUndo: Bool { !undoStack.isEmpty }

    private func pushUndo(_ message: String, _ undo: @escaping () -> Void) {
        undoStack.append(UndoEntry(undo: undo))
        if undoStack.count > 50 { undoStack.removeFirst() }
        toast = Toast(message: message)
    }

    func undo() {
        guard let entry = undoStack.popLast() else { return }
        entry.undo()
        toast = nil
    }
}
