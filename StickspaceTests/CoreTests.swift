import XCTest

final class PersistenceTests: XCTestCase {
    private func sampleState() -> AppState {
        var stick = Stick(name: "Workspace", blocks: [
            Block(type: .text, text: "plain note"),
            Block(type: .link, text: "https://github.com"),
            Block(type: .text, text: "npm run dev", isHidden: true),
            Block(type: .text, text: "hunter2", isMasked: true),
        ])
        stick.isExpanded = true
        var group = StickGroup(sticks: [stick, Stick(name: "Links", isHidden: true)])
        group.isPinned = true
        group.isHidden = true
        group.zoom = 1.25
        group.originX = 100
        group.topY = 700
        return AppState(theme: .dark, groups: [group, StickGroup(sticks: [Stick(name: "Other")])])
    }

    func testRoundTripPreservesEverything() throws {
        let state = sampleState()
        XCTAssertEqual(try StateCodec.decode(try StateCodec.encode(state)), state)
    }

    func testMaskFlagSurvivesButIsOnlyVisual() throws {
        let decoded = try StateCodec.decode(try StateCodec.encode(sampleState()))
        let secret = decoded.groups[0].sticks[0].blocks[3]
        XCTAssertTrue(secret.isMasked)
        XCTAssertEqual(secret.text, "hunter2")
    }

    func testFutureVersionIsRejected() {
        let json = #"{"version": 99, "theme": "system", "groups": []}"#
        XCTAssertThrowsError(try StateCodec.decode(Data(json.utf8))) {
            XCTAssertEqual($0 as? StateError, .unsupportedVersion(99))
        }
    }

    func testUnreadableFileIsMovedAsideNotDeleted() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = StateFile(url: dir.appendingPathComponent("state.json"))
        try file.write(Data("{ not json".utf8))
        guard case .unreadable(let moved) = file.load(), let moved else { return XCTFail("expected unreadable") }
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "{ not json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
    }

    func testAtomicWriteAndReload() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let persistence = StatePersistence(file: StateFile(url: dir.appendingPathComponent("state.json")))
        let state = sampleState()
        persistence.scheduleSave(state)
        persistence.flush()
        guard case .loaded(let loaded) = persistence.load() else { return XCTFail("expected loaded") }
        XCTAssertEqual(loaded, state)
    }

    func testZoomIsClampedOnLoad() throws {
        var state = sampleState()
        state.groups[0].zoom = 99
        XCTAssertEqual(try StateCodec.decode(try StateCodec.encode(state)).groups[0].zoom, 2.0)
    }
}

final class InterchangeTests: XCTestCase {
    private let sticks = [
        Stick(name: "Links", blocks: [
            Block(type: .link, text: "https://github.com"),
            Block(type: .text, text: "line one\nline two"),
            Block(type: .text, text: "ls -la", isHidden: true),
            Block(type: .text, text: "top-secret", isMasked: true),
        ]),
        Stick(name: "Empty"),
    ]

    func testExportImportRoundTripWithSensitive() throws {
        let json = Interchange.export(sticks, asSingle: false, includeSensitive: true)
        let back = try Interchange.parse(json)
        XCTAssertEqual(back.map(\.name), ["Links", "Empty"])
        XCTAssertEqual(back[0].blocks.map(\.text), sticks[0].blocks.map(\.text))
        XCTAssertEqual(back[0].blocks.map(\.type), sticks[0].blocks.map(\.type))
        XCTAssertEqual(back[0].blocks.map(\.isHidden), sticks[0].blocks.map(\.isHidden))
        XCTAssertEqual(back[0].blocks.map(\.isMasked), sticks[0].blocks.map(\.isMasked))
    }

    func testSensitiveExcludedByDefault() throws {
        let json = Interchange.export(sticks, asSingle: false, includeSensitive: false)
        XCTAssertFalse(json.contains("top-secret"))
        XCTAssertEqual(try Interchange.parse(json)[0].blocks.count, 3)
    }

    func testSingleStickShapeMatchesReference() throws {
        let json = Interchange.export([sticks[0]], asSingle: true, includeSensitive: false)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(object["name"] as? String, "Links")
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertNil(object["sticks"])
        XCTAssertEqual(try Interchange.parse(json).count, 1)
    }

