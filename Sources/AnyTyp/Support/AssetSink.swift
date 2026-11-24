import Foundation

/// Embedded-asset accumulation with the fixed retained-bytes cap (port of
/// `shared/assets.rs`).
final class AssetSink {
    private(set) var assets: [AnyTypAsset] = []
    /// Origin part -> retained asset id, so repeated references share one
    /// asset instead of duplicating its bytes.
    private var byPart: [String: Int] = [:]
    private var total = 0

    /// Retain an asset's bytes. Crossing the retained-bytes cap is a hard error.
    func add(mediaType: String, originPart: String, bytes: [UInt8]) throws -> Int {
        if let id = byPart[originPart] { return id }
        total += bytes.count
        if total > Limits.maxAssetTotalBytes {
            throw ConvertError.resourceLimit(
                limit: "max_asset_total_bytes",
                detail: "embedded assets exceed the retained-bytes cap"
            )
        }
        let id = assets.count
        byPart[originPart] = id
        assets.append(.init(id: id, mediaType: mediaType, originPart: originPart, data: Data(bytes)))
        return id
    }
}

/// Resolve an image relationship to its source. External-mode relationships
/// carry the image's URL directly; internal-mode targets load from the
/// package and are retained as assets. Failures degrade to `nil` per the
/// unified policy; fatal errors propagate (port of `shared/assets.rs`).
func relImageSource(
    _ pkg: Package,
    _ rels: Relationships,
    basePart: String,
    _ assets: AssetSink,
    relId: String
) throws -> AnyTypImageSource? {
    guard let rel = rels.get(relId) else { return nil }
    if rel.mode == .external {
        return rel.target.isEmpty ? nil : .external(rel.target)
    }
    guard let (part, data) = try relTargetBytes(pkg, rels, basePart: basePart, relId: relId) else {
        return nil
    }
    let id = try assets.add(mediaType: mediaTypeFor(part), originPart: part, bytes: [UInt8](data))
    return .asset(id)
}

/// MIME type from a part path's extension.
func mediaTypeFor(_ part: String) -> String {
    let ext = part.split(separator: ".").last.map { $0.lowercased() } ?? ""
    switch ext {
    case "png": return "image/png"
    case "jpg", "jpeg": return "image/jpeg"
    case "gif": return "image/gif"
    case "bmp": return "image/bmp"
    case "tif", "tiff": return "image/tiff"
    case "svg": return "image/svg+xml"
    case "emf": return "image/emf"
    case "wmf": return "image/wmf"
    case "webp": return "image/webp"
    default: return "application/octet-stream"
    }
}
