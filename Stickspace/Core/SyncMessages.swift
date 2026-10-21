import Foundation

/// The sentences shown after a sync, push or export. Kept here so they can be tested.
enum SyncMessages {
    static func syncDone(_ r: SyncMerge.SpaceReport) -> String {
        if r.isEmpty { return "Everything is up to date." }
        var parts: [String] = []
        if r.added > 0 { parts.append("\(r.added) group\(r.added == 1 ? "" : "s") added") }
        if r.updated > 0 { parts.append("\(r.updated) updated") }
        if r.removed > 0 { parts.append("\(r.removed) removed") }
        if r.detached > 0 { parts.append("\(r.detached) kept as custom (deleted upstream)") }
        if r.waiting > 0 { parts.append("waiting for a merge request to be merged") }
        var text = parts.joined(separator: ", ") + "."
        if r.conflicts > 0 {
            text += "\n\(r.conflicts) item\(r.conflicts == 1 ? " was" : "s were") changed on both sides: yours \(r.conflicts == 1 ? "was" : "were") kept. Use Revert in the group or entity menu to take the repository's version."
        }
        return text
    }

    static func exportDone(_ result: GitRepo.PushResult?, groups: [String]) -> String {
        let what = groups.joined(separator: ", ")
        guard let result else { return "The repository already has \(what). It is now linked to this one." }
        if result.direct { return "Wrote \(what) to \(result.branch). Others can import it now." }
        return "Pushed \(what) to the branch \(result.branch). Merge the request; then others can import it (Import → GIT), and Sync here will find it."
    }

    static func pushDone(_ summaries: [SyncService.PushSummary], afterSync report: SyncMerge.SpaceReport) -> (text: String, link: String?)? {
        let pushed = summaries.filter { $0.result != nil }
        guard !pushed.isEmpty else { return nil }
        var lines: [String] = []
        for s in pushed {
            guard let r = s.result else { continue }
            let what = s.groups.joined(separator: ", ")
            lines.append(r.direct ? "Pushed \(what) to \(r.branch)." : "Pushed \(what) to the branch \(r.branch).")
        }
        if !report.isEmpty { lines.append("Before pushing, " + syncDone(report).lowercasedFirst) }
        return (lines.joined(separator: "\n"), pushed.compactMap { $0.result?.link }.first)
    }
}

extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
