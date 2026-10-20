import SwiftUI

/// Entry points into the helper windows, injected so views never reach for global state.
struct WindowActions {
    /// "stick" is a group in the UI; "group" is a space.
    var newStick: (_ space: UUID?, _ visibleIndex: Int?) -> Void = { _, _ in }
    var rename: (_ stick: UUID) -> Void = { _ in }
    var renameSpace: (_ space: UUID) -> Void = { _ in }
    var importInto: (_ space: UUID, _ visibleIndex: Int?) -> Void = { _, _ in }
    var export: (_ stick: UUID) -> Void = { _ in }
    var exportSpace: (_ space: UUID) -> Void = { _ in }
}

private struct FramesKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) { value.merge(nextValue()) { $1 } }
}

// MARK: - Group

struct GroupView: View {
    @ObservedObject var store: AppStore
    let groupID: UUID
    let actions: WindowActions
    /// Reports the content's *current* (animated) height so the window can follow it frame by frame.
    var onHeight: (CGFloat) -> Void = { _ in }
    /// True while a stick is being dragged: the window grows a transparent margin so the lifted stick is never clipped.
    var onDragging: (Bool) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var frames: [UUID: CGRect] = [:]
    @State private var drag: DragState?

    private struct DragState: Equatable {
        let id: UUID
        var order: [UUID]
        let startMinY: CGFloat
        let height: CGFloat
        var translation: CGFloat = 0
    }

