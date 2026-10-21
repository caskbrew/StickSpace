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

    // MARK: Export

    /// Publishes a space's visible custom groups, then ties them to the new files.
    func exportSpace(_ id: UUID, source: GitSource, separateFiles: Bool, done: @escaping (Result<Void, Error>) -> Void) {
        guard let git = GitRunner.locate() else { return done(.failure(GitError(message: GitRunner.missingMessage))) }
        guard let space = store.groupIndex(id).map({ store.state.groups[$0] }) else { return done(.failure(GitError(message: "The space is gone."))) }
        let sticks = space.sticks.filter { !$0.isHidden && $0.origin == nil }
        guard space.source == nil, !sticks.isEmpty else { return done(.failure(GitError(message: "There is nothing to export."))) }
        let plan = SyncExport.spacePlan(name: space.name, sticks: sticks, path: source.path, separateFiles: separateFiles)
        run(plan, source: source, git: git, done: done) { bound in self.store.bindExportedSpace(id, source: bound, files: plan.groupFiles) }
    }

    func exportGroup(_ id: UUID, source: GitSource, done: @escaping (Result<Void, Error>) -> Void) {
        guard let git = GitRunner.locate() else { return done(.failure(GitError(message: GitRunner.missingMessage))) }
        guard let stick = store.stick(id), stick.origin == nil else { return done(.failure(GitError(message: "There is nothing to export."))) }
        let plan = SyncExport.groupPlan(stick, path: source.path)
        run(plan, source: source, git: git, done: done) { bound in self.store.bindExportedGroup(id, source: bound) }
    }

    private func run(_ plan: SyncExport.Plan, source: GitSource, git: String, done: @escaping (Result<Void, Error>) -> Void,
                     bind: @escaping (GitSource) -> Void) {
        let repoFor = repoFor(git)
        queue.async {
            do {
                let user = (try? GitRunner(gitPath: git).output(["config", "user.name"])).flatMap { $0.isEmpty ? nil : $0 } ?? NSUserName()
                let result = try SyncService.export(plan, source: source, repoFor: repoFor, user: user)
                DispatchQueue.main.async {
                    bind(SyncExport.bound(source, result: result))
                    done(.success(()))
                    self.onMessage("Exported", SyncMessages.exportDone(result, groups: plan.groupNames), result?.link)
                    self.check()
                }
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
                    self.onMessage("Synced", SyncMessages.syncDone(report), nil)
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
        guard let done = SyncMessages.pushDone(summaries, afterSync: report) else {
            onMessage("Nothing to push", "The repository already has your changes.", nil)
            return
        }
        onMessage("Pushed", done.text, done.link)
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
