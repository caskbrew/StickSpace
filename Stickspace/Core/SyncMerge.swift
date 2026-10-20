import Foundation

/// Three-way merge of shared content (base = last synced version, local = what is on this Mac, remote = the repository now).
/// Pure functions: no Git, no UI. See docs/design/git-sync.md.
enum SyncMerge {
    enum Outcome: Equatable {
        case unchanged
        case updated
        /// Both sides changed the same thing: yours is kept. The count is how many items.
        case conflicts(Int)
        /// Deleted upstream but edited here: the group stays as a custom group.
        case detached
        /// Deleted upstream and untouched here.
        case removed
    }

    struct Result: Equatable {
        var stick: Stick?
        var outcome: Outcome
    }

    /// A group as it is in the repository: `file` is its own file, nil when it is written inline in the space file.
    struct RemoteGroup: Equatable {
        var snapshot: GroupSnapshot
        var file: String?
    }

    struct SpaceReport: Equatable {
        var added = 0, updated = 0, removed = 0, detached = 0, conflicts = 0
        var isEmpty: Bool { added + updated + removed + detached + conflicts == 0 }
    }

    // MARK: One group

    /// `remote == nil` means the group is gone from the repository.
    static func merge(_ local: Stick, remote: GroupSnapshot?, file: String?? = nil) -> Result {
        guard var origin = local.origin else { return Result(stick: local, outcome: .unchanged) }
        let base = origin.base
        guard let remote else {
            if local.isModified {
                var custom = local
                custom.origin = nil
                return Result(stick: custom, outcome: .detached)
            }
            return Result(stick: nil, outcome: .removed)
        }

        var out = local
        if let file { origin.file = file }
        var conflicts = 0

        // Name.
        if local.name == base.name {
            out.name = remote.name
        } else if remote.name != base.name && remote.name != local.name {
            conflicts += 1
        }

        // Entities, by id.
        let localShared = local.sharedBlocks
        let baseByID = Dictionary(uniqueKeysWithValues: base.blocks.map { ($0.id, $0) })
        let remoteByID = Dictionary(uniqueKeysWithValues: remote.blocks.map { ($0.id, $0) })
        let localByID = Dictionary(uniqueKeysWithValues: localShared.map { ($0.id, $0) })

        var merged: [UUID: Block] = [:]
        let ids = Set(baseByID.keys).union(remoteByID.keys).union(localByID.keys)
        for id in ids {
            let b = baseByID[id], l = localByID[id], r = remoteByID[id]
            switch (l, r) {
            case let (l?, r?):
                guard let b else { merged[id] = with(shared: r, on: l); continue }
                let localChanged = SharedEntity(l) != SharedEntity(b)
                let remoteChanged = SharedEntity(r) != SharedEntity(b)
                if !localChanged { merged[id] = with(shared: r, on: l) }
                else if !remoteChanged || SharedEntity(l) == SharedEntity(r) { merged[id] = l }
                else { merged[id] = l; conflicts += 1 }
            case let (l?, nil):
                guard let b else { merged[id] = l; continue }              // added here
                if SharedEntity(l) == SharedEntity(b) { continue }         // deleted upstream, untouched here
                merged[id] = l; conflicts += 1                             // deleted upstream, edited here
            case let (nil, r?):
                guard let b else { merged[id] = r; continue }              // added upstream
                if SharedEntity(r) == SharedEntity(b) { continue }         // deleted here, untouched upstream
                merged[id] = r; conflicts += 1                             // deleted here, edited upstream: the edit wins
            case (nil, nil):
                break
            }
        }

        let order = mergeOrder(base: base.blocks.map(\.id), local: localShared.map(\.id), remote: remote.blocks.map(\.id),
                               keep: Set(merged.keys))
        var blocks = order.compactMap { merged[$0] }

        // Local-only entities stay where they were, after the shared entity that preceded them.
        var previous: UUID?
        for block in local.blocks {
            if local.isLocalOnly(block) {
                let at = previous.flatMap { p in blocks.firstIndex { $0.id == p } }.map { $0 + 1 } ?? (previous == nil ? 0 : blocks.count)
                blocks.insert(block, at: at)
            } else {
                previous = block.id
            }
        }
        out.blocks = blocks
        origin.base = remote
        out.origin = origin

        let changed = remote != base || (file != nil && file! != local.origin?.file)
        let outcome: Outcome = conflicts > 0 ? .conflicts(conflicts) : (changed ? .updated : .unchanged)
        return Result(stick: out, outcome: outcome)
    }

    /// Shared fields come from `source`; hidden / masked stay as they are on this Mac.
    private static func with(shared source: Block, on local: Block) -> Block {
        var b = local
        b.type = source.type; b.text = source.text; b.title = source.title; b.tags = source.tags
        return b
    }

    /// The remote order, unless only the local order changed. Items missing from the primary list are
    /// placed after the nearest preceding item of the other list.
    static func mergeOrder(base: [UUID], local: [UUID], remote: [UUID], keep: Set<UUID>) -> [UUID] {
        func changed(_ list: [UUID]) -> Bool {
            let common = Set(base).intersection(list)
            return base.filter(common.contains) != list.filter(common.contains)
        }
        let useLocal = changed(local) && !changed(remote)
        let primary = useLocal ? local : remote
        let secondary = useLocal ? remote : local
        var result = primary.filter(keep.contains)
        for (i, id) in secondary.enumerated() where keep.contains(id) && !result.contains(id) {
            var at = 0
            var j = i - 1
            while j >= 0 {
                if let p = result.firstIndex(of: secondary[j]) { at = p + 1; break }
                j -= 1
            }
            result.insert(id, at: at)
        }
        return result
    }

    // MARK: A whole space

    /// Merges the groups of a space file into the space. Groups the user keeps hidden stay hidden; custom groups are untouched.
    static func mergeSpace(_ space: StickGroup, remote: [RemoteGroup], head: String) -> (space: StickGroup, report: SpaceReport) {
        var out = space
        var report = SpaceReport()
        let remoteByID = Dictionary(uniqueKeysWithValues: remote.map { ($0.snapshot.id, $0) })

        var sticks: [Stick] = []
        for stick in space.sticks {
            guard let origin = stick.origin, origin.source == nil else { sticks.append(stick); continue }   // custom or single import
            let r = remoteByID[stick.id]
            let result = merge(stick, remote: r?.snapshot, file: r.map { $0.file })
            tally(result.outcome, into: &report)
            if let merged = result.stick { sticks.append(merged) }
        }

        // New groups go after the group that precedes them in the repository.
        let known = Set(sticks.map(\.id))
        for (i, r) in remote.enumerated() where !known.contains(r.snapshot.id) {
            let stick = Stick(id: r.snapshot.id, name: r.snapshot.name, blocks: r.snapshot.blocks,
                              origin: GroupOrigin(source: nil, file: r.file, base: r.snapshot))
            var at = 0
            var j = i - 1
            while j >= 0 {
                if let p = sticks.firstIndex(where: { $0.id == remote[j].snapshot.id }) { at = p + 1; break }
                j -= 1
            }
            sticks.insert(stick, at: at)
            report.added += 1
        }
        out.sticks = sticks
        out.source?.appliedHead = head
        return (out, report)
    }

    static func tally(_ outcome: Outcome, into report: inout SpaceReport) {
        switch outcome {
        case .unchanged: break
        case .updated: report.updated += 1
        case .conflicts(let n): report.updated += 1; report.conflicts += n
        case .detached: report.detached += 1
        case .removed: report.removed += 1
        }
    }
}
