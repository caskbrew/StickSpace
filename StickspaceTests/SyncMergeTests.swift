import XCTest

final class SyncMergeTests: XCTestCase {
    private func block(_ text: String, _ id: UUID = UUID()) -> Block { Block(id: id, type: .text, text: text) }

    /// A synced group whose local content equals its base.
    private func synced(_ blocks: [Block], name: String = "Ops", file: String? = nil) -> Stick {
        let id = UUID()
        var s = Stick(id: id, name: name, blocks: blocks)
        s.origin = GroupOrigin(source: nil, file: file, base: GroupSnapshot(id: id, name: name, blocks: blocks))
        return s
    }

    private func remote(of s: Stick, name: String? = nil, _ blocks: [Block]) -> GroupSnapshot {
        GroupSnapshot(id: s.id, name: name ?? s.origin!.base.name, blocks: blocks)
    }

    func testNothingNewUpstreamChangesNothing() {
        let s = synced([block("a"), block("b")])
        let r = SyncMerge.merge(s, remote: s.origin!.base)
        XCTAssertEqual(r.outcome, .unchanged)
        XCTAssertEqual(r.stick, s)
    }

    func testRemoteChangeIsTakenAndLocalFlagsStay() {
        var s = synced([block("a"), block("b")])
        s.blocks[0].isMasked = true
        s.blocks[1].isHidden = true
        var upstream = s.origin!.base.blocks
        upstream[0].text = "a2"; upstream[1].title = "B"; upstream[1].tags = ["prod"]
        let r = SyncMerge.merge(s, remote: remote(of: s, upstream))
        XCTAssertEqual(r.outcome, .updated)
        let out = r.stick!
        XCTAssertEqual(out.blocks.map(\.text), ["a2", "b"])
        XCTAssertEqual(out.blocks[1].title, "B")
        XCTAssertEqual(out.blocks[1].tags, ["prod"])
        XCTAssertTrue(out.blocks[0].isMasked)
        XCTAssertTrue(out.blocks[1].isHidden)
        XCTAssertFalse(out.isModified)
        XCTAssertEqual(out.origin!.base.blocks.map(\.text), ["a2", "b"])
    }

    func testLocalChangeSurvivesAndStaysModified() {
        var s = synced([block("a"), block("b")])
        s.blocks[0].text = "mine"
        var upstream = s.origin!.base.blocks
        upstream[1].text = "theirs"
        let r = SyncMerge.merge(s, remote: remote(of: s, upstream))
        XCTAssertEqual(r.outcome, .updated)
        XCTAssertEqual(r.stick!.blocks.map(\.text), ["mine", "theirs"])
        XCTAssertTrue(r.stick!.isModified)
        XCTAssertEqual(r.stick!.origin!.base.blocks.map(\.text), ["a", "theirs"], "base is the repository's version")
    }

    func testSameEntityChangedOnBothSidesKeepsMineAndCounts() {
        var s = synced([block("a")])
        s.blocks[0].text = "mine"
        let r = SyncMerge.merge(s, remote: remote(of: s, [Block(id: s.blocks[0].id, type: .text, text: "theirs")]))
        XCTAssertEqual(r.outcome, .conflicts(1))
        XCTAssertEqual(r.stick!.blocks[0].text, "mine")
        XCTAssertTrue(r.stick!.isModified)

        // Both made the same edit: no conflict, and nothing left to push.
        let same = SyncMerge.merge(s, remote: remote(of: s, [Block(id: s.blocks[0].id, type: .text, text: "mine")]))
        XCTAssertEqual(same.outcome, .updated)
        XCTAssertFalse(same.stick!.isModified)
    }

