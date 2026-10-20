import AppKit
import SwiftUI
import Combine

// MARK: - Group window

/// Borderless panel for one group. Clicking it activates StickSpace (like Stickies) so shortcuts and typing work;
/// merely pinning or hiding never activates anything.
final class GroupPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        return keyHandler?(event) ?? false
    }
}

final class TopPinnedContainer: NSView {
    static let hostHeight: CGFloat = 3000
    /// Transparent margin around the content (used while dragging so the lifted stick is not clipped).
    var insets = CGSize.zero { didSet { needsLayout = true } }
    override var isFlipped: Bool { true }

    init(host: NSView) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        autoresizesSubviews = false
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func placeHost() {
        subviews.first?.frame = NSRect(x: insets.width, y: insets.height,
                                       width: max(0, bounds.width - 2 * insets.width), height: Self.hostHeight)
    }

    override func layout() { super.layout(); placeHost() }
    override func resizeSubviews(withOldSize oldSize: NSSize) { placeHost() }
}

final class GroupWindowController: NSObject, NSWindowDelegate {
    let groupID: UUID
    let panel: GroupPanel
    private let store: AppStore
    private var anchorTop: CGFloat
    private var contentX: CGFloat
    private var contentHeight: CGFloat = 80
    private var margin = CGSize.zero
    private weak var container: TopPinnedContainer?
    private var zoom: CGFloat
    /// Content width at 100% zoom; the user can drag the window edge to change it.
    private var unitWidth: CGFloat
    private var measuredHeight: CGFloat = 0
    private var shrinkDeadline: Date?
    private var settleTimer: Timer?
    private var settleUntil = Date.distantPast
    private var persistWork: DispatchWorkItem?
    private weak var host: NSView?

