import Foundation

/// Versioned JSON exchange format (version 2). JSON only. See docs/design/git-sync.md.
///
/// Group:  {"version":2,"id":"…","name":"…","entities":[{"id":"…","type":"text","text":"…","title":"…","tags":["prod"]}]}
/// Space:  {"version":2,"name":"…","groups":[ <group> | {"file":"groups/a.json"} ]}
///
/// Version 1 (`sticks` / `sections`) is still read. Link entities are written with "url"; "url" and "text" are both read.
enum Interchange {
    static let version = 2

    struct ImportError: Error, Equatable, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// One entry of a space file's group list.
    enum SpaceEntry: Equatable {
        case inline(Stick)
        /// Path relative to the space file.
        case file(String)
    }

    // MARK: Export (copy / paste)

    static func export(_ sticks: [Stick], asSingle: Bool, includeSensitive: Bool, spaceName: String? = nil) -> String {
        let items = sticks.map { groupObject($0, includeSensitive: includeSensitive, localFlags: true) }
        var root: [String: Any] = ["version": version]
        if asSingle, items.count == 1, let one = items.first {
            root.merge(one) { a, _ in a }
        } else {
            root["groups"] = items
            if let spaceName, !spaceName.isEmpty { root["name"] = spaceName }
        }
        return json(root)
    }

    // MARK: Files in a repository

    /// The caller decides which entities go in: masked and hidden flags are never written.
    static func encodeGroupFile(_ stick: Stick) -> String {
        var root: [String: Any] = ["version": version]
        root.merge(groupObject(stick, includeSensitive: true, localFlags: false)) { a, _ in a }
        return json(root)
    }

    static func encodeSpaceFile(name: String, entries: [SpaceEntry]) -> String {
        let groups: [[String: Any]] = entries.map {
            switch $0 {
            case .inline(let stick): return groupObject(stick, includeSensitive: true, localFlags: false)
            case .file(let path): return ["file": path]
            }
        }
        return json(["version": version, "name": name, "groups": groups])
    }

    static func decodeGroupFile(_ text: String) throws -> Stick {
        let root = try rootObject(text)
        try checkVersion(root["version"])
        return try parseGroup(root, label: "Group")
    }

    static func decodeSpaceFile(_ text: String) throws -> (name: String, entries: [SpaceEntry]) {
        let root = try rootObject(text)
        try checkVersion(root["version"])
        guard let array = (root["groups"] ?? root["sticks"]) as? [Any] else { throw ImportError(message: "A space file needs a \"groups\" array.") }
        let name = (root["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Space"
        var entries: [SpaceEntry] = []
        for (i, any) in array.enumerated() {
            guard let o = any as? [String: Any] else { throw ImportError(message: "Group #\(i + 1) must be an object.") }
            if let file = o["file"] {
                guard let path = file as? String, isSafeRelative(path) else {
                    throw ImportError(message: "Group #\(i + 1): \"file\" must be a relative path inside the repository.")
                }
                entries.append(.file(path))
            } else {
                entries.append(.inline(try parseGroup(o, label: "Group #\(i + 1)")))
            }
        }
        return (name, entries)
    }

    /// No absolute paths and no `..`: a space file must not point outside its repository.
    static func isSafeRelative(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == ".." || $0.isEmpty }
    }

    // MARK: Import (paste)

    static func parse(_ text: String) throws -> [Stick] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ImportError(message: "Nothing to import.") }
        let object = try parseJSON(trimmed)

