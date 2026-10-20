import SwiftUI
import UniformTypeIdentifiers

// MARK: - New Group / New Space

/// `group == nil` creates a new space (window); otherwise a group inside that space.
/// Deliberately bare: just a name field and the two buttons on the glass surface.
struct NewStickView: View {
    @ObservedObject var store: AppStore
    let group: UUID?
    let visibleIndex: Int?
    let close: () -> Void

    @State private var name: String
    @Environment(\.colorScheme) private var scheme

    init(store: AppStore, group: UUID?, visibleIndex: Int?, close: @escaping () -> Void) {
        self.store = store
        self.group = group
        self.visibleIndex = visibleIndex
        self.close = close
        _name = State(initialValue: group == nil ? "New Space" : "New Group")
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AppTextField(placeholder: group == nil ? "Space name" : "Group name", text: $name, onSubmit: create)
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
        if group == nil { store.addSpace(name: trimmed) } else { store.addStick(name: trimmed, group: group, atVisible: visibleIndex) }
        close()
    }
}

// MARK: - Rename

struct RenameView: View {
    enum Target { case group(UUID), space(UUID) }

    @ObservedObject var store: AppStore
    let target: Target
    let close: () -> Void

    @State private var name: String

    init(store: AppStore, target: Target, close: @escaping () -> Void) {
        self.store = store
        self.target = target
        self.close = close
        switch target {
        case .group(let id): _name = State(initialValue: store.stick(id)?.name ?? "")
        case .space(let id): _name = State(initialValue: store.groupIndex(id).map { store.state.groups[$0].name } ?? "")
        }
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        AppWindowChrome(title: { if case .space = target { return "Rename Space" } else { return "Rename Group" } }(), close: close) {
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
        switch target {
        case .group(let id): store.renameStick(id, to: trimmed)
        case .space(let id): store.renameSpace(id, to: trimmed)
        }
        close()
    }
}

// MARK: - Export

struct ExportView: View {
    @ObservedObject var store: AppStore
    /// nil: exporting a space from its own menu (no group to pick).
    let stickID: UUID?
    let spaceID: UUID
    let close: () -> Void

    private enum Scope: Hashable { case group, space }

    @State private var scope: Scope
    @State private var includeSensitive: Bool
    @State private var copied = false
    @Environment(\.colorScheme) private var scheme

    init(store: AppStore, stickID: UUID?, spaceID: UUID, includeSensitive: Bool = false, wholeSpace: Bool = false, close: @escaping () -> Void) {
        self.store = store
        self.stickID = stickID
        self.spaceID = spaceID
        self.close = close
        _scope = State(initialValue: wholeSpace || stickID == nil ? .space : .group)
        _includeSensitive = State(initialValue: includeSensitive)
    }

    private var sticks: [Stick] {
        if scope == .space, let g = store.groupIndex(spaceID) { return store.state.groups[g].sticks }
        return stickID.flatMap { store.stick($0) }.map { [$0] } ?? []
    }

    private var json: String {
        let name = store.groupIndex(spaceID).map { store.state.groups[$0].name }
        return Interchange.export(sticks, asSingle: scope == .group, includeSensitive: includeSensitive, spaceName: name)
    }

    var body: some View {
        // Bare surface (no title row): scope switch, JSON, one option row with the Copy button.
        VStack(alignment: .leading, spacing: 10) {
            if stickID != nil {
                AppSegmented(options: [(Scope.group, "This Group"), (Scope.space, "This Space")], selection: $scope)
            }
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

/// `group == nil`: imports a whole space (a list of groups) as a new window.
/// Otherwise: imports exactly one group into that space at `visibleIndex`.
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

    private var isSpace: Bool { group == nil }
    private var sectionCount: Int { parsed.reduce(0) { $0 + $1.blocks.count } }

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // Bare surface like New Space: no title row, no close button (Esc or Cancel closes).
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
        "\(parsed.count) group\(parsed.count == 1 ? "" : "s") · \(sectionCount) entit\(sectionCount == 1 ? "y" : "ies")"
    }

    private func reparse(_ new: String) {
        guard !new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            parsed = []; error = nil
            return
        }
        do {
            let sticks = try Interchange.parse(new)
            if !isSpace && sticks.count != 1 {
                throw Interchange.ImportError(message: "This JSON has \(sticks.count) groups. A group import takes exactly one; use Import in the menu bar for a whole space.")
            }
            parsed = sticks
            error = nil
        } catch {
            parsed = []
            self.error = (error as? Interchange.ImportError)?.message ?? "Could not read JSON."
        }
    }

