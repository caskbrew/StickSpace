import Foundation

struct GitError: Error, Equatable, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Runs the system `git`. Prompts are disabled (a missing credential is an error, never a hang) and every call has a timeout.
struct GitRunner {
    var gitPath: String
    var sshKey: String?
    /// Extra environment (tests use it to give commits an identity and ignore the user's git config).
    var extraEnv: [String: String] = [:]
    var timeout: TimeInterval = 90

    /// The system git, if there is one. `/usr/bin/git` is only a shim until the Command Line Tools are installed,
    /// and calling it before that pops up an installer, so it is checked first.
    static func locate() -> String? {
        let fm = FileManager.default
        for path in ["/opt/homebrew/bin/git", "/usr/local/bin/git"] where fm.isExecutableFile(atPath: path) { return path }
        if fm.isExecutableFile(atPath: "/Library/Developer/CommandLineTools/usr/bin/git") { return "/usr/bin/git" }
        if fm.fileExists(atPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/git") { return "/usr/bin/git" }
        return nil
    }

    static let missingMessage = "Git is not installed. Install the Command Line Tools: run “xcode-select --install” in Terminal."

    @discardableResult
    func run(_ args: [String], in dir: URL? = nil) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: gitPath)
        task.arguments = args
        task.currentDirectoryURL = dir

        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["LC_ALL"] = "C"
        var ssh = "ssh -o BatchMode=yes"
        if let key = sshKey, !key.isEmpty { ssh += " -i \"\(key)\" -o IdentitiesOnly=yes" }
        env["GIT_SSH_COMMAND"] = ssh
        env.merge(extraEnv) { _, new in new }
        task.environment = env

        let out = Pipe(), err = Pipe()
        task.standardOutput = out
        task.standardError = err
        task.standardInput = FileHandle.nullDevice

        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        do { try task.run() } catch { throw GitError(message: "Could not run git: \(error.localizedDescription)") }
        group.enter(); DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let killer = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        task.waitUntilExit()
        group.wait()
        let timedOut = killer.isCancelled == false && task.terminationReason == .uncaughtSignal
        killer.cancel()

        let stdout = String(decoding: outData, as: UTF8.self)
        let stderr = String(decoding: errData, as: UTF8.self)
        guard task.terminationStatus == 0 else {
            let text = (stderr.isEmpty ? stdout : stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError(message: timedOut ? "git timed out." : Self.friendly(text))
        }
        // Push reports its news (merge request links) on stderr.
        return stdout + (stderr.isEmpty ? "" : "\n" + stderr)
    }

    /// Plain output of a command, without stderr mixed in.
    func output(_ args: [String], in dir: URL? = nil) throws -> String {
        let text = try run(args, in: dir)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func friendly(_ text: String) -> String {
        let lower = text.lowercased()
        if lower.contains("permission denied") || lower.contains("authentication failed") || lower.contains("could not read from remote") {
            return "Git could not sign in to the repository. Check your ssh key or credentials.\n\(text)"
        }
        return text.isEmpty ? "git failed." : text
    }
}

/// A local clone of one repository, kept under Application Support. Reads never touch the working tree.
struct GitRepo {
    let url: String
    let dir: URL
    var runner: GitRunner

    init(url: String, root: URL, runner: GitRunner) {
        self.url = url
        self.runner = runner
        let slug = String(url.map { $0.isLetter || $0.isNumber ? $0 : "_" })
        self.dir = root.appendingPathComponent(String(slug.suffix(120)), isDirectory: true)
    }

    struct Resolved: Equatable {
        var sha: String
        /// A branch can be pushed to; a tag cannot.
        var isBranch: Bool
    }

    /// Clones if needed, fetches everything, and returns what `ref` points to now.
    func fetch(ref: String) throws -> Resolved {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.appendingPathComponent(".git").path) {
            try fm.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
            try runner.run(["clone", "--quiet", "--no-checkout", url, dir.path])
        }
        try runner.run(["remote", "set-url", "origin", url], in: dir)
        try runner.run(["fetch", "--quiet", "--prune", "--tags", "--force", "origin"], in: dir)
        return try resolve(ref: ref)
    }