    private var anim: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.2) }

    var body: some View {
        if let group = store.state.groups.first(where: { $0.id == groupID }) {
            stack(group)
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }

    private func stack(_ g: StickGroup) -> some View {
        let z = CGFloat(g.zoom)
        let showHidden = store.showingHidden.contains(g.id)
        let sticks = showHidden ? g.sticks : g.visibleSticks
        let byID = Dictionary(uniqueKeysWithValues: sticks.map { ($0.id, $0) })
        let order = drag?.order ?? sticks.map(\.id)

        let list = VStack(spacing: Metrics.gap * z) {
            ForEach(order, id: \.self) { id in
                if let stick = byID[id] {
                    let lifted = drag?.id == id
                    StickView(
                        store: store, stick: stick, groupID: g.id,
                        visibleIndex: sticks.prefix { $0.id != id }.filter { !$0.isHidden }.count,
                        isPinned: g.isPinned, actions: actions,
                        onGripChanged: { gripChanged(id, $0, sticks: sticks) },
                        onGripEnded: { _ in gripEnded() }
                    )
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: FramesKey.self, value: [id: proxy.frame(in: .named("group"))])
                    })
                    .scaleEffect(lifted ? 1.015 : 1)
                    .shadow(color: .black.opacity(lifted ? 0.30 : 0), radius: 10 * z, y: 4 * z)
                    .offset(y: dragOffset(id, z: z))
                    .zIndex(lifted ? 1 : 0)
                }
            }
        }
        .padding(.vertical, Metrics.edge * z)
        .animation(anim, value: order)
        .coordinateSpace(name: "group")
        .onPreferenceChange(FramesKey.self) { frames = $0 }

        // Same recipe as a group's rows: the groups are inserted at full size inside a clipping container whose height
        // animates, so folding the space slides them away and opening it slides them down from under the header.
        // The mask grows while a group is dragged so the lifted one is never cut off.
        let groups = VStack(spacing: 0) {
            if !g.isCollapsed {
                VStack(spacing: 0) {
                    if sticks.isEmpty { AddGroupRow(actions: actions, spaceID: g.id) } else { list }
                }
                .padding(.top, Metrics.gap * z)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .mask { Rectangle().padding(drag == nil ? 0 : -80 * z) }

        let content = VStack(spacing: 0) {
            SpaceHeader(store: store, space: g, actions: actions, onToggle: { toggleSpace(g) })
                .zIndex(1)
            groups
        }
        .frame(width: CGFloat(g.width) * z)
        .environment(\.zoom, z)
        .environment(\.showsHidden, showHidden)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }

        // The window may briefly be taller than the content (it jumps to the final height while the content animates).
        // A trailing Spacer pins the stack to the top so the row being toggled never moves.
        return VStack(spacing: 0) {
            content
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func toggleSpace(_ g: StickGroup) {
        withAnimation(anim) { store.setCollapsed(!g.isCollapsed, space: g.id) }
    }

    // MARK: Reorder

    private func top(of id: UUID, in order: [UUID], z: CGFloat) -> CGFloat {
        var y = Metrics.edge * z
        for other in order {
            if other == id { break }
            y += (frames[other]?.height ?? 0) + Metrics.gap * z
        }
        return y
    }

    private func dragOffset(_ id: UUID, z: CGFloat) -> CGFloat {
        guard let d = drag, d.id == id else { return 0 }
        return d.startMinY + d.translation - top(of: id, in: d.order, z: z)
    }

    private func gripChanged(_ id: UUID, _ value: DragGesture.Value, sticks: [Stick]) {
        let z = CGFloat(store.zoom(of: groupID))
        if drag == nil {
            guard let frame = frames[id] else { return }
            drag = DragState(id: id, order: sticks.map(\.id), startMinY: frame.minY, height: frame.height)
            onDragging(true)
        }
        guard var d = drag else { return }
        let total = Metrics.edge * z * 2 + sticks.reduce(0) { $0 + (frames[$1.id]?.height ?? 0) } + Metrics.gap * z * CGFloat(max(0, sticks.count - 1))
        let limit = Metrics.dragMargin * z * 0.8
        d.translation = min(max(value.translation.height, -d.startMinY - limit), total - d.startMinY - d.height + limit)
        let center = d.startMinY + d.translation + d.height / 2
        let others = d.order.filter { $0 != id }
        var y = Metrics.edge * z
        var index = 0
        for other in others {
            let h = frames[other]?.height ?? 0
            if center > y + h / 2 { index += 1 }
            y += h + Metrics.gap * z
        }
        var newOrder = others
        newOrder.insert(id, at: min(index, others.count))
        d.order = newOrder
        drag = d
    }

    private func gripEnded() {
        guard let d = drag else { return }
        withAnimation(anim) {
            store.setVisibleOrder(d.order, group: groupID)
            drag = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { if drag == nil { onDragging(false) } }
    }
}

// MARK: - Stick

struct StickView: View {
    @ObservedObject var store: AppStore
    let stick: Stick
    let groupID: UUID
    let visibleIndex: Int
    let isPinned: Bool
    let actions: WindowActions
    let onGripChanged: (DragGesture.Value) -> Void
    let onGripEnded: (DragGesture.Value) -> Void

    @Environment(\.zoom) private var z
    @Environment(\.showsHidden) private var showsHidden
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var blockFrames: [UUID: CGRect] = [:]
    @State private var blockDrag: BlockDrag?

    private struct BlockDrag: Equatable {
        let id: UUID
        var order: [UUID]
        let startMinY: CGFloat
        let height: CGFloat
        var translation: CGFloat = 0
    }

    private var shownBlocks: [Block] { showsHidden ? stick.blocks : stick.blocks.filter { !$0.isHidden } }

    var body: some View {
        VStack(spacing: 0) {
            header
            if stick.isExpanded {
                content.transition(.opacity)
            }
        }
        .foregroundStyle(Palette.text(scheme))
        .stickSurface()
        .opacity(stick.isHidden ? 0.5 : 1)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(stick.name)
    }

    private func toggle() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            store.setExpanded(!stick.isExpanded, stick: stick.id)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 0) {
            GripDots()
                .frame(width: 22 * z, height: Metrics.headerHeight * z)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("group"))
                    .onChanged(onGripChanged).onEnded(onGripEnded))
                .help("Drag to reorder")
                .accessibilityLabel("Reorder")
                .accessibilityHint("Use the Move actions to change this group's position")

            HStack(spacing: 6 * z) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11 * z, weight: .semibold))
                    .foregroundStyle(Palette.icon(scheme))
                    .rotationEffect(.degrees(stick.isExpanded ? 90 : 0))
                    .frame(width: 14 * z)
                Text(stick.name)
                    .font(.system(size: 13 * z))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Metrics.headerHeight * z)
            .contentShape(Rectangle())
            .overlay(DragClickArea(canDrag: !isPinned, doubleClickOnly: true, onClick: toggle, onContextMenu: showMenu))
            .help("Double-click to expand or collapse")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(stick.name)
            .accessibilityValue(stick.isExpanded ? "Expanded" : "Collapsed")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { toggle() }
            .accessibilityAction(named: "Add entity") { store.addBlock(to: stick.id) }
            .accessibilityAction(named: "Add group below") { actions.newStick(groupID, visibleIndex + 1) }
            .accessibilityAction(named: "Move up") { move(by: -1) }
            .accessibilityAction(named: "Move down") { move(by: 1) }
            .accessibilityAction(named: "Show menu") { showMenu() }

            if stick.isExpanded && hovering && !stick.isHidden {
                IconButton(symbol: "plus", label: "Add entity", help: "Add entity") {
                    NSApp.activate(ignoringOtherApps: true)
                    store.addBlock(to: stick.id)
                }
                .transition(.opacity)
            }
            let links = stick.openableLinks
            IconButton(symbol: "arrow.up.right", label: "Open all links",
                       help: links.isEmpty ? "No links to open"
                                           : "Open all links (\(links.count)) · ⌘-click opens in background",
                       enabled: !links.isEmpty) {
                LinkOpener.open(links, background: LinkOpener.commandHeld)
            }
        }
        .padding(.horizontal, 4 * z)
        .frame(height: Metrics.headerHeight * z)
    }

    private func move(by delta: Int) {
        guard let g = store.groupIndex(groupID) else { return }
        var ids = (showsHidden ? store.state.groups[g].sticks : store.state.groups[g].visibleSticks).map(\.id)
        guard let i = ids.firstIndex(of: stick.id), ids.indices.contains(i + delta) else { return }
        ids.swapAt(i, i + delta)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { store.setVisibleOrder(ids, group: groupID) }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addAction("Rename") { actions.rename(stick.id) }
        menu.addAction("Hide", checked: stick.isHidden) { store.setHidden(!stick.isHidden, stick: stick.id) }
        menu.addItem(.separator())
        menu.addAction("Add Group Above") { actions.newStick(groupID, visibleIndex) }
        menu.addAction("Add Group Below") { actions.newStick(groupID, visibleIndex + 1) }
        menu.addItem(.separator())
        menu.addAction("Import Group") { actions.importInto(groupID, visibleIndex + 1) }
        menu.addAction("Export") { actions.export(stick.id) }
        menu.addItem(.separator())
        menu.addAction("Delete", destructive: true) { store.deleteStick(stick.id) }
        menu.popUpAtCurrentEvent()
    }

    // MARK: Content

    private var content: some View {
        VStack(spacing: 0) {
            if shownBlocks.isEmpty {
                separator
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    store.addBlock(to: stick.id)
                } label: {
                    HStack(spacing: 6 * z) {
                        Image(systemName: "doc.text").frame(width: 18 * z)
                        Text("Add entities…")
                        Spacer()
                    }
                    .font(.system(size: 13 * z))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8 * z)
                    .frame(height: Metrics.rowHeight * z)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add entities")
            } else {
                let byID = Dictionary(uniqueKeysWithValues: shownBlocks.map { ($0.id, $0) })
                let order = blockDrag?.order ?? shownBlocks.map(\.id)
                VStack(spacing: 0) {
                    ForEach(order, id: \.self) { id in
                        if let block = byID[id] {
                            let lifted = blockDrag?.id == id
                            VStack(spacing: 0) {
                                separator
                                BlockRow(store: store, block: block,
                                         onGripChanged: { blockGripChanged(id, $0) },
                                         onGripEnded: { _ in blockGripEnded() })
                            }
                            .background(GeometryReader { proxy in
                                Color.clear.preference(key: FramesKey.self, value: [id: proxy.frame(in: .named("blocks-\(stick.id)"))])
                            })
                            .background(lifted ? Palette.blue.opacity(0.10) : Color.clear)
                            .scaleEffect(lifted ? 1.015 : 1)
                            .shadow(color: .black.opacity(lifted ? 0.25 : 0), radius: 8 * z, y: 3 * z)
                            .offset(y: blockDragOffset(id))
                            .zIndex(lifted ? 1 : 0)
                        }
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: order)
                .coordinateSpace(name: "blocks-\(stick.id)")
                .onPreferenceChange(FramesKey.self) { blockFrames = $0 }
            }
        }
        .clipped()
    }

    // MARK: Section reorder

    private func blockTop(of id: UUID, in order: [UUID]) -> CGFloat {
        var y: CGFloat = 0
        for other in order {
            if other == id { break }
            y += blockFrames[other]?.height ?? 0
        }
        return y
    }

    private func blockDragOffset(_ id: UUID) -> CGFloat {
        guard let d = blockDrag, d.id == id else { return 0 }
        return d.startMinY + d.translation - blockTop(of: id, in: d.order)
    }

    private func blockGripChanged(_ id: UUID, _ value: DragGesture.Value) {
        if blockDrag == nil {
            guard let frame = blockFrames[id] else { return }
            blockDrag = BlockDrag(id: id, order: shownBlocks.map(\.id), startMinY: frame.minY, height: frame.height)
        }
        guard var d = blockDrag else { return }
        let total = d.order.reduce(0) { $0 + (blockFrames[$1]?.height ?? 0) }
        d.translation = min(max(value.translation.height, -d.startMinY), total - d.startMinY - d.height)
        let center = d.startMinY + d.translation + d.height / 2
        let others = d.order.filter { $0 != id }
        var y: CGFloat = 0
        var index = 0
        for other in others {
            let h = blockFrames[other]?.height ?? 0
            if center > y + h / 2 { index += 1 }
            y += h
        }
        var order = others
        order.insert(id, at: min(index, others.count))
        d.order = order
        blockDrag = d
    }

    private func blockGripEnded() {
        guard let d = blockDrag else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            store.setBlockOrder(d.order, stick: stick.id)
            blockDrag = nil
        }
    }

    private var separator: some View {
        Rectangle().fill(Palette.separator(scheme)).frame(height: 0.5)
    }
}

