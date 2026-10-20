import XCTest

/// End to end against a local bare repository: import, sync, edit, push, merge upstream, sync again.
final class SyncServiceTests: GitTestCase {
    private let clusterID = UUID(), jiraID = UUID()
    private let c1 = UUID(), c2 = UUID(), j1 = UUID()

    private func clusters(_ texts: (String, String) = ("kubectl --context prod get pods", "kubectl --context stg get pods")) -> Stick {
        Stick(id: clusterID, name: "Clusters", blocks: [
            Block(id: c1, type: .text, text: texts.0, title: "prod", tags: ["prod"]),
            Block(id: c2, type: .text, text: texts.1, title: "stg", tags: ["stg"]),
        ])
    }

    private func jira(_ url: String = "https://jira.example.com/board") -> Stick {
        Stick(id: jiraID, name: "Jira", blocks: [Block(id: j1, type: .link, text: url, title: "Board")])
    }

    private func publish(clusters: Stick? = nil, jira: Stick? = nil, extra: [String: String] = [:]) throws {
        var files = ["platform/stickspace.json": Interchange.encodeSpaceFile(name: "Platform team",
                                                                           entries: [.file("groups/clusters.json"), .inline(jira ?? self.jira())]),
                     "platform/groups/clusters.json": Interchange.encodeGroupFile(clusters ?? self.clusters())]
        files.merge(extra) { _, new in new }
        try upstreamCommit(files)
    }

    private var source: GitSource { GitSource(url: bare.path, path: "platform/stickspace.json", ref: "main") }
    private func repoFor() -> SyncService.RepoFor { { [self] src in GitRepo(url: src.url, root: tmp.appendingPathComponent("clones"), runner: runner) } }

    private func importedStore() throws -> (AppStore, UUID) {
        try publish()
        let store = AppStore()
        let read = try SyncService.readSpace(source, repo: repoFor()(source))
        let id = try store.importSpace(read, source: source)
        return (store, id)
    }

    private func space(_ s: AppStore, _ id: UUID) -> StickGroup { s.state.groups[s.groupIndex(id)!] }

    // MARK: Import

    func testImportSpaceReadsInlineAndFileGroups() throws {
        let (store, id) = try importedStore()
        let sp = space(store, id)
        XCTAssertEqual(sp.name, "Platform team")
        XCTAssertEqual(sp.sticks.map(\.name), ["Clusters", "Jira"])
        XCTAssertEqual(sp.sticks[0].origin?.file, "platform/groups/clusters.json")
        XCTAssertNil(sp.sticks[1].origin?.file)
        XCTAssertEqual(sp.sticks[0].blocks.map(\.id), [c1, c2])
        XCTAssertEqual(sp.sticks[0].blocks[0].tags, ["prod"])
        XCTAssertEqual(sp.sticks[1].blocks[0].type, .link)
        XCTAssertNotNil(sp.source?.appliedHead)
        XCTAssertTrue(sp.sticks.allSatisfy { !$0.isModified })
        // The same groups cannot be imported twice.
        let again = try SyncService.readSpace(source, repo: repoFor()(source))
        XCTAssertThrowsError(try store.importSpace(again, source: source))
    }

    func testImportProblemsAreReported() throws {
        try upstreamCommit(["a/stickspace.json": Interchange.encodeSpaceFile(name: "S", entries: [.file("missing.json")]), "bad.json": "{oops"])
        func message(_ path: String, ref: String = "main") -> String? {
            let s = GitSource(url: bare.path, path: path, ref: ref)
            do { _ = try SyncService.readSpace(s, repo: repoFor()(s)); return nil } catch { return (error as? GitError)?.message }
        }
        XCTAssertTrue(message("a/stickspace.json")?.contains("a/missing.json") == true)
        XCTAssertTrue(message("nope.json")?.contains("was not found") == true)
        XCTAssertTrue(message("bad.json")?.contains("Invalid JSON") == true)
        XCTAssertTrue(message("a/stickspace.json", ref: "zzz")?.contains("zzz") == true)
    }

    // MARK: Sync