    func testAcceptsUrlAliasAndBareStick() throws {
        let parsed = try Interchange.parse(#"{"name":"W","sections":[{"type":"link","url":"https://figma.com"},{"type":"text","text":"Hello"}]}"#)
        XCTAssertEqual(parsed[0].blocks[0].text, "https://figma.com")
        XCTAssertEqual(parsed[0].blocks[1].text, "Hello")
    }

    func testInvalidJSONReportsLine() {
        let text = "{\n  \"name\": \"W\",\n  \"sections\": [\n    { oops }\n  ]\n}"
        XCTAssertThrowsError(try Interchange.parse(text)) {
            XCTAssertEqual(($0 as? Interchange.ImportError)?.message, "Invalid JSON — line 4")
        }
    }

    func testStructureTypeAndVersionValidation() {
        let cases = [
            "",
            "42",
            #"{"version": 2, "sticks": []}"#,
            #"{"version": "1", "sticks": []}"#,
            #"{"sticks": {}}"#,
            #"{"sticks": []}"#,
            #"{"sticks": [{"name": ""}]}"#,
            #"{"name": "A", "sections": {}}"#,
            #"{"name": "A", "sections": [{"type": "markdown", "text": "x"}]}"#,
            #"{"name": "A", "sections": [{"type": "text"}]}"#,
            #"{"name": "A", "sections": [{"text": "x", "masked": "yes"}]}"#,
        ]
        for text in cases {
            XCTAssertThrowsError(try Interchange.parse(text), "should reject: \(text)")
        }
    }

    func testImportNeverOverwritesExistingSticks() throws {
        let store = AppStore()
        store.seedIfNeeded()
        let before = store.state
        let imported = try Interchange.parse(Interchange.export(before.groups[0].sticks, asSingle: false, includeSensitive: true))
        store.insert(imported, group: before.groups[0].id)
        let sticks = store.state.groups[0].sticks
        XCTAssertEqual(sticks.count, before.groups[0].sticks.count * 2)
        XCTAssertEqual(Set(sticks.map(\.id)).count, sticks.count, "imported sticks get fresh ids")
        XCTAssertEqual(Array(sticks.prefix(before.groups[0].sticks.count)), before.groups[0].sticks)
    }
}

final class LinkTests: XCTestCase {
    func testWholeBlockUrlIsALink() {
        XCTAssertNotNil(Block(type: .link, text: "https://github.com").linkURL)
        XCTAssertNotNil(Block(type: .link, text: "  http://example.com/a?b=1  \n").linkURL)
        XCTAssertEqual(Block(type: .link, text: "https://figma.com").kind, .link(URL(string: "https://figma.com")!))
    }

    func testEmbeddedOrNonHttpTextIsNotALink() {
        XCTAssertNil(Block(type: .link, text: "see https://github.com for more").linkURL)
        XCTAssertNil(Block(type: .link, text: "https://a.com https://b.com").linkURL)
        XCTAssertNil(Block(type: .link, text: "ftp://example.com").linkURL)
        XCTAssertNil(Block(type: .link, text: "javascript:alert(1)").linkURL)
        XCTAssertNil(Block(type: .link, text: "https://").linkURL)
        XCTAssertNil(Block(type: .link, text: "example.com").linkURL)
    }

    func testTextTypeNeverLinks() {
        XCTAssertNil(Block(type: .text, text: "https://github.com").linkURL)
        XCTAssertEqual(Block(type: .link, text: "x").kind, .text)
    }

    func testOldTypesAreMapped() {
        XCTAssertEqual(BlockType.parse("auto", text: "https://a.com"), .link)
        XCTAssertEqual(BlockType.parse("auto", text: "hello"), .text)
        XCTAssertEqual(BlockType.parse("code", text: "ls"), .text)
        XCTAssertNil(BlockType.parse("nope", text: ""))
    }

