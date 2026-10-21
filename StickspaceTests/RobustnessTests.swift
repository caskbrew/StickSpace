import XCTest

/// Old files, hostile input, and the sentences the user reads.
final class RobustnessTests: XCTestCase {
    // MARK: Old state files

    func testAStateFileFromBeforeSpacesAndTwoTypesStillLoads() throws {
        let old = """
        {"version":1,"theme":"dark","groups":[{"id":"\(UUID())","pinned":true,"zoom":1.25,
          "sticks":[{"id":"\(UUID())","name":"Workspace","hidden":false,"expanded":true,"blocks":[
            {"id":"\(UUID())","type":"auto","text":"https://github.com","hidden":false,"masked":false},
            {"id":"\(UUID())","type":"auto","text":"just a note","hidden":false,"masked":false},
            {"id":"\(UUID())","type":"code","text":"npm run dev","hidden":true,"masked":false},
            {"id":"\(UUID())","type":"text","text":"secret","hidden":false,"masked":true}]},
           {"id":"\(UUID())","name":"Links","hidden":true,"expanded":false,"blocks":[]}]}]}
        """
        let state = try StateCodec.decode(Data(old.utf8))
        let space = state.groups[0]
        XCTAssertEqual(space.name, "Workspace · Links", "an unnamed space is named after its groups")
        XCTAssertEqual(space.zoom, 1.3)
        XCTAssertEqual(space.width, SpaceWidth.standard)
        XCTAssertFalse(space.isCollapsed)
        XCTAssertFalse(space.isExclusive)
        XCTAssertNil(space.source)
        XCTAssertTrue(space.isPinned)
        let blocks = space.sticks[0].blocks
        XCTAssertEqual(blocks.map(\.type), [.link, .text, .text, .text])
        XCTAssertEqual(blocks.map(\.isHidden), [false, false, true, false])
        XCTAssertEqual(blocks.map(\.isMasked), [false, false, false, true])
        XCTAssertTrue(blocks.allSatisfy { $0.title.isEmpty && $0.tags.isEmpty })
        XCTAssertNil(space.sticks[0].origin)
        XCTAssertTrue(space.sticks[1].isHidden)
        // And it saves again in the current shape.
        let again = try StateCodec.decode(StateCodec.encode(state))
        XCTAssertEqual(again, state)
    }

    func testAnEmptyOldSpaceGetsADefaultName() throws {
        let old = #"{"version":1,"theme":"system","groups":[{"id":"\#(UUID())","pinned":false,"zoom":1,"sticks":[]}]}"#
        XCTAssertEqual(try StateCodec.decode(Data(old.utf8)).groups[0].name, "Space")
    }

    // MARK: Hand-edited data must not crash

    func testDuplicateIdsDoNotCrashTheMerge() {
        let id = UUID()
        let twin = Block(id: id, type: .text, text: "a")
        var stick = Stick(id: UUID(), name: "G", blocks: [twin, Block(id: id, type: .text, text: "b")])
        stick.origin = GroupOrigin(source: nil, file: nil, base: GroupSnapshot(id: stick.id, name: "G", blocks: [twin, twin]))
        let r = SyncMerge.merge(stick, remote: GroupSnapshot(id: stick.id, name: "G", blocks: [twin]))
        XCTAssertNotNil(r.stick)
        let space = StickGroup(sticks: [stick, stick], name: "S")
        _ = SyncMerge.mergeSpace(space, remote: [SyncMerge.RemoteGroup(snapshot: GroupSnapshot(stick), file: nil)], head: "h")
        let store = AppStore()
        store.state.groups = [space]
        store.setBlockOrder([id, id], stick: stick.id)
    }

    func testACustomGroupWithTheSameIdIsNotOverwrittenBySync() {
        let custom = Stick(id: UUID(), name: "Mine", blocks: [Block(text: "private")])
        var space = StickGroup(sticks: [custom], name: "S")
        space.source = GitSource(url: "u", path: "s.json")
        let remote = SyncMerge.RemoteGroup(snapshot: GroupSnapshot(id: custom.id, name: "Theirs", blocks: []), file: nil)
        let result = SyncMerge.mergeSpace(space, remote: [remote], head: "h")
        XCTAssertEqual(result.space.sticks, [custom])
        XCTAssertEqual(result.report.added, 0)
    }

    // MARK: What the user types

