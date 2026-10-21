import Foundation

/// State changes for Git sync. No Git here: the data comes in already read (see SyncService).
extension AppStore {
    struct SyncError: Error, Equatable, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func existingIDs() -> Set<UUID> {
        Set(state.groups.flatMap { $0.sticks.map(\.id) })
    }

    private func stick(from remote: SyncMerge.RemoteGroup, source: GitSource?) -> Stick {
        Stick(id: remote.snapshot.id, name: remote.snapshot.name, blocks: remote.snapshot.blocks,
              origin: GroupOrigin(source: source, file: remote.file, base: remote.snapshot))
    }

    /// A new space from a space file. Refuses groups that are already in the app, so nothing appears twice.
    @discardableResult
    func importSpace(_ read: SyncService.SpaceRead, source: GitSource) throws -> UUID {
        let taken = existingIDs()
        if let dup = read.groups.first(where: { taken.contains($0.snapshot.id) }) {
            throw SyncError(message: "“\(dup.snapshot.name)” is already in this app.")
        }
        var src = source
        src.appliedHead = read.head
        var space = StickGroup(sticks: read.groups.map { stick(from: $0, source: nil) }, name: read.name)
        space.source = src
        state.groups.append(space)
        activeGroupID = space.id
        return space.id
    }

    /// One group file, added to an existing space.
    @discardableResult
    func importGroup(_ read: SyncService.GroupRead, source: GitSource, into space: UUID) throws -> UUID {
        guard let remote = read.group, let g = groupIndex(space) else { throw SyncError(message: "Nothing to import.") }
        if existingIDs().contains(remote.snapshot.id) { throw SyncError(message: "“\(remote.snapshot.name)” is already in this app.") }
        var src = source
        src.appliedHead = read.head
        var stick = stick(from: remote, source: src)
        stick.isExpanded = true
        state.groups[g].sticks.append(stick)
        if state.groups[g].isExclusive { setExpanded(true, stick: stick.id) }
        return stick.id
    }

    /// Merges what was read into the space and its single imported groups.
    @discardableResult
    func applySync(space id: UUID, fetched: SyncService.Fetched) -> SyncMerge.SpaceReport {
        guard let g = groupIndex(id) else { return SyncMerge.SpaceReport() }
        var space = state.groups[g]
        var report = SyncMerge.SpaceReport()
        if let read = fetched.space {
            let merged = SyncMerge.mergeSpace(space, remote: read.groups, head: read.head)
            space = merged.space
            report = merged.report
        } else if space.source?.isAwaitingMerge == true {
            report.waiting += 1
        }
        var sticks: [Stick] = []
        for stick in space.sticks {
            guard let source = stick.origin?.source, let single = fetched.singles[stick.id] else { sticks.append(stick); continue }
            if source.isAwaitingMerge && single.group == nil {            // exported, not merged yet: leave it alone
                report.waiting += 1
                sticks.append(stick)
                continue
            }
            var result = SyncMerge.merge(stick, remote: single.group?.snapshot)
            result.stick?.origin?.source?.appliedHead = single.head
            result.stick?.origin?.source?.awaitingMerge = nil
            SyncMerge.tally(result.outcome, into: &report)
            if let merged = result.stick { sticks.append(merged) }
        }
        space.sticks = sticks
        state.groups[g] = space
        return report
    }

    // MARK: Export (the other way round: what is here becomes the shared version)

    /// After an export, the exported groups are tied to the new files, so Sync and Push work on them from now on.
    /// `files` maps each exported group to its own file, or nil when it was written inline in the space file.
    func bindExportedSpace(_ id: UUID, source: GitSource, files: [UUID: String?]) {
        guard let g = groupIndex(id) else { return }
        state.groups[g].source = source
        for s in state.groups[g].sticks.indices {
            let stick = state.groups[g].sticks[s]
            guard let file = files[stick.id] else { continue }
            let exported = Stick(id: stick.id, name: stick.name, blocks: stick.blocks.filter { !$0.isMasked })
            state.groups[g].sticks[s].origin = GroupOrigin(source: nil, file: file, base: GroupSnapshot(exported))
        }
    }

    func bindExportedGroup(_ id: UUID, source: GitSource) {
        guard let l = locate(stick: id) else { return }
        let stick = state.groups[l.group].sticks[l.stick]
        let exported = Stick(id: stick.id, name: stick.name, blocks: stick.blocks.filter { !$0.isMasked })
        state.groups[l.group].sticks[l.stick].origin = GroupOrigin(source: source, file: source.path, base: GroupSnapshot(exported))
    }

    // MARK: Revert (= take the repository's version)

    func revertGroup(_ id: UUID) {
        guard let l = locate(stick: id), let origin = state.groups[l.group].sticks[l.stick].origin else { return }
        let stick = state.groups[l.group].sticks[l.stick]
        let flags = Dictionary(uniqueKeysWithValues: stick.blocks.map { ($0.id, $0) })
        var blocks = origin.base.blocks.map { b -> Block in
            var out = b
            out.isHidden = flags[b.id]?.isHidden ?? false
            out.isMasked = flags[b.id]?.isMasked ?? false
            return out
        }
        blocks += stick.blocks.filter { stick.isLocalOnly($0) }
        state.groups[l.group].sticks[l.stick].name = origin.base.name
        state.groups[l.group].sticks[l.stick].blocks = blocks
    }

    func revertBlock(_ id: UUID) {
        guard let l = locate(block: id), let origin = state.groups[l.group].sticks[l.stick].origin,
              let base = origin.base.blocks.first(where: { $0.id == id }) else { return }
        updateBlock(id) { $0.type = base.type; $0.text = base.text; $0.title = base.title; $0.tags = base.tags }
    }

    /// Entities that differ from the repository's version (for menus).
    func isBlockModified(_ id: UUID) -> Bool {
        guard let l = locate(block: id) else { return false }
        let stick = state.groups[l.group].sticks[l.stick]
        guard let base = stick.origin?.base.blocks.first(where: { $0.id == id }) else { return false }
        return SharedEntity(stick.blocks[l.block]) != SharedEntity(base)
    }
}