    func testOpenAllSelection() {
        let stick = Stick(name: "S", blocks: [
            Block(type: .link, text: "https://a.com"),
            Block(type: .link, text: "not a link"),
            Block(type: .link, text: "https://hidden.com", isHidden: true),
            Block(type: .link, text: "https://secret.com", isMasked: true),
            Block(type: .link, text: "https://b.com"),
            Block(type: .link, text: "https://a.com"),
            Block(type: .text, text: "https://code.com"),
        ])
        XCTAssertEqual(stick.openableLinks.map(\.absoluteString), ["https://a.com", "https://b.com"])
        XCTAssertTrue(Stick(name: "none", blocks: [Block(text: "x")]).openableLinks.isEmpty)
    }
}

final class StoreTests: XCTestCase {
    private func store() -> (AppStore, UUID, UUID) {
        let s = AppStore()
        s.state.groups = [
            StickGroup(sticks: [Stick(name: "A"), Stick(name: "B")]),
            StickGroup(sticks: [Stick(name: "C")]),
        ]
        return (s, s.state.groups[0].id, s.state.groups[1].id)
    }

    func testZoomIsIndependentPerGroup() {
        let (s, g1, g2) = store()
        s.zoomIn(group: g1)
        s.zoomIn(group: g1)
        s.zoomOut(group: g2)
        XCTAssertEqual(s.zoom(of: g1), 1.25)
        XCTAssertEqual(s.zoom(of: g2), 0.9)
        s.resetZoom(group: g1)
        XCTAssertEqual(s.zoom(of: g1), 1.0)
        XCTAssertEqual(s.zoom(of: g2), 0.9)
    }

    func testZoomLimits() {
        let (s, g1, _) = store()
        for _ in 0..<30 { s.zoomIn(group: g1) }
        XCTAssertEqual(s.zoom(of: g1), 2.0)
        for _ in 0..<30 { s.zoomOut(group: g1) }
        XCTAssertEqual(s.zoom(of: g1), 0.6)
    }

    func testZoomCommandsTargetActiveGroup() {
        let (s, g1, g2) = store()
        s.activeGroupID = g2
        s.zoomIn(group: s.commandGroupID!)
        XCTAssertEqual(s.zoom(of: g2), 1.1)
        XCTAssertEqual(s.zoom(of: g1), 1.0)
    }

    func testSpaceKeepsItsWindowWhenEmptyAndWhenLastGroupIsDeleted() {
        let s = AppStore()
        let id = s.addSpace(name: "Ops")
        XCTAssertTrue(s.state.groups[0].showsWindow)
        let stick = s.addStick(name: "G", group: id).stick
        s.deleteStick(stick)
        XCTAssertEqual(s.state.groups.count, 1)
        XCTAssertTrue(s.state.groups[0].sticks.isEmpty)
        s.undo()
        XCTAssertEqual(s.state.groups[0].sticks.map(\.name), ["G"])
        s.deleteSpace(id)
        XCTAssertTrue(s.state.groups.isEmpty)
        s.undo()
        XCTAssertEqual(s.state.groups[0].name, "Ops")
    }

    func testSpaceNameAndCollapseSurvivePersistence() throws {
        var g = StickGroup(sticks: [Stick(name: "A")], name: "Prod ops")
        g.isCollapsed = true
        g.width = 500
        let back = try StateCodec.decode(StateCodec.encode(AppState(theme: .system, groups: [g])))
        XCTAssertEqual(back.groups[0].name, "Prod ops")
        XCTAssertTrue(back.groups[0].isCollapsed)
        XCTAssertEqual(back.groups[0].width, 500)
        let store = AppStore()
        store.state = back
        store.setWidth(5000, space: back.groups[0].id)
        XCTAssertEqual(store.state.groups[0].width, SpaceWidth.range.upperBound)
    }

    func testTitleAndTagsRoundTripThroughPersistenceAndJSON() throws {
        let b = Block(type: .link, text: "https://grafana.example.com/d/abc?var-env=prod", title: "Grafana", tags: ["prod", "Prod", " eu "])
        XCTAssertEqual(Tags.clean(b.tags), ["prod", "eu"])
        let stick = Stick(name: "Dash", blocks: [b])
        let state = try StateCodec.decode(StateCodec.encode(AppState(theme: .system, groups: [StickGroup(sticks: [stick])])))
        XCTAssertEqual(state.groups[0].sticks[0].blocks[0].title, "Grafana")
        let json = Interchange.export([stick], asSingle: false, includeSensitive: false, spaceName: "Team")
        let parsed = try Interchange.parse(json)
        XCTAssertEqual(parsed[0].blocks[0].title, "Grafana")
        XCTAssertEqual(parsed[0].blocks[0].tags, ["prod", "eu"])
        XCTAssertEqual(Interchange.spaceName(in: json), "Team")
        XCTAssertEqual(b.menuTitle, "Grafana")
        XCTAssertEqual(Tags.parse("prod, stg,\ndev,,"), ["prod", "stg", "dev"])
    }