        var groupObjects: [Any]
        if let array = object as? [Any] {
            groupObjects = array
        } else if let root = object as? [String: Any] {
            try checkVersion(root["version"])
            if let groups = root["groups"] ?? root["sticks"] {
                guard let array = groups as? [Any] else { throw ImportError(message: "\"groups\" must be an array.") }
                groupObjects = array
            } else if root["name"] != nil {
                groupObjects = [root]
            } else {
                throw ImportError(message: "Expected a \"groups\" array or a group with a \"name\".")
            }
        } else {
            throw ImportError(message: "Expected a JSON object.")
        }
        guard !groupObjects.isEmpty else { throw ImportError(message: "No groups found.") }
        if groupObjects.contains(where: { ($0 as? [String: Any])?["file"] != nil }) {
            throw ImportError(message: "This space keeps groups in separate files. Import it from Git instead of pasting.")
        }
        return try groupObjects.enumerated().map { try parseGroup($1, label: "Group #\($0 + 1)") }
    }

    /// The "name" of a whole-space document, if there is one.
    static func spaceName(in text: String) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              root["groups"] != nil || root["sticks"] != nil else { return nil }
        return (root["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    // MARK: Writing

    private static func groupObject(_ stick: Stick, includeSensitive: Bool, localFlags: Bool) -> [String: Any] {
        let entities: [[String: Any]] = stick.blocks.compactMap { b in
            if b.isMasked && !includeSensitive { return nil }
            var o: [String: Any] = ["id": b.id.uuidString.lowercased(), "type": b.type.rawValue]
            o[b.type == .link ? "url" : "text"] = b.text
            if b.hasTitle { o["title"] = b.title }
            if !b.tags.isEmpty { o["tags"] = b.tags }
            if localFlags {
                if b.isHidden { o["hidden"] = true }
                if b.isMasked { o["masked"] = true }
            }
            return o
        }
        return ["id": stick.id.uuidString.lowercased(), "name": stick.name, "entities": entities]
    }

    private static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    // MARK: Reading

    private static func rootObject(_ text: String) throws -> [String: Any] {
        guard let root = try parseJSON(text.trimmingCharacters(in: .whitespacesAndNewlines)) as? [String: Any] else {
            throw ImportError(message: "Expected a JSON object.")
        }
        return root
    }

    private static func parseJSON(_ text: String) throws -> Any {
        let data = Data(text.utf8)
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch let error as NSError {
            let offset = (error.userInfo["NSJSONSerializationErrorIndex"] as? Int) ?? 0
            let line = 1 + data.prefix(max(0, min(offset, data.count))).filter { $0 == 10 }.count
            throw ImportError(message: "Invalid JSON — line \(line)")
        }
    }

    private static func checkVersion(_ value: Any?) throws {
        guard let value else { return }
        guard let n = value as? Int else { throw ImportError(message: "\"version\" must be a number.") }
        guard n >= 1 else { throw ImportError(message: "Invalid format version \(n).") }
        guard n <= version else { throw ImportError(message: "Unsupported format version \(n); this app supports up to \(version).") }
    }

    private static func parseGroup(_ any: Any, label: String) throws -> Stick {
        guard let o = any as? [String: Any] else { throw ImportError(message: "\(label) must be an object.") }
        guard let name = (o["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            throw ImportError(message: "\(label): \"name\" must be a non-empty string.")
        }
        var stick = Stick(name: name)
        if let raw = o["id"] {
            guard let str = raw as? String, let id = UUID(uuidString: str) else { throw ImportError(message: "\(label) \"\(name)\": \"id\" must be a UUID.") }
            stick.id = id
        }
        guard let rawEntities = o["entities"] ?? o["sections"] else { return stick }
        guard let entities = rawEntities as? [Any] else { throw ImportError(message: "\(label) \"\(name)\": \"entities\" must be an array.") }

        var seen = Set<UUID>()
        for (i, item) in entities.enumerated() {
            let where_ = "Group \"\(name)\", entity #\(i + 1)"
            guard let s = item as? [String: Any] else { throw ImportError(message: "\(where_): must be an object.") }
            guard let text = (s["text"] ?? s["url"]) as? String else { throw ImportError(message: "\(where_): missing \"text\".") }

            var type: BlockType = LinkCheck.url(from: text) != nil ? .link : .text
            if let raw = s["type"] {
                guard let str = raw as? String, let t = BlockType.parse(str, text: text) else {
                    throw ImportError(message: "\(where_): \"type\" must be text or link.")
                }
                type = t
            }
            var block = Block(type: type, text: text)
            if let raw = s["id"] {
                guard let str = raw as? String, let id = UUID(uuidString: str) else { throw ImportError(message: "\(where_): \"id\" must be a UUID.") }
                block.id = id
            }
            guard seen.insert(block.id).inserted else { throw ImportError(message: "\(where_): duplicate \"id\".") }
            if let raw = s["title"] {
                guard let str = raw as? String else { throw ImportError(message: "\(where_): \"title\" must be a string.") }
                block.title = str
            }
            if let raw = s["tags"] {
                guard let list = raw as? [String] else { throw ImportError(message: "\(where_): \"tags\" must be a list of strings.") }
                block.tags = Tags.clean(list)
            }
            for key in ["hidden", "masked"] {
                guard let raw = s[key] else { continue }
                guard let flag = raw as? Bool else { throw ImportError(message: "\(where_): \"\(key)\" must be true or false.") }
                if key == "hidden" { block.isHidden = flag } else { block.isMasked = flag }
            }
            stick.blocks.append(block)
        }
        return stick
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
