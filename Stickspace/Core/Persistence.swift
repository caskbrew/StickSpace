import Foundation

// MARK: - Codec

enum StateError: Error, Equatable {
    case unsupportedVersion(Int)
}

private struct PBlock: Codable {
    var id: UUID
    var type: String
    var text: String
    var hidden: Bool
    var masked: Bool
}

private struct PStick: Codable {
    var id: UUID
    var name: String
    var hidden: Bool
    var expanded: Bool
    var blocks: [PBlock]
}

private struct PGroup: Codable {
    var id: UUID
    var pinned: Bool
    var hidden: Bool?
    var zoom: Double
    var originX: Double?
    var topY: Double?
    var sticks: [PStick]
}

private struct PState: Codable {
    var version: Int
    var theme: String
    var groups: [PGroup]
}

enum StateCodec {
    static func encode(_ state: AppState) throws -> Data {
        let groups: [PGroup] = state.groups.map { g in
            PGroup(id: g.id, pinned: g.isPinned, hidden: g.isHidden ? true : nil, zoom: g.zoom, originX: g.originX, topY: g.topY,
                   sticks: g.sticks.map { s in
                PStick(id: s.id, name: s.name, hidden: s.isHidden, expanded: s.isExpanded,
                       blocks: s.blocks.map { b in
                    PBlock(id: b.id, type: b.type.rawValue, text: b.text, hidden: b.isHidden, masked: b.isMasked)
                })
            })
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(PState(version: AppState.currentVersion, theme: state.theme.rawValue, groups: groups))
    }

    static func decode(_ data: Data) throws -> AppState {
        let p = try JSONDecoder().decode(PState.self, from: data)
        guard p.version >= 1, p.version <= AppState.currentVersion else { throw StateError.unsupportedVersion(p.version) }
        var state = AppState()
        state.theme = ThemeChoice(rawValue: p.theme) ?? .system
        state.groups = p.groups.map { g in
            StickGroup(id: g.id, sticks: g.sticks.map { s in
                Stick(id: s.id, name: s.name, blocks: s.blocks.map { b in
                    Block(id: b.id, type: BlockType(rawValue: b.type) ?? .auto,
                          text: b.text, isHidden: b.hidden, isMasked: b.masked)
                }, isHidden: s.hidden, isExpanded: s.expanded)
            }, isPinned: g.pinned, isHidden: g.hidden ?? false, zoom: min(max(g.zoom, Zoom.steps[0]), Zoom.steps[Zoom.steps.count - 1]),
                       originX: g.originX, topY: g.topY)
        }
        return state
    }
}

// MARK: - File store

enum LoadResult {
    case empty
    case loaded(AppState)
    /// The file could not be read; it was moved aside (never deleted) so the next save cannot overwrite it.
    case unreadable(movedTo: URL?)
}

struct StateFile {
    let url: URL

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Stickspace", isDirectory: true).appendingPathComponent("state.json")
    }

    func load() -> LoadResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        do {
            let data = try Data(contentsOf: url)
            return .loaded(try StateCodec.decode(data))
        } catch {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let aside = url.deletingLastPathComponent().appendingPathComponent("state.unreadable-\(stamp).json")
            do {
                try FileManager.default.moveItem(at: url, to: aside)
                return .unreadable(movedTo: aside)
            } catch {
                return .unreadable(movedTo: nil)
            }
        }
    }

    func write(_ data: Data) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

/// Debounced, off-main persistence. Encryption and disk I/O happen on a private serial queue.
final class StatePersistence {
    let file: StateFile
    private let queue = DispatchQueue(label: "stickspace.persistence", qos: .utility)
    private var pending: AppState?
    private var timer: DispatchWorkItem?
    private var lastWritten: Data?

    init(file: StateFile) {
        self.file = file
    }

    func load() -> LoadResult { file.load() }

    func scheduleSave(_ state: AppState) {
        queue.async {
            self.pending = state
            self.timer?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.writePending() }
            self.timer = work
            self.queue.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
    }

    /// Blocks until everything scheduled so far is on disk (quit / restart).
    func flush() {
        queue.sync {
            timer?.cancel()
            writePending()
        }
    }

    private func writePending() {
        guard let state = pending else { return }
        pending = nil
        do {
            let data = try StateCodec.encode(state)
            if data != lastWritten {
                try file.write(data)
                lastWritten = data
            }
        } catch {
            // Never log content; the error kind alone is enough.
            NSLog("Stickspace: could not save state (%@)", String(describing: type(of: error)))
        }
    }
}