    func testReorderKeepsHiddenSticksInTheirSlots() {
        let s = AppStore()
        var group = StickGroup(sticks: [Stick(name: "1"), Stick(name: "H", isHidden: true), Stick(name: "2"), Stick(name: "3")])
        let ids = group.sticks.map(\.id)
        s.state.groups = [group]
        group = s.state.groups[0]
        s.setVisibleOrder([ids[3], ids[0], ids[2]], group: group.id)
        XCTAssertEqual(s.state.groups[0].sticks.map(\.name), ["3", "H", "1", "2"])
    }

    func testDeleteStickUndo() {
        let (s, g1, _) = store()
        let before = s.state
        let id = s.state.groups[0].sticks[0].id
        s.deleteStick(id)
        XCTAssertEqual(s.state.groups[0].sticks.count, 1)
        XCTAssertNotNil(s.toast)
        s.undo()
        XCTAssertEqual(s.state, before)
        XCTAssertNil(s.toast)
        _ = g1
    }

    func testDeleteLastStickKeepsTheSpaceAndUndoRestoresIt() {
        let (s, _, g2) = store()
        let before = s.state
        s.deleteStick(s.state.groups[1].sticks[0].id)
        XCTAssertTrue(s.state.groups[1].sticks.isEmpty)
        XCTAssertNotNil(s.groupIndex(g2))
        s.undo()
        XCTAssertEqual(s.state, before)
    }

    func testDeleteBlockUndoRestoresPositionAndContent() {
        let s = AppStore()
        s.state.groups = [StickGroup(sticks: [Stick(name: "S", blocks: [Block(text: "1"), Block(text: "2"), Block(text: "3")])])]
        let before = s.state
        s.deleteBlock(s.state.groups[0].sticks[0].blocks[1].id)
        XCTAssertEqual(s.state.groups[0].sticks[0].blocks.map(\.text), ["1", "3"])
        s.undo()
        XCTAssertEqual(s.state, before)
    }

    func testRevealIsTransientAndClearedOnCollapseHideAndDelete() {
        let s = AppStore()
        let secret = Block(text: "pw", isMasked: true)
        var stick = Stick(name: "S", blocks: [secret])
        stick.isExpanded = true
        s.state.groups = [StickGroup(sticks: [stick])]
        s.toggleReveal(secret.id)
        XCTAssertTrue(s.revealed.contains(secret.id))
        s.setExpanded(false, stick: stick.id)
        XCTAssertTrue(s.revealed.isEmpty)
        s.toggleReveal(secret.id)
        s.hideRevealed(inGroup: s.state.groups[0].id)
        XCTAssertTrue(s.revealed.isEmpty)
        s.toggleReveal(secret.id)
        s.setMasked(false, block: secret.id)
        s.setMasked(true, block: secret.id)
        XCTAssertTrue(s.revealed.isEmpty)
        // Loading a persisted state never restores a reveal.
        s.toggleReveal(secret.id)
        s.load(s.state)
        XCTAssertTrue(s.revealed.isEmpty)
    }

    func testAddStickInsertsAtVisiblePosition() {
        let (s, g1, _) = store()
        s.addStick(name: "Top", group: g1, atVisible: 0)
        s.addStick(name: "Mid", group: g1, atVisible: 2)
        s.addStick(name: "End", group: g1, atVisible: nil)
        XCTAssertEqual(s.state.groups[0].sticks.map(\.name), ["Top", "A", "Mid", "B", "End"])
        let created = s.addStick(name: "New group", group: nil)
        XCTAssertEqual(s.state.groups.count, 3)
        XCTAssertEqual(s.state.groups[2].id, created.group)
    }

    func testHiddenSticksAreSkippedByInsertIndex() {
        let s = AppStore()
        s.state.groups = [StickGroup(sticks: [Stick(name: "A"), Stick(name: "H", isHidden: true), Stick(name: "B")])]
        s.addStick(name: "X", group: s.state.groups[0].id, atVisible: 1)
        XCTAssertEqual(s.state.groups[0].sticks.map(\.name), ["A", "H", "X", "B"])
    }