    func testAdditionsOnBothSidesAreKept() {
        var s = synced([block("a"), block("b")])
        let mineNew = block("mine")
        s.blocks.insert(mineNew, at: 1)                                       // a, mine, b
        let theirsNew = block("theirs")
        let upstream = [s.origin!.base.blocks[0], s.origin!.base.blocks[1], theirsNew]   // a, b, theirs
        let r = SyncMerge.merge(s, remote: remote(of: s, upstream))
        XCTAssertEqual(r.outcome, .updated)
        XCTAssertEqual(Set(r.stick!.blocks.map(\.text)), ["a", "b", "mine", "theirs"])
        XCTAssertEqual(r.stick!.blocks.first { $0.id == mineNew.id }?.text, "mine")
        XCTAssertTrue(r.stick!.isModified, "my addition is still to be pushed")
    }

    func testDeletions() {
        // Deleted upstream and untouched here: gone. Deleted upstream but edited here: kept, counted.
        var s = synced([block("a"), block("b"), block("c")])
        let base = s.origin!.base.blocks
        var r = SyncMerge.merge(s, remote: remote(of: s, [base[1], base[2]]))
        XCTAssertEqual(r.stick!.blocks.map(\.text), ["b", "c"])
        XCTAssertEqual(r.outcome, .updated)
        s.blocks[0].text = "a edited"
        r = SyncMerge.merge(s, remote: remote(of: s, [base[1], base[2]]))
        XCTAssertEqual(r.stick!.blocks.map(\.text), ["a edited", "b", "c"])
        XCTAssertEqual(r.outcome, .conflicts(1))

        // Deleted here, untouched upstream: stays deleted. Deleted here but edited upstream: the edit comes back.
        var t = synced([block("a"), block("b")])
        let tb = t.origin!.base.blocks
        t.blocks.remove(at: 0)
        r = SyncMerge.merge(t, remote: remote(of: t, tb))
        XCTAssertEqual(r.stick!.blocks.map(\.text), ["b"])
        XCTAssertEqual(r.outcome, .unchanged)
        XCTAssertTrue(r.stick!.isModified, "the deletion is still to be pushed")
        var edited = tb[0]; edited.text = "a upstream"
        r = SyncMerge.merge(t, remote: remote(of: t, [edited, tb[1]]))
        XCTAssertEqual(r.stick!.blocks.map(\.text), ["a upstream", "b"])
        XCTAssertEqual(r.outcome, .conflicts(1))
    }

    func testNameRules() {
        var s = synced([block("a")], name: "Ops")
        var r = SyncMerge.merge(s, remote: remote(of: s, name: "Platform", s.origin!.base.blocks))
        XCTAssertEqual(r.stick!.name, "Platform")
        s.name = "My Ops"
        r = SyncMerge.merge(s, remote: remote(of: s, s.origin!.base.blocks))
        XCTAssertEqual(r.stick!.name, "My Ops")
        XCTAssertTrue(r.stick!.isModified)
        r = SyncMerge.merge(s, remote: remote(of: s, name: "Platform", s.origin!.base.blocks))
        XCTAssertEqual(r.stick!.name, "My Ops")
        XCTAssertEqual(r.outcome, .conflicts(1))
    }

    func testOrderFollowsRemoteUnlessOnlyLocalReordered() {
        let (a, b, c) = (UUID(), UUID(), UUID())
        XCTAssertEqual(SyncMerge.mergeOrder(base: [a, b, c], local: [a, b, c], remote: [c, a, b], keep: [a, b, c]), [c, a, b])
        XCTAssertEqual(SyncMerge.mergeOrder(base: [a, b, c], local: [b, a, c], remote: [a, b, c], keep: [a, b, c]), [b, a, c])
        XCTAssertEqual(SyncMerge.mergeOrder(base: [a, b, c], local: [b, a, c], remote: [c, b, a], keep: [a, b, c]), [c, b, a], "both: remote wins")
        let d = UUID()
        XCTAssertEqual(SyncMerge.mergeOrder(base: [a, b], local: [a, d, b], remote: [b, a], keep: [a, b, d]), [b, a, d])
    }

