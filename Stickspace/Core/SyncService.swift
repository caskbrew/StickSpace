import Foundation

/// Reading from and pushing to a repository. Synchronous and UI-free: callers run it off the main thread.
/// Applying what was read is `AppStore.applySync`; planning what to write is `SyncPush`.
enum SyncService {
    typealias RepoFor = (GitSource) -> GitRepo

    struct SpaceRead {
        var name: String
        var groups: [SyncMerge.RemoteGroup]
        var head: String
    }

    struct GroupRead {
        /// nil: the file is no longer in the repository.
        var group: SyncMerge.RemoteGroup?
        var head: String
    }

    /// Everything a sync needs: the space file (if the space was imported) and each group imported on its own.
    struct Fetched {
        var space: SpaceRead?
        var singles: [UUID: GroupRead] = [:]
    }

    // MARK: Reading

    static func readSpace(_ source: GitSource, repo: GitRepo) throws -> SpaceRead {
        let head = try repo.fetch(ref: source.ref)
        guard let text = try repo.read(source.path, at: head.sha) else {
            throw GitError(message: "“\(source.path)” was not found on “\(source.ref)”.")
        }
        let decoded: (name: String, entries: [Interchange.SpaceEntry])
        do { decoded = try Interchange.decodeSpaceFile(text) } catch { throw GitError(message: "\(source.path): \(error.localizedDescription)") }

        let dir = (source.path as NSString).deletingLastPathComponent
        var groups: [SyncMerge.RemoteGroup] = []
        var seen = Set<UUID>()
        for entry in decoded.entries {
            let group: SyncMerge.RemoteGroup
            switch entry {
            case .inline(let stick):
                group = SyncMerge.RemoteGroup(snapshot: GroupSnapshot(stick), file: nil)
            case .file(let relative):
                let path = dir.isEmpty ? relative : dir + "/" + relative
                guard let fileText = try repo.read(path, at: head.sha) else {
                    throw GitError(message: "\(source.path) refers to “\(path)”, which is not in the repository.")
                }
                do { group = SyncMerge.RemoteGroup(snapshot: GroupSnapshot(try Interchange.decodeGroupFile(fileText)), file: path) }
                catch { throw GitError(message: "\(path): \(error.localizedDescription)") }
            }
            guard seen.insert(group.snapshot.id).inserted else {
                throw GitError(message: "“\(group.snapshot.name)” appears twice in \(source.path).")
            }
            groups.append(group)
        }
        return SpaceRead(name: decoded.name, groups: groups, head: head.sha)
    }

    /// A group file. `required` is true when importing (a missing file is an error); false when syncing (it was deleted upstream).
    static func readGroup(_ source: GitSource, repo: GitRepo, required: Bool) throws -> GroupRead {
        let head = try repo.fetch(ref: source.ref)
        guard let text = try repo.read(source.path, at: head.sha) else {
            if required { throw GitError(message: "“\(source.path)” was not found on “\(source.ref)”.") }
            return GroupRead(group: nil, head: head.sha)
        }
        do {
            let stick = try Interchange.decodeGroupFile(text)
            return GroupRead(group: SyncMerge.RemoteGroup(snapshot: GroupSnapshot(stick), file: source.path), head: head.sha)
        } catch {
            throw GitError(message: "\(source.path): \(error.localizedDescription)")
        }
    }

    /// Reads every source a space depends on.
    static func fetch(space: StickGroup, repoFor: RepoFor) throws -> Fetched {
        var fetched = Fetched()
        if let source = space.source { fetched.space = try readSpace(source, repo: repoFor(source)) }
        for stick in space.sticks {
            guard let source = stick.origin?.source else { continue }
            fetched.singles[stick.id] = try readGroup(source, repo: repoFor(source), required: false)
        }
        return fetched
    }

