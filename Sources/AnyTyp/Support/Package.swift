import Foundation

/// A ZIP-based document package (OOXML, ODF, EPUB).
///
/// Parts are served from a cache so repeated references do not re-charge the
/// decompression budget (`Limits.maxTotalBytes`). `Data` is copy-on-write, so
/// cache hits share storage.
final class Package {
    private let zip: ZipArchive
    private(set) var totalRead: UInt64 = 0
    private var cache: [String: Data] = [:]

    init(bytes: [UInt8]) throws {
        self.zip = try ZipArchive(bytes: bytes)
    }

    /// Read a part's bytes. `nil` means the part is absent (a valid state for
    /// optional parts); a throw means it exists but cannot be read. Callers
    /// apply the unified policy: skip + log when useful output remains,
    /// propagate when the part is the primary content.
    func part(_ name: String) throws -> Data? {
        // OPC part URIs may carry leading slashes; entries never do.
        let name = String(name.drop(while: { $0 == "/" }))
        if let cached = cache[name] {
            return cached
        }
        guard let entry = zip.entry(named: name) else {
            return nil
        }
        if entry.uncompressedSize > Limits.maxEntryBytes {
            throw ConvertError.resourceLimit(
                limit: "max_entry_bytes",
                detail: "\(name) declares \(entry.uncompressedSize) decompressed bytes"
            )
        }
        // The declared size can lie; the read is hard-capped by whichever
        // budget has less room: the per-entry limit or what remains of the
        // whole-archive total.
        let remaining = Limits.maxTotalBytes > totalRead ? Limits.maxTotalBytes - totalRead : 0
        let cap = min(Limits.maxEntryBytes, remaining)
        let bytes = try zip.read(entry, cap: cap)
        totalRead += UInt64(bytes.count)
        let data = Data(bytes)
        cache[name] = data
        return data
    }

    /// True when a part exists, without reading (or budget-charging) it.
    func hasPart(_ name: String) -> Bool {
        zip.hasEntry(String(name.drop(while: { $0 == "/" })))
    }

    /// Read a part that must exist for any meaningful output.
    func requiredPart(_ name: String) throws -> Data {
        guard let data = try part(name) else {
            throw ConvertError.missingPart(part: name)
        }
        return data
    }

    /// Read an optional part under the unified recovery policy: absent is a
    /// valid state (`nil`, silent); an unreadable part is skipped with a log;
    /// fatal resource-limit errors always propagate.
    func optionalPart(_ name: String) throws -> Data? {
        do {
            return try part(name)
        } catch let e as ConvertError {
            if e.isFatal { throw e }
            AnyTypLog.warn("skipping unreadable part \(name): \(errorDesc(e))")
            return nil
        }
    }

    /// Read and parse an optional XML part under the unified recovery policy:
    /// absent -> `nil`; unreadable or corrupt -> skipped with a log; fatal
    /// resource-limit errors always propagate.
    func optionalXMLPart(_ name: String) throws -> XmlElement? {
        guard let data = try optionalPart(name) else { return nil }
        do {
            return try parseXML(data)
        } catch let e as ConvertError {
            if e.isFatal { throw e }
            AnyTypLog.warn("skipping corrupt part \(name): \(errorDesc(e))")
            return nil
        }
    }

    /// Read and parse an XML part that must exist and parse for any
    /// meaningful output.
    func requiredXMLPart(_ name: String) throws -> XmlElement {
        let data = try requiredPart(name)
        return try parseXML(data)
    }
}

/// A zip-open failure on OOXML input may actually be an OLE compound file:
/// an encrypted package, or a legacy binary document with the wrong
/// extension.
func probeOle(bytes: [UInt8]) -> ConvertError? {
    let oleMagic: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
    guard bytes.starts(with: oleMagic) else { return nil }
    if let ole = try? OleFile(bytes: bytes),
       ole.exists("EncryptionInfo") || ole.exists("EncryptedPackage") {
        return .encrypted
    }
    return .malformed(
        "OLE compound document where an OOXML package was expected (legacy binary format?)"
    )
}

/// Short description of a ConvertError for log messages.
func errorDesc(_ e: ConvertError) -> String {
    switch e {
    case .unsupported(let w): return "unsupported input: \(w)"
    case .needsOCR(let p, let c): return "pages \(p) of \(c) need OCR"
    case .malformed(let part, let d):
        return part.map { "malformed document (\($0)): \(d)" } ?? "malformed document: \(d)"
    case .encrypted: return "document is encrypted"
    case .resourceLimit(let l, let d): return "resource limit exceeded (\(l)): \(d)"
    case .missingPart(let p): return "missing required part: \(p)"
    case .io(let d): return "io error: \(d)"
    }
}