/// Six-dot reorder grip (there is no matching SF Symbol).
struct GripDots: View {
    @Environment(\.zoom) private var z
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 2.2 * z) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 2.4 * z) {
                    Circle().frame(width: 2.4 * z, height: 2.4 * z)
                    Circle().frame(width: 2.4 * z, height: 2.4 * z)
                }
            }
        }
        .foregroundStyle(Palette.icon(scheme).opacity(0.55))
    }
}

// MARK: - Space header

/// The window's own header: always on top, looks like a group row. Name, pin, and a double click that folds the groups away.
struct SpaceHeader: View {
    @ObservedObject var store: AppStore
    let space: StickGroup
    let actions: WindowActions
    let onToggle: () -> Void

    @Environment(\.zoom) private var z
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10 * z, weight: .semibold))
                    .foregroundStyle(Palette.icon(scheme))
                    .rotationEffect(.degrees(space.isCollapsed ? 0 : 90))
                    .frame(width: 22 * z)
                Text(space.name)
                    .font(.system(size: 12 * z, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Metrics.spaceHeaderHeight * z)
            .contentShape(Rectangle())
            .overlay(DragClickArea(canDrag: !space.isPinned, doubleClickOnly: true, onClick: onToggle, onContextMenu: showMenu))
            .help("Double-click to show or hide groups")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(space.name)
            .accessibilityValue(space.isCollapsed ? "Collapsed" : "Expanded")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onToggle() }
            .accessibilityAction(named: "Add group") { actions.newStick(space.id, nil) }
            .accessibilityAction(named: "Show menu") { showMenu() }

            if hovering && !space.isCollapsed {
                IconButton(symbol: "plus", label: "Add group", help: "Add group") { actions.newStick(space.id, nil) }
                    .transition(.opacity)
            }
            IconButton(symbol: space.isPinned ? "pin.fill" : "pin",
                       label: space.isPinned ? "Unpin window" : "Pin window",
                       help: space.isPinned ? "Unpin: allow moving this window" : "Pin: lock this window in place",
                       tint: space.isPinned ? Palette.blue : nil,
                       rotation: 45) {
                store.setPinned(!space.isPinned, group: space.id)
            }
        }
        .padding(.horizontal, 4 * z)
        .frame(height: Metrics.spaceHeaderHeight * z)
        .foregroundStyle(Palette.text(scheme))
        .stickSurface()
        .onHover { hovering = $0 }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addAction("Rename") { actions.renameSpace(space.id) }
        menu.addAction("Add Group") { actions.newStick(space.id, nil) }
        let showing = store.showingHidden.contains(space.id)
        menu.addAction("Hidden", checked: showing, enabled: showing || store.hiddenCount(space: space.id) > 0) {
            store.setShowingHidden(!showing, space: space.id)
        }
        menu.addItem(.separator())
        menu.addAction("Zoom In", key: "+", enabled: space.zoom < Zoom.steps.last!) { store.zoomIn(group: space.id) }
        menu.addAction("Zoom Out", key: "-", enabled: space.zoom > Zoom.steps.first!) { store.zoomOut(group: space.id) }
        menu.addAction("Actual Size", key: "0", enabled: space.zoom != 1) { store.resetZoom(group: space.id) }
        menu.addItem(.separator())
        menu.addAction("Import Group") { actions.importInto(space.id, nil) }
        menu.addAction("Export") { actions.exportSpace(space.id) }
        menu.addItem(.separator())
        menu.addAction("Close") { store.setGroupHidden(true, group: space.id) }
        menu.addAction("Delete", destructive: true) { store.deleteSpace(space.id) }
        menu.popUpAtCurrentEvent()
    }
}

