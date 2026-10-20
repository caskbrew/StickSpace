import SwiftUI
import UniformTypeIdentifiers

// MARK: - New Stick / New Stack

/// `group == nil` creates a new stack (window) whose first stick is this one.
/// Deliberately bare: just a name field and the two buttons on the glass surface.
struct NewStickView: View {
    @ObservedObject var store: AppStore
    let group: UUID?
    let visibleIndex: Int?
    let close: () -> Void

    @State private var name = "New Stick"
    @Environment(\.colorScheme) private var scheme

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AppTextField(placeholder: group == nil ? "Stack's first stick" : "Stick name", text: $name, onSubmit: create)
            HStack {
                Spacer()
                AppButton(title: "Cancel", action: close).keyboardShortcut(.cancelAction)
                AppButton(title: "Create", style: .primary, enabled: !trimmed.isEmpty, action: create)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 300)
        .foregroundStyle(Palette.text(scheme))
        .stickSurface(radius: 12)
    }

    private func create() {
        guard !trimmed.isEmpty else { return }
        store.addStick(name: trimmed, group: group, atVisible: visibleIndex)
        close()
    }
}

// MARK: - Rename

struct RenameView: View {
    @ObservedObject var store: AppStore
    let stickID: UUID
    let close: () -> Void

    @State private var name: String

    init(store: AppStore, stickID: UUID, close: @escaping () -> Void) {
        self.store = store
        self.stickID = stickID
        self.close = close
        _name = State(initialValue: store.stick(stickID)?.name ?? "")
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        AppWindowChrome(title: "Rename Stick", close: close) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Name").font(.system(size: 12)).foregroundStyle(.secondary)
                AppTextField(placeholder: "Name", text: $name, onSubmit: save)
                HStack {
                    Spacer()
                    AppButton(title: "Cancel", action: close).keyboardShortcut(.cancelAction)
                    AppButton(title: "Save", style: .primary, enabled: !trimmed.isEmpty, action: save)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 6)
            }
        }
        .frame(width: 300)
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        store.renameStick(stickID, to: trimmed)
        close()
    }
}

// MARK: - Export

struct ExportView: View {
    @ObservedObject var store: AppStore
    let stickID: UUID
    let close: () -> Void

    private enum Scope: Hashable { case stick, stack }

    @State private var scope: Scope
    @State private var includeSensitive: Bool
    @State private var copied = false
    @Environment(\.colorScheme) private var scheme

    init(store: AppStore, stickID: UUID, includeSensitive: Bool = false, wholeStack: Bool = false, close: @escaping () -> Void) {
        self.store = store
        self.stickID = stickID
        self.close = close
        _scope = State(initialValue: wholeStack ? .stack : .stick)
        _includeSensitive = State(initialValue: includeSensitive)
    }

    private var sticks: [Stick] {
        if scope == .stack, let gid = store.groupID(ofStick: stickID), let g = store.groupIndex(gid) { return store.state.groups[g].sticks }
        return store.stick(stickID).map { [$0] } ?? []
    }

    private var json: String { Interchange.export(sticks, asSingle: scope == .stick, includeSensitive: includeSensitive) }

    var body: some View {
        // Bare surface (no title row): scope switch, JSON, one option row with the Copy button.
        VStack(alignment: .leading, spacing: 10) {
            AppSegmented(options: [(Scope.stick, "This Stick"), (Scope.stack, "This Stack")], selection: $scope)
            AppCodeBox { JSONEditor(text: .constant(json), editable: false) }
                .frame(height: 190)
            HStack(alignment: .center) {
                AppCheckbox(title: "Include masked content", isOn: $includeSensitive)
                Spacer(minLength: 12)
                AppButton(title: copied ? "Copied" : "Copy", style: .primary, action: copy)
                    .keyboardShortcut(.defaultAction)
            }
            if includeSensitive {
                AppNotice(kind: .warning, message: "Masked content will be exported as plain text.")
            }
        }
        .padding(14)
        .frame(width: 440)
        .foregroundStyle(Palette.text(scheme))
        .stickSurface(radius: 12)
    }

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(json, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}

// MARK: - Import (paste only)

/// `group == nil`: imports a whole stack (a list of sticks) as a new window.
/// Otherwise: imports exactly one stick into that stack at `visibleIndex`.
struct ImportView: View {
    @ObservedObject var store: AppStore
    let group: UUID?
    let visibleIndex: Int?
    let close: () -> Void

