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
            Block(type: .auto, text: "Keep useful things close."),
            Block(type: .auto, text: "https://github.com"),
            Block(type: .auto, text: "https://figma.com"),
            Block(type: .auto, text: "demo-secret", isMasked: true),
            Block(type: .code, text: "npm run dev"),
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
        let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        g.originX = Double(screen.midX); g.topY = Double(screen.midY + 100)
        store.load(AppState(theme: .light, groups: [g]))
        windows.sync(); wait(1.0)
        let panel = windows.controllers[g.id]!.panel
        let id = g.sticks[1].id
        NSLog("TOG before frame=%@", NSStringFromRect(panel.frame))
        withAnimation(.easeInOut(duration: 0.2)) { store.setExpanded(true, stick: id) }
        for i in 0..<12 {
            wait(0.03)
            NSLog("TOG t=%d frame=%@", i, NSStringFromRect(panel.frame))
            capture(panel, dir.appendingPathComponent("t\(i).png").path)
        }
        NSApp.terminate(nil)
    }

    func run() {
        let fullStick = full()
        var editing = full()
        editing.blocks[0] = Block(type: .auto, text: "Keep useful things close.\nIdeas, links, and commands\nin one place.")
        var empty = Stick(name: "Personal"); empty.isExpanded = true
        var multi = full()
        multi.blocks.append(Block(type: .text, text: "A hidden line", isHidden: true))
        multi.blocks[0] = Block(type: .text, text: "Multi-line text grows the row\nnaturally, one line at a time,\nwithout a separate editor.")

        struct Variant { let name: String; var sticks: [Stick]; var zoom = 1.0; var pinned = false }
        let variants: [Variant] = [
            Variant(name: "01-collapsed", sticks: collapsed()),
            Variant(name: "02-expanded", sticks: [fullStick, Stick(name: "Links"), Stick(name: "Personal")]),
            Variant(name: "03-pinned", sticks: collapsed(), pinned: true),
            Variant(name: "04-editing", sticks: [editing, Stick(name: "Links")]),
            Variant(name: "05-empty-stick", sticks: [Stick(name: "Workspace"), empty]),
            Variant(name: "06-multiline-hidden-line", sticks: [multi]),
            Variant(name: "07-zoom-80", sticks: [fullStick, Stick(name: "Links")], zoom: 0.8),
            Variant(name: "08-zoom-125", sticks: [fullStick, Stick(name: "Links")], zoom: 1.25),
        ]

        let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        var groups: [StickGroup] = []
        for (i, v) in variants.enumerated() {
            var g = StickGroup(sticks: v.sticks.map { var s = $0; s.id = UUID(); s.blocks = s.blocks.map { var b = $0; b.id = UUID(); return b }; return s })
            g.isPinned = v.pinned
            g.zoom = v.zoom
            g.originX = Double(screen.minX + 30 + CGFloat(i % 4) * 500)
            g.topY = Double(screen.maxY - 20 - CGFloat(i / 4) * 330)
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
                ("window-export-stick", "export", { self.helpers.showExport(stick: stickID) }),
                ("window-export-stack", "export", { self.helpers.showExport(stick: stickID, wholeStack: true) }),
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