/// Shown in a space that has no visible group yet.
struct AddGroupRow: View {
    let actions: WindowActions
    let spaceID: UUID

    @Environment(\.zoom) private var z
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button { actions.newStick(spaceID, nil) } label: {
            HStack(spacing: 6 * z) {
                Image(systemName: "plus").frame(width: 18 * z)
                Text("Add group…")
                Spacer()
            }
            .font(.system(size: 13 * z))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8 * z)
            .frame(height: Metrics.headerHeight * z)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.text(scheme))
        .stickSurface()
        .accessibilityLabel("Add group")
    }
}

/// Small coloured label. prod / stg / dev have fixed colours; any other tag gets a stable one from its name.
struct TagChip: View {
    let name: String
    @Environment(\.zoom) private var z

    static func color(_ name: String) -> Color {
        switch name.lowercased() {
        case "prod", "production": return .red
        case "stg", "stage", "staging": return .orange
        case "dev", "development": return .green
        default:
            let palette: [Color] = [.blue, .teal, .purple, .pink, .indigo, .brown]
            return palette[name.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff } % palette.count]
        }
    }

    var body: some View {
        let color = Self.color(name)
        Text(verbatim: name)
            .font(.system(size: 10 * z, weight: .medium))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 5 * z)
            .frame(height: 15 * z)
            .background(RoundedRectangle(cornerRadius: 4 * z).fill(color.opacity(0.16)))
            .fixedSize()
    }
}