    private func doImport() {
        store.insert(parsed, group: group, atVisible: visibleIndex, spaceName: Interchange.spaceName(in: text) ?? "Imported Space")
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
            "An entity holds one piece of text. Entities form a group, and groups form a space: one window.",
            "The space header is always on top. Double-click it to fold the groups away or bring them back.",
            "Double-click a group's title to expand or collapse it. Several can stay open.",
            "Double-click an entity to edit it. Esc or ⌘↩ finishes; text is saved as you type.",
            "Drag the dotted grip to reorder groups; drag an entity up or down to reorder entities within its group.",
            "Drag the space header or a group's title row to move the whole window (not while it is pinned).",
            "Each entity's copy button copies its exact text, nothing else.",
            "An entity is a link only when the whole text is an http/https address.",
        ]),
        Topic(title: "Titles & Tags", symbol: "tag", bullets: [
            "A title is shown instead of a long text or link. Copy and Open still use the real value; hover to see it.",
            "Tags are short labels such as prod, stg or dev, shown as coloured chips. Separate several with commas.",
            "Tags you already use are offered as one-click suggestions while editing.",
        ]),
        Topic(title: "Hidden Items", symbol: "eye.slash", bullets: [
            "Hide (right-click a group or entity) tucks it away without deleting it; the item shows a check mark while hidden.",
            "When a space has hidden items, an eye button appears in its header (or use Show Hidden in the header menu). It lists them, dimmed, in place.",
            "While they are listed, right-click a hidden item and untick Hide to bring it back. Click the header eye again to hide them from view.",
            "Hidden items can still be reordered and deleted while listed. Open All and Export skip hidden entities.",
        ]),
        Topic(title: "Sensitive Content", symbol: "eye", bullets: [
            "Mask shows •••••••• instead of the text, whatever its length. A title, if set, stays visible.",
            "The eye reveals it temporarily. It hides again when you press the eye, the window loses focus, or the group collapses.",
            "Copy works without revealing.",
            "Masking only hides the text on screen. It is not encryption: the text is saved in plain form in Stickspace's data file.",
            "After you copy it, the text sits on the system clipboard where other apps can read it.",
            "Masked entities are skipped by Open All and by Export unless you opt in.",
        ]),
        Topic(title: "Pin", symbol: "pin", bullets: [
            "The pin sits in the space header. A pinned window cannot be moved; it does not stay above other windows.",
            "Pinning never takes keyboard focus.",
        ]),
        Topic(title: "Context Menus", symbol: "contextualmenu.and.cursorarrow", bullets: [
            "Right-click the space header for Rename, Add Group, Show Hidden, zoom, Import Group, Export, Close and Delete.",
            "Right-click a group for Rename, Hide, Add Group Above/Below, Import Group, Export and Delete.",
            "Right-click an entity for Edit, Copy, Type, Move Up/Down, Hide, Mask and Delete.",
            "Close hides the whole window; bring it back from the menu bar.",
            "Link buttons: click opens in the browser; ⌘-click opens in the background so Stickspace stays active.",
            "The arrow in a group's title row opens all of its visible, non-sensitive links, once each.",
        ]),
        Topic(title: "Menu Bar", symbol: "menubar.rectangle", bullets: [
            "New Space creates a new window. Add groups to it from the + in its header or its context menu.",
            "Each space is listed with a check mark: click it to hide or show that window.",
            "Import adds a whole space (a list of groups) pasted as JSON as a new window.",
            "The three icons switch between system, light and dark appearance for the whole app.",
            "Restart (⇧⌘R) saves and relaunches. Quit (⌘Q) saves and exits.",
        ]),
        Topic(title: "Delete & Undo", symbol: "trash", bullets: [
            "Deleting a space, group or entity happens immediately, with no confirmation.",
            "Press Undo in the notice or ⌘Z to bring it back.",
        ]),
        Topic(title: "Zoom per Space", symbol: "magnifyingglass", bullets: [
            "⌘+ (or ⌘=) zooms in, ⌘− zooms out, ⌘0 resets. The range is 60%–200%. The space header menu has the same items.",
            "Zoom applies only to the space you last used and is remembered per space.",
        ]),
        Topic(title: "Import & Export (JSON)", symbol: "doc", bullets: [
            "Paste JSON to import. Import never overwrites existing groups.",
            "Menu bar → Import takes a space. A group's menu → Import Group takes exactly one group.",
            "Export one group or its whole space: copy the JSON.",
            "Sensitive entities are excluded unless you tick the option, which writes them as plain text.",
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