    func testScreenFit() {
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: 1440, y: 0, width: 1920, height: 1080)]
        let inside = CGRect(x: 100, y: 100, width: 320, height: 200)
        XCTAssertEqual(ScreenFit.fit(inside, screens: screens), inside)
        let second = CGRect(x: 2000, y: 300, width: 320, height: 200)
        XCTAssertEqual(ScreenFit.fit(second, screens: screens), second)
        let gone = CGRect(x: 5000, y: -4000, width: 320, height: 200)
        let fitted = ScreenFit.fit(gone, screens: screens)
        XCTAssertTrue(screens[0].contains(fitted))
        // Second monitor was unplugged.
        XCTAssertTrue(screens[0].contains(ScreenFit.fit(second, screens: [screens[0]])))
    }

    func testHiddenGroupHasNoWindowButKeepsSticks() {
        var g = StickGroup(sticks: [Stick(name: "A"), Stick(name: "B")])
        XCTAssertTrue(g.showsWindow)
        g.isHidden = true
        XCTAssertFalse(g.showsWindow)
        let s = AppStore()
        s.state.groups = [StickGroup(sticks: [Stick(name: "A")])]
        s.setGroupHidden(true, group: s.state.groups[0].id)
        XCTAssertFalse(s.state.groups[0].showsWindow)
        XCTAssertEqual(s.state.groups[0].sticks.count, 1)
    }

    func testReorderWithHiddenItemsListed() {
        let s = AppStore()
        let blocks = [Block(text: "1"), Block(text: "H", isHidden: true), Block(text: "2")]
        let stick = Stick(name: "S", blocks: blocks)
        s.state.groups = [StickGroup(sticks: [stick, Stick(name: "X", isHidden: true), Stick(name: "Y")])]
        s.setBlockOrder([blocks[2].id, blocks[1].id, blocks[0].id], stick: stick.id)   // every entity, hidden included
        XCTAssertEqual(s.state.groups[0].sticks[0].blocks.map(\.text), ["2", "H", "1"])
        let ids = s.state.groups[0].sticks.map(\.id)
        s.setVisibleOrder([ids[2], ids[1], ids[0]], group: s.state.groups[0].id)
        XCTAssertEqual(s.state.groups[0].sticks.map(\.name), ["Y", "X", "S"])
        s.setVisibleOrder([ids[0], ids[2]], group: s.state.groups[0].id)   // visible only: X stays in its slot
        XCTAssertEqual(s.state.groups[0].sticks.map(\.name), ["S", "X", "Y"])
        XCTAssertEqual(s.hiddenCount(space: s.state.groups[0].id), 2)
    }

    func testBlockReorderKeepsHiddenSectionsInPlace() {
        let s = AppStore()
        let blocks = [Block(text: "1"), Block(text: "H", isHidden: true), Block(text: "2"), Block(text: "3")]
        let stick = Stick(name: "S", blocks: blocks)
        s.state.groups = [StickGroup(sticks: [stick])]
        s.setBlockOrder([blocks[3].id, blocks[0].id, blocks[2].id], stick: stick.id)
        XCTAssertEqual(s.state.groups[0].sticks[0].blocks.map(\.text), ["3", "H", "1", "2"])
        s.setBlockOrder([blocks[0].id], stick: stick.id)   // wrong count: ignored
        XCTAssertEqual(s.state.groups[0].sticks[0].blocks.map(\.text), ["3", "H", "1", "2"])
    }

    func testImportedStackBecomesNewGroupAndStickJoinsExisting() throws {
        let s = AppStore()
        s.state.groups = [StickGroup(sticks: [Stick(name: "A")])]
        let imported = try Interchange.parse(#"{"sticks":[{"name":"X"},{"name":"Y"}]}"#)
        s.insert(imported, group: nil)
        XCTAssertEqual(s.state.groups.count, 2)
        XCTAssertEqual(s.state.groups[1].sticks.map(\.name), ["X", "Y"])
        s.insert(try Interchange.parse(#"{"name":"Z"}"#), group: s.state.groups[0].id, atVisible: 1)
        XCTAssertEqual(s.state.groups[0].sticks.map(\.name), ["A", "Z"])
    }
}
