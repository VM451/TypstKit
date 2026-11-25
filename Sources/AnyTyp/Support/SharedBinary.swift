import Foundation
import CZlib

/// Shared primitives for the legacy OLE2 binary formats (DOC, PPT)
/// (port of `shared/binary.rs`): checked little-endian integer readers
/// and bounded compound-file stream reading.

/// Little-endian `u16` at `off`; `nil` when out of bounds.
func oleGetU16(_ b: [UInt8], _ off: Int) -> UInt16? {
    guard off >= 0, off + 2 <= b.count else { return nil }
    return UInt16(b[off]) | UInt16(b[off + 1]) << 8
}

/// Little-endian `u32` at `off`; `nil` when out of bounds.
func oleGetU32(_ b: [UInt8], _ off: Int) -> UInt32? {
    guard off >= 0, off + 4 <= b.count else { return nil }
    return UInt32(b[off]) | UInt32(b[off + 1]) << 8
        | UInt32(b[off + 2]) << 16 | UInt32(b[off + 3]) << 24
}

/// The UTF-16LE code units of `bytes`; a trailing odd byte is dropped.
func utf16leUnits(_ bytes: [UInt8]) -> [UInt16] {
    var out = [UInt16]()
    out.reserveCapacity(bytes.count / 2)
    var i = 0
    while i + 1 < bytes.count {
        out.append(UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8)
        i += 2
    }
    return out
}

/// UTF-16LE units decoded to a String; unpaired surrogates become U+FFFD.
func utf16leString(_ bytes: [UInt8]) -> String {
    var scalars = String.UnicodeScalarView()
    scalars.reserveCapacity(bytes.count / 2)
    var units = utf16leUnits(bytes).makeIterator()
    while let u = units.next() {
        if (0xD800...0xDBFF).contains(u), let lo = units.next(),
           (0xDC00...0xDFFF).contains(lo) {
            let cp = 0x10000 + ((UInt32(u) - 0xD800) << 10) + (UInt32(lo) - 0xDC00)
            scalars.append(Unicode.Scalar(cp) ?? "\u{FFFD}")
        } else if (0xD800...0xDFFF).contains(u) {
            scalars.append("\u{FFFD}")
        } else {
            scalars.append(Unicode.Scalar(u) ?? "\u{FFFD}")
        }
    }
    return String(scalars)
}

/// Read a named stream from an OLE2 compound file. A missing stream is
/// `MissingPart`; the read is hard-capped at `maxEntryBytes` so a corrupt
/// sector chain cannot expand without bound.
func readOleStream(_ ole: OleFile, _ name: String) throws -> [UInt8] {
    do {
        let bytes = try ole.readStream(name)
        if UInt64(bytes.count) > Limits.maxEntryBytes {
            throw ConvertError.resourceLimit(
                limit: "max_entry_bytes",
                detail: "\(name) stream exceeds the read cap")
        }
        return bytes
    } catch is OleFile.OleError {
        throw ConvertError.missingPart(part: name)
    }
}

/// Raw DEFLATE inflate hard-capped at `cap` bytes of output; `nil` on
/// failure (OfficeArt metafile payloads degrade rather than fail).
func rawInflate(_ comp: [UInt8], cap: Int) -> [UInt8]? {
    guard !comp.isEmpty else { return nil }
    let outCap = cap + 1
    var out = [UInt8](repeating: 0, count: outCap)
    var produced = 0
    let inCount = uInt(min(comp.count, Int(UInt32.max)))
    var ok = false
    comp.withUnsafeBufferPointer { inBuf in
        out.withUnsafeMutableBufferPointer { outBuf in
            var stream = z_stream()
            guard inflateInit2_(&stream, -15, zlibVersion(),
                                Int32(MemoryLayout<z_stream>.size)) == Z_OK,
                  let inBase = inBuf.baseAddress else { return }
            defer { inflateEnd(&stream) }
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inBase)
            stream.avail_in = inCount
            stream.next_out = outBuf.baseAddress
            stream.avail_out = uInt(outCap)
            var status = Z_OK
            while status == Z_OK {
                status = inflate(&stream, Z_NO_FLUSH)
                if status == Z_STREAM_END || status != Z_OK { break }
            }
            produced = Int(stream.total_out)
            ok = status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR
        }
    }
    guard ok, produced <= cap else { return nil }
    return Array(out.prefix(produced))
}
