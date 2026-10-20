import AppKit
import Combine

/// Runs Git work off the main thread and applies the results to the store. UI-facing glue; the logic is in Core.
final class SyncController: ObservableObject {
    private let store: AppStore
    private let queue = DispatchQueue(label: "stickspace.sync", qos: .utility)
    private var busy = Set<UUID>()
    private var timer: Timer?

    /// Spaces whose repository has moved since their last sync (set by the background check).
    @Published private(set) var updates: Set<UUID> = []

    /// Title and text of something the user should read; the optional link is a merge request page.
    var onMessage: (_ title: String, _ text: String, _ link: String?) -> Void = { _, _, _ in }

    init(store: AppStore) { self.store = store }

    static let checkInterval: TimeInterval = 3 * 60 * 60

    private var remotesRoot: URL { StateFile.defaultURL.deletingLastPathComponent().appendingPathComponent("remotes", isDirectory: true) }

    private func repoFor(_ git: String) -> SyncService.RepoFor {
        let root = remotesRoot
        return { source in GitRepo(url: source.url, root: root, runner: GitRunner(gitPath: git, sshKey: source.sshKey)) }
    }

    private func gitOrExplain() -> String? {
        if let git = GitRunner.locate() { return git }
        onMessage("Git is missing", GitRunner.missingMessage, nil)
        return nil
    }

    // MARK: Import

    func importSpace(_ source: GitSource, done: @escaping (Result<Void, Error>) -> Void) {
        guard let git = GitRunner.locate() else { return done(.failure(GitError(message: GitRunner.missingMessage))) }
        let repoFor = repoFor(git)
        queue.async {
            do {
                let read = try SyncService.readSpace(source, repo: repoFor(source))
                DispatchQueue.main.async { done(Result { _ = try self.store.importSpace(read, source: source) }) }
            } catch { DispatchQueue.main.async { done(.failure(error)) } }
        }
    }

    func importGroup(_ source: GitSource, into space: UUID, done: @escaping (Result<Void, Error>) -> Void) {
        guard let git = GitRunner.locate() else { return done(.failure(GitError(message: GitRunner.missingMessage))) }
        let repoFor = repoFor(git)
        queue.async {
            do {
                let read = try SyncService.readGroup(source, repo: repoFor(source), required: true)
                DispatchQueue.main.async { done(Result { _ = try self.store.importGroup(read, source: source, into: space) }) }
            } catch { DispatchQueue.main.async { done(.failure(error)) } }
        }
    }

    // MARK: Sync and push

    func hasSources(_ space: StickGroup) -> Bool { space.source != nil || space.sticks.contains { $0.origin?.source != nil } }

    func isModified(_ space: StickGroup) -> Bool { space.sticks.contains(where: \.isModified) }

    func sync(space id: UUID) {
        guard let git = gitOrExplain(), let space = store.groupIndex(id).map({ store.state.groups[$0] }), !busy.contains(id) else { return }
        busy.insert(id)
        let repoFor = repoFor(git)
        queue.async {
            do {
                let fetched = try SyncService.fetch(space: space, repoFor: repoFor)
                DispatchQueue.main.async {
                    let report = self.store.applySync(space: id, fetched: fetched)
                    self.busy.remove(id)
                    self.updates.remove(id)
                    self.onMessage("Synced", Self.describe(report), nil)
                }
            } catch { self.fail("Sync failed", error, id) }
        }
    }

    /// Syncs first (so the push is built on what the repository has now), then pushes the changed groups.
    func push(space id: UUID) {
        guard let git = gitOrExplain(), let space = store.groupIndex(id).map({ store.state.groups[$0] }), !busy.contains(id) else { return }
        busy.insert(id)
        let repoFor = repoFor(git)
        queue.async {
            do {
                let fetched = try SyncService.fetch(space: space, repoFor: repoFor)
                var synced: StickGroup?
                var report = SyncMerge.SpaceReport()
                DispatchQueue.main.sync {
                    report = self.store.applySync(space: id, fetched: fetched)
                    synced = self.store.groupIndex(id).map { self.store.state.groups[$0] }
                }
                guard let synced else { throw GitError(message: "The space is gone.") }
                let user = (try? GitRunner(gitPath: git).output(["config", "user.name"])).flatMap { $0.isEmpty ? nil : $0 } ?? NSUserName()
                let summaries = try SyncService.push(space: synced, repoFor: repoFor, user: user)
                DispatchQueue.main.async {
                    self.busy.remove(id)
                    self.updates.remove(id)
                    self.reportPush(summaries, afterSync: report)
                }
            } catch { self.fail("Push failed", error, id) }
        }
    }

    private func fail(_ title: String, _ error: Error, _ id: UUID) {
        DispatchQueue.main.async {
            self.busy.remove(id)
            self.onMessage(title, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, nil)
        }
    }

    private func reportPush(_ summaries: [SyncService.PushSummary], afterSync report: SyncMerge.SpaceReport) {
        let pushed = summaries.filter { $0.result != nil }
        if pushed.isEmpty {
            onMessage("Nothing to push", "The repository already has your changes.", nil)
            return
        }
        var lines: [String] = []
        for s in pushed {
            guard let r = s.result else { continue }
            let what = s.groups.joined(separator: ", ")
            lines.append(r.direct ? "Pushed \(what) to \(r.branch)." : "Pushed \(what) to the branch \(r.branch).")
        }
        if !report.isEmpty { lines.append("Before pushing, " + Self.describe(report).lowercasedFirst) }
        onMessage("Pushed", lines.joined(separator: "\n"), pushed.compactMap { $0.result?.link }.first)
    }

    static func describe(_ r: SyncMerge.SpaceReport) -> String {
        if r.isEmpty { return "Everything is up to date." }
        var parts: [String] = []
        if r.added > 0 { parts.append("\(r.added) group\(r.added == 1 ? "" : "s") added") }
        if r.updated > 0 { parts.append("\(r.updated) updated") }
        if r.removed > 0 { parts.append("\(r.removed) removed") }
        if r.detached > 0 { parts.append("\(r.detached) kept as custom (deleted upstream)") }
        var text = parts.joined(separator: ", ") + "."
        if r.conflicts > 0 {
            text += "\n\(r.conflicts) item\(r.conflicts == 1 ? " was" : "s were") changed on both sides: yours \(r.conflicts == 1 ? "was" : "were") kept. Use Revert in the group or entity menu to take the repository's version."
        }
        return text
    }

    // MARK: Background check

    /// At launch and every few hours: fetch only, and remember which spaces have updates.
    func startChecking() {
        check()
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in self?.check() }
        timer?.tolerance = 300
    }

    func check() {
        guard let git = GitRunner.locate() else { return }
        let spaces = store.state.groups.filter(hasSources)
        let repoFor = repoFor(git)
        queue.async {
            var found = Set<UUID>()
            for space in spaces where (try? SyncService.hasUpdates(space: space, repoFor: repoFor)) == true { found.insert(space.id) }
            DispatchQueue.main.async { self.updates = found }
        }
    }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