    func testSourceValidation() throws {
        func bad(_ s: GitSource, _ why: String, line: UInt = #line) {
            XCTAssertThrowsError(try SyncService.validate(s), why, line: line)
        }
        let ok = GitSource(url: "git@gitlab.example.com:team/links.git", path: "platform/stickspace.json", ref: "main")
        XCTAssertNoThrow(try SyncService.validate(ok))
        var tagged = ok; tagged.ref = "release/1.2"
        XCTAssertNoThrow(try SyncService.validate(tagged))
        var s = ok; s.url = "--upload-pack=touch /tmp/x"; bad(s, "option injection through the url")
        s = ok; s.url = "  "; bad(s, "empty url")
        s = ok; s.ref = "-D"; bad(s, "ref that looks like an option")
        s = ok; s.ref = "a..b"; bad(s, "range syntax")
        s = ok; s.ref = "a b"; bad(s, "space in ref")
        s = ok; s.path = "/etc/passwd"; bad(s, "absolute path")
        s = ok; s.path = "../x.json"; bad(s, "path outside the repository")
        s = ok; s.path = ""; bad(s, "empty path")
        s = ok; s.sshKey = "/k\" -o ProxyCommand=evil"; bad(s, "quote in key path")
    }

    func testSlugs() {
        XCTAssertEqual(SyncService.slug("Anna Q."), "anna-q")
        XCTAssertEqual(SyncService.slug("Grafana & co!"), "grafana-co")
        XCTAssertEqual(SyncService.slug("日本語"), "日本語")
        XCTAssertEqual(SyncService.slug("***"), "user")
        XCTAssertTrue(SyncService.branchName(user: "Anna Q", now: Date(timeIntervalSince1970: 0)).hasPrefix("stickspace/anna-q-"))
    }

    // MARK: The sentences

    func testSyncMessages() {
        XCTAssertEqual(SyncMessages.syncDone(SyncMerge.SpaceReport()), "Everything is up to date.")
        var r = SyncMerge.SpaceReport()
        r.added = 1; r.updated = 2
        XCTAssertEqual(SyncMessages.syncDone(r), "1 group added, 2 updated.")
        r = SyncMerge.SpaceReport(); r.removed = 1; r.detached = 1; r.conflicts = 2
        let text = SyncMessages.syncDone(r)
        XCTAssertTrue(text.contains("1 removed, 1 kept as custom"))
        XCTAssertTrue(text.contains("2 items were changed on both sides: yours were kept"))
        XCTAssertTrue(text.contains("Revert"))
        r = SyncMerge.SpaceReport(); r.conflicts = 1
        XCTAssertTrue(SyncMessages.syncDone(r).contains("1 item was changed on both sides: yours was kept"))
        r = SyncMerge.SpaceReport(); r.waiting = 1
        XCTAssertEqual(SyncMessages.syncDone(r), "waiting for a merge request to be merged.")
    }

    func testPushAndExportMessages() {
        let branch = GitRepo.PushResult(branch: "stickspace/a-1", commit: "abc", link: "https://gitlab.example.com/mr/1", direct: false)
        let summary = SyncService.PushSummary(url: "u", ref: "main", groups: ["Grafana", "Jira"], result: branch)
        let done = SyncMessages.pushDone([summary], afterSync: SyncMerge.SpaceReport())
        XCTAssertEqual(done?.text, "Pushed Grafana, Jira to the branch stickspace/a-1.")
        XCTAssertEqual(done?.link, "https://gitlab.example.com/mr/1")
        var report = SyncMerge.SpaceReport(); report.updated = 1
        XCTAssertTrue(SyncMessages.pushDone([summary], afterSync: report)!.text.hasSuffix("Before pushing, 1 updated."))
        XCTAssertNil(SyncMessages.pushDone([SyncService.PushSummary(url: "u", ref: "main", groups: ["x"], result: nil)], afterSync: SyncMerge.SpaceReport()))
        let direct = GitRepo.PushResult(branch: "main", commit: "abc", link: nil, direct: true)
        XCTAssertTrue(SyncMessages.exportDone(direct, groups: ["A"]).contains("Others can import it now"))
        XCTAssertTrue(SyncMessages.exportDone(branch, groups: ["A"]).contains("Merge the request"))
        XCTAssertTrue(SyncMessages.exportDone(nil, groups: ["A"]).contains("already has A"))
    }

    // MARK: What a push would write

