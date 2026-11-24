import Foundation

/// OfficeArt (MS-ODRAW) blip extraction shared by the legacy binary
/// formats (port of `shared/officeart.rs`): DOC picture data (`PICF` +
/// OfficeArt records in the Data stream) and the PPT `Pictures` stream (a
/// sequence of BStore file blocks). Only the picture payloads are
/// extracted; drawing geometry is out of scope.

/// (verAndInstance, recType, body) of the OfficeArt record at `off` — the
/// same 8-byte header the PPT record stream uses.
func officeArtRecordAt(_ data: [UInt8], _ off: Int) -> (UInt16, UInt16, ArraySlice<UInt8>)? {
    guard off >= 0, off + 8 <= data.count else { return nil }
    let verInst = UInt16(data[off]) | UInt16(data[off + 1]) << 8
    let recType = UInt16(data[off + 2]) | UInt16(data[off + 3]) << 8
    let len = Int(UInt32(data[off + 4]) | UInt32(data[off + 5]) << 8
        | UInt32(data[off + 6]) << 16 | UInt32(data[off + 7]) << 24)
    guard off + 8 + len <= data.count else { return nil }
    return (verInst, recType, data[(off + 8)..<(off + 8 + len)])
}

/// An extracted picture payload.
struct OfficeArtBlip {
    var mediaType: String
    var ext: String
    var bytes: [UInt8]
}

/// Decode one blip record (`recType` 0xF01A–0xF01F). Metafile blips may
/// be deflate-compressed; the output is bounded by the declared
/// uncompressed size, capped at `maxBytes`.
func officeArtDecodeBlip(
    _ verInst: UInt16, _ recType: UInt16, _ body: [UInt8], maxBytes: Int
) -> OfficeArtBlip? {
    let instance = verInst >> 4
    switch recType {
    // Bitmap blips: rgbUid1 (16), + rgbUid2 (16) for the doubled
    // instance, then the picture bytes, with one tag byte first.
    case 0xF01D, 0xF01E:
        let doubled = [0x46B, 0x6E3, 0x6E1].contains(instance)
        let start = (doubled ? 32 : 16) + 1
        guard start <= body.count else { return nil }
        let (mediaType, ext) = recType == 0xF01D
            ? ("image/jpeg", "jpg") : ("image/png", "png")
        return OfficeArtBlip(
            mediaType: mediaType, ext: ext, bytes: Array(body[start...]))
    // Metafile blips: rgbUid (16/32), then a 34-byte metafile header
    // (cbSize, bounds, ptSize, cbSave, compression, filter).
    case 0xF01A, 0xF01B:
        let doubled = [0x3D5, 0x217].contains(instance)
        let header = doubled ? 32 : 16
        guard header + 34 <= body.count else { return nil }
        let headerAndData = Array(body[header...])
        let cbSize = Int(oleGetU32(headerAndData, 0) ?? 0)
        let compression = headerAndData[32]
        let data = Array(headerAndData[34...])
        let (mediaType, ext) = recType == 0xF01A
            ? ("image/emf", "emf") : ("image/wmf", "wmf")
        let bytes: [UInt8]
        if compression == 0x00 {
            // 0x00 = deflate-compressed; 0xFE = uncompressed.
            let limit = min(cbSize, maxBytes)
            guard let inflated = rawInflate(data, cap: limit) else { return nil }
            bytes = inflated
        } else {
            bytes = data
        }
        return OfficeArtBlip(mediaType: mediaType, ext: ext, bytes: bytes)
    default:
        return nil
    }
}

/// Offset of the embedded blip record inside an FBSE (0xF007) body: the
/// 36-byte header plus the entry's name.
func officeArtFbseBlipOffset(_ body: [UInt8]) -> Int? {
    guard body.count > 33 else { return nil }
    return 36 + Int(body[33])
}

/// Decode the blip embedded in an FBSE (0xF007) record body, if present.
func officeArtFbseBlip(_ body: [UInt8], maxBytes: Int) -> OfficeArtBlip? {
    guard let offset = officeArtFbseBlipOffset(body),
          offset <= body.count,
          let (verInst, recType, blipBody) = officeArtRecordAt(body, offset) else {
        return nil
    }
    return officeArtDecodeBlip(verInst, recType, Array(blipBody), maxBytes: maxBytes)
}

/// Find and decode the first blip in a run of OfficeArt records (a
/// `Pictures` stream block sequence, or an inline shape container),
/// descending into containers. Bounded traversal: record counts and
/// nesting beyond any real drawing abort the search (port of
/// `shared/officeart.rs::first_blip`).
func officeArtFirstBlip(_ data: [UInt8], maxBytes: Int) -> OfficeArtBlip? {
    // (cursor, end) ranges into `data`.
    var stack: [(Int, Int)] = [(0, data.count)]
    var visited = 0
    while let (cursor, end) = stack.last {
        if cursor >= end {
            stack.removeLast()
            continue
        }
        guard let (verInst, recType, body) =
            officeArtRecordAt(Array(data[..<end]), cursor) else {
            stack.removeLast()
            continue
        }
        let bodyStart = cursor + 8
        let bodyEnd = bodyStart + body.count
        stack[stack.count - 1].0 = bodyEnd
        visited += 1
        if visited > 10_000 || stack.count > 16 { return nil }
        if let blip = officeArtDecodeBlip(verInst, recType, Array(body), maxBytes: maxBytes) {
            return blip
        }
        if recType == 0xF007 {
            let innerStart = bodyStart + (officeArtFbseBlipOffset(Array(body)) ?? body.count)
            if innerStart < bodyEnd {
                stack.append((innerStart, bodyEnd))
            }
            continue
        }
        if verInst & 0xF == 0xF {
            stack.append((bodyStart, bodyEnd))
        }
    }
    return nil
}