    init(group: StickGroup, slot: Int, store: AppStore, actions: WindowActions, keyHandler: @escaping (UUID, NSEvent) -> Bool) {
        self.groupID = group.id
        self.store = store
        self.zoom = CGFloat(group.zoom)
        self.unitWidth = CGFloat(group.width)

        let width = unitWidth * zoom
        let height: CGFloat = 80
        let screens = NSScreen.screens.map(\.visibleFrame)
        var frame: NSRect
        if let x = group.originX, let top = group.topY {
            frame = ScreenFit.fit(NSRect(x: x, y: top - height, width: width, height: height), screens: screens)
        } else {
            let area = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
            let x = area.maxX - 24 - width - CGFloat(slot) * (width + 16)
            frame = NSRect(x: max(area.minX + 8, x), y: area.maxY - 40 - height, width: width, height: height)
        }
        anchorTop = frame.maxY
        contentX = frame.minX

        panel = GroupPanel(contentRect: frame, styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        super.init()

        panel.keyHandler = { [groupID] in keyHandler(groupID, $0) }
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.delegate = self
        panel.title = AppInfo.name

        let host = GroupHostingView(rootView: GroupView(
            store: store, groupID: group.id, actions: actions,
            onHeight: { [weak self] in self?.measuredHeight = $0; self?.kick() },
            onDragging: { [weak self] in self?.setDragging($0) }))
        host.sizingOptions = []
        host.onIntrinsicSizeChange = { [weak self] in self?.kick() }
        self.host = host
        // The host keeps a fixed, tall frame pinned to the top of the window, so resizing the window never changes
        // SwiftUI's proposal (no re-centering/jump); the window just reveals more or less of it.
        let container = TopPinnedContainer(host: host)
        self.container = container
        panel.contentView = container
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
    }

    func update(_ group: StickGroup) {
        kick()
        panel.title = group.name
        zoom = CGFloat(group.zoom)
        unitWidth = CGFloat(group.width)
        let width = unitWidth * zoom
        if abs(panel.frame.width - width - 2 * margin.width) > 0.5 {
            panel.setFrame(NSRect(x: contentX - margin.width, y: anchorTop - contentHeight - margin.height,
                                  width: width + 2 * margin.width, height: contentHeight + 2 * margin.height), display: true)
            panel.invalidateShadow()
        }
    }

    /// While a stick is dragged the window gets a transparent margin so the lifted stick is never cut off.
    func setDragging(_ on: Bool) {
        let new = on ? CGSize(width: 20, height: Metrics.dragMargin * zoom) : .zero
        guard new != margin else { return }
        margin = new
        container?.insets = new
        shrinkDeadline = nil
        applyFrame(force: true)
    }

    func close() {
        settleTimer?.invalidate()
        panel.delegate = nil
        panel.orderOut(nil)
        panel.close()
    }

    func persistFrame() {
        persistWork?.cancel()
        store.setOrigin(group: groupID, x: panel.frame.minX + margin.width, topY: panel.frame.maxY - margin.height)
    }

    // MARK: Sizing — the window follows the SwiftUI content height, anchored to its top edge.

    /// SwiftUI reports its new ideal size a beat after a state change, and animations change it every frame.
    /// So after any change we sample the fitting height at ~60 Hz until the layout has been stable for a while.
    func kick() {
        settleUntil = Date().addingTimeInterval(0.45)
        guard settleTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        settleTimer = timer
    }

    private func tick() {
        applyFrame()
        if Date() > settleUntil {
            settleTimer?.invalidate()
            settleTimer = nil
        }
    }

    private func applyFrame(force: Bool = false) {
        guard let host else { return }
        let height = ceil(measuredHeight > 1 ? measuredHeight : host.fittingSize.height)
        guard height > 1 else { return }
        // Growing is immediate; shrinking waits for the collapse animation so the rows sliding up are not clipped.
        if !force, height < contentHeight {
            let deadline = shrinkDeadline ?? Date().addingTimeInterval(0.24)
            shrinkDeadline = deadline
            settleUntil = max(settleUntil, deadline.addingTimeInterval(0.1))
            if Date() < deadline { return }
        } else {
            shrinkDeadline = nil
        }
        let frame = NSRect(x: contentX - margin.width, y: anchorTop - height - margin.height,
                           width: unitWidth * zoom + 2 * margin.width, height: height + 2 * margin.height)
        contentHeight = height
        guard frame != panel.frame else { return }
        // No implicit Core Animation on the resize: it slides the old layer contents (the "jump") before the redraw lands.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.setFrame(frame, display: true)
        CATransaction.commit()
        shrinkDeadline = nil
        panel.invalidateShadow()
    }

    // MARK: NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        let top = panel.frame.maxY - margin.height
        guard abs(top - anchorTop) > 0.5 || abs(panel.frame.minX + margin.width - contentX) > 0.5 || persistWork == nil else { return }
        anchorTop = top
        contentX = panel.frame.minX + margin.width
        persistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persistFrame() }
        persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Edge-dragging changes the width only (the height always follows the content), and never while pinned.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        if store.state.groups.first(where: { $0.id == groupID })?.isPinned == true { return sender.frame.size }
        let w = min(max(frameSize.width - 2 * margin.width, CGFloat(SpaceWidth.range.lowerBound) * zoom),
                    CGFloat(SpaceWidth.range.upperBound) * zoom)
        return NSSize(width: w + 2 * margin.width, height: sender.frame.height)
    }

    func windowDidResize(_ notification: Notification) {
        let w = (panel.frame.width - 2 * margin.width) / zoom
        guard abs(w - unitWidth) > 0.5 else { return }
        unitWidth = w
        contentX = panel.frame.minX + margin.width
        store.setWidth(Double(w), space: groupID)
    }

    func windowDidBecomeKey(_ notification: Notification) { store.activeGroupID = groupID }

    func windowDidResignKey(_ notification: Notification) {
        store.hideRevealed(inGroup: groupID)
        if let editing = store.editingBlock, let l = store.locate(block: editing), store.state.groups[l.group].id == groupID {
            store.editingBlock = nil
        }
    }
}

final class WindowManager {
    private let store: AppStore
    var actions = WindowActions()
    private(set) var controllers: [UUID: GroupWindowController] = [:]
    private var subscription: AnyCancellable?
    private var scheduled = false

    init(store: AppStore) {
        self.store = store
        subscription = store.objectWillChange.sink { [weak self] in self?.scheduleSync() }
    }

    func scheduleSync() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.scheduled = false
            self?.sync()
        }
    }

    func sync() {
        Self.apply(theme: store.state.theme)
        let visible = store.state.groups.filter(\.showsWindow)
        let live = Set(visible.map(\.id))
        for (id, controller) in controllers where !live.contains(id) {
            controller.persistFrame()
            controller.close()
            controllers[id] = nil
        }
        for group in visible {
            if let controller = controllers[group.id] {
                controller.update(group)
            } else {
                let controller = GroupWindowController(group: group, slot: controllers.count, store: store, actions: actions) { [weak self] in
                    self?.handleKey($0, $1) ?? false
                }
                controllers[group.id] = controller
                controller.update(group)
            }
        }
    }

    static func apply(theme: ThemeChoice) {
        let appearance: NSAppearance? = switch theme {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        if NSApp.appearance?.name != appearance?.name { NSApp.appearance = appearance }
    }

    func flushFrames() { controllers.values.forEach { $0.persistFrame() } }

    /// ⌘= is not a menu key equivalent (the menu uses ⌘+), so zoom is handled here. It always applies to the
    /// group whose panel is key, never to other groups.
    private func handleKey(_ group: UUID, _ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard mods.subtracting(.shift) == .command else { return false }
        // Key codes, not characters: stays correct on non-Latin layouts. 24/69 = "=" and keypad "+", 27/78 = "-", 29/82 = "0".
        switch event.keyCode {
        case 24, 69: store.zoomIn(group: group)
        case 27, 78: store.zoomOut(group: group)
        case 29, 82 where mods == .command: store.resetZoom(group: group)
        default: return false
        }
        return true
    }
}