    private func syncedSpace() -> (StickGroup, Stick, Stick) {
        func synced(_ name: String, file: String?, _ text: String) -> Stick {
            let id = UUID()
            let b = Block(type: .text, text: text)
            var s = Stick(id: id, name: name, blocks: [b])
            s.origin = GroupOrigin(source: nil, file: file, base: GroupSnapshot(id: id, name: name, blocks: [b]))
            return s
        }
        let inline = synced("Inline", file: nil, "a"), filed = synced("Filed", file: "p/groups/f.json", "b")
        var space = StickGroup(sticks: [inline, filed], name: "S")
        space.source = GitSource(url: "git@h:t/r.git", path: "p/stickspace.json")
        return (space, inline, filed)
    }

    private func spaceFile(_ space: StickGroup) -> (name: String, entries: [Interchange.SpaceEntry]) {
        ("S", [.inline(SyncExport.shared(space.sticks[0])), .file("groups/f.json")])
    }

    func testNothingChangedMeansNothingToPush() {
        let (space, _, _) = syncedSpace()
        XCTAssertTrue(SyncPush.plans(space: space, spaceFile: spaceFile(space)).isEmpty)
    }

    func testRenamingAnInlineGroupRewritesOnlyTheSpaceFile() throws {
        var (space, inline, _) = syncedSpace()
        space.sticks[0].name = "Renamed"
        let plans = SyncPush.plans(space: space, spaceFile: spaceFile(space))
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(Set(plans[0].files.keys), ["p/stickspace.json"])
        let decoded = try Interchange.decodeSpaceFile(plans[0].files["p/stickspace.json"]!)
        guard case .inline(let g) = decoded.entries[0] else { return XCTFail() }
        XCTAssertEqual(g.name, "Renamed")
        XCTAssertEqual(g.id, inline.id)
        XCTAssertEqual(decoded.entries[1], .file("groups/f.json"), "the reference to the other file is kept")
    }

    func testReorderingAndLocalFlagsAreNotPushed() {
        var (space, _, _) = syncedSpace()
        space.sticks.reverse()
        space.sticks[0].isHidden = true
        space.sticks[1].isExpanded = true
        space.sticks[0].blocks[0].isMasked = true
        XCTAssertTrue(SyncPush.plans(space: space, spaceFile: spaceFile(space)).isEmpty)
    }

    func testChangesInTwoRepositoriesMakeTwoPlansAndMaskedContentStaysOut() {
        var (space, _, _) = syncedSpace()
        space.sticks[1].blocks[0].text = "edited"
        space.sticks[1].blocks.append(Block(type: .text, text: "hunter2", isMasked: true))
        var solo = Stick(name: "Solo", blocks: [Block(text: "x")])
        solo.origin = GroupOrigin(source: GitSource(url: "git@other:t/o.git", path: "solo.json"), file: "solo.json",
                                  base: GroupSnapshot(id: solo.id, name: "Solo", blocks: []))
        space.sticks.append(solo)
        let plans = SyncPush.plans(space: space, spaceFile: spaceFile(space))
        XCTAssertEqual(plans.count, 2)
        XCTAssertEqual(Set(plans[0].files.keys), ["p/groups/f.json"])
        XCTAssertFalse(plans[0].files.values.joined().contains("hunter2"))
        XCTAssertEqual(Set(plans[1].files.keys), ["solo.json"])
        XCTAssertEqual(plans[1].source.url, "git@other:t/o.git")
    }

    // MARK: Formats