    func resolve(ref: String) throws -> Resolved {
        if let sha = try? runner.output(["rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(ref)^{commit}"], in: dir), !sha.isEmpty {
            return Resolved(sha: sha, isBranch: true)
        }
        if let sha = try? runner.output(["rev-parse", "--verify", "--quiet", "refs/tags/\(ref)^{commit}"], in: dir), !sha.isEmpty {
            return Resolved(sha: sha, isBranch: false)
        }
        throw GitError(message: "“\(ref)” is not a branch or tag of this repository.")
    }

    /// The file's text at a commit, or nil if it does not exist there.
    func read(_ path: String, at sha: String) throws -> String? {
        guard (try? runner.run(["cat-file", "-e", "\(sha):\(path)"], in: dir)) != nil else { return nil }
        return try runner.run(["show", "\(sha):\(path)"], in: dir)
    }

    struct PushResult: Equatable {
        var branch: String
        var commit: String
        /// A merge / pull request page, when the server printed one.
        var link: String?
        var direct: Bool
    }

    /// Writes `files` (repo path → text) on top of `ref`, commits and pushes: to a new branch, or straight to `ref`.
    /// Returns nil when the files already match the repository.
    func push(files: [String: String], ref: String, direct: Bool, message: String, branchName: String) throws -> PushResult? {
        let base = try resolve(ref: ref)
        guard base.isBranch else { throw GitError(message: "“\(ref)” is a tag, so it is read-only. Use a branch to push changes.") }

        try runner.run(["checkout", "--quiet", "--force", "--detach", base.sha], in: dir)
        try runner.run(["clean", "-fdq"], in: dir)
        if !direct { try runner.run(["checkout", "--quiet", "-b", branchName], in: dir) }

        let fm = FileManager.default
        for (path, text) in files {
            let file = dir.appendingPathComponent(path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        try runner.run(["add", "--"] + files.keys.sorted(), in: dir)
        // Whatever happens next, leave the clone detached at `ref` and without a leftover local branch.
        defer {
            _ = try? runner.run(["checkout", "--quiet", "--force", "--detach", base.sha], in: dir)
            if !direct { _ = try? runner.run(["branch", "-D", branchName], in: dir) }
        }
        if (try? runner.run(["diff", "--cached", "--quiet"], in: dir)) != nil { return nil }   // nothing differs

        try runner.run(["commit", "--quiet", "-m", message], in: dir)
        let commit = try runner.output(["rev-parse", "HEAD"], in: dir)

        var args = ["push", "--quiet"]
        if direct {
            args += ["origin", "HEAD:refs/heads/\(ref)"]
        } else {
            // GitLab opens the merge request from push options; other servers reject unknown options.
            if url.lowercased().contains("gitlab") { args += ["-o", "merge_request.create", "-o", "merge_request.target=\(ref)"] }
            args += ["origin", "\(branchName):refs/heads/\(branchName)"]
        }
        let output = try runner.run(args, in: dir)
        return PushResult(branch: direct ? ref : branchName, commit: commit, link: Self.link(in: output), direct: direct)
    }

    /// A merge / pull request URL from a push's output: on the line that mentions it, or the one after it
    /// (GitLab and GitHub print "View merge request …:" / "Create a pull request … by visiting:" and then the URL).
    static func link(in output: String) -> String? {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        func url(_ line: String) -> String? { line.range(of: "https?://\\S+", options: .regularExpression).map { String(line[$0]) } }
        for (i, line) in lines.enumerated() {
            let lower = line.lowercased()
            guard lower.contains("merge request") || lower.contains("pull request") else { continue }
            if let found = url(line) ?? (i + 1 < lines.count ? url(lines[i + 1]) : nil) { return found }
        }
        return nil
    }
}
