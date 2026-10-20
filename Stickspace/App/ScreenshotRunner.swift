#if DEBUG
import AppKit
import SwiftUI

/// Debug-only: `STICKSPACE_SCREENSHOTS=<dir>` opens every window and variant with sample data, in both themes,
/// and captures each one by window ID. Nothing is read from or written to the user's data.
final class ScreenshotRunner {
    let dir: URL
    let store: AppStore
    let windows: WindowManager
    let helpers: HelperWindows
    let toasts: ToastController
    let captureStatusMenu: (String, @escaping () -> Void) -> Void

    init(dir: URL, store: AppStore, windows: WindowManager, helpers: HelperWindows, toasts: ToastController,
         captureStatusMenu: @escaping (String, @escaping () -> Void) -> Void) {
        self.dir = dir; self.store = store; self.windows = windows; self.helpers = helpers; self.toasts = toasts
        self.captureStatusMenu = captureStatusMenu
    }

    private func wait(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private func capture(_ window: NSWindow?, _ path: String) {
        guard let window else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", path]
        try? p.run()
        p.waitUntilExit()
    }

    private func full() -> Stick {
        var s = Stick(name: "Workspace", blocks: [
            Block(type: .text, text: "Keep useful things close."),
            Block(type: .link, text: "https://grafana.corp.example.com/d/8fKq2/cluster-overview?orgId=1&var-env=prod", title: "Grafana", tags: ["prod"]),
            Block(type: .link, text: "https://grafana.corp.example.com/d/8fKq2/cluster-overview?orgId=1&var-env=stg", title: "Grafana", tags: ["stg"]),
            Block(type: .link, text: "https://figma.com", tags: ["dev", "design"]),
            Block(type: .text, text: "demo-secret", isMasked: true),
            Block(type: .text, text: "npm run dev"),
        ])
        s.isExpanded = true
        return s
    }

    private func collapsed() -> [Stick] {
        [Stick(name: "Workspace", blocks: [Block(text: "https://github.com")]), Stick(name: "Links"), Stick(name: "Personal")]
    }

    /// Expands the middle stick and records window frames/captures during the animation.
    func runToggleTest() {
        var g = StickGroup(sticks: collapsed() + [Stick(name: "Fourth")])
        g.sticks[1].blocks = [Block(text: "one"), Block(text: "two"), Block(text: "three")]
        let stickMode = ProcessInfo.processInfo.environment["STICKSPACE_TOGGLETEST"] == "stick"
        g.sticks[1].isExpanded = !stickMode
        g.isCollapsed = !stickMode
        let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        g.originX = Double(screen.midX); g.topY = Double(screen.midY + 100)
        store.load(AppState(theme: .light, groups: [g]))
        windows.sync(); wait(1.0)
        let panel = windows.controllers[g.id]!.panel
        let id = g.sticks[1].id
        NSLog("TOG before frame=%@", NSStringFromRect(panel.frame))
        withAnimation(.easeInOut(duration: 0.2)) {
            if stickMode { store.setExpanded(true, stick: id) } else { store.setCollapsed(false, space: g.id) }
        }
        for i in 0..<12 {
            wait(0.03)
            NSLog("TOG t=%d frame=%@", i, NSStringFromRect(panel.frame))
            capture(panel, dir.appendingPathComponent("t\(i).png").path)
        }
        NSApp.terminate(nil)
    }

    // MARK: README hero shots

    private final class BackdropView: NSView {
        var dark = false { didSet { needsDisplay = true } }

        override func draw(_ dirtyRect: NSRect) {
            let stops: [NSColor] = dark
                ? [NSColor(srgbRed: 0.03, green: 0.06, blue: 0.15, alpha: 1), NSColor(srgbRed: 0.05, green: 0.13, blue: 0.33, alpha: 1), NSColor(srgbRed: 0.11, green: 0.08, blue: 0.30, alpha: 1)]
                : [NSColor(srgbRed: 0.94, green: 0.97, blue: 1.0, alpha: 1), NSColor(srgbRed: 0.78, green: 0.87, blue: 1.0, alpha: 1), NSColor(srgbRed: 0.88, green: 0.83, blue: 1.0, alpha: 1)]
            NSGradient(colors: stops)?.draw(in: bounds, angle: -35)
            // Soft glows give the glass something to refract.
            let glow = dark ? NSColor(srgbRed: 0.25, green: 0.5, blue: 1.0, alpha: 0.35) : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.75)
            NSGradient(colors: [glow, glow.withAlphaComponent(0)])?
                .draw(fromCenter: NSPoint(x: bounds.width * 0.28, y: bounds.height * 0.72), radius: 0,
                      toCenter: NSPoint(x: bounds.width * 0.28, y: bounds.height * 0.72), radius: bounds.height * 0.7, options: [])
            let glow2 = dark ? NSColor(srgbRed: 0.6, green: 0.35, blue: 1.0, alpha: 0.28) : NSColor(srgbRed: 0.75, green: 0.8, blue: 1.0, alpha: 0.6)
            NSGradient(colors: [glow2, glow2.withAlphaComponent(0)])?
                .draw(fromCenter: NSPoint(x: bounds.width * 0.85, y: bounds.height * 0.25), radius: 0,
                      toCenter: NSPoint(x: bounds.width * 0.85, y: bounds.height * 0.25), radius: bounds.height * 0.6, options: [])
        }
    }

