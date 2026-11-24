import Foundation

/// Package target resolution per OPC/EPUB URI semantics, applied before any
/// archive lookup.
///
/// The reference is treated as a URI: fragment and query split off first,
/// then each path segment is percent-decoded *after* segmentation. A segment
/// whose decoded form would introduce structure (`/`, `\`, `.`, `..`) is
/// rejected — encoded traversal never becomes path structure.
struct PackageTarget {
    /// Normalized archive path (no leading slash).
    let path: String
    let fragment: String?
}

/// Resolve a relative or package-absolute reference against the part it
/// appears in.
func resolvePackageTarget(_ basePart: String, _ reference: String) throws -> PackageTarget {
    var ref = reference
    var fragment: String? = nil
    if let hashIdx = ref.firstIndex(of: "#") {
        fragment = decodeComponent(String(ref[ref.index(after: hashIdx)...]))
        ref = String(ref[..<hashIdx])
    }
    if let qIdx = ref.firstIndex(of: "?") {
        ref = String(ref[..<qIdx])
    }
    if ref.isEmpty {
        // Fragment-only reference: the target is the base part itself.
        return PackageTarget(path: basePart, fragment: fragment)
    }

    var segments: [String] = []
    if !ref.hasPrefix("/") {
        // Start from the base part's directory.
        if let slashIdx = basePart.lastIndex(of: "/") {
            let dir = basePart[..<slashIdx]
            segments.append(contentsOf: dir.split(separator: "/").map(String.init))
        }
    }
    for raw in ref.split(separator: "/", omittingEmptySubsequences: false) {
        let rawStr = String(raw)
        switch rawStr {
        case "", ".":
            continue
        case "..":
            // Dot segments resolve against the base, clamped at the package
            // root (a traversal above root is producer sloppiness in the
            // wild; clamping preserves OPC behavior).
            if !segments.isEmpty { segments.removeLast() }
        default:
            let decoded = decodeComponent(rawStr)
            if decoded.contains("/") || decoded.contains("\\") {
                throw ConvertError.malformed(
                    "percent-encoded separator in package reference segment \"\(rawStr)\""
                )
            }
            if decoded == "." || decoded == ".." {
                throw ConvertError.malformed(
                    "percent-encoded traversal in package reference segment \"\(rawStr)\""
                )
            }
            segments.append(decoded)
        }
    }
    return PackageTarget(path: segments.joined(separator: "/"), fragment: fragment)
}

/// Percent-decode one URI component. Infallible by design: a `%` not
/// followed by two hex digits passes through literally (producers emit such
/// names), and non-UTF-8 decoded bytes degrade lossily - the result is only
/// ever matched against archive entry names, where a near-miss simply fails
/// the lookup.
func decodeComponent(_ component: String) -> String {
    let bytes = Array(component.utf8)
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count)
    var i = 0
    while i < bytes.count {
        if bytes[i] == UInt8(ascii: "%"), i + 2 < bytes.count {
            let h1 = bytes[i + 1], h2 = bytes[i + 2]
            if let d1 = hexValue(h1), let d2 = hexValue(h2) {
                out.append(d1 << 4 | d2)
                i += 3
                continue
            }
        }
        out.append(bytes[i])
        i += 1
    }
    return String(decoding: out, as: UTF8.self)
}

func decodeFragment(_ fragment: String) -> String {
    decodeComponent(fragment)
}

private func hexValue(_ b: UInt8) -> UInt8? {
    switch b {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): return b - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"): return b - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"): return b - UInt8(ascii: "A") + 10
    default: return nil
    }
}
