import CZlib
import Foundation

/// ZIP archive access with decompression limits.
///
/// Reads the central directory, then each entry's local header on demand.
/// Stored (method 0) and deflated (method 8) entries are supported; the
/// inflated output is hard-capped by the same budgets the Rust implementation
/// enforced (`Limits.maxEntryBytes` / `maxTotalBytes`).
final class ZipArchive {
    struct Entry {
        var name: String
        var method: UInt16
        var compressedSize: UInt64
        var uncompressedSize: UInt64
        var localHeaderOffset: UInt64
        var flags: UInt16
    }

    private let bytes: [UInt8]
    private var entries: [String: Entry] = [:]

    init(bytes: [UInt8]) throws {
        self.bytes = bytes
        try readCentralDirectory()
        if entries.count > Limits.maxEntryCount {
            throw ConvertError.resourceLimit(
                limit: "max_entry_count",
                detail: "archive contains \(entries.count) entries"
            )
        }
    }

    var count: Int { entries.count }

    func entry(named name: String) -> Entry? {
        entries[name]
    }

    func hasEntry(_ name: String) -> Bool {
        entries[name] != nil
    }

    /// Decompressed bytes of one entry, capped by `cap` (the smaller of the
    /// per-entry and remaining-total budgets). Throws `resourceLimit` when
    /// the entry exceeds the cap.
    func read(_ entry: Entry, cap: UInt64) throws -> [UInt8] {
        if entry.flags & 0x1 != 0 {
            throw ConvertError.encrypted
        }
        let dataStart = try localDataOffset(entry)
        let compLen = Int(entry.compressedSize)
        guard dataStart + compLen <= bytes.count else {
            throw ConvertError.malformedPart(
                entry.name,
                "archive entry extends past end of file"
            )
        }
        let comp = Array(bytes[dataStart..<(dataStart + compLen)])

        switch entry.method {
        case 0: // stored
            if UInt64(comp.count) > cap {
                throw zipCapExceeded(entry.name, cap: cap)
            }
            return comp
        case 8: // deflate
            return try inflate(comp, expected: entry.uncompressedSize, cap: cap, name: entry.name)
        default:
            throw ConvertError.malformedPart(
                entry.name,
                "unsupported compression method \(entry.method)"
            )
        }
    }

    /// Offset of an entry's compressed data: parse its local header.
    private func localDataOffset(_ entry: Entry) throws -> Int {
        let off = Int(entry.localHeaderOffset)
        guard off + 30 <= bytes.count else {
            throw ConvertError.malformedPart(entry.name, "local header out of range")
        }
        func u16(_ p: Int) -> Int { Int(bytes[p]) | Int(bytes[p + 1]) << 8 }
        func u32(_ p: Int) -> UInt32 {
            UInt32(bytes[p]) | UInt32(bytes[p + 1]) << 8 | UInt32(bytes[p + 2]) << 16 |
                UInt32(bytes[p + 3]) << 24
        }
        guard u32(off) == 0x04034b50 else {
            throw ConvertError.malformedPart(entry.name, "bad local header signature")
        }
        let nameLen = u16(off + 26)
        let extraLen = u16(off + 28)
        let dataStart = off + 30 + nameLen + extraLen
        guard dataStart <= bytes.count else {
            throw ConvertError.malformedPart(entry.name, "local header out of range")
        }
        return dataStart
    }

    // MARK: - Central directory

