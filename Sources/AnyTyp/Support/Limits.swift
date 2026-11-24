import Foundation

/// Fixed safety limits, applied identically to every conversion.
///
/// These are hard caps against attack/abuse input shapes (decompression
/// bombs, pathological nesting, runaway expansion) - crossing one returns
/// `ConvertError.resourceLimit`, always. They are deliberately not
/// configurable: real-world documents sit orders of magnitude below every
/// value here.
enum Limits {
    /// Maximum decompressed size of a single archive entry: 128 MiB.
    static let maxEntryBytes: UInt64 = 128 * 1024 * 1024

    /// Maximum total decompressed bytes read from one archive: 512 MiB.
    static let maxTotalBytes: UInt64 = 512 * 1024 * 1024

    /// Maximum number of entries in one archive.
    static let maxEntryCount = 100_000

    /// Maximum XML element nesting depth.
    static let maxXMLDepth = 256

    /// Maximum number of XML nodes (elements + text runs) in one part.
    static let maxXMLNodes = 2_000_000

    /// Maximum grid positions one spreadsheet table may materialize.
    static let maxGridSlots: UInt64 = 4_000_000

    /// Maximum content-bearing cells a repeat expansion may produce per table.
    static let maxExpansion: UInt64 = 4_000_000

    /// Maximum total text bytes duplicated by repeat expansion per document.
    static let maxExpansionTextBytes: UInt64 = 64 * 1024 * 1024

    /// Maximum total bytes of embedded assets retained in a document.
    static let maxAssetTotalBytes = 128 * 1024 * 1024

    /// Maximum nesting depth of binary record containers (legacy PPT stream).
    static let maxRecordDepth = 64

    /// Maximum total binary records visited in one legacy record stream.
    static let maxRecords: UInt64 = 16_000_000
}