    /// Captures real screen regions over a gradient backdrop so the glass refracts something pleasant.
    func runHero() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let vis = screen.visibleFrame
        let size = NSSize(width: 1240, height: 400)
        let origin = NSPoint(x: vis.minX + 60, y: vis.maxY - size.height - 30)
        let backdrop = NSWindow(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        backdrop.isOpaque = true
        backdrop.hasShadow = false
        backdrop.level = .floating
        backdrop.isReleasedWhenClosed = false
        let view = BackdropView(frame: NSRect(origin: .zero, size: size))
        backdrop.contentView = view
        backdrop.orderFrontRegardless()
        let above = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        let top = Double(origin.y + size.height)

        func place(_ i: Int, x: Double, topOffset: Double, _ g: inout StickGroup) {
            g.originX = Double(origin.x) + x
            g.topY = top - topOffset
        }
        func newGroup(_ sticks: [Stick], zoom: Double = 1.0) -> StickGroup {
            var g = StickGroup(sticks: sticks.map { var s = $0; s.id = UUID(); s.blocks = s.blocks.map { var b = $0; b.id = UUID(); return b }; return s })
            g.zoom = zoom
            return g
        }
        func region() -> String {
            let y = screen.frame.height - (origin.y + size.height)
            return "\(Int(origin.x)),\(Int(y)),\(Int(size.width)),\(Int(size.height))"
        }
        func shoot(_ path: String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-R", region(), path]
            try? p.run(); p.waitUntilExit()
        }

        var editing = full()
        editing.blocks[0] = Block(type: .text, text: "Keep useful things close.\nIdeas, links, and commands\nin one place.")
        var dev = full(); dev.name = "Dev"
        dev.blocks = [Block(type: .text, text: "npm run dev"), Block(type: .link, text: "https://localhost:3000"), Block(type: .text, text: "api-token-1234", isMasked: true)]
        var a = newGroup([fullStick(), Stick(name: "Links"), Stick(name: "Personal")])
        var b = newGroup([editing, Stick(name: "Notes")])
        var c = newGroup([Stick(name: "Workspace", blocks: [Block(text: "https://github.com")]), Stick(name: "Links"), Stick(name: "Personal")])
        var d = newGroup([dev])
        c.isPinned = true
        place(0, x: 50, topOffset: 48, &a)
        place(1, x: 450, topOffset: 48, &b)
        place(2, x: 850, topOffset: 48, &c)
        place(3, x: 850, topOffset: 170, &d)
        let sceneStacks = [a, b, c, d]
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        for theme in [ThemeChoice.light, .dark] {
            view.dark = theme == .dark
            // Scene 1: stacks
            store.load(AppState(theme: theme, groups: sceneStacks))
            if let edit = sceneStacks[1].sticks[0].blocks.first?.id { store.editingBlock = edit }
            windows.sync()
            wait(1.4)
            for g in sceneStacks { windows.controllers[g.id]?.panel.orderFrontRegardless(); windows.controllers[g.id]?.panel.level = above }
            wait(0.6)
            shoot(dir.appendingPathComponent("hero-stacks-\(theme.rawValue).png").path)

            // Scene 2: helper windows
            store.editingBlock = nil
            let stickID = sceneStacks[0].sticks[0].id
            helpers.showExport(stick: stickID)
            helpers.showImport(group: nil, index: nil, initialText: #"{"sticks":[{"name":"Workspace","sections":[{"type":"text","text":"Hello"}]},{"name":"Links","sections":[{"type":"link","url":"https://github.com"}]}]}"#)
            wait(1.0)
            func put(_ key: String, x: CGFloat, topOff: CGFloat) {
                guard let w = helpers.window(key) else { return }
                w.level = above
                w.setFrameOrigin(NSPoint(x: origin.x + x, y: origin.y + size.height - topOff - w.frame.height))
            }
            put("export", x: 110, topOff: 28)
            put("import", x: 670, topOff: 28)
            for g in sceneStacks { windows.controllers[g.id]?.panel.orderOut(nil) }
            wait(0.8)
            shoot(dir.appendingPathComponent("hero-windows-\(theme.rawValue).png").path)
            helpers.closeAll()
            wait(0.3)
        }
        NSApp.terminate(nil)
    }

    private func fullStick() -> Stick { full() }

    func run() {
        let fullStick = full()
        var editing = full()
        editing.blocks[0] = Block(type: .text, text: "Keep useful things close.\nIdeas, links, and commands\nin one place.")
        var empty = Stick(name: "Personal"); empty.isExpanded = true
        var multi = full()
        multi.blocks.append(Block(type: .text, text: "A hidden line", isHidden: true))
        multi.blocks[0] = Block(type: .text, text: "Multi-line text grows the row\nnaturally, one line at a time,\nwithout a separate editor.")

        struct Variant { let name: String; var sticks: [Stick]; var zoom = 1.0; var pinned = false; var collapsed = false }
        let variants: [Variant] = [
            Variant(name: "01-collapsed", sticks: collapsed()),
            Variant(name: "02-expanded", sticks: [fullStick, Stick(name: "Links"), Stick(name: "Personal")]),
            Variant(name: "03-pinned", sticks: collapsed(), pinned: true),
            Variant(name: "04-editing", sticks: [editing, Stick(name: "Links")]),
            Variant(name: "05-empty-stick", sticks: [Stick(name: "Workspace"), empty]),
            Variant(name: "06-multiline-hidden-line", sticks: [multi]),
            Variant(name: "07-zoom-80", sticks: [fullStick, Stick(name: "Links")], zoom: 0.8),
            Variant(name: "08-zoom-125", sticks: [fullStick, Stick(name: "Links")], zoom: 1.25),
            Variant(name: "09-space-collapsed", sticks: collapsed(), collapsed: true),
            Variant(name: "10-empty-space", sticks: []),
        ]

        let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        var groups: [StickGroup] = []
        for (i, v) in variants.enumerated() {
            var g = StickGroup(sticks: v.sticks.map { var s = $0; s.id = UUID(); s.blocks = s.blocks.map { var b = $0; b.id = UUID(); return b }; return s })
            g.isPinned = v.pinned
            g.name = ["Work", "Production", "Pinned", "Editing", "Personal", "Notes", "Small", "Large", "Collapsed", "Empty"][i]
            g.isCollapsed = v.collapsed
            g.zoom = v.zoom
            g.originX = Double(screen.minX + 30 + CGFloat(i % 4) * 500)
            g.topY = Double(screen.maxY - 20 - CGFloat(i / 4) * 300)
            groups.append(g)
        }
        store.load(AppState(theme: .light, groups: groups))
        if let editID = groups[3].sticks[0].blocks.first?.id { store.editingBlock = editID }
        if let secret = groups[1].sticks[0].blocks.first(where: \.isMasked)?.id { store.toggleReveal(secret) }
        // Revealed variant: second masked state is shown by revealing in the "multiline" group's twin; keep 02 masked.
        store.hideReveal(groups[1].sticks[0].blocks.first(where: \.isMasked)!.id)

        let fm = FileManager.default
        for theme in [ThemeChoice.light, .dark] {
            let out = dir.appendingPathComponent(theme.rawValue)
            try? fm.createDirectory(at: out, withIntermediateDirectories: true)
            func path(_ name: String) -> String { out.appendingPathComponent("\(name).png").path }

            store.setTheme(theme)
            windows.sync()
            wait(1.2)
            wait(1.0)
            for (i, v) in variants.enumerated() { capture(windows.controllers[groups[i].id]?.panel, path("group-" + v.name)) }

            // Revealed sensitive block
            let secret = groups[1].sticks[0].blocks.first(where: \.isMasked)!.id
            store.toggleReveal(secret)
            wait(0.8)
            capture(windows.controllers[groups[1].id]?.panel, path("group-02b-expanded-revealed"))
            store.hideReveal(secret)

            // Helper windows
            let gid = groups[1].id
            let stickID = groups[1].sticks[0].id
            let multiJSON = #"{"sticks":[{"name":"Workspace","sections":[{"type":"text","text":"Hello"}]},{"name":"Links","sections":[{"type":"link","url":"https://github.com"},{"type":"link","url":"https://figma.com"}]},{"name":"Personal","sections":[]}]}"#
            let oneJSON = #"{"name":"Workspace","sections":[{"type":"text","text":"Hello"}]}"#
            let steps: [(String, String, () -> Void)] = [
                ("window-new-stick", "new", { self.helpers.showNewStick(group: gid, index: nil) }),
                ("window-new-stack", "new", { self.helpers.showNewStick(group: nil, index: nil) }),
                ("window-rename", "rename", { self.helpers.showRename(stick: stickID) }),
                ("window-import-stick", "import", { self.helpers.showImport(group: gid, index: nil, initialText: oneJSON) }),
                ("window-import-stack", "import", { self.helpers.showImport(group: nil, index: nil, initialText: multiJSON) }),
                ("window-import-empty", "import", { self.helpers.showImport(group: nil, index: nil) }),
                ("window-import-error", "import", { self.helpers.showImport(group: nil, index: nil, initialText: "{\n  \"sticks\": [\n    { oops }\n  ]\n}") }),
                ("window-export-group", "export", { self.helpers.showExport(stick: stickID) }),
                ("window-export-space", "export", { self.helpers.showExport(stick: stickID, wholeSpace: true) }),
                ("window-export-sensitive", "export", { self.helpers.showExport(stick: stickID, includeSensitive: true) }),
                ("window-about", "about", { self.helpers.showAbout() }),
                ("window-about-expanded", "about", { self.helpers.closeAll(); self.helpers.showAbout(expandAll: true) }),
            ]
            for (name, key, open) in steps {
                helpers.closeAll()
                open()
                wait(1.0)
                capture(helpers.window(key), path(name))
            }
            helpers.closeAll()

            // Undo toast
            if let block = store.stick(stickID)?.blocks.first?.id {
                store.deleteBlock(block)
                wait(1.0)
                capture(toasts.panelWindow, path("toast-line-deleted"))
                store.undo()
                wait(0.4)
            }

            // Menu bar menu
            var done = false
            captureStatusMenu(path("menu-status")) { done = true }
            while !done { wait(0.1) }
            wait(0.3)
        }
        NSApp.terminate(nil)
    }
}
#endif