// MARK: - Block row

struct BlockRow: View {
    @ObservedObject var store: AppStore
    let block: Block
    var onGripChanged: (DragGesture.Value) -> Void = { _ in }
    var onGripEnded: (DragGesture.Value) -> Void = { _ in }

    @Environment(\.zoom) private var z
    @Environment(\.showsHidden) private var showsHidden
    @Environment(\.colorScheme) private var scheme
    @State private var copied = false
    @State private var tagsText = ""

    private var isEditing: Bool { store.editingBlock == block.id }
    private var revealed: Bool { store.revealed.contains(block.id) }
    private var showsMask: Bool { block.isMasked && !revealed }

    private var icon: String {
        if block.isMasked { return "lock.fill" }
        switch block.kind {
        case .text: return "doc.text"
        case .link: return "link"
        }
    }

    var body: some View {
        Group {
            if isEditing { editor } else { display }
        }
        .opacity(block.isHidden ? 0.5 : 1)
        .padding(.horizontal, 8 * z)
        .padding(.vertical, 3 * z)
        .frame(minHeight: Metrics.rowHeight * z)
    }

    private func iconView(grip: Bool = false) -> some View {
        let image = Image(systemName: icon)
            .font(.system(size: 12 * z))
            .foregroundStyle(block.isMasked ? Palette.icon(scheme) : Color.secondary)
            .frame(width: 18 * z, height: 22 * z)
        if grip {
            return AnyView(image
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("group"))
                    .onChanged(onGripChanged).onEnded(onGripEnded))
                .help("Drag to reorder")
                .accessibilityLabel("Reorder entity"))
        }
        return AnyView(image.accessibilityHidden(true))
    }

    // MARK: Display

    private var display: some View {
        HStack(alignment: .top, spacing: 6 * z) {
            iconView()
            textView
                .padding(.vertical, 3 * z)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { beginEdit() }
                .help(block.hasTitle && !block.isMasked ? block.text : "")
            if !block.tags.isEmpty {
                HStack(spacing: 3 * z) { ForEach(block.tags, id: \.self) { TagChip(name: $0) } }
                    .padding(.top, 4 * z)
            }
            actions
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 5, coordinateSpace: .named("group"))
            .onChanged(onGripChanged).onEnded(onGripEnded))
        .overlay(ContextMenuArea(build: contextMenu))
    }

    @ViewBuilder private var textView: some View {
        if showsMask && block.hasTitle {
            Text(verbatim: block.title).font(.system(size: 13 * z))
        } else if showsMask {
            Text(verbatim: "••••••••")
                .font(.system(size: 13 * z, design: .monospaced))
                .accessibilityLabel("Sensitive content, hidden")
        } else if block.hasTitle {
            Text(verbatim: block.title).font(.system(size: 13 * z))
                .foregroundStyle(block.linkURL != nil ? Palette.link(scheme) : Palette.text(scheme))
        } else if block.text.isEmpty {
            Text("Empty").font(.system(size: 13 * z)).foregroundStyle(.tertiary)
        } else {
            switch block.kind {
            case .link:
                Text(verbatim: block.text).font(.system(size: 13 * z)).foregroundStyle(Palette.link(scheme))
            case .text:
                Text(verbatim: block.text).font(.system(size: 13 * z))
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 0) {
            if block.isMasked {
                IconButton(symbol: revealed ? "eye.slash" : "eye",
                           label: revealed ? "Hide content" : "Reveal content") { store.toggleReveal(block.id) }
            }
            if !block.isMasked, let url = block.linkURL {
                IconButton(symbol: "arrow.up.right", label: "Open link",
                           help: "Open link · ⌘-click opens in background") {
                    LinkOpener.open([url], background: LinkOpener.commandHeld)
                }
            }
            IconButton(symbol: copied ? "checkmark" : "doc.on.doc",
                       label: "Copy", help: "Copy", tint: copied ? Palette.blue : nil) { copy() }
        }
    }

    private func copy() {
        Clipboard.copy(block.text, concealed: block.isMasked)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }

    private func beginEdit() {
        NSApp.activate(ignoringOtherApps: true)
        store.editingBlock = block.id
    }

    private func siblings() -> (stick: UUID, ids: [UUID])? {
        guard let l = store.locate(block: block.id) else { return nil }
        let stick = store.state.groups[l.group].sticks[l.stick]
        return (stick.id, (showsHidden ? stick.blocks : stick.blocks.filter { !$0.isHidden }).map(\.id))
    }

    private func canMove(_ delta: Int) -> Bool {
        guard let s = siblings(), let i = s.ids.firstIndex(of: block.id) else { return false }
        return s.ids.indices.contains(i + delta)
    }

    private func move(_ delta: Int) {
        guard var s = siblings(), let i = s.ids.firstIndex(of: block.id), s.ids.indices.contains(i + delta) else { return }
        s.ids.swapAt(i, i + delta)
        store.setBlockOrder(s.ids, stick: s.stick)
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addAction("Move Up", enabled: canMove(-1)) { move(-1) }
        menu.addAction("Move Down", enabled: canMove(1)) { move(1) }
        menu.addItem(.separator())
        menu.addAction("Hide", checked: block.isHidden) { store.setHidden(!block.isHidden, block: block.id) }
        menu.addAction("Mask", checked: block.isMasked) { store.setMasked(!block.isMasked, block: block.id) }
        menu.addItem(.separator())
        menu.addAction("Delete", destructive: true) { store.deleteBlock(block.id) }
        return menu
    }

    // MARK: Editing

    private var editor: some View {
        HStack(alignment: .top, spacing: 6 * z) {
            iconView()
            VStack(alignment: .leading, spacing: 5 * z) {
                InlineEditor(
                    text: Binding(get: { store.block(block.id)?.text ?? "" }, set: { store.setText($0, block: block.id) }),
                    fontSize: 13 * z, monospaced: false,
                    onFinish: { store.editingBlock = nil })
                    .padding(.horizontal, 6 * z)
                    .padding(.vertical, 4 * z)
                    .background(RoundedRectangle(cornerRadius: 5 * z).fill(scheme == .dark ? Color.black.opacity(0.25) : Color.white.opacity(0.9)))
                    .overlay(RoundedRectangle(cornerRadius: 5 * z).strokeBorder(Palette.blue, lineWidth: 1.5))
                editorField("Title",
                            text: Binding(get: { store.block(block.id)?.title ?? "" }, set: { store.setTitle($0, block: block.id) }))
                editorField("Tags", text: $tagsText)
                    .onChange(of: tagsText) { _, new in store.setTags(Tags.parse(new), block: block.id) }
                tagSuggestions
                HStack(alignment: .center, spacing: 6 * z) {
                    typePicker
                    Spacer(minLength: 0)
                    Button { store.deleteBlock(block.id) } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10.5 * z))
                            .foregroundStyle(Color.red)
                            .frame(width: Self.controlHeight * z + 6 * z, height: Self.controlHeight * z)
                            .overlay(RoundedRectangle(cornerRadius: 5 * z).strokeBorder(Palette.separator(scheme).opacity(2), lineWidth: 0.5))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Delete this entity (undo with ⌘Z)")
                    .accessibilityLabel("Delete entity")
                    Button { store.editingBlock = nil } label: {
                        Text("Save")
                            .font(.system(size: 11 * z, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12 * z)
                            .frame(height: Self.controlHeight * z)
                            .background(RoundedRectangle(cornerRadius: 5 * z).fill(Palette.blue))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Save (⌘↩ or Esc)")
                    .accessibilityLabel("Save")
                }
            }
            .padding(.bottom, 2 * z)
        }
        .onAppear { tagsText = block.tags.joined(separator: ", ") }
    }

    private func editorField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 12 * z))
            .padding(.horizontal, 6 * z)
            .frame(height: 22 * z)
            .background(RoundedRectangle(cornerRadius: 5 * z).fill(scheme == .dark ? Color.black.opacity(0.25) : Color.white.opacity(0.9)))
            .overlay(RoundedRectangle(cornerRadius: 5 * z).strokeBorder(Palette.separator(scheme).opacity(2), lineWidth: 0.5))
    }

    /// Tags already in use that this entity does not have yet: one click adds them.
    @ViewBuilder private var tagSuggestions: some View {
        let have = Set(block.tags.map { $0.lowercased() })
        let options = Array(store.knownTags.filter { !have.contains($0.lowercased()) }.prefix(6))
        if !options.isEmpty {
            HStack(spacing: 4 * z) {
                ForEach(options, id: \.self) { tag in
                    Button {
                        let new = Tags.clean(block.tags + [tag])
                        store.setTags(new, block: block.id)
                        tagsText = new.joined(separator: ", ")
                    } label: { TagChip(name: tag) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Add tag \(tag)")
                }
            }
        }
    }

    /// Height shared by the type picker and the Save button so they line up.
    private static let controlHeight: CGFloat = 20

    private static let typeSymbols: [BlockType: String] = [
        .text: "doc.text", .link: "link",
    ]

    /// Icon-only segments; the selected one also shows its name.
    private var typePicker: some View {
        HStack(spacing: 0) {
            ForEach(BlockType.allCases, id: \.self) { type in
                let selected = block.type == type
                Button { store.setType(type, block: block.id) } label: {
                    Image(systemName: Self.typeSymbols[type] ?? "questionmark")
                        .font(.system(size: 10.5 * z))
                        .frame(width: 14 * z, height: 14 * z)
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        // Same box for every type, whatever the glyph's own width.
                        .frame(width: 36 * z, height: Self.controlHeight * z)
                    .background(selected ? Palette.blue : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(type == .link ? "Link: shows an open button" : "Text")
                .accessibilityLabel("Type \(type.title)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5 * z))
        .overlay(RoundedRectangle(cornerRadius: 5 * z).strokeBorder(Palette.separator(scheme).opacity(2), lineWidth: 0.5))
    }
}

/// Right-click (or ⌃-click) menu on a region. Left clicks and hover pass straight through to the SwiftUI content below.
struct ContextMenuArea: NSViewRepresentable {
    let build: () -> NSMenu

    func makeNSView(context: Context) -> MenuView { MenuView() }
    func updateNSView(_ view: MenuView, context: Context) { view.build = build }

    final class MenuView: NSView {
        var build: (() -> NSMenu)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let e = NSApp.currentEvent else { return nil }
            let isContext = e.type == .rightMouseDown || (e.type == .leftMouseDown && e.modifierFlags.contains(.control))
            return isContext ? super.hitTest(point) : nil
        }

        private func pop(_ event: NSEvent) {
            if let menu = build?() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
        }

        override func rightMouseDown(with event: NSEvent) { pop(event) }
        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { pop(event) } else { super.mouseDown(with: event) }
        }
    }
}