    func testSpaceFileAcceptsTheOldGroupsKeyAndRejectsGarbage() throws {
        let v1 = #"{"version":1,"name":"Old","sticks":[{"name":"G","sections":[]}]}"#
        XCTAssertEqual(try Interchange.decodeSpaceFile(v1).entries.count, 1)
        for text in [#"{"version":2,"name":"S"}"#, #"{"version":2,"groups":{}}"#, #"{"version":2,"groups":[1]}"#, #"[]"#, "", #"{"version":9,"groups":[]}"#] {
            XCTAssertThrowsError(try Interchange.decodeSpaceFile(text), text)
        }
        XCTAssertEqual(try Interchange.decodeSpaceFile(#"{"version":2,"groups":[]}"#).name, "Space")
    }

    func testExportKeepsTheSpaceNameOnlyForAWholeSpace() throws {
        let g = Stick(name: "G", blocks: [Block(text: "x", title: "T", tags: ["prod"])])
        XCTAssertEqual(Interchange.spaceName(in: Interchange.export([g], asSingle: false, includeSensitive: false, spaceName: "Team")), "Team")
        XCTAssertNil(Interchange.spaceName(in: Interchange.export([g], asSingle: true, includeSensitive: false, spaceName: "Team")))
    }

    func testEntityMenuTitles() {
        XCTAssertEqual(Block(text: "https://a.com/very/long", title: "Grafana").menuTitle, "Grafana")
        XCTAssertEqual(Block(text: "first line\nsecond").menuTitle, "first line")
        XCTAssertEqual(Block(text: "").menuTitle, "Empty entity")
        XCTAssertEqual(Block(text: "hunter2", isMasked: true, title: "Prod DB").menuTitle, "Sensitive entity", "never reveals a masked entity")
        XCTAssertEqual(Block(text: String(repeating: "x", count: 80)).menuTitle.count, 40)
    }

    func testKnownTagsAreMostUsedFirst() {
        let store = AppStore()
        store.addSpace(name: "S", groups: [Stick(name: "G", blocks: [
            Block(text: "1", tags: ["stg", "prod"]), Block(text: "2", tags: ["prod"]), Block(text: "3", tags: ["dev", "prod"]),
        ])])
        XCTAssertEqual(store.knownTags, ["prod", "dev", "stg"])
    }

    func testRevertingThingsThatHaveNoSharedVersionDoesNothing() {
        let store = AppStore()
        let custom = Stick(name: "C", blocks: [Block(text: "x")])
        let id = store.addSpace(name: "S", groups: [custom])
        let before = store.state
        store.revertGroup(custom.id)
        store.revertBlock(custom.blocks[0].id)
        XCTAssertFalse(store.isBlockModified(custom.blocks[0].id))
        XCTAssertEqual(store.state, before)
        XCTAssertTrue(store.applySync(space: UUID(), fetched: SyncService.Fetched()).isEmpty)
        XCTAssertTrue(store.applySync(space: id, fetched: SyncService.Fetched()).isEmpty)
    }
}

/// Things that need the real git.
final class GitSafetyTests: GitTestCase {
    func testAPushCannotWriteOutsideTheClone() throws {
        try upstreamCommit(["a.json": "1"])
        let r = repo()
        _ = try r.fetch(ref: "main")
        for path in ["../evil.json", "/tmp/evil.json", "a/../../evil.json"] {
            XCTAssertThrowsError(try r.push(files: [path: "x"], ref: "main", direct: false, message: "m", branchName: "b"), path)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.dir.deletingLastPathComponent().appendingPathComponent("evil.json").path))
    }

    func testReadingWithAnUnsafeSourceNeverReachesGit() {
        let src = GitSource(url: bare.path, path: "../x.json", ref: "main")
        XCTAssertThrowsError(try SyncService.readSpace(src, repo: repo()))
        XCTAssertThrowsError(try SyncService.readGroup(src, repo: repo(), required: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo().dir.path), "nothing was cloned")
    }

    func testTwoGroupsWithTheSameIdInOneSpaceFileAreRefused() throws {
        let g = Stick(id: UUID(), name: "Dup", blocks: [])
        try upstreamCommit(["s.json": Interchange.encodeSpaceFile(name: "S", entries: [.inline(g), .inline(g)])])
        let src = GitSource(url: bare.path, path: "s.json", ref: "main")
        XCTAssertThrowsError(try SyncService.readSpace(src, repo: repo())) {
            XCTAssertTrue(($0 as? GitError)?.message.contains("twice") == true)
        }
    }

    func testChangingTheRepositoryAddressKeepsTheCloneWorking() throws {
        try upstreamCommit(["a.json": "1"])
        let r = repo()
        _ = try r.fetch(ref: "main")
        let moved = tmp.appendingPathComponent("moved.git")
        try FileManager.default.moveItem(at: bare, to: moved)
        let again = GitRepo(url: bare.path, root: tmp.appendingPathComponent("clones"), runner: runner)
        XCTAssertThrowsError(try again.fetch(ref: "main"), "the old address is gone")
        try FileManager.default.moveItem(at: moved, to: bare)
        XCTAssertNoThrow(try again.fetch(ref: "main"))
    }

    func testGitIsFoundOnThisMachine() {
        XCTAssertNotNil(GitRunner.locate())
        XCTAssertTrue(GitRunner.missingMessage.contains("xcode-select --install"))
    }
}