    func testSyncBringsUpstreamChangesAndKeepsLocalState() throws {
        let (store, id) = try importedStore()
        store.setHidden(true, stick: jiraID)                                     // local choice
        store.state.groups[0].sticks.append(Stick(name: "Mine"))                 // custom group
        XCTAssertFalse(try SyncService.hasUpdates(space: space(store, id), repoFor: repoFor()))

        var newCluster = clusters(("kubectl --context prod-eu get pods", "kubectl --context stg get pods"))
        newCluster.blocks.append(Block(id: UUID(), type: .text, text: "kubectl --context dev get pods", title: "dev", tags: ["dev"]))
        let extra = Stick(id: UUID(), name: "Grafana", blocks: [Block(id: UUID(), type: .link, text: "https://grafana.example.com", title: "G")])
        try upstreamCommit(["platform/stickspace.json": Interchange.encodeSpaceFile(
                                name: "Platform team", entries: [.file("groups/clusters.json"), .inline(jira()), .inline(extra)]),
                            "platform/groups/clusters.json": Interchange.encodeGroupFile(newCluster)])

        XCTAssertTrue(try SyncService.hasUpdates(space: space(store, id), repoFor: repoFor()))
        let fetched = try SyncService.fetch(space: space(store, id), repoFor: repoFor())
        let report = store.applySync(space: id, fetched: fetched)
        XCTAssertEqual(report.added, 1)
        XCTAssertEqual(report.updated, 1)
        XCTAssertEqual(report.conflicts, 0)
        let sp = space(store, id)
        XCTAssertEqual(sp.sticks.map(\.name), ["Clusters", "Jira", "Grafana", "Mine"])
        XCTAssertEqual(sp.sticks[0].blocks.map(\.title), ["prod", "stg", "dev"])
        XCTAssertTrue(sp.sticks[1].isHidden)
        XCTAssertFalse(try SyncService.hasUpdates(space: sp, repoFor: repoFor()))

        let again = store.applySync(space: id, fetched: try SyncService.fetch(space: sp, repoFor: repoFor()))
        XCTAssertTrue(again.isEmpty)
    }

    // MARK: Push

    func testPushWritesOnlyChangedGroupsAndNeverLocalOnlyContent() throws {
        let (store, id) = try importedStore()
        store.updateBlock(c2) { $0.text = "kubectl --context stg-2 get pods" }               // a group in its own file
        store.updateBlock(j1) { $0.title = "Team board" }                                     // an inline group
        store.state.groups[0].sticks.append(Stick(name: "Mine", blocks: [Block(text: "private")]))   // custom
        let secret = Block(id: UUID(), type: .text, text: "hunter2", isMasked: true)
        store.state.groups[0].sticks[0].blocks.append(secret)                                 // masked, local-only
        XCTAssertEqual(SyncPush.plans(space: space(store, id), spaceFile: nil).count, 0, "without the space file only singles are planned")

        let summaries = try SyncService.push(space: space(store, id), repoFor: repoFor(), user: "Anna Q")
        let summary = try XCTUnwrap(summaries.first)
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(Set(summary.groups), ["Clusters", "Jira"])
        let result = try XCTUnwrap(summary.result)
        XCTAssertTrue(result.branch.hasPrefix("stickspace/anna-q-"))

        func file(_ path: String) throws -> String { try runner.output(["show", "\(result.branch):\(path)"], in: bare) }
        let cl = try Interchange.decodeGroupFile(try file("platform/groups/clusters.json"))
        XCTAssertEqual(cl.blocks.map(\.text), ["kubectl --context prod get pods", "kubectl --context stg-2 get pods"])
        let sf = try Interchange.decodeSpaceFile(try file("platform/stickspace.json"))
        XCTAssertEqual(sf.entries.count, 2)
        XCTAssertEqual(sf.entries[0], .file("groups/clusters.json"))
        guard case .inline(let jr) = sf.entries[1] else { return XCTFail() }
        XCTAssertEqual(jr.blocks[0].title, "Team board")
        let all = try runner.output(["grep", "-l", "-e", "private", "-e", "hunter2", result.branch], in: bare, allowFailure: true)
        XCTAssertEqual(all, "", "custom and masked content never leaves")
        XCTAssertEqual(try runner.output(["rev-parse", "main"], in: bare), try runner.output(["rev-parse", "\(result.branch)~1"], in: bare))

        // Still modified until the merge request is merged.
        XCTAssertTrue(space(store, id).sticks[0].isModified)
        let again = try SyncService.fetch(space: space(store, id), repoFor: repoFor())
        _ = store.applySync(space: id, fetched: again)
        XCTAssertTrue(space(store, id).sticks[0].isModified, "an unmerged push does not revert my edit")
        XCTAssertEqual(space(store, id).sticks[0].blocks[1].text, "kubectl --context stg-2 get pods")

        // The merge request is merged: main now has my content, and the next sync finds nothing left to push.
        try runner.run(["update-ref", "refs/heads/main", result.commit], in: bare)
        let merged = try SyncService.fetch(space: space(store, id), repoFor: repoFor())
        let report = store.applySync(space: id, fetched: merged)
        XCTAssertEqual(report.conflicts, 0)
        XCTAssertTrue(space(store, id).sticks.filter { $0.origin != nil }.allSatisfy { !$0.isModified })
        XCTAssertEqual(space(store, id).sticks[0].blocks.map(\.text).last, "hunter2", "the local-only entity is still there")
        XCTAssertTrue(try SyncService.push(space: space(store, id), repoFor: repoFor(), user: "Anna").isEmpty)
    }