    @State private var text: String
    @State private var parsed: [Stick] = []
    @State private var error: String?

    init(store: AppStore, group: UUID?, visibleIndex: Int?, initialText: String = "", close: @escaping () -> Void) {
        self.store = store
        self.group = group
        self.visibleIndex = visibleIndex
        self.close = close
        _text = State(initialValue: initialText)
    }

    private var isStack: Bool { group == nil }
    private var sectionCount: Int { parsed.reduce(0) { $0 + $1.blocks.count } }

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // Bare surface like New Stack: no title row, no close button (Esc or Cancel closes).
        VStack(alignment: .leading, spacing: 10) {
            AppCodeBox { JSONEditor(text: $text) }
                .frame(height: 200)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Paste JSON").font(.system(size: 12)).foregroundStyle(.tertiary).padding(.leading, 44).padding(.top, 6)
                            .allowsHitTesting(false)
                    }
                }
            Group {
                if let error {
                    AppNotice(kind: .error, message: error)
                } else if !parsed.isEmpty {
                    Text(summary).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .frame(height: 34, alignment: .topLeading)
            HStack {
                Spacer()
                AppButton(title: "Cancel", action: close).keyboardShortcut(.cancelAction)
                AppButton(title: "Import", style: .primary, enabled: !parsed.isEmpty && error == nil, action: doImport)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 460)
        .foregroundStyle(Palette.text(scheme))
        .stickSurface(radius: 12)
        .onChange(of: text) { _, new in reparse(new) }
        .onAppear { if !text.isEmpty { reparse(text) } }
    }

    private var summary: String {
        "\(parsed.count) stick\(parsed.count == 1 ? "" : "s") · \(sectionCount) line\(sectionCount == 1 ? "" : "s")"
    }

    private func reparse(_ new: String) {
        guard !new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            parsed = []; error = nil
            return
        }
        do {
            let sticks = try Interchange.parse(new)
            if !isStack && sticks.count != 1 {
                throw Interchange.ImportError(message: "This JSON has \(sticks.count) sticks. A stick import takes exactly one; use Import in the menu bar for a whole stack.")
            }
            parsed = sticks
            error = nil
        } catch {
            parsed = []
            self.error = (error as? Interchange.ImportError)?.message ?? "Could not read JSON."
        }
    }

    private func doImport() {
        store.insert(parsed, group: group, atVisible: visibleIndex)
        close()
    }
}

// MARK: - About & Help

struct AboutView: View {
    private struct Topic: Identifiable {
        let id = UUID()
        let title: String
        let symbol: String
        let bullets: [String]
    }

