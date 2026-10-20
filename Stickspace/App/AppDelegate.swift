import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = AppStore()
    private var persistence: StatePersistence?
    private var windows: WindowManager!
    private var helpers: HelperWindows!
    private var toasts: ToastController!
    private var statusItem: NSStatusItem!
    private var saveSubscription: AnyCancellable?

    // MARK: Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        // One instance only: hand over to a running copy instead of opening a second set of windows.
        guard let id = Bundle.main.bundleIdentifier else { return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0 != NSRunningApplication.current && !$0.isTerminated }
        if let other = others.first {
            other.activate()
            exit(0)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        helpers = HelperWindows(store: store)
        windows = WindowManager(store: store)
        windows.actions = makeActions()
        toasts = ToastController(store: store)
        buildMainMenu()
        buildStatusItem()
        #if DEBUG
        if let dir = ProcessInfo.processInfo.environment["STICKSPACE_SCREENSHOTS"] {
            // Run from a timer, not a main-queue block: a serial queue would starve the async work the app relies on.
            Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [self] _ in
                let runner = ScreenshotRunner(dir: URL(fileURLWithPath: dir), store: store, windows: windows, helpers: helpers, toasts: toasts,
                                 captureStatusMenu: captureStatusMenu)
                if ProcessInfo.processInfo.environment["STICKSPACE_TOGGLETEST"] != nil { runner.runToggleTest() }
                else if ProcessInfo.processInfo.environment["STICKSPACE_HERO"] != nil { runner.runHero() }
                else { runner.run() }
            }
            return
        }
        #endif
        loadState()
    }

    #if DEBUG
    /// Opens the status menu, captures its window, then dismisses it.
    private func captureStatusMenu(to path: String, done: @escaping () -> Void) {
        // A Timer in .common modes still fires while the menu is tracking; GCD's main queue does not.
        let timer = Timer(timeInterval: 0.8, repeats: false) { [self] _ in
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            let menu = list.filter { ($0[kCGWindowOwnerName as String] as? String) == ProcessInfo.processInfo.processName && ($0[kCGWindowLayer as String] as? Int) == 101 }
                .max { ($0[kCGWindowBounds as String] as? [String: CGFloat])?["Height"] ?? 0 < ($1[kCGWindowBounds as String] as? [String: CGFloat])?["Height"] ?? 0 }
            if let id = menu?[kCGWindowNumber as String] as? Int {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-x", "-o", "-l", "\(id)", path]
                try? p.run(); p.waitUntilExit()
            }
            statusItem.menu?.cancelTracking()
            done()
        }
        RunLoop.main.add(timer, forMode: .common)
        statusItem.button?.performClick(nil)
    }
    #endif

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        windows.flushFrames()
        if let persistence {
            persistence.scheduleSave(store.state)
            persistence.flush()
        }
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windows.sync()
        return true
    }

    private func makeActions() -> WindowActions {
        WindowActions(
            newStick: { [unowned self] group, index in helpers.showNewStick(group: group ?? store.commandGroupID, index: index) },
            rename: { [unowned self] in helpers.showRename(stick: $0) },
            renameSpace: { [unowned self] in helpers.showRename(space: $0) },
            importInto: { [unowned self] group, index in helpers.showImport(group: group, index: index) },
            export: { [unowned self] in helpers.showExport(stick: $0) },
            exportSpace: { [unowned self] in helpers.showExport(space: $0) }
        )
    }

    // MARK: Loading

    private func loadState() {
        let file = StateFile(url: StateFile.defaultURL)
        DispatchQueue.global(qos: .userInitiated).async {
            let persistence = StatePersistence(file: file)
            let result = persistence.load()
            DispatchQueue.main.async { self.finishLoading(persistence, result) }
        }
    }

    private func finishLoading(_ persistence: StatePersistence, _ result: LoadResult) {
        self.persistence = persistence
        var notice: (String, String)?
        switch result {
        case .loaded(let state): store.load(state)
        case .empty: store.seedIfNeeded()
        case .unreadable(let moved):
            store.seedIfNeeded()
            let where_ = moved.map { "It was kept as \($0.lastPathComponent) in \($0.deletingLastPathComponent().path)." } ?? "The original file was left untouched."
            notice = ("Saved data could not be read", "\(AppInfo.name) started with a fresh set. \(where_)")
        }
        windows.sync()
        saveSubscription = store.$state.dropFirst().sink { persistence.scheduleSave($0) }
        persistence.scheduleSave(store.state)
        if let notice {
            let alert = NSAlert()
            alert.messageText = notice.0
            alert.informativeText = notice.1
            alert.runModal()
        }
    }

    // MARK: Commands

    /// A new space (window); groups are added from its header.
    @objc func addSpace() { helpers.showNewStick(group: nil, index: nil) }
    @objc func importSpace() { helpers.showImport(group: nil, index: nil) }
    @objc func showAbout() { helpers.showAbout() }
    @objc func zoomIn() { store.commandGroupID.map { store.zoomIn(group: $0) } }
    @objc func zoomOut() { store.commandGroupID.map { store.zoomOut(group: $0) } }
    @objc func zoomReset() { store.commandGroupID.map { store.resetZoom(group: $0) } }

    @objc func performUndo() {
        // While typing in an entity, ⌘Z is the text view's; otherwise it undoes the last delete.
        if let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.isEditable, tv.undoManager?.canUndo == true {
            tv.undoManager?.undo()
        } else {
            store.undo()
        }
    }

    @objc func restart() {
        windows.flushFrames()
        persistence?.scheduleSave(store.state)
        persistence?.flush()
        // A detached helper waits for this process to exit, then reopens the bundle: no duplicate instance.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; /usr/bin/open \"$2\"",
                          "sh", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

    // MARK: Main menu

    private func buildMainMenu() {
        let main = NSMenu()
        main.autoenablesItems = false

        let app = NSMenu(title: AppInfo.name)
        app.addAction("About & Help") { [unowned self] in showAbout() }
        app.addItem(.separator())
        app.addItem(withTitle: "Hide \(AppInfo.name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addAction("Restart", key: "r", modifiers: [.command, .shift]) { [unowned self] in restart() }
        app.addItem(withTitle: "Quit \(AppInfo.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: app)

        let file = NSMenu(title: "File")
        file.addAction("New Space", key: "n") { [unowned self] in addSpace() }
        file.addAction("Import", key: "i") { [unowned self] in importSpace() }
        file.addItem(.separator())
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu: file)

        let edit = NSMenu(title: "Edit")
        edit.addAction("Undo", key: "z") { [unowned self] in performUndo() }
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu: edit)

        let view = NSMenu(title: "View")
        view.addAction("Zoom In", key: "+") { [unowned self] in zoomIn() }
        view.addAction("Zoom Out", key: "-") { [unowned self] in zoomOut() }
        view.addAction("Actual Size", key: "0") { [unowned self] in zoomReset() }
        main.addItem(submenu: view)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(submenu: window)
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
    }

    // MARK: Status item

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(named: "MenuBarIcon")
            image?.isTemplate = true
            button.image = image
            button.setAccessibilityLabel(AppInfo.name)
            button.toolTip = AppInfo.name
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        menu.removeAllItems()
        menu.addAction("New Space", key: "n") { [unowned self] in addSpace() }
        menu.addAction("Import", key: "i") { [unowned self] in importSpace() }
        menu.addItem(.separator())

        // One entry per space (window): check = shown.
        for group in store.state.groups {
            let title = group.name
            menu.addAction(title.count > 42 ? String(title.prefix(41)) + "…" : title, checked: !group.isHidden) { [unowned self] in
                store.setGroupHidden(!group.isHidden, group: group.id)
            }
        }
        if !store.state.groups.isEmpty { menu.addItem(.separator()) }

        let themeItem = NSMenuItem()
        let host = NSHostingView(rootView: ThemeSwitch(store: store))
        host.frame = NSRect(origin: .zero, size: NSSize(width: 250, height: 28))
        host.autoresizingMask = [.width]
        themeItem.view = host
        menu.addItem(themeItem)
        menu.addItem(.separator())

        menu.addAction("About & Help") { [unowned self] in showAbout() }
        menu.addAction("Restart", key: "r", modifiers: [.command, .shift]) { [unowned self] in restart() }
        menu.addAction("Quit", key: "q") { NSApp.terminate(nil) }
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