    /// Fetches only, and says whether the repository has moved since the last sync.
    static func hasUpdates(space: StickGroup, repoFor: RepoFor) throws -> Bool {
        var sources: [GitSource] = space.source.map { [$0] } ?? []
        sources += space.sticks.compactMap { $0.origin?.source }
        for source in sources {
            let head = try repoFor(source).fetch(ref: source.ref)
            if head.sha != source.appliedHead { return true }
        }
        return false
    }

    // MARK: Pushing

    struct PushSummary: Equatable {
        var url: String
        var ref: String
        var groups: [String]
        /// nil: the repository already had these contents.
        var result: GitRepo.PushResult?
    }

    static func push(space: StickGroup, repoFor: RepoFor, user: String, now: Date = Date()) throws -> [PushSummary] {
        var spaceFile: (name: String, entries: [Interchange.SpaceEntry])?
        if let source = space.source {
            let repo = repoFor(source)
            let head = try repo.fetch(ref: source.ref)
            if let text = try repo.read(source.path, at: head.sha) {
                do { spaceFile = try Interchange.decodeSpaceFile(text) } catch { throw GitError(message: "\(source.path): \(error.localizedDescription)") }
            }
        }
        var summaries: [PushSummary] = []
        for plan in SyncPush.plans(space: space, spaceFile: spaceFile) {
            let repo = repoFor(plan.source)
            let stamp = DateFormatter()
            stamp.dateFormat = "yyyyMMdd-HHmmss"
            stamp.locale = Locale(identifier: "en_US_POSIX")
            let branch = "stickspace/\(slug(user))-\(stamp.string(from: now))"
            let message = "Update \(plan.groups.joined(separator: ", ")) (StickSpace)"
            let result = try repo.push(files: plan.files, ref: plan.source.ref, direct: plan.source.directPush, message: message, branchName: branch)
            summaries.append(PushSummary(url: plan.source.url, ref: plan.source.ref, groups: plan.groups, result: result))
        }
        return summaries
    }

    static func slug(_ text: String) -> String {
        let s = text.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        let trimmed = s.split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return trimmed.isEmpty ? "user" : trimmed
    }
}

/// What a push would write. Only groups that differ from their last synced version are included.
enum SyncPush {
    struct Plan: Equatable {
        var source: GitSource
        var files: [String: String] = [:]
        var groups: [String] = []
    }

    static func plans(space: StickGroup, spaceFile: (name: String, entries: [Interchange.SpaceEntry])?) -> [Plan] {
        var order: [String] = []
        var byKey: [String: Plan] = [:]
        func add(_ source: GitSource, path: String, text: String, groups: [String]) {
            let key = source.url + "\u{0}" + source.ref
            if byKey[key] == nil { byKey[key] = Plan(source: source); order.append(key) }
            byKey[key]!.files[path] = text
            for name in groups where !byKey[key]!.groups.contains(name) { byKey[key]!.groups.append(name) }
        }
        func shared(_ s: Stick) -> Stick { Stick(id: s.id, name: s.name, blocks: s.sharedBlocks) }

        if let source = space.source, let file = spaceFile {
            var entries = file.entries
            var inlineNames: [String] = []
            for stick in space.sticks {
                guard let origin = stick.origin, origin.source == nil, stick.isModified else { continue }
                if let path = origin.file {
                    add(source, path: path, text: Interchange.encodeGroupFile(shared(stick)), groups: [stick.name])
                } else if let i = entries.firstIndex(where: { if case .inline(let s) = $0 { return s.id == stick.id } else { return false } }) {
                    entries[i] = .inline(shared(stick))
                    inlineNames.append(stick.name)
                }
            }
            if !inlineNames.isEmpty {
                add(source, path: source.path, text: Interchange.encodeSpaceFile(name: file.name, entries: entries), groups: inlineNames)
            }
        }
        for stick in space.sticks {
            guard let origin = stick.origin, let source = origin.source, stick.isModified else { continue }
            add(source, path: origin.file ?? source.path, text: Interchange.encodeGroupFile(shared(stick)), groups: [stick.name])
        }
        return order.compactMap { byKey[$0] }
    }
}