// MARK: - Helper windows

/// Borderless glass panel for helper windows. Esc closes it; it can be dragged by its background.
final class HelperPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
}

final class HelperWindows: NSObject, NSWindowDelegate {
    private let store: AppStore
    private var windows: [String: NSWindow] = [:]

    var sync: SyncController?

    init(store: AppStore) { self.store = store }

    /// New group in a space, or (group == nil) a new space.
    func showNewStick(group: UUID?, index: Int?) {
        presentApp("new") { close in NewStickView(store: self.store, group: group, visibleIndex: index, close: close) }
    }

    func showRename(stick: UUID) {
        presentApp("rename") { close in RenameView(store: self.store, target: .group(stick), close: close) }
    }

    func showRename(space: UUID) {
        presentApp("rename") { close in RenameView(store: self.store, target: .space(space), close: close) }
    }

    /// `group == nil` imports a whole space as a new window; otherwise one group into that space.
    /// Two tabs: pasted JSON, or a file in a Git repository.
    func showImport(group: UUID?, index: Int?, initialText: String = "", tab: ImportWindowView.Tab = .json) {
        guard let sync else { return }
        presentApp("import") { close in
            ImportWindowView(store: self.store, sync: sync, space: group, visibleIndex: index, initialText: initialText, tab: tab, close: close)
        }
    }

    func showExport(stick: UUID, includeSensitive: Bool = false, wholeSpace: Bool = false) {
        guard let space = store.groupID(ofStick: stick) else { return }
        presentApp("export") { close in
            ExportView(store: self.store, stickID: stick, spaceID: space, includeSensitive: includeSensitive, wholeSpace: wholeSpace, close: close)
        }
    }

    func showExport(space: UUID) {
        presentApp("export") { close in ExportView(store: self.store, stickID: nil, spaceID: space, close: close) }
    }

    func showAbout(expandAll: Bool = false) {
        if let existing = windows["about"] {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }
        presentApp("about", size: NSSize(width: 540, height: 540), minSize: NSSize(width: 480, height: 320)) { close in AboutView(expandAll: expandAll, close: close) }
    }

    func window(_ key: String) -> NSWindow? { windows[key] }
    func closeAll() { windows.values.forEach { $0.close() } }

    /// `size` makes the window resizable (borderless panel with edge resizing) down to `minSize`.
    private func presentApp<V: View>(_ key: String, size: NSSize? = nil, minSize: NSSize? = nil, _ make: (@escaping () -> Void) -> V) {
        windows[key]?.close()
        let host = NSHostingView(rootView: make { [weak self] in self?.windows[key]?.close() })
        let resizable = size != nil
        if resizable { host.sizingOptions = [] }
        let frameSize = size ?? host.fittingSize
        let panel = HelperPanel(contentRect: NSRect(origin: .zero, size: frameSize),
                                styleMask: resizable ? [.borderless, .resizable] : [.borderless], backing: .buffered, defer: false)
        if let minSize { panel.contentMinSize = minSize }
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentView = host
        panel.delegate = self
        panel.center()
        windows[key] = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let key = windows.first(where: { $0.value === window })?.key else { return }
        windows[key] = nil
    }
}

// MARK: - Undo toast

final class ToastController {
    private let store: AppStore
    private var panel: NSPanel?
    private var subscription: AnyCancellable?
    var panelWindow: NSWindow? { panel }

    init(store: AppStore) {
        self.store = store
        subscription = store.$toast.sink { [weak self] toast in
            DispatchQueue.main.async { self?.show(toast) }
        }
    }

    private func show(_ toast: Toast?) {
        guard let toast else {
            panel?.orderOut(nil)
            return
        }
        let view = ToastView(message: toast.message,
                             undo: { [store] in store.undo() },
                             dismiss: { [store] in store.toast = nil })
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let panel = self.panel ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.level = .floating
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            self.panel = p
            return p
        }()
        panel.contentView = host
        let area = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x: area.midX - size.width / 2, y: area.minY + 56, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()

        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.store.toast == toast else { return }
            self.store.toast = nil
        }
    }
}
