import Foundation
import CoreGraphics

enum BlockType: String, CaseIterable {
    case auto, text, link, code

    var title: String { rawValue.capitalized }
}

enum ThemeChoice: String, CaseIterable {
    case system, light, dark
}

/// A section of a stick ("block"). Kept free of UI types so it can be tested in isolation.
struct Block: Identifiable, Equatable {
    var id = UUID()
    var type: BlockType = .auto
    var text = ""
    var isHidden = false
    var isMasked = false
}

enum BlockKind: Equatable {
    case text, code, link(URL)
}

extension Block {
    /// Short label for menus and lists. Never reveals masked text.
    var menuTitle: String {
        if isMasked { return "Sensitive line" }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return line.isEmpty ? "Empty line" : String(line.prefix(40))
    }

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

struct StickGroup: Identifiable, Equatable {
    var id = UUID()
    var sticks: [Stick] = []
    var isPinned = false
    /// Hides the whole window; every stick keeps its own state.
    var isHidden = false
    var zoom: Double = 1.0
    var originX: Double?
    var topY: Double?

    var visibleSticks: [Stick] { sticks.filter { !$0.isHidden } }
    /// A window exists only for a shown group that has at least one shown stick.
    var showsWindow: Bool { !isHidden && !visibleSticks.isEmpty }
    var title: String { sticks.map(\.name).joined(separator: " · ") }
    /// The single pin lives on the top visible stick.
    var pinHolderID: UUID? { visibleSticks.first?.id }
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
