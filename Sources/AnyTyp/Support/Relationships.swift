import Foundation

/// Well-known OPC relationship types (Transitional form; Strict types are
/// normalized onto these when the rels part is read).
enum RelType {
    static let officeDocument =
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"
    static let styles =
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles"
    static let numbering =
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering"
    static let footnotes =
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships/footnotes"
    static let endnotes =
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships/endnotes"
}

enum TargetMode {
    case `internal`
    case external
}

struct Relationship {
    let target: String
    let relType: String
    let mode: TargetMode
}

/// Typed OPC relationships, keyed by relationship id.
struct Relationships {
    fileprivate var map: [String: Relationship] = [:]

    func get(_ id: String) -> Relationship? {
        map[id]
    }

    /// Internal-mode target for an id, the common case for parts.
    func internalTarget(_ id: String) -> String? {
        map[id].flatMap { $0.mode == .internal ? $0.target : nil }
    }

    /// The internal-mode relationship of a given type, lowest id first so the
    /// pick is deterministic when a producer emits duplicates.
    func firstOfType(_ relType: String) -> Relationship? {
        map
            .filter { $0.value.relType == relType && $0.value.mode == .internal }
            .min { $0.key < $1.key }?
            .value
    }

    /// Every relationship, in id order (deterministic for diagnostics).
    var all: [(id: String, rel: Relationship)] {
        map.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
}

/// Read a relationships part. An absent, unreadable, or corrupt part yields
/// an empty map (absent is valid - many parts simply have no relationships;
/// the rest degrade per the unified policy with a log). Resource-limit
/// errors always propagate.
func readRels(_ pkg: Package, _ part: String) throws -> Relationships {
    guard let root = try pkg.optionalXMLPart(part) else {
        return Relationships()
    }
    var rels = Relationships()
    for rel in root.descendants(XmlNS.pkgRels, "Relationship") {
        guard let id = rel.attrAny("Id"), let target = rel.attrAny("Target") else {
            continue
        }
        let mode: TargetMode = rel.attrAny("TargetMode")?.lowercased() == "external"
            ? .external
            : .internal
        let rawType = rel.attrAny("Type") ?? ""
        let relType = normalizeOoxmlURI(rawType) ?? rawType
        rels.map[id] = Relationship(target: target, relType: relType, mode: mode)
    }
    return rels
}

/// A loaded internal relationship target: its resolved part path and bytes.
typealias RelTarget = (path: String, bytes: Data)

/// Load an internal relationship target's bytes, resolved against the part
/// the relationship appears in. Unknown ids, external targets, and
/// unresolvable or unreadable targets degrade (log + `nil`) per the unified
/// policy; fatal resource-limit errors always propagate.
func relTargetBytes(
    _ pkg: Package,
    _ rels: Relationships,
    basePart: String,
    relId: String
) throws -> RelTarget? {
    guard let rel = rels.get(relId) else { return nil }
    guard rel.mode == .internal else { return nil }
    let target: PackageTarget
    do {
        target = try resolvePackageTarget(basePart, rel.target)
    } catch {
        AnyTypLog.warn("skipping unresolvable relationship target \"\(rel.target)\": \(error)")
        return nil
    }
    guard let bytes = try pkg.optionalPart(target.path) else {
        AnyTypLog.warn("relationship target \(target.path) is missing")
        return nil
    }
    return (target.path, bytes)
}

/// Conventional rels part name for a part (`word/document.xml` ->
/// `word/_rels/document.xml.rels`).
func relsPartFor(_ part: String) -> String {
    if let slash = part.lastIndex(of: "/") {
        let dir = part[..<slash]
        let file = part[part.index(after: slash)...]
        return "\(dir)/_rels/\(file).rels"
    }
    return "_rels/\(part).rels"
}