    private func readCentralDirectory() throws {
        // Locate EOCD: signature 0x06054b50 within the last 64KiB+22 bytes.
        let minPos = max(0, bytes.count - (65_536 + 22))
        var eocd = -1
        var i = bytes.count - 22
        while i >= minPos {
            if u32le(i) == 0x06054b50 {
                eocd = i
                break
            }
            i -= 1
        }
        guard eocd >= 0 else {
            throw ConvertError.malformed("not a readable zip archive: end of central directory not found")
        }
        func u16le(_ p: Int) -> Int { Int(bytes[p]) | Int(bytes[p + 1]) << 8 }
        let entryCount = u16le(eocd + 10)
        let cdOffset = UInt64(u32le(eocd + 16))
        let cdSize = UInt64(u32le(eocd + 12))
        _ = cdSize

        var pos = Int(cdOffset)
        for _ in 0..<entryCount {
            guard pos + 46 <= bytes.count, u32le(pos) == 0x02014b50 else {
                throw ConvertError.malformed("corrupt zip central directory")
            }
            let flags = UInt16(u16le(pos + 8))
            let method = UInt16(u16le(pos + 10))
            var compSize = UInt64(u32le(pos + 20))
            var uncompSize = UInt64(u32le(pos + 24))
            let nameLen = u16le(pos + 28)
            let extraLen = u16le(pos + 30)
            let commentLen = u16le(pos + 32)
            var localOffset = UInt64(u32le(pos + 42))
            let nameStart = pos + 46
            guard nameStart + nameLen <= bytes.count else {
                throw ConvertError.malformed("corrupt zip central directory")
            }
            let name = String(decoding: bytes[nameStart..<(nameStart + nameLen)], as: UTF8.self)

            // ZIP64 extra field 0x0001 fills in 0xFFFFFFFF placeholders.
            let extraStart = nameStart + nameLen
            if compSize == 0xFFFFFFFF || uncompSize == 0xFFFFFFFF || localOffset == 0xFFFFFFFF {
                var ep = extraStart
                let extraEnd = extraStart + extraLen
                while ep + 4 <= extraEnd {
                    let tag = u16le(ep)
                    let size = u16le(ep + 2)
                    let dataStart = ep + 4
                    guard dataStart + size <= extraEnd else { break }
                    if tag == 0x0001 {
                        var q = dataStart
                        if uncompSize == 0xFFFFFFFF, q + 8 <= dataStart + size {
                            uncompSize = u64le(q); q += 8
                        }
                        if compSize == 0xFFFFFFFF, q + 8 <= dataStart + size {
                            compSize = u64le(q); q += 8
                        }
                        if localOffset == 0xFFFFFFFF, q + 8 <= dataStart + size {
                            localOffset = u64le(q); q += 8
                        }
                        break
                    }
                    ep = dataStart + size
                }
            }

            // Skip directory entries (names ending in '/').
            if !name.hasSuffix("/") {
                entries[name] = Entry(
                    name: name,
                    method: method,
                    compressedSize: compSize,
                    uncompressedSize: uncompSize,
                    localHeaderOffset: localOffset,
                    flags: flags
                )
            }
            pos = nameStart + nameLen + extraLen + commentLen
        }
    }

    private func u32le(_ p: Int) -> UInt32 {
        UInt32(bytes[p]) | UInt32(bytes[p + 1]) << 8 | UInt32(bytes[p + 2]) << 16 |
            UInt32(bytes[p + 3]) << 24
    }

    private func u64le(_ p: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<8 {
            v |= UInt64(bytes[p + k]) << (8 * k)
        }
        return v
    }
}

// MARK: - Raw DEFLATE via zlib

/// Inflate a raw DEFLATE stream (no zlib header), hard-capped at `cap` bytes
/// of output. `expected` is the declared uncompressed size.
private func inflate(_ comp: [UInt8], expected: UInt64, cap: UInt64, name: String) throws -> [UInt8] {
    guard !comp.isEmpty else {
        throw ConvertError.malformedPart(name, "empty deflate stream")
    }
    // Output buffer: cap + 1 so exceeding the cap is detectable.
    let outCap = Int(cap) + 1
    var out = [UInt8](repeating: 0, count: outCap)
    var totalOut = 0
    var streamStatus: Int32 = Z_OK

    let inCount = uInt(min(comp.count, Int(UInt32.max)))
    comp.withUnsafeBufferPointer { inBuf in
        out.withUnsafeMutableBufferPointer { outBuf in
            var stream = z_stream()
            let initResult = inflateInit2_(&stream, -15, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
            guard initResult == Z_OK, let inBase = inBuf.baseAddress else {
                streamStatus = initResult == Z_OK ? Z_MEM_ERROR : initResult
                return
            }
            defer { inflateEnd(&stream) }

            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inBase)
            stream.avail_in = inCount
            stream.next_out = outBuf.baseAddress
            stream.avail_out = uInt(outCap)

            var status = Z_OK
            while status == Z_OK {
                status = inflate(&stream, Z_NO_FLUSH)
                if status == Z_STREAM_END { break }
                if status != Z_OK && status != Z_BUF_ERROR { break }
                // Z_BUF_ERROR with no progress means truncated stream.
                if status == Z_BUF_ERROR, stream.avail_in == 0, stream.avail_out > 0 {
                    break
                }
            }
            totalOut = Int(stream.total_out)
            streamStatus = status
        }
    }

    if totalOut > Int(cap) {
        throw zipCapExceeded(name, cap: cap)
    }
    if streamStatus != Z_OK && streamStatus != Z_STREAM_END && streamStatus != Z_BUF_ERROR {
        throw ConvertError.malformedPart(name, "inflate failed with status \(streamStatus)")
    }
    if UInt64(totalOut) != expected {
        // Lenient: trust the stream over the declared size when within cap.
    }
    return Array(out.prefix(totalOut))
}

/// The tighter of the per-entry and remaining-total budgets was exceeded.
private func zipCapExceeded(_ name: String, cap: UInt64) -> ConvertError {
    if cap < Limits.maxEntryBytes {
        return .resourceLimit(
            limit: "max_total_bytes",
            detail: "\(name) exceeds the archive's remaining decompression budget"
        )
    }
    return .resourceLimit(
        limit: "max_entry_bytes",
        detail: "\(name) exceeds the decompression cap"
    )
}