    func testDirectPushMovesMain() throws {
        let (store, id) = try importedStore()
        store.state.groups[0].source?.directPush = true
        store.updateBlock(c1) { $0.title = "production" }
        let summary = try XCTUnwrap(try SyncService.push(space: space(store, id), repoFor: repoFor(), user: "a").first)
        XCTAssertEqual(summary.result?.direct, true)
        XCTAssertEqual(try runner.output(["rev-parse", "main"], in: bare), summary.result?.commit)
    }

    func testPushingToATagIsRefusedAndLocalWorkIsKept() throws {
        try publish()
        try runner.run(["tag", "v1"], in: work)
        try runner.run(["push", "--quiet", "origin", "v1"], in: work)
        var pinned = source
        pinned.ref = "v1"
        let store = AppStore()
        let id = try store.importSpace(try SyncService.readSpace(pinned, repo: repoFor()(pinned)), source: pinned)
        store.updateBlock(c1) { $0.title = "changed" }
        XCTAssertThrowsError(try SyncService.push(space: space(store, id), repoFor: repoFor(), user: "a")) {
            XCTAssertTrue(($0 as? GitError)?.message.contains("read-only") == true)
        }
        XCTAssertEqual(space(store, id).sticks[0].blocks[0].title, "changed")
    }

    // MARK: A single group file

    func testImportingOneGroupFileAndSyncingIt() throws {
        try publish()
        let store = AppStore()
        let space = store.addSpace(name: "Mine")
        let src = GitSource(url: bare.path, path: "platform/groups/clusters.json", ref: "main")
        let read = try SyncService.readGroup(src, repo: repoFor()(src), required: true)
        let stickID = try store.importGroup(read, source: src, into: space)
        XCTAssertEqual(store.stick(stickID)?.name, "Clusters")
        XCTAssertThrowsError(try store.importGroup(read, source: src, into: space), "no duplicates")

        try upstreamCommit(["platform/groups/clusters.json": Interchange.encodeGroupFile(clusters(("a", "b")))])
        var report = store.applySync(space: space, fetched: try SyncService.fetch(space: self.space(store, space), repoFor: repoFor()))
        XCTAssertEqual(report.updated, 1)
        XCTAssertEqual(store.stick(stickID)?.blocks.map(\.text), ["a", "b"])
        XCTAssertNotNil(store.stick(stickID)?.origin?.source?.appliedHead)

        // Edited here, then deleted upstream: it stays as a custom group.
        store.updateBlock(c1) { $0.text = "mine" }
        try runner.run(["rm", "--quiet", "platform/groups/clusters.json"], in: work)
        try runner.run(["commit", "--quiet", "-m", "drop"], in: work)
        try runner.run(["push", "--quiet", "origin", "HEAD:refs/heads/main"], in: work)
        report = store.applySync(space: space, fetched: try SyncService.fetch(space: self.space(store, space), repoFor: repoFor()))
        XCTAssertEqual(report.detached, 1)
        XCTAssertNil(store.stick(stickID)?.origin)
        XCTAssertEqual(store.stick(stickID)?.blocks[0].text, "mine")
    }

    // MARK: Revert

    func testRevertGroupAndEntityRestoreTheSharedVersion() throws {
        let (store, id) = try importedStore()
        store.updateBlock(c1) { $0.text = "edited"; $0.isMasked = true }
        store.updateBlock(c2) { $0.title = "changed" }
        store.renameStick(clusterID, to: "Renamed")
        XCTAssertTrue(store.isBlockModified(c1))
        store.revertBlock(c1)
        XCTAssertEqual(store.block(c1)?.text, "kubectl --context prod get pods")
        XCTAssertTrue(store.block(c1)?.isMasked == true, "local flags stay")
        XCTAssertFalse(store.isBlockModified(c1))
        store.revertGroup(clusterID)
        XCTAssertEqual(store.stick(clusterID)?.name, "Clusters")
        XCTAssertEqual(store.block(c2)?.title, "stg")
        XCTAssertFalse(store.stick(clusterID)!.isModified)
        _ = id
    }
}
