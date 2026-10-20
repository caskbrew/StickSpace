import Foundation
import CoreGraphics

enum BlockType: String, CaseIterable {
    case auto, text, link, code

    var title: String { rawValue.capitalized }
}

enum ThemeChoice: String, CaseIterable {
    case system, light, dark
}

/// An entity ("block" in code): one piece of text. Kept free of UI types so it can be tested in isolation.
struct Block: Identifiable, Equatable {
    var id = UUID()
    var type: BlockType = .auto
    var text = ""
    var isHidden = false
    var isMasked = false
    /// Shown instead of the text (or link) when not empty.
    var title = ""
    var tags: [String] = []
}

enum BlockKind: Equatable {
    case text, code, link(URL)
}

extension Block {
    /// Short label for menus and lists. Never reveals masked text.
    var menuTitle: String {
        if isMasked { return "Sensitive entity" }
        let shown = title.trimmingCharacters(in: .whitespaces)
        let line = shown.isEmpty ? (text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "") : shown
        return line.isEmpty ? "Empty entity" : String(line.prefix(40))
    }

    var hasTitle: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Auto and Link blocks are links only when the *whole* text is a valid http(s) address.
    var kind: BlockKind {
        switch type {
        case .code: return .code
        case .text: return .text
        case .auto, .link:
            if let url = LinkCheck.url(from: text) { return .link(url) }
            return .text
        }
    }

    var linkURL: URL? {
        if case .link(let url) = kind { return url }
        return nil
    }
}

enum LinkCheck {
    static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let comps = URLComponents(string: trimmed),
              let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = comps.host, !host.isEmpty,
              let url = comps.url else { return nil }
        return url
    }
}

/// A group ("stick" in code): a named list of entities.
struct Stick: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var blocks: [Block] = []
    var isHidden = false
    var isExpanded = false

    /// Links for "open all": visible, non-sensitive, in section order, duplicates removed.
    var openableLinks: [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for block in blocks where !block.isHidden && !block.isMasked {
            guard let url = block.linkURL, seen.insert(url.absoluteString).inserted else { continue }
            result.append(url)
        }
        return result
    }
}

/// A space ("StickGroup" in code): one window holding groups.
struct StickGroup: Identifiable, Equatable {
    var id = UUID()
    var sticks: [Stick] = []
    var isPinned = false
    /// Hides the whole window; every group keeps its own state.
    var isHidden = false
    var zoom: Double = 1.0
    var originX: Double?
    var topY: Double?
    var name = "Space"
    /// Collapsed to its header row only.
    var isCollapsed = false

    var visibleSticks: [Stick] { sticks.filter { !$0.isHidden } }
    /// The header keeps an empty space reachable, so a window exists for every shown space.
    var showsWindow: Bool { !isHidden }
}

struct AppState: Equatable {
    static let currentVersion = 1
    var theme: ThemeChoice = .system
    var groups: [StickGroup] = []
}

enum Zoom {
    static let steps: [Double] = [0.6, 0.7, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0]

    static func next(_ z: Double) -> Double { steps.first { $0 > z + 0.001 } ?? steps[steps.count - 1] }
    static func previous(_ z: Double) -> Double { steps.last { $0 < z - 0.001 } ?? steps[0] }
}

/// Keeps a restored window reachable: if it no longer overlaps any screen, move it onto the first one.
enum ScreenFit {
    static func fit(_ frame: CGRect, screens: [CGRect]) -> CGRect {
        guard let first = screens.first else { return frame }
        let minVisible = CGSize(width: 60, height: 24)
        for screen in screens {
            let overlap = screen.intersection(frame)
            if !overlap.isNull, overlap.width >= min(minVisible.width, frame.width),
               overlap.height >= min(minVisible.height, frame.height) { return frame }
        }
        var moved = frame
        moved.origin.x = min(max(frame.origin.x, first.minX + 8), max(first.minX + 8, first.maxX - frame.width - 8))
        moved.origin.y = min(max(frame.origin.y, first.minY + 8), max(first.minY + 8, first.maxY - frame.height - 8))
        return moved
    }
}

enum Tags {
    /// Trimmed, no empties, no case-insensitive duplicates, order kept.
    static func clean(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    static func parse(_ text: String) -> [String] {
        clean(text.split(whereSeparator: { $0 == "," || $0 == "\n" }).map(String.init))
    }
}
