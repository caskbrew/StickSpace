import AppKit
import SwiftUI

// MARK: - Clipboard

enum Clipboard {
    /// Copies the exact source text. Sensitive content is flagged so clipboard managers that honor the convention skip it.
    static func copy(_ text: String, concealed: Bool) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        if concealed { pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) }
    }
}

// MARK: - Opening links

enum LinkOpener {
    /// `background` keeps the current app active (⌘-click); otherwise the browser comes to the front.
    static func open(_ urls: [URL], background: Bool) {
        guard let first = urls.first else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = !background
        if let app = NSWorkspace.shared.urlForApplication(toOpen: first) {
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: config)
        } else {
            for url in urls { NSWorkspace.shared.open(url, configuration: config) }
        }
    }

    static var commandHeld: Bool { NSEvent.modifierFlags.contains(.command) }
}

// MARK: - Menus

final class MenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}

extension NSMenu {
    @discardableResult
    func addAction(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [.command],
                   checked: Bool = false, enabled: Bool = true, destructive: Bool = false,
                   action: (() -> Void)? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        if let action {
            let target = MenuAction(action)
            item.target = target
            item.action = #selector(MenuAction.fire)
            item.representedObject = target
        }
        item.state = checked ? .on : .off
        item.isEnabled = enabled && action != nil
        if destructive {
            item.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: NSColor.systemRed])
        }
        addItem(item)
        return item
    }

    @discardableResult
    func addSubmenu(_ title: String, enabled: Bool = true, build: (NSMenu) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu(title: title)
        sub.autoenablesItems = false
        build(sub)
        item.submenu = sub
        item.isEnabled = enabled
        addItem(item)
        return item
    }

    /// Shows the menu at the current mouse event and blocks until it closes.
    func popUpAtCurrentEvent() {
        guard let event = NSApp.currentEvent, let view = event.window?.contentView else { return }
        NSMenu.popUpContextMenu(self, with: event, for: view)
    }
}

// MARK: - Window drag + click region

/// Transparent region that moves the window when dragged and reports a plain click. This lets a title row both
/// toggle on click and drag the whole group, without conflicting with text selection or the reorder grip.
struct DragClickArea: NSViewRepresentable {
    /// False while the group is pinned: a pinned window must not be moved.
    var canDrag = true
    /// Only a double click counts as a click (single clicks do nothing).
    var doubleClickOnly = false
    var onClick: () -> Void
    var onContextMenu: (() -> Void)?

    func makeNSView(context: Context) -> DragClickView { DragClickView() }

    func updateNSView(_ view: DragClickView, context: Context) {
        view.canDrag = canDrag
        view.doubleClickOnly = doubleClickOnly
        view.onClick = onClick
        view.onContextMenu = onContextMenu
    }

    final class DragClickView: NSView {
        var canDrag = true
        var doubleClickOnly = false
        var onClick: (() -> Void)?
        var onContextMenu: (() -> Void)?
        private var start: NSPoint = .zero
        private var dragged = false

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { onContextMenu?(); return }
            start = event.locationInWindow
            dragged = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard !dragged, canDrag else { return }
            if hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 3 {
                dragged = true
                window?.performDrag(with: event)
            }
        }

        override func mouseUp(with event: NSEvent) {
            if !dragged, !doubleClickOnly || event.clickCount >= 2 { onClick?() }
            dragged = false
        }

        override func rightMouseDown(with event: NSEvent) { onContextMenu?() }
    }
}

// MARK: - Auto-sizing text editor used for inline editing

final class InlineTextView: NSTextView {
    var onFinish: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        if event.keyCode == 53 || (command && (event.keyCode == 36 || event.keyCode == 76)) {
            onFinish?()
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌘↩ may arrive as a key equivalent.
        if event.modifierFlags.contains(.command), event.keyCode == 36 || event.keyCode == 76 {
            onFinish?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

struct InlineEditor: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat
    var monospaced: Bool
    var onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> InlineTextView {
        let tv = InlineTextView(frame: .zero)
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tv.string = text
        tv.onFinish = onFinish
        DispatchQueue.main.async {
            tv.window?.makeFirstResponder(tv)
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        }
        return tv
    }

    func updateNSView(_ tv: InlineTextView, context: Context) {
        context.coordinator.parent = self
        tv.onFinish = onFinish
        let font = monospaced
            ? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            : NSFont.systemFont(ofSize: fontSize)
        if tv.font != font { tv.font = font }
        if tv.string != text { tv.string = text }
        tv.textColor = .labelColor
        tv.insertionPointColor = .controlAccentColor
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView tv: InlineTextView, context: Context) -> CGSize? {
        let width = max(proposal.width ?? 200, 20)
        tv.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        tv.layoutManager?.ensureLayout(for: tv.textContainer!)
        let used = tv.layoutManager?.usedRect(for: tv.textContainer!).height ?? 16
        let line = (tv.font?.boundingRectForFont.height ?? 16)
        return CGSize(width: width, height: ceil(max(used, line)))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: InlineEditor
        init(_ parent: InlineEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }
}

// MARK: - JSON editor with line numbers

final class LineNumberRuler: NSRulerView {
    private var observers: [NSObjectProtocol] = []

    init(scrollView: NSScrollView, textView: NSTextView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 34
        clipsToBounds = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in self?.needsDisplay = true })
        observers.append(NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: textView, queue: .main) { [weak self] _ in self?.needsDisplay = true })
    }

    required init(coder: NSCoder) { fatalError() }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = clientView as? NSTextView, let lm = tv.layoutManager, let tc = tv.textContainer,
              let clip = scrollView?.contentView else { return }
        NSColor.textBackgroundColor.withAlphaComponent(0.6).setFill()
        rect.fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let visible = clip.bounds
        let glyphs = lm.glyphRange(forBoundingRect: visible, in: tc)
        let text = tv.string as NSString
        let firstChar = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil).location
        var line = 0
        for i in 0..<min(firstChar, text.length) where text.character(at: i) == 10 { line += 1 }
        lm.enumerateLineFragments(forGlyphRange: glyphs) { frame, _, _, glyphRange, _ in
            let loc = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil).location
            guard loc == 0 || text.character(at: loc - 1) == 10 else { return }
            line += 1
            let label = "\(line)" as NSString
            let size = label.size(withAttributes: attrs)
            let y = frame.minY + tv.textContainerInset.height - visible.minY + (frame.height - size.height) / 2
            label.draw(at: NSPoint(x: self.ruleThickness - size.width - 6, y: y), withAttributes: attrs)
        }
    }
}

struct JSONEditor: NSViewRepresentable {
    @Binding var text: String
    var editable = true

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let tv = NSTextView(frame: .zero)
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.delegate = context.coordinator
        scroll.documentView = tv
        scroll.verticalRulerView = LineNumberRuler(scrollView: scroll, textView: tv)
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        tv.string = text
        tv.isEditable = editable
        tv.setAccessibilityLabel("JSON")
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? NSTextView else { return }
        tv.isEditable = editable
        tv.textColor = .labelColor
        if tv.string != text {
            tv.string = text
            scroll.verticalRulerView?.needsDisplay = true
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: JSONEditor
        init(_ parent: JSONEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }
}

// MARK: - Hosting view

/// Hosting view that accepts the first click and reports SwiftUI's ideal size changes.
final class GroupHostingView<Content: View>: NSHostingView<Content> {
    /// Fires whenever SwiftUI's ideal size changes (including on every frame of an expand/collapse animation).
    var onIntrinsicSizeChange: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onIntrinsicSizeChange?()
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