    private let topics: [Topic] = [
        Topic(title: "Getting Started", symbol: "questionmark.circle", bullets: [
            "A line holds one piece of text. Lines form a stick, and sticks form a stack: one window.",
            "Double-click a stick's title to expand or collapse it. Several can stay open.",
            "Double-click a line to edit it. Esc or ⌘↩ finishes; text is saved as you type.",
            "Drag the dotted grip to reorder sticks; drag a line up or down to reorder lines within its stick.",
            "Drag a stick's title row to move the whole window (not while it is pinned).",
            "Each line's copy button copies its exact text, nothing else.",
            "A line is a link only when the whole text is an http/https address.",
        ]),
        Topic(title: "Sensitive Content", symbol: "eye", bullets: [
            "Mask Content shows •••••••• instead of the text, whatever its length.",
            "The eye reveals it temporarily. It hides again when you press the eye, the window loses focus, or the stick collapses.",
            "Copy works without revealing.",
            "Masking only hides the text on screen. It is not encryption: the text is saved in plain form in Stickspace's data file.",
            "After you copy it, the text sits on the system clipboard where other apps can read it.",
            "Masked lines are skipped by Open All and by Export unless you opt in.",
        ]),
        Topic(title: "Pin", symbol: "pin", bullets: [
            "One pin per stack, on its top stick. It keeps the whole window above normal windows and locks it in place.",
            "If you reorder or hide the top stick, the pin moves to the new top stick.",
            "Pinning never takes keyboard focus.",
        ]),
        Topic(title: "Context Menus", symbol: "contextualmenu.and.cursorarrow", bullets: [
            "Right-click a stick for Rename, Hide, Lines…, Add Stick Above/Below, Show Hidden Sticks…, zoom, Import Stick, Export and Delete.",
            "Right-click a line for Edit, Copy, Type, Move Up/Down, Hide Line, Mask Content and Delete Line.",
            "Link buttons: click opens in the browser; ⌘-click opens in the background so Stickspace stays active.",
            "The arrow in a stick's title row opens all of its visible, non-sensitive links, once each.",
        ]),
        Topic(title: "Menu Bar", symbol: "menubar.rectangle", bullets: [
            "New Stack creates a new window. Add sticks to it from its context menu.",
            "Each stack is listed with a check mark: click it to hide or show that window.",
            "Import adds a whole stack (a list of sticks) pasted as JSON as a new window.",
            "The three icons switch between system, light and dark appearance for the whole app.",
            "Restart (⇧⌘R) saves and relaunches. Quit (⌘Q) saves and exits.",
        ]),
        Topic(title: "Delete & Undo", symbol: "trash", bullets: [
            "Deleting a stick or line happens immediately, with no confirmation.",
            "Press Undo in the notice or ⌘Z to bring it back.",
        ]),
        Topic(title: "Zoom per Stack", symbol: "magnifyingglass", bullets: [
            "⌘+ (or ⌘=) zooms in, ⌘− zooms out, ⌘0 resets. The range is 60%–200%.",
            "Zoom applies only to the stack you last used and is remembered per stack.",
        ]),
        Topic(title: "Import & Export (JSON)", symbol: "doc", bullets: [
            "Paste JSON to import. Import never overwrites existing sticks.",
            "Menu bar → Import takes a stack. A stick's menu → Import Stick takes exactly one stick.",
            "Export one stick or its whole stack: copy the JSON or save it to a file.",
            "Sensitive lines are excluded unless you tick the option, which writes them as plain text.",
        ]),
    ]

    var expandAll = false
    var close: () -> Void = {}
    @State private var open: Set<UUID> = []

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        AppWindowChrome(title: "About & Help", close: close) {
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Stickspace").font(.system(size: 16, weight: .semibold))
                        Text("Reusable text, kept close.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(topics) { topic in
                            let isOpen = open.contains(topic.id)
                            Button {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    if isOpen { open.remove(topic.id) } else { open.insert(topic.id) }
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10, weight: .semibold))
                                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                                        .frame(width: 12)
                                    Image(systemName: topic.symbol).font(.system(size: 12)).frame(width: 16)
                                    Text(topic.title).font(.system(size: 13))
                                    Spacer()
                                }
                                .frame(height: 30)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
                            if isOpen {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(topic.bullets, id: \.self) { b in
                                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                                            Text("•").foregroundStyle(Palette.blue)
                                            Text(b).fixedSize(horizontal: false, vertical: true)
                                        }
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.leading, 36)
                                .padding(.bottom, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Rectangle().fill(Palette.separator(scheme)).frame(height: 0.5)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 480, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
        .onAppear { open = expandAll ? Set(topics.map(\.id)) : [topics[0].id] }
    }
}
