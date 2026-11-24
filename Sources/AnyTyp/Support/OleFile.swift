import Foundation

/// Read-only OLE Compound File (CFB) reader — the container behind legacy
/// `.doc`, `.ppt`, `.xls`, and encrypted OOXML packages. Port of the subset of
/// the `cfb` crate needed by the format parsers: directory walk + stream read
/// with the 4096-byte mini-stream cutoff.
///
/// Spec: [MS-CFB]. Sector size is 512 for version 3 (the only version these
/// formats use); mini sectors are 64 bytes.
struct OleFile {
    enum OleError: Error {
        case notOle
        case truncated
        case badSector(UInt32)
    }

    private let data: [UInt8]
    private let sectorSize: Int
    private let miniSectorSize = 64
    private let miniCutoff = 4096
    private let fat: [UInt32]
    private let miniFat: [UInt32]
    private let directory: [DirEntry]
    private let rootStart: UInt32
    private let rootSize: UInt64
    private let firstMiniFat: UInt32
    private let numMiniFat: UInt32
    private let firstDifat: UInt32
    private let numDifat: UInt32
    private let difat: [UInt32]

    private struct DirEntry {
        var name: String
        var objectType: UInt8 // 0 unknown, 1 storage, 2 stream, 5 root
        var left: UInt32
        var right: UInt32
        var child: UInt32
        var startSector: UInt32
        var streamSize: UInt64
    }

