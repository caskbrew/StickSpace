import Foundation

/// Versioned JSON exchange format. JSON only.
///
/// Single stick:  {"version":1,"name":"…","sections":[{"type":"text","text":"…"}]}
/// Several:       {"version":1,"sticks":[ … ]}
/// Link sections are written with "url"; both "url" and "text" are accepted on import.
enum Interchange {
    static let version = 1

    struct ImportError: Error, Equatable, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: Export

    static func export(_ sticks: [Stick], asSingle: Bool, includeSensitive: Bool) -> String {
        let items = sticks.map { stickObject($0, includeSensitive: includeSensitive) }
        var root: [String: Any] = ["version": version]
        if asSingle, items.count == 1, let one = items.first {
            root.merge(one) { a, _ in a }
        } else {
            root["sticks"] = items
        }
        let data = (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private static func stickObject(_ stick: Stick, includeSensitive: Bool) -> [String: Any] {
        let sections: [[String: Any]] = stick.blocks.compactMap { b in
            if b.isMasked && !includeSensitive { return nil }
            var o: [String: Any] = ["type": b.type.rawValue]
            o[b.type == .link ? "url" : "text"] = b.text
            if b.isHidden { o["hidden"] = true }
            if b.isMasked { o["masked"] = true }
            return o
        }
        return ["name": stick.name, "sections": sections]
    }

    // MARK: Import

    static func parse(_ text: String) throws -> [Stick] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ImportError(message: "Nothing to import.") }
        let data = Data(trimmed.utf8)

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch let error as NSError {
            let offset = (error.userInfo["NSJSONSerializationErrorIndex"] as? Int) ?? 0
            let line = 1 + data.prefix(max(0, min(offset, data.count))).filter { $0 == 10 }.count
            throw ImportError(message: "Invalid JSON — line \(line)")
        }

        var stickObjects: [Any]
        if let array = object as? [Any] {
            stickObjects = array
        } else if let root = object as? [String: Any] {
            try checkVersion(root["version"])
            if let sticks = root["sticks"] {
                guard let array = sticks as? [Any] else { throw ImportError(message: "\"sticks\" must be an array.") }
                stickObjects = array
            } else if root["name"] != nil {
                stickObjects = [root]
            } else {
                throw ImportError(message: "Expected a \"sticks\" array or a stick with a \"name\".")
            }
        } else {
            throw ImportError(message: "Expected a JSON object.")
        }
        guard !stickObjects.isEmpty else { throw ImportError(message: "No sticks found.") }

        return try stickObjects.enumerated().map { try parseStick($1, index: $0 + 1) }
    }

    private static func checkVersion(_ value: Any?) throws {
        guard let value else { return }
        guard let n = value as? Int else { throw ImportError(message: "\"version\" must be a number.") }
        guard n >= 1 else { throw ImportError(message: "Invalid format version \(n).") }
        guard n <= version else { throw ImportError(message: "Unsupported format version \(n); this app supports up to \(version).") }
    }

    private static func parseStick(_ any: Any, index: Int) throws -> Stick {
        guard let o = any as? [String: Any] else { throw ImportError(message: "Stick #\(index) must be an object.") }
        guard let name = (o["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            throw ImportError(message: "Stick #\(index): \"name\" must be a non-empty string.")
        }
        var stick = Stick(name: name)
        guard let rawSections = o["sections"] else { return stick }
        guard let sections = rawSections as? [Any] else { throw ImportError(message: "Stick \"\(name)\": \"sections\" must be an array.") }

        for (i, item) in sections.enumerated() {
            let where_ = "Stick \"\(name)\", section #\(i + 1)"
            guard let s = item as? [String: Any] else { throw ImportError(message: "\(where_): must be an object.") }
            var type = BlockType.auto
            if let raw = s["type"] {
                guard let str = raw as? String, let t = BlockType(rawValue: str.lowercased()) else {
                    throw ImportError(message: "\(where_): \"type\" must be auto, text, link or code.")
                }
                type = t
            }
            let value = (s["text"] ?? s["url"])
            guard let text = value as? String else { throw ImportError(message: "\(where_): missing \"text\".") }
            var block = Block(type: type, text: text)
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
