import SwiftUI

/// Entry points into the helper windows, injected so views never reach for global state.
struct WindowActions {
    var newStick: (_ group: UUID?, _ visibleIndex: Int?) -> Void = { _, _ in }
    var rename: (_ stick: UUID) -> Void = { _ in }
    var importInto: (_ group: UUID, _ visibleIndex: Int?) -> Void = { _, _ in }
    var export: (_ stick: UUID) -> Void = { _ in }
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
        let sticks = g.visibleSticks
        let byID = Dictionary(uniqueKeysWithValues: sticks.map { ($0.id, $0) })
        let order = drag?.order ?? sticks.map(\.id)

        let content = ZStack(alignment: .topLeading) {
            VStack(spacing: Metrics.gap * z) {
                ForEach(order, id: \.self) { id in
                    if let stick = byID[id] {
                        let lifted = drag?.id == id
                        StickView(
                            store: store, stick: stick, groupID: g.id,
                            visibleIndex: sticks.firstIndex { $0.id == id } ?? 0,
                            isPinHolder: id == sticks.first?.id, isPinned: g.isPinned, actions: actions,
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
        }
        .frame(width: Metrics.width * z)
        .coordinateSpace(name: "group")
        .onPreferenceChange(FramesKey.self) { frames = $0 }
        .environment(\.zoom, z)
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
    let isPinHolder: Bool
    let isPinned: Bool
    let actions: WindowActions
    let onGripChanged: (DragGesture.Value) -> Void
    let onGripEnded: (DragGesture.Value) -> Void

    @Environment(\.zoom) private var z
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showSections = false
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

    private var shownBlocks: [Block] { stick.blocks.filter { !$0.isHidden } }

    var body: some View {
        VStack(spacing: 0) {
            header
            if stick.isExpanded {
                content.transition(.opacity)
            }
        }
        .foregroundStyle(Palette.text(scheme))
        .stickSurface()
        .onHover { hovering = $0 }
        .popover(isPresented: $showSections, arrowEdge: .bottom) {
            SectionsPopover(store: store, stickID: stick.id)
        }
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
                .accessibilityHint("Use the Move actions to change this stick's position")

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
            .accessibilityAction(named: "Add line") { store.addBlock(to: stick.id) }
            .accessibilityAction(named: "Add stick below") { actions.newStick(groupID, visibleIndex + 1) }
            .accessibilityAction(named: "Move up") { move(by: -1) }
            .accessibilityAction(named: "Move down") { move(by: 1) }
            .accessibilityAction(named: "Show menu") { showMenu() }

            if stick.isExpanded && hovering {
                IconButton(symbol: "plus", label: "Add line", help: "Add line") {
                    NSApp.activate(ignoringOtherApps: true)
                    store.addBlock(to: stick.id)
                }
                .transition(.opacity)
            }
            if isPinHolder {
                IconButton(symbol: isPinned ? "pin.fill" : "pin",
                           label: isPinned ? "Unpin window" : "Pin window",
                           help: isPinned ? "Unpin: allow moving this window" : "Pin: lock this window in place",
                           tint: isPinned ? Palette.blue : nil,
                           rotation: 45) {
                    store.setPinned(!isPinned, group: groupID)
                }
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
        var ids = store.state.groups[g].visibleSticks.map(\.id)
        guard let i = ids.firstIndex(of: stick.id), ids.indices.contains(i + delta) else { return }
        ids.swapAt(i, i + delta)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { store.setVisibleOrder(ids, group: groupID) }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addAction("Rename") { actions.rename(stick.id) }
        menu.addAction("Hide") { store.setHidden(true, stick: stick.id) }
        menu.addAction("Lines…") { showSections = true }
        let hiddenLines = stick.blocks.filter(\.isHidden)
        menu.addSubmenu("Show Hidden Lines…", enabled: !hiddenLines.isEmpty) { sub in
            for line in hiddenLines { sub.addAction(line.menuTitle) { store.setHidden(false, block: line.id) } }
        }
        menu.addItem(.separator())
        menu.addAction("Add Stick Above") { actions.newStick(groupID, visibleIndex) }
        menu.addAction("Add Stick Below") { actions.newStick(groupID, visibleIndex + 1) }
        let hidden = store.groupIndex(groupID).map { store.state.groups[$0].sticks.filter(\.isHidden) } ?? []
        menu.addSubmenu("Show Hidden Sticks…", enabled: !hidden.isEmpty) { sub in
            for s in hidden { sub.addAction(s.name) { store.setHidden(false, stick: s.id) } }
        }
        menu.addItem(.separator())
        let zoom = store.zoom(of: groupID)
        menu.addAction("Zoom In", key: "+", enabled: zoom < Zoom.steps.last!) { store.zoomIn(group: groupID) }
        menu.addAction("Zoom Out", key: "-", enabled: zoom > Zoom.steps.first!) { store.zoomOut(group: groupID) }
        menu.addAction("Actual Size", key: "0", enabled: zoom != 1) { store.resetZoom(group: groupID) }
        menu.addItem(.separator())
        menu.addAction("Import") { actions.importInto(groupID, visibleIndex + 1) }
        menu.addAction("Export") { actions.export(stick.id) }
        menu.addItem(.separator())
        menu.addAction("Delete Stick", destructive: true) { store.deleteStick(stick.id) }
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
                        Text("Add lines…")
                        Spacer()
                    }
                    .font(.system(size: 13 * z))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8 * z)
                    .frame(height: Metrics.rowHeight * z)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add lines")
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

// MARK: - Block row

struct BlockRow: View {
    @ObservedObject var store: AppStore
    let block: Block
    var onGripChanged: (DragGesture.Value) -> Void = { _ in }
    var onGripEnded: (DragGesture.Value) -> Void = { _ in }

    @Environment(\.zoom) private var z
    @Environment(\.colorScheme) private var scheme
    @State private var copied = false

    private var isEditing: Bool { store.editingBlock == block.id }
    private var revealed: Bool { store.revealed.contains(block.id) }
    private var showsMask: Bool { block.isMasked && !revealed }

    private var icon: String {
        if block.isMasked { return "lock.fill" }
        switch block.kind {
        case .text: return "doc.text"
        case .link: return "link"
        case .code: return "chevron.right"
        }
    }

    var body: some View {
        Group {
            if isEditing { editor } else { display }
        }
        .padding(.horizontal, 8 * z)
        .padding(.vertical, 3 * z)
        .frame(minHeight: Metrics.rowHeight * z)
    }

    private func iconView(grip: Bool = false) -> some View {
        let image = Image(systemName: icon)
            .font(.system(size: 12 * z, weight: block.kind == .code && !block.isMasked ? .bold : .regular))
            .foregroundStyle(block.isMasked ? Palette.icon(scheme) : Color.secondary)
            .frame(width: 18 * z, height: 22 * z)
        if grip {
            return AnyView(image
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("group"))
                    .onChanged(onGripChanged).onEnded(onGripEnded))
                .help("Drag to reorder")
                .accessibilityLabel("Reorder line"))
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
            actions
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 5, coordinateSpace: .named("group"))
            .onChanged(onGripChanged).onEnded(onGripEnded))
        .overlay(ContextMenuArea(build: contextMenu))
    }

    @ViewBuilder private var textView: some View {
        if showsMask {
            Text(verbatim: "••••••••")
                .font(.system(size: 13 * z, design: .monospaced))
                .accessibilityLabel("Sensitive content, hidden")
        } else if block.text.isEmpty {
            Text("Empty").font(.system(size: 13 * z)).foregroundStyle(.tertiary)
        } else {
            switch block.kind {
            case .code:
                Text(verbatim: block.text).font(.system(size: 12.5 * z, design: .monospaced))
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
        return (stick.id, stick.blocks.filter { !$0.isHidden }.map(\.id))
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
        menu.addAction("Edit") { beginEdit() }
        menu.addAction("Copy") { copy() }
        menu.addSubmenu("Type") { sub in
            for type in BlockType.allCases {
                sub.addAction(type.title, checked: block.type == type) { store.setType(type, block: block.id) }
            }
        }
        menu.addItem(.separator())
        menu.addAction("Move Up", enabled: canMove(-1)) { move(-1) }
        menu.addAction("Move Down", enabled: canMove(1)) { move(1) }
        menu.addItem(.separator())
        menu.addAction("Hide Line") { store.setHidden(true, block: block.id) }
        menu.addAction("Mask Content", checked: block.isMasked) { store.setMasked(!block.isMasked, block: block.id) }
        menu.addItem(.separator())
        menu.addAction("Delete Line", destructive: true) { store.deleteBlock(block.id) }
        return menu
    }

    // MARK: Editing

    private var editor: some View {
        HStack(alignment: .top, spacing: 6 * z) {
            iconView()
            VStack(alignment: .leading, spacing: 5 * z) {
                InlineEditor(
                    text: Binding(get: { store.block(block.id)?.text ?? "" }, set: { store.setText($0, block: block.id) }),
                    fontSize: 13 * z, monospaced: block.type == .code,
                    onFinish: { store.editingBlock = nil })
                    .padding(.horizontal, 6 * z)
                    .padding(.vertical, 4 * z)
                    .background(RoundedRectangle(cornerRadius: 5 * z).fill(scheme == .dark ? Color.black.opacity(0.25) : Color.white.opacity(0.9)))
                    .overlay(RoundedRectangle(cornerRadius: 5 * z).strokeBorder(Palette.blue, lineWidth: 1.5))
                HStack(alignment: .center, spacing: 6 * z) {
                    Button { store.deleteBlock(block.id) } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10.5 * z))
                            .foregroundStyle(Color.red)
                            .frame(width: Self.controlHeight * z + 6 * z, height: Self.controlHeight * z)
                            .overlay(RoundedRectangle(cornerRadius: 5 * z).strokeBorder(Palette.separator(scheme).opacity(2), lineWidth: 0.5))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Delete this line (undo with ⌘Z)")
                    .accessibilityLabel("Delete line")
                    typePicker
                    Spacer(minLength: 0)
                    Button { store.editingBlock = nil } label: {
                        Text("Done")
                            .font(.system(size: 11 * z, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12 * z)
                            .frame(height: Self.controlHeight * z)
                            .background(RoundedRectangle(cornerRadius: 5 * z).fill(Palette.blue))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Finish editing (⌘↩ or Esc)")
                    .accessibilityLabel("Done editing")
                }
            }
            .padding(.bottom, 2 * z)
        }
    }

    /// Height shared by the type picker and the Done button so they line up.
    private static let controlHeight: CGFloat = 20

    private static let typeSymbols: [BlockType: String] = [
        .auto: "sparkles", .text: "doc.text", .link: "link", .code: "chevron.left.forwardslash.chevron.right",
    ]

    /// Icon-only segments; the selected one also shows its name.
    private var typePicker: some View {
        HStack(spacing: 0) {
            ForEach(BlockType.allCases, id: \.self) { type in
                let selected = block.type == type
                Button { store.setType(type, block: block.id) } label: {
                    HStack(spacing: 4 * z) {
                        Image(systemName: Self.typeSymbols[type] ?? "questionmark").font(.system(size: 10 * z))
                    }
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .fixedSize()
                    .padding(.horizontal, 11 * z)
                    .frame(height: Self.controlHeight * z)
                    .background(selected ? Palette.blue : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(type == .auto ? "Auto: detect links" : type.title)
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

// MARK: - Sections popover

struct SectionsPopover: View {
    @ObservedObject var store: AppStore
    let stickID: UUID

    var body: some View {
        let blocks = store.stick(stickID)?.blocks ?? []
        VStack(alignment: .leading, spacing: 0) {
            if blocks.isEmpty {
                Text("No lines yet.").foregroundStyle(.secondary).padding(12)
            }
            ForEach(blocks) { b in
                HStack(spacing: 6) {
                    Toggle(isOn: Binding(get: { !b.isHidden }, set: { store.setHidden(!$0, block: b.id) })) {
                        Text(verbatim: b.menuTitle).lineLimit(1)
                    }
                    .toggleStyle(.checkbox)
                    .accessibilityLabel(b.menuTitle)
                    Spacer(minLength: 8)
                    Menu {
                        Button(b.isHidden ? "Show Line" : "Hide Line") { store.setHidden(!b.isHidden, block: b.id) }
                        Button("Delete Line", role: .destructive) { store.deleteBlock(b.id) }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Line actions")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
            }
            Divider().padding(.top, 4)
            HStack {
                Text("Hidden lines can also be deleted from here.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Button { NSApp.activate(ignoringOtherApps: true); store.addBlock(to: stickID) } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("Add line")
                    .accessibilityLabel("Add line")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 270)
        .padding(.top, 6)
    }
}