    init(bytes: [UInt8]) throws {
        data = bytes
        // Header must be at least one sector.
        guard bytes.count >= 512 else { throw OleError.truncated }
        let magic: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
        guard bytes.starts(with: magic) else { throw OleError.notOle }
        func ru16(_ o: Int) -> UInt16 {
            UInt16(bytes[o]) | UInt16(bytes[o + 1]) << 8
        }
        func ru32(_ o: Int) -> UInt32 {
            UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8
               | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24
        }
        func ru64(_ o: Int) -> UInt64 {
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(bytes[o + i]) << (8 * i) }
            return v
        }
        let byteOrder = ru16(0x1C)
        guard byteOrder == 0xFFFE else { throw OleError.notOle }
        let sectorShift = Int(ru16(0x1E))
        sectorSize = 1 << sectorShift
        guard sectorSize == 512 || sectorSize == 4096 else { throw OleError.truncated }
        let numFat = Int(ru32(0x2C))
        firstDifat = ru32(0x44)
        numDifat = ru32(0x48)
        firstMiniFat = ru32(0x3C)
        numMiniFat = ru32(0x40)
        rootStart = ru32(0x30)
        rootSize = ru64(0x38) // v3: high 32 bits must be 0; mask below
        _ = numFat
        // DIFAT: first 109 entries live in the header at 0x4C.
        var difatEntries: [UInt32] = []
        difatEntries.reserveCapacity(109)
        for i in 0..<109 {
            let v = ru32(0x4C + i * 4)
            if v != 0xFFFFFFFF { difatEntries.append(v) }
        }
        // Extended DIFAT sectors chain additional FAT sector lists.
        var difatSectors = difatEntries
        var cur = firstDifat
        var remaining = Int(numDifat)
        let perDifatSector = (sectorSize - 4) / 4
        while remaining > 0 && cur != 0xFFFFFFFE && cur != 0xFFFFFFFF {
            guard let sec = oleSectorBytes(data: data, sectorSize: sectorSize, sid: cur) else { throw OleError.badSector(cur) }
            for i in 0..<perDifatSector {
                let off = i * 4
                let v = UInt32(sec[off]) | UInt32(sec[off + 1]) << 8
                    | UInt32(sec[off + 2]) << 16 | UInt32(sec[off + 3]) << 24
                if v != 0xFFFFFFFF { difatSectors.append(v) }
            }
            let nextOff = perDifatSector * 4
            cur = UInt32(sec[nextOff]) | UInt32(sec[nextOff + 1]) << 8
                | UInt32(sec[nextOff + 2]) << 16 | UInt32(sec[nextOff + 3]) << 24
            remaining -= 1
        }
        difat = difatSectors
        // Read all FAT sectors.
        var fatEntries: [UInt32] = []
        fatEntries.reserveCapacity(difatSectors.count * (sectorSize / 4))
        for fatSec in difatSectors.prefix(numFat == 0 ? difatSectors.count : numFat) {
            guard let sec = oleSectorBytes(data: data, sectorSize: sectorSize, sid: fatSec) else { continue }
            for i in stride(from: 0, to: sec.count, by: 4) {
                fatEntries.append(UInt32(sec[i]) | UInt32(sec[i + 1]) << 8
                    | UInt32(sec[i + 2]) << 16 | UInt32(sec[i + 3]) << 24)
            }
        }
        fat = fatEntries
        // Directory stream.
        let dirBytes = try oleReadChain(data: data, sectorSize: sectorSize, start: rootStart, size: min(rootSize, 1 << 32), fat: fatEntries)
        var entries: [DirEntry] = []
        entries.reserveCapacity(dirBytes.count / 128)
        func du16(_ o: Int) -> UInt16 {
            UInt16(dirBytes[o]) | UInt16(dirBytes[o + 1]) << 8
        }
        func du32(_ o: Int) -> UInt32 {
            UInt32(dirBytes[o]) | UInt32(dirBytes[o + 1]) << 8
               | UInt32(dirBytes[o + 2]) << 16 | UInt32(dirBytes[o + 3]) << 24
        }
        func du64(_ o: Int) -> UInt64 {
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(dirBytes[o + i]) << (8 * i) }
            return v
        }
        for off in stride(from: 0, to: dirBytes.count - 127, by: 128) {
            let nameLen = Int(du16(off + 64))
            var name = ""
            if nameLen >= 2 {
                let chars = nameLen - 2
                var s = ""
                var i = 0
                while i < chars {
                    let lo = dirBytes[off + i]
                    let hi = dirBytes[off + i + 1]
                    let cp = UInt32(lo) | UInt32(hi) << 8
                    if cp == 0 { break }
                    s.unicodeScalars.append(UnicodeScalar(cp) ?? UnicodeScalar(0xFFFD)!)
                    i += 2
                }
                name = s
            }
            let objType = dirBytes[off + 66]
            let child = du32(off + 76)
            let startSector = du32(off + 116)
            let size = du64(off + 120) & 0xFFFFFFFF // v3: 32-bit size
            entries.append(DirEntry(
                name: name,
                objectType: objType,
                left: du32(off + 68),
                right: du32(off + 72),
                child: child,
                startSector: startSector,
                streamSize: size
            ))
        }
        directory = entries
        // Mini FAT + mini stream (root entry's stream).
        if numMiniFat > 0, firstMiniFat != 0xFFFFFFFE {
            let mfBytes = try oleReadChain(data: data, sectorSize: sectorSize, start: firstMiniFat, size: UInt64(numMiniFat) * UInt64(sectorSize), fat: fatEntries)
            var mf: [UInt32] = []
            mf.reserveCapacity(mfBytes.count / 4)
            for i in stride(from: 0, to: mfBytes.count - 3, by: 4) {
                mf.append(UInt32(mfBytes[i]) | UInt32(mfBytes[i + 1]) << 8
                    | UInt32(mfBytes[i + 2]) << 16 | UInt32(mfBytes[i + 3]) << 24)
            }
            miniFat = mf
        } else {
            miniFat = []
        }
    }

    // MARK: - Public API

    /// Does a stream or storage with this (top-level or nested) path exist?
    func exists(_ path: String) -> Bool {
        findEntry(path.split(separator: "/").map(String.init)) != nil
    }

    /// Read a stream by slash-separated path. Returns nil for storages.
    func readStream(_ path: String) throws -> [UInt8] {
        guard let entry = findEntry(path.split(separator: "/").map(String.init)),
              entry.objectType == 2 else {
            throw OleError.truncated
        }
        return try readEntry(entry)
    }

    /// List top-level storage/stream names.
    func topLevelNames() -> [String] {
        directory.filter { $0.objectType == 1 || $0.objectType == 2 }
            .map(\.name).filter { !$0.isEmpty }
    }

    // MARK: - Internals

    /// Offset of a sector's bytes in the file (sector 0 starts after header).
    private func sectorOffset(_ sid: UInt32) -> Int? {
        let off = (Int(sid) + 1) * sectorSize
        return off <= data.count ? off : nil
    }

    private func sectorBytes(_ sid: UInt32) -> [UInt8]? {
        oleSectorBytes(data: data, sectorSize: sectorSize, sid: sid)
    }

    /// Follow a FAT chain collecting bytes, capped by `size`.
    private func readChain(start: UInt32, size: UInt64, fat: [UInt32]) throws -> [UInt8] {
        try oleReadChain(data: data, sectorSize: sectorSize, start: start, size: size, fat: fat)
    }

    /// Read one directory entry's stream (mini or regular chain).
    private func readEntry(_ entry: DirEntry) throws -> [UInt8] {
        let size = Int(entry.streamSize)
        if size >= miniCutoff || entry.startSector == 0xFFFFFFFE {
            return try readChain(start: entry.startSector, size: entry.streamSize, fat: fat)
        }
        // Mini stream: sectors within the root entry's stream.
        guard !miniFat.isEmpty, let root = directory.first(where: { $0.objectType == 5 }) else {
            return try readChain(start: entry.startSector, size: entry.streamSize, fat: fat)
        }
        let miniStream = try readChain(start: root.startSector, size: root.streamSize, fat: fat)
        var out: [UInt8] = []
        out.reserveCapacity(size)
        var sid = entry.startSector
        var guardCount = 0
        while sid != 0xFFFFFFFE && sid != 0xFFFFFFFF {
            let off = Int(sid) * miniSectorSize
            if off + miniSectorSize <= miniStream.count {
                out.append(contentsOf: miniStream[off..<(off + miniSectorSize)])
            }
            if out.count >= size { break }
            guard Int(sid) < miniFat.count else { break }
            sid = miniFat[Int(sid)]
            guardCount += 1
            if guardCount > miniFat.count + 1 { break }
        }
        if out.count > size { out = Array(out.prefix(size)) }
        return out
    }

    /// Walk the directory tree level by level for `components`.
    private func findEntry(_ components: [String]) -> DirEntry? {
        guard let root = directory.first(where: { $0.objectType == 5 }) else { return nil }
        var children = root.child
        for (level, comp) in components.enumerated() {
            guard let entry = findInTree(root: children, name: comp) else { return nil }
            if level == components.count - 1 { return entry }
            guard entry.objectType == 1 else { return nil }
            children = entry.child
        }
        return nil
    }

    /// DFS over one level of the directory red-black tree (left/right
    /// siblings only — `child` links belong to the next path level).
    private func findInTree(root: UInt32, name: String) -> DirEntry? {
        var stack: [UInt32] = [root]
        var visited: Set<UInt32> = []
        while let cur = stack.popLast() {
            guard cur != 0xFFFFFFFF, cur != 0xFFFFFFFE,
                  Int(cur) < directory.count, visited.insert(cur).inserted else {
                continue
            }
            let e = directory[Int(cur)]
            if e.name.caseInsensitiveCompare(name) == .orderedSame { return e }
            stack.append(e.left)
            stack.append(e.right)
        }
        return nil
    }
}


// MARK: - Free helpers (usable before full init)

private func oleSectorBytes(data: [UInt8], sectorSize: Int, sid: UInt32) -> [UInt8]? {
    let off = (Int(sid) + 1) * sectorSize
    guard off + sectorSize <= data.count else { return nil }
    return Array(data[off..<(off + sectorSize)])
}

private func oleReadChain(data: [UInt8], sectorSize: Int, start: UInt32,
                          size: UInt64, fat: [UInt32]) throws -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(Int(min(size, 1 << 24)))
    var sid = start
    var guardCount = 0
    while sid != 0xFFFFFFFE && sid != 0xFFFFFFFF {
        guard Int(sid) < fat.count else { throw OleFile.OleError.badSector(sid) }
        guard let sec = oleSectorBytes(data: data, sectorSize: sectorSize, sid: sid)
        else { throw OleFile.OleError.badSector(sid) }
        out.append(contentsOf: sec)
        if UInt64(out.count) >= size { break }
        sid = fat[Int(sid)]
        guardCount += 1
        if guardCount > fat.count + 1 { break }
    }
    if out.count > size { out = Array(out.prefix(Int(size))) }
    return out
}
