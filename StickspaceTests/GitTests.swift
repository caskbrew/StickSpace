import XCTest

/// Runs the real `git` against a local bare repository.
class GitTestCase: XCTestCase {
    var tmp: URL!
    var runner: GitRunner!
    var bare: URL { tmp.appendingPathComponent("remote.git") }
    var work: URL { tmp.appendingPathComponent("work") }

    override func setUpWithError() throws {
        guard let git = GitRunner.locate() else { throw XCTSkip("git is not installed") }
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("stickspace-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        runner = GitRunner(gitPath: git, extraEnv: [
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
            "GIT_AUTHOR_NAME": "Tester", "GIT_AUTHOR_EMAIL": "t@example.com",
            "GIT_COMMITTER_NAME": "Tester", "GIT_COMMITTER_EMAIL": "t@example.com",
        ])
        try runner.run(["init", "--bare", "--quiet", "--initial-branch=main", bare.path])
        try runner.run(["clone", "--quiet", bare.path, work.path])
    }

    override func tearDownWithError() throws { if let tmp { try? FileManager.default.removeItem(at: tmp) } }

    /// A commit by "someone else" straight into the remote's main.
    @discardableResult
    func upstreamCommit(_ files: [String: String], message: String = "upstream", tag: String? = nil) throws -> String {
        try runner.run(["checkout", "--quiet", "-B", "main"], in: work)
        for (path, text) in files {
            let f = work.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: f, atomically: true, encoding: .utf8)
        }
        try runner.run(["add", "-A"], in: work)
        try runner.run(["commit", "--quiet", "-m", message], in: work)
        if let tag { try runner.run(["tag", tag], in: work) }
        try runner.run(["push", "--quiet", "--tags", "origin", "HEAD:refs/heads/main"], in: work)
        return try runner.output(["rev-parse", "HEAD"], in: work)
    }

    func repo() -> GitRepo { GitRepo(url: bare.path, root: tmp.appendingPathComponent("clones"), runner: runner) }
}

final class GitTests: GitTestCase {
    func testFetchClonesResolvesAndReadsFiles() throws {
        let sha = try upstreamCommit(["platform/stickspace.json": "one\n"], tag: "v1")
        let r = repo()
        let head = try r.fetch(ref: "main")
        XCTAssertEqual(head, GitRepo.Resolved(sha: sha, isBranch: true))
        XCTAssertEqual(try r.read("platform/stickspace.json", at: sha), "one\n")
        XCTAssertNil(try r.read("platform/missing.json", at: sha))
        XCTAssertEqual(try r.fetch(ref: "v1"), GitRepo.Resolved(sha: sha, isBranch: false))
        XCTAssertThrowsError(try r.fetch(ref: "nope")) { XCTAssertTrue(($0 as? GitError)?.message.contains("nope") == true) }
    }

    func testFetchPicksUpNewCommitsAndOldOnesStayReadable() throws {
        let first = try upstreamCommit(["a.json": "1"])
        let r = repo()
        XCTAssertEqual(try r.fetch(ref: "main").sha, first)
        let second = try upstreamCommit(["a.json": "2"])
        XCTAssertEqual(try r.fetch(ref: "main").sha, second)
        XCTAssertEqual(try r.read("a.json", at: second), "2")
        XCTAssertEqual(try r.read("a.json", at: first), "1")
    }

    func testPushCreatesABranchAndLeavesMainAlone() throws {
        let main = try upstreamCommit(["g/a.json": "old", "keep.txt": "keep"])
        let r = repo()
        _ = try r.fetch(ref: "main")
        let result = try XCTUnwrap(try r.push(files: ["g/a.json": "new"], ref: "main", direct: false,
                                              message: "Update a", branchName: "stickspace/tester-1"))
        XCTAssertEqual(result.branch, "stickspace/tester-1")
        XCTAssertFalse(result.direct)
        XCTAssertEqual(try runner.output(["rev-parse", "main"], in: bare), main, "main is untouched")
        XCTAssertEqual(try runner.output(["rev-parse", "stickspace/tester-1"], in: bare), result.commit)
        XCTAssertEqual(try runner.output(["show", "stickspace/tester-1:g/a.json"], in: bare), "new")
        XCTAssertEqual(try runner.output(["show", "stickspace/tester-1:keep.txt"], in: bare), "keep", "other files stay")
        XCTAssertEqual(try runner.output(["log", "-1", "--format=%s", "stickspace/tester-1"], in: bare), "Update a")
        // The clone is left detached at main with no leftover branch.
        XCTAssertEqual(try runner.output(["branch", "--list", "stickspace/*"], in: r.dir), "")
        XCTAssertEqual(try runner.output(["rev-parse", "HEAD"], in: r.dir), main)
    }

    func testPushingIdenticalContentIsANoOp() throws {
        try upstreamCommit(["a.json": "same"])
        let r = repo()
        _ = try r.fetch(ref: "main")
        XCTAssertNil(try r.push(files: ["a.json": "same"], ref: "main", direct: false, message: "m", branchName: "stickspace/x"))
        XCTAssertEqual(try runner.output(["branch", "--list", "stickspace/*"], in: bare), "")
    }

    func testDirectPushMovesTheBranch() throws {
        try upstreamCommit(["a.json": "old"])
        let r = repo()
        _ = try r.fetch(ref: "main")
        let result = try XCTUnwrap(try r.push(files: ["a.json": "new"], ref: "main", direct: true, message: "Direct", branchName: "unused"))
        XCTAssertTrue(result.direct)
        XCTAssertEqual(try runner.output(["rev-parse", "main"], in: bare), result.commit)
        XCTAssertEqual(try r.fetch(ref: "main").sha, result.commit)
    }

    func testPushToATagIsRefused() throws {
        try upstreamCommit(["a.json": "1"], tag: "v1")
        let r = repo()
        _ = try r.fetch(ref: "v1")
        XCTAssertThrowsError(try r.push(files: ["a.json": "2"], ref: "v1", direct: false, message: "m", branchName: "b")) {
            XCTAssertTrue(($0 as? GitError)?.message.contains("read-only") == true)
        }
    }

    func testUnreachableRepositoryReportsAnError() {
        let r = GitRepo(url: tmp.appendingPathComponent("nope.git").path, root: tmp.appendingPathComponent("clones2"), runner: runner)
        XCTAssertThrowsError(try r.fetch(ref: "main"))
    }

    func testMergeRequestLinkIsFoundInPushOutput() {
        let out = "remote: \nremote: View merge request for stickspace/a:\nremote:   https://gitlab.example.com/t/r/-/merge_requests/7\nremote: \n"
        XCTAssertEqual(GitRepo.link(in: out), "https://gitlab.example.com/t/r/-/merge_requests/7", "the link is on the line after the label")
        let one = "remote: To create a merge request for x, visit: https://gitlab.example.com/t/r/-/merge_requests/new?x=1\n"
        XCTAssertEqual(GitRepo.link(in: one), "https://gitlab.example.com/t/r/-/merge_requests/new?x=1")
        let gh = "remote: Create a pull request for 'x' on GitHub by visiting:\nremote:      https://github.com/o/r/pull/new/x\n"
        XCTAssertEqual(GitRepo.link(in: gh), "https://github.com/o/r/pull/new/x")
        XCTAssertNil(GitRepo.link(in: "remote: nothing here\n"))
    }
}