    func testLocalOnlyMaskedEntitiesStayPutAndAreNotShared() {
        var s = synced([block("a"), block("b")])
        let secret = Block(id: UUID(), type: .text, text: "hunter2", isMasked: true)
        s.blocks.insert(secret, at: 1)                                         // a, secret, b
        var upstream = s.origin!.base.blocks
        upstream.insert(block("new"), at: 0)                                   // new, a, b
        let r = SyncMerge.merge(s, remote: remote(of: s, upstream))
        XCTAssertEqual(r.stick!.blocks.map(\.text), ["new", "a", "hunter2", "b"])
        XCTAssertFalse(r.stick!.isModified)
        XCTAssertEqual(r.stick!.snapshot.blocks.map(\.text), ["new", "a", "b"])
        XCTAssertFalse(r.stick!.origin!.base.blocks.contains { $0.text == "hunter2" })
    }

    func testGroupDeletedUpstream() {
        let clean = synced([block("a")])
        XCTAssertEqual(SyncMerge.merge(clean, remote: nil).outcome, .removed)
        XCTAssertNil(SyncMerge.merge(clean, remote: nil).stick)
        var edited = clean
        edited.blocks[0].text = "mine"
        let r = SyncMerge.merge(edited, remote: nil)
        XCTAssertEqual(r.outcome, .detached)
        XCTAssertNil(r.stick!.origin, "becomes a custom group")
        XCTAssertEqual(r.stick!.blocks[0].text, "mine")
        XCTAssertEqual(SyncMerge.merge(Stick(name: "custom"), remote: nil).outcome, .unchanged)
    }

    // MARK: Space

    private func remoteGroup(_ name: String, file: String? = nil, _ texts: [String] = []) -> SyncMerge.RemoteGroup {
        SyncMerge.RemoteGroup(snapshot: GroupSnapshot(id: UUID(), name: name, blocks: texts.map { block($0) }), file: file)
    }

    func testSpaceMergeAddsRemovesAndKeepsLocalChoices() {
        let g1 = remoteGroup("Clusters", file: "groups/clusters.json", ["x"])
        let g2 = remoteGroup("Grafana", ["y"])
        let g3 = remoteGroup("Jira")
        var space = StickGroup(sticks: [], name: "Platform")
        space.source = GitSource(url: "u", path: "stickspace.json")
        let first = SyncMerge.mergeSpace(space, remote: [g1, g2], head: "h1")
        XCTAssertEqual(first.report.added, 2)
        XCTAssertEqual(first.space.sticks.map(\.name), ["Clusters", "Grafana"])
        XCTAssertEqual(first.space.sticks[0].origin?.file, "groups/clusters.json")
        XCTAssertNil(first.space.sticks[1].origin?.file)
        XCTAssertEqual(first.space.source?.appliedHead, "h1")

        // The user hides Grafana, makes a custom group, and imports one group on its own.
        var local = first.space
        local.sticks[1].isHidden = true
        local.sticks.append(Stick(name: "Mine"))
        var single = Stick(name: "Solo")
        single.origin = GroupOrigin(source: GitSource(url: "u2", path: "solo.json"), file: "solo.json",
                                    base: GroupSnapshot(id: single.id, name: "Solo", blocks: []))
        local.sticks.append(single)

        // Upstream: Jira is added between the two, Clusters is dropped, Grafana moves into its own file.
        var g2moved = g2; g2moved.file = "groups/grafana.json"
        let second = SyncMerge.mergeSpace(local, remote: [g2moved, g3], head: "h2")
        XCTAssertEqual(second.report.added, 1)
        XCTAssertEqual(second.report.removed, 1)
        XCTAssertEqual(second.space.sticks.map(\.name), ["Grafana", "Jira", "Mine", "Solo"])
        XCTAssertTrue(second.space.sticks[0].isHidden, "hidden stays hidden")
        XCTAssertEqual(second.space.sticks[0].origin?.file, "groups/grafana.json")
        XCTAssertEqual(second.space.sticks[3], single, "a single imported group is not part of the space sync")
        XCTAssertEqual(second.space.source?.appliedHead, "h2")

        let third = SyncMerge.mergeSpace(second.space, remote: [g2moved, g3], head: "h2")
        XCTAssertTrue(third.report.isEmpty)
        XCTAssertEqual(third.space.sticks.map(\.id), second.space.sticks.map(\.id))
    }
}
