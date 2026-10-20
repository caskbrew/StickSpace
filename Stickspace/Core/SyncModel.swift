import Foundation

/// Where shared content lives. `path` is a space file (on a space) or a group file (on a single imported group).
struct GitSource: Equatable, Codable {
    var url: String
    var path: String
    var ref = "main"
    /// Optional private key for this source (`ssh -i … -o IdentitiesOnly=yes`).
    var sshKey: String?
    /// Push straight to `ref` instead of a new branch.
    var directPush = false
    /// The commit applied at the last sync.
    var appliedHead: String?

    /// Same repository, ref and path: two sources like this would import the same thing twice.
    func sameLocation(as other: GitSource) -> Bool { url == other.url && path == other.path && ref == other.ref }
}

/// The shared version of a group (what the repository held at the last sync). Local flags are not kept.
struct GroupSnapshot: Equatable {
    var id: UUID
    var name: String
    var blocks: [Block]

    init(id: UUID, name: String, blocks: [Block]) {
        self.id = id
        self.name = name
        self.blocks = blocks.map { Block(id: $0.id, type: $0.type, text: $0.text, title: $0.title, tags: $0.tags) }
    }

    init(_ stick: Stick) { self.init(id: stick.id, name: stick.name, blocks: stick.blocks) }
}

struct GroupOrigin: Equatable {
    /// Set for a group imported on its own (File); groups of an imported space use the space's source.
    var source: GitSource?
    /// Repository path of the group's own file; nil when the group is written inline in the space file.
    var file: String?
    var base: GroupSnapshot
}

/// An entity's shared fields: what is compared, merged and written to a file.
struct SharedEntity: Equatable {
    var id: UUID
    var type: BlockType
    var text: String
    var title: String
    var tags: [String]

    init(_ b: Block) { id = b.id; type = b.type; text = b.text; title = b.title; tags = b.tags }
}

extension Stick {
    /// Masked and not part of the shared version: it never leaves this Mac and sync leaves it alone.
    func isLocalOnly(_ block: Block) -> Bool {
        guard block.isMasked, let origin else { return false }
        return !origin.base.blocks.contains { $0.id == block.id }
    }

    /// The group as it would be written to a file.
    var sharedBlocks: [Block] { origin == nil ? blocks : blocks.filter { !isLocalOnly($0) } }

    /// True when the shared content differs from the last synced version.
    var isModified: Bool {
        guard let origin else { return false }
        return name != origin.base.name || sharedBlocks.map(SharedEntity.init) != origin.base.blocks.map(SharedEntity.init)
    }

    var snapshot: GroupSnapshot { GroupSnapshot(id: id, name: name, blocks: sharedBlocks) }
}
