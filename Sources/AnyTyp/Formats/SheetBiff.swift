import Foundation

/// Binary spreadsheet readers (port of `sheet/xls.rs` + `sheet/xlsb.rs`):
/// BIFF8/BIFF5 record streams in the OLE `Workbook`/`Book` stream (.xls),
/// and MS-XLSB 7-bit-varint record streams in `xl/*.bin` parts (.xlsb).
enum SheetBiff {
    static let maxRows = SheetXlsx.maxRows
    static let maxCols = SheetXlsx.maxCols

    // MARK: - Shared BIFF helpers

    /// Decode an RK value, the packed number both binary containers use.
    /// Bit 0 asks for a hundredth; bit 1 selects an integer over the high
    /// 30 bits of a double.
    static func rkNumber(_ rk: UInt32) -> Double {
        let value: Double
        if rk & 0x02 != 0 {
            value = Double(Int32(bitPattern: rk) >> 2)
        } else {
            value = Double(bitPattern: UInt64(rk & 0xFFFF_FFFC) << 32)
        }
        return rk & 0x01 != 0 ? value / 100.0 : value
    }

    /// The literal an error code displays as.
    static func errorLiteral(_ code: UInt8) -> String? {
        switch code {
        case 0x00: return "#NULL!"
        case 0x07: return "#DIV/0!"
        case 0x0F: return "#VALUE!"
        case 0x17: return "#REF!"
        case 0x1D: return "#NAME?"
        case 0x24: return "#NUM!"
        case 0x2A: return "#N/A"
        case 0x2B: return "#GETTING_DATA"
        default: return nil
        }
    }

    /// Record only non-empty cell text, like the xlsx reader.
    static func put(_ out: inout SheetContent, _ row: UInt32, _ col: UInt32, _ text: String) {
        if !text.isEmpty {
            out.cells[SheetCellKey(row: row, col: col)] = text
        }
    }

    // MARK: - .xls (BIFF)

    private static let bof: UInt16 = 0x0809
    private static let eofRec: UInt16 = 0x000A
    private static let filepass: UInt16 = 0x002F
    private static let codepage: UInt16 = 0x0042
    private static let datemode: UInt16 = 0x0022
    private static let boundsheet: UInt16 = 0x0085
    private static let sst: UInt16 = 0x00FC
    private static let continueRec: UInt16 = 0x003C
    private static let formatRec: UInt16 = 0x041E
    private static let xfRec: UInt16 = 0x00E0
    private static let rowRec: UInt16 = 0x0208
    private static let colinfo: UInt16 = 0x007D
    private static let mergedcells: UInt16 = 0x00E5
    private static let labelsst: UInt16 = 0x00FD
    private static let labelRec: UInt16 = 0x0204
    private static let rstring: UInt16 = 0x00D6
    private static let numberRec: UInt16 = 0x0203
    private static let rkRec: UInt16 = 0x027E
    private static let mulrk: UInt16 = 0x00BD
    private static let boolerr: UInt16 = 0x0205
    private static let formulaRec: UInt16 = 0x0006
    private static let stringRec: UInt16 = 0x0207
    private static let msodrawing: UInt16 = 0x00EC
    private static let objRec: UInt16 = 0x005D
    private static let txoRec: UInt16 = 0x01B6
    private static let worksheetSubstream: UInt16 = 0x0010

    /// The record at `pos`: (type, body range, position after it).
    private static func recordAt(_ data: [UInt8], _ pos: Int) -> (UInt16, Range<Int>, Int)? {
        guard let t = oleGetU16(data, pos),
              let len = oleGetU16(data, pos + 2) else { return nil }
        let bodyAt = pos + 4
        guard bodyAt + Int(len) <= data.count else { return nil }
        return (t, bodyAt..<(bodyAt + Int(len)), bodyAt + Int(len))
    }

    /// A record iterator charging the stream-wide record budget.
    private struct RecordIter {
        let data: [UInt8]
        var pos: Int
        var seen: UInt64 = 0

        mutating func next() throws -> (UInt16, [UInt8], Int)? {
            guard pos < data.count else { return nil }
            guard let (t, range, next) = SheetBiff.recordAt(data, pos) else {
                if pos < data.count {
                    AnyTypLog.warn("workbook stream ends mid-record at byte \(pos); output may be partial")
                }
                return nil
            }
            seen += 1
            if seen > Limits.maxRecords {
                throw ConvertError.resourceLimit(
                    limit: "max_records",
                    detail: "workbook stream exceeds \(Limits.maxRecords) records")
            }
            pos = next
            return (t, Array(data[range]), next)
        }
    }

    /// The record body plus following CONTINUE bodies. The iterator is
    /// left positioned at the first non-CONTINUE record.
    private static func continued(
        _ body: [UInt8], _ iter: inout RecordIter
    ) throws -> [[UInt8]] {
        var segs = [body]
        while true {
            let mark = iter.pos
            guard let (t, b, _) = try iter.next() else { break }
            if t != continueRec {
                iter.pos = mark
                iter.seen -= 1
                break
            }
            segs.append(b)
        }
        return segs
    }

    /// Reader over a record's segments. Fixed fields never straddle a
    /// segment boundary; only string character data crosses, re-reading
    /// the option-flags byte at each boundary.
    private struct SegReader {
        let segs: [[UInt8]]
        var seg = 0
        var off = 0

        init(_ segs: [[UInt8]]) { self.segs = segs }

        mutating func normalize() {
            while seg < segs.count && inSeg() == 0 {
                seg += 1
                off = 0
            }
        }

        mutating func nextSeg() -> Bool {
            if seg + 1 < segs.count {
                seg += 1
                off = 0
                return true
            }
            return false
        }

        func inSeg() -> Int {
            seg < segs.count ? segs[seg].count - off : 0
        }

        mutating func bytes(_ n: Int) -> [UInt8]? {
            normalize()
            guard seg < segs.count, off + n <= segs[seg].count else { return nil }
            let out = Array(segs[seg][off..<(off + n)])
            off += n
            return out
        }

        mutating func u8() -> UInt8? { bytes(1).map { $0[0] } }
        mutating func u16() -> UInt16? {
            bytes(2).flatMap { oleGetU16($0, 0) }
        }
        mutating func u32() -> UInt32? {
            bytes(4).flatMap { oleGetU32($0, 0) }
        }
        mutating func skip(_ n: Int) -> Bool {
            var remaining = n
            while remaining > 0 {
                normalize()
                let step = min(inSeg(), remaining)
                if step == 0 { return false }
                off += step
                remaining -= step
            }
            return true
        }
    }

    /// A BIFF8 Unicode string (option flags: bit0 wide, bit3 rich runs,
    /// bit2 ext phonetic). Character data may continue into following
    /// segments; at every boundary the flags byte is repeated.
    private static func readBiff8String(
        _ r: inout SegReader, short: Bool, rich: Bool
    ) -> String? {
        guard let cch = short ? r.u8().map(Int.init) : r.u16().map(Int.init),
              let flags = r.u8() else { return nil }
        var wide = flags & 0x01 != 0
        let runs = rich && flags & 0x08 != 0 ? Int(r.u16() ?? 0) : 0
        let ext = rich && flags & 0x04 != 0 ? Int(r.u32() ?? 0) : 0
        var units: [UInt16] = []
        var remaining = cch
        while remaining > 0 {
            if r.inSeg() == 0 {
                guard r.nextSeg(), let f = r.u8() else { return nil }
                wide = f & 0x01 != 0
            }
            let unit = wide ? 2 : 1
            let take = min(r.inSeg() / unit, remaining)
            if take == 0 { return nil }
            guard let bytes = r.bytes(take * unit) else { return nil }
            if wide {
                units.append(contentsOf: utf16leUnits(bytes))
            } else {
                units.append(contentsOf: bytes.map { UInt16($0) })
            }
            remaining -= take
        }
        _ = r.skip(runs * 4) && r.skip(ext)
        return utf16String(units)
    }

    /// UTF-16 code units to String with unpaired surrogates -> U+FFFD.
    private static func utf16String(_ units: [UInt16]) -> String {
        var scalars = String.UnicodeScalarView()
        var i = 0
        while i < units.count {
            let u = units[i]
            if (0xD800...0xDBFF).contains(u), i + 1 < units.count,
               (0xDC00...0xDFFF).contains(units[i + 1]) {
                let cp = 0x10000 + ((UInt32(u) - 0xD800) << 10) + (UInt32(units[i + 1]) - 0xDC00)
                scalars.append(Unicode.Scalar(cp) ?? "\u{FFFD}")
                i += 2
            } else if (0xD800...0xDFFF).contains(u) {
                scalars.append("\u{FFFD}")
                i += 1
            } else {
                scalars.append(Unicode.Scalar(u) ?? "\u{FFFD}")
                i += 1
            }
        }
        return String(scalars)
    }

    /// A BIFF5/BIFF7 byte string decoded per the workbook's CODEPAGE.
    private static func readByteString(
        _ r: inout SegReader, short: Bool, encoding: String.Encoding
    ) -> String? {
        guard let cch = short ? r.u8().map(Int.init) : r.u16().map(Int.init) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(cch)
        var remaining = cch
        while remaining > 0 {
            r.normalize()
            let take = min(r.inSeg(), remaining)
            if take == 0 { return nil }
            guard let b = r.bytes(take) else { return nil }
            bytes.append(contentsOf: b)
            remaining -= take
        }
        return String(bytes: bytes, encoding: encoding)
            ?? String(bytes: bytes, encoding: .windowsCP1252)
    }

    /// ANSI code page from the CODEPAGE record (BIFF5 byte strings only;
    /// BIFF8 strings carry their own encoding flag). Encodings without a
    /// Foundation mapping degrade to windows-1252.
    private static func biffEncoding(_ cp: UInt16) -> String.Encoding {
        switch cp {
        case 932: return .shiftJIS
        case 936, 949, 950: return .windowsCP1252
        case 1250: return .windowsCP1250
        case 1251: return .windowsCP1251
        case 1252, 0: return .windowsCP1252
        case 1253: return .windowsCP1253
        case 1254: return .windowsCP1254
        case 1257, 1258: return .windowsCP1252
        default: return .windowsCP1252
        }
    }

    private struct BoundSheet {
        var name: String
        var offset: Int
        var visible: Bool
    }

    private struct Globals {
        var biff8 = false
        var date1904 = false
        var encoding = String.Encoding.windowsCP1252
        var sst: [String] = []
        var xfs: [SheetCellFormat] = []
        var sheets: [BoundSheet] = []

        func format(_ ixfe: UInt16) -> SheetCellFormat {
            xfs.indices.contains(Int(ixfe)) ? xfs[Int(ixfe)] : .general
        }

        func readString(_ r: inout SegReader, short: Bool) -> String? {
            if biff8 {
                return readBiff8String(&r, short: short, rich: false)
            }
            return readByteString(&r, short: short, encoding: encoding)
        }
    }

    static func parseXls(_ bytes: [UInt8]) throws -> AnyTypDocument {
        guard let ole = try? OleFile(bytes: bytes) else {
            throw ConvertError.malformed(part: nil, detail: "not an OLE2 compound file")
        }
        // The BIFF stream: `Workbook` (BIFF8) or `Book` (older BIFF).
        var data: [UInt8]?
        for name in ["Workbook", "Book"] where ole.exists(name) {
            data = try? readOleStream(ole, name)
            if data != nil { break }
        }
        guard let data else {
            AnyTypLog.warn("OLE streams: \(ole.topLevelNames())")
            throw ConvertError.missingPart(part: "Workbook")
        }
        var iter = RecordIter(data: data, pos: 0)
        guard let (t0, body0, _) = try iter.next(), t0 == bof else {
            throw ConvertError.malformed(
                part: nil, detail: "workbook stream does not start with a BOF record")
        }
        var globals = Globals()
        globals.biff8 = oleGetU16(body0, 0) == 0x0600
        var formats: [UInt32: String] = [:]
        var xfIfmts: [UInt16] = []
        var depth = 1
        globalsLoop: while let (t, body, _) = try iter.next() {
            switch t {
            case bof:
                depth += 1
            case eofRec:
                if depth == 1 { break globalsLoop }
                depth -= 1
            default:
                if depth > 1 { continue }
                switch t {
                case filepass:
                    throw ConvertError.encrypted
                case codepage:
                    if let cp = oleGetU16(body, 0) { globals.encoding = biffEncoding(cp) }
                case datemode:
                    globals.date1904 = oleGetU16(body, 0) == 1
                case boundsheet:
                    if let sheet = readBoundsheet(body, globals: globals) {
                        globals.sheets.append(sheet)
                    }
                case formatRec:
                    guard let ifmt = oleGetU16(body, 0) else { continue }
                    var r = SegReader([Array(body[2...])])
                    // BIFF5 FORMAT carries a one-byte length, BIFF8 two.
                    if let code = globals.readString(&r, short: !globals.biff8) {
                        formats[UInt32(ifmt)] = code
                    }
                case xfRec:
                    if xfIfmts.count <= Int(UInt16.max),
                       let ifmt = oleGetU16(body, 2) {
                        xfIfmts.append(ifmt)
                    }
                case sst where globals.biff8:
                    globals.sst = readSst(try continued(body, &iter))
                default: break
                }
            }
        }
        // Resolve formats after the pass: FORMAT records are unordered
        // relative to the XFs that reference them.
        var cache: [UInt16: SheetCellFormat] = [:]
        globals.xfs = xfIfmts.map { ifmt in
            if let hit = cache[ifmt] { return hit }
            let fmt = SheetXlsx.resolveFormat(UInt32(ifmt), custom: formats)
            cache[ifmt] = fmt
            return fmt
        }

        let visible = globals.sheets.filter { $0.visible }
        let multiSheet = visible.count > 1
        var doc = AnyTypDocument()
        var failed = 0
        var slots: UInt64 = 0
        for sheet in visible {
            guard let content = try readSheetXls(
                data, globals: globals, offset: sheet.offset
            ) else {
                AnyTypLog.warn("skipping unreadable sheet \(sheet.name.debugDescription)")
                failed += 1
                continue
            }
            guard let table = try sheetBuildTable(content, slots: &slots) else { continue }
            if multiSheet {
                doc.blocks.append(.heading(
                    level: 2, anchor: nil,
                    content: [.text(sheet.name, style: .plain)]))
            }
            doc.blocks.append(.table(table))
        }
        if !visible.isEmpty && failed == visible.count {
            throw ConvertError.malformed(
                part: nil, detail: "no sheet in the workbook could be read")
        }
        return doc
    }

    /// BOUNDSHEET: substream offset, hidden state, sheet type, name.
    /// Chart/macro sheets stay listed (their substreams fail the worksheet
    /// check); VBA modules are dropped.
    private static func readBoundsheet(_ body: [UInt8], globals: Globals) -> BoundSheet? {
        guard let offset = oleGetU32(body, 0), body.count > 6 else { return nil }
        let stateByte = body[4], typeByte = body[5]
        if typeByte == 0x06 { return nil }
        var r = SegReader([Array(body[6...])])
        guard let name = globals.readString(&r, short: true) else { return nil }
        return BoundSheet(
            name: SharedText.clean(name), offset: Int(offset), visible: stateByte & 0x03 == 0)
    }

    /// The shared string table; a malformed tail keeps entries read so far.
    private static func readSst(_ segs: [[UInt8]]) -> [String] {
        var r = SegReader(segs)
        guard let _ = r.u32(), let unique = r.u32() else { return [] }
        var out: [String] = []
        while out.count < Int(unique) {
            guard let text = readBiff8String(&r, short: false, rich: true) else {
                if out.count < Int(unique) {
                    AnyTypLog.debug("shared string table truncated at entry \(out.count)")
                }
                break
            }
            out.append(SharedText.clean(text))
        }
        return out
    }

    /// A cell record's leading (row, column, ixfe).
    private static func cellRef(_ body: [UInt8]) -> (UInt32, UInt32, UInt16)? {
        guard let row = oleGetU16(body, 0), let col = oleGetU16(body, 2),
              let ixfe = oleGetU16(body, 4), UInt32(col) < maxCols else { return nil }
        return (UInt32(row), UInt32(col), ixfe)
    }

    private static func getF64(_ body: [UInt8], _ off: Int) -> Double? {
        guard off + 8 <= body.count else { return nil }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(body[off + i]) << (8 * i) }
        return Double(bitPattern: v)
    }

    private static func readSheetXls(
        _ data: [UInt8], globals: Globals, offset: Int
    ) throws -> SheetContent? {
        guard let (t0, bodyRange, pos0) = SheetBiff.recordAt(data, offset), t0 == bof else {
            return nil
        }
        let body0 = Array(data[bodyRange])
        guard body0.count >= 4,
              oleGetU16(Array(body0[2...4]), 0) == worksheetSubstream else {
            return nil
        }
        var iter2 = RecordIter(data: data, pos: pos0)
        var out = SheetContent()
        var depth = 1
        var pending: (UInt32, UInt32, UInt16)? = nil
        var shape: (anchor: (UInt32, UInt32), hidden: Bool)? = nil
        var lastCheckbox: (UInt32, UInt32)? = nil
        sheetLoop: while let (t, body, _) = try iter2.next() {
            switch t {
            case bof:
                depth += 1
            case eofRec:
                if depth == 1 { break sheetLoop }
                depth -= 1
            default:
                if depth > 1 { continue }
                switch t {
                case rowRec:
                    if body.count > 12, body[12] & 0x20 != 0,
                       let row = oleGetU16(body, 0) {
                        out.hiddenRows.insert(UInt32(row))
                    }
                case colinfo:
                    if let first = oleGetU16(body, 0), let last = oleGetU16(body, 2),
                       let flags = oleGetU16(body, 8), flags & 0x01 != 0, first <= last {
                        out.hiddenCols.append((UInt32(first), min(UInt32(last), maxCols - 1)))
                    }
                case mergedcells:
                    let count = min(Int(oleGetU16(body, 0) ?? 0), max(0, body.count - 2) / 8)
                    for i in 0..<count {
                        let at = 2 + i * 8
                        guard let r1 = oleGetU16(body, at), let r2 = oleGetU16(body, at + 2),
                              let c1 = oleGetU16(body, at + 4), let c2 = oleGetU16(body, at + 6)
                        else { break }
                        let (rLo, rHi) = (min(r1, r2), max(r1, r2))
                        let (cLo, cHi) = (min(c1, c2), max(c1, c2))
                        if UInt32(cLo) >= maxCols || (rLo == rHi && cLo == cHi) { continue }
                        out.merges.append((UInt32(rLo), UInt32(cLo), UInt32(rHi),
                                           min(UInt32(cHi), maxCols - 1)))
                    }
                case labelsst:
                    if let (row, col, ixfe) = cellRef(body),
                       let isst = oleGetU32(body, 6),
                       let text = globals.sst.indices.contains(Int(isst))
                           ? globals.sst[Int(isst)] : nil {
                        put(&out, row, col,
                            sheetFormatAsText(globals.format(ixfe), text: text))
                    } else if let (_, _, _) = cellRef(body) {
                        AnyTypLog.debug("shared string index out of range")
                    }
                case labelRec, rstring:
                    let segs = try continued(body, &iter2)
                    if let (row, col, ixfe) = cellRef(body) {
                        var r = stringReader(segs, skip: 6)
                        if let text = globals.readString(&r, short: false) {
                            put(&out, row, col, sheetFormatAsText(
                                globals.format(ixfe),
                                text: SharedText.clean(text)))
                        }
                    }
                case numberRec:
                    if let (row, col, ixfe) = cellRef(body), let n = getF64(body, 6) {
                        put(&out, row, col, sheetRenderNumber(
                            globals.format(ixfe), n, date1904: globals.date1904))
                    }
                case rkRec:
                    if let (row, col, ixfe) = cellRef(body), let rk = oleGetU32(body, 6) {
                        put(&out, row, col, sheetRenderNumber(
                            globals.format(ixfe), rkNumber(rk), date1904: globals.date1904))
                    }
                case mulrk:
                    if let row = oleGetU16(body, 0), let colFirst = oleGetU16(body, 2) {
                        var i = 0
                        while 4 + i * 6 + 6 <= body.count {
                            guard let ixfe = oleGetU16(body, 4 + i * 6),
                                  let rk = oleGetU32(body, 6 + i * 6) else { break }
                            let col = UInt32(colFirst) + UInt32(i)
                            if col >= maxCols { break }
                            put(&out, UInt32(row), col, sheetRenderNumber(
                                globals.format(ixfe), rkNumber(rk),
                                date1904: globals.date1904))
                            i += 1
                        }
                    }
                case boolerr:
                    if let (row, col, _) = cellRef(body), body.count > 7 {
                        let value = body[6], isErr = body[7]
                        let text: String?
                        switch (isErr, value) {
                        case (0, 0): text = "FALSE"
                        case (0, _): text = "TRUE"
                        case (1, let code): text = errorLiteral(code)
                        default: text = nil
                        }
                        if let text { put(&out, row, col, text) }
                    }
                case formulaRec:
                    if let (row, col, ixfe) = cellRef(body), body.count >= 14 {
                        let value = Array(body[6..<14])
                        if value[6] == 0xFF && value[7] == 0xFF {
                            switch value[0] {
                            case 0x00: pending = (row, col, ixfe)
                            case 0x01:
                                put(&out, row, col, value[2] == 0 ? "FALSE" : "TRUE")
                            case 0x02:
                                if let text = errorLiteral(value[2]) { put(&out, row, col, text) }
                            default: break
                            }
                        } else if let n = getF64(body, 6) {
                            put(&out, row, col, sheetRenderNumber(
                                globals.format(ixfe), n, date1904: globals.date1904))
                        }
                    }
                case msodrawing where globals.biff8:
                    let segs = try continued(body, &iter2)
                    shape = lastShape(segs.count == 1 ? segs[0] : segs.flatMap { $0 })
                    lastCheckbox = nil
                case objRec where globals.biff8:
                    lastCheckbox = nil
                    if let checked = objCheckbox(body),
                       let sh = shape, !sh.hidden, sh.anchor.1 < maxCols {
                        out.checkboxes[SheetCellKey(row: sh.anchor.0, col: sh.anchor.1),
                                       default: []]
                            .append(SheetCheckbox(checked: checked, caption: ""))
                        lastCheckbox = sh.anchor
                    }
                case txoRec:
                    let segs = try continued(body, &iter2)
                    if let at = lastCheckbox, let caption = txoText(segs) {
                        let key = SheetCellKey(row: at.0, col: at.1)
                        if var boxes = out.checkboxes[key], !boxes.isEmpty {
                            boxes[boxes.count - 1].caption = SharedText.clean(caption)
                            out.checkboxes[key] = boxes
                        }
                    }
                case stringRec:
                    let segs = try continued(body, &iter2)
                    if let (row, col, ixfe) = pending {
                        pending = nil
                        var r = SegReader(segs)
                        if let text = globals.readString(&r, short: false) {
                            put(&out, row, col, sheetFormatAsText(
                                globals.format(ixfe), text: SharedText.clean(text)))
                        }
                    }
                default: break
                }
            }
        }
        return out
    }

    /// What an OBJ needs from its shape: the cell the client anchor starts
    /// in, and whether the shape is hidden.
    private static func lastShape(_ data: [UInt8]) -> (anchor: (UInt32, UInt32), hidden: Bool)? {
        let spContainer: UInt16 = 0xF004
        let optRec: UInt16 = 0xF00B
        let clientAnchor: UInt16 = 0xF010
        let pidGroupShape: UInt16 = 0x03BF
        let fHidden: UInt32 = 0x0000_0002
        let fUseHidden: UInt32 = 0x0002_0000
        var anchor: (UInt32, UInt32)? = nil
        var hidden = false
        var off = 0
        while let (verInst, recType, bodySlice) = officeArtRecordAt(data, off) {
            if verInst & 0x000F == 0x000F {
                if recType == spContainer {
                    anchor = nil
                    hidden = false
                }
                off += 8
                continue
            }
            let body = Array(bodySlice)
            switch recType {
            case clientAnchor:
                if let col = oleGetU16(body, 2), let row = oleGetU16(body, 6) {
                    anchor = (UInt32(row), UInt32(col))
                }
            case optRec:
                for i in 0..<Int(verInst >> 4) {
                    let at = i * 6
                    guard let pid = oleGetU16(body, at), let op = oleGetU32(body, at + 2) else { break }
                    if pid & 0x3FFF == pidGroupShape && op & fUseHidden != 0 {
                        hidden = op & fHidden != 0
                    }
                }
            default: break
            }
            off += 8 + body.count
        }
        guard let anchor else { return nil }
        return (anchor, hidden)
    }

    /// The checked state of an OBJ record when its FtCmo names a checkbox
    /// and its FtCblsData carries a definite state.
    private static func objCheckbox(_ body: [UInt8]) -> Bool? {
        let ftEnd: UInt16 = 0x0000
        let ftCmo: UInt16 = 0x0015
        let ftCblsData: UInt16 = 0x0012
        let otCheckbox: UInt16 = 0x000B
        var off = 0
        var isCheckbox = false
        var state: UInt16? = nil
        while off + 4 <= body.count,
              let ft = oleGetU16(body, off), let cb = oleGetU16(body, off + 2), ft != ftEnd {
            let dataEnd = off + 4 + Int(cb)
            guard dataEnd <= body.count else { return nil }
            let data = Array(body[(off + 4)..<dataEnd])
            switch ft {
            case ftCmo: isCheckbox = oleGetU16(data, 0) == otCheckbox
            case ftCblsData: state = oleGetU16(data, 0)
            default: break
            }
            off = dataEnd
        }
        guard isCheckbox, let state else { return nil }
        switch state {
        case 0: return false
        case 1: return true
        default: return nil
        }
    }

    /// The text of a TXO record: `cchText` characters spread over the
    /// CONTINUE records after it, each opening with its own encoding flag.
    private static func txoText(_ segs: [[UInt8]]) -> String? {
        guard let first = segs.first, oleGetU16(first, 10) != nil else { return nil }
        var remaining = Int(oleGetU16(first, 10) ?? 0)
        var units: [UInt16] = []
        units.reserveCapacity(remaining)
        for seg in segs.dropFirst() {
            if remaining == 0 { break }
            guard let flags = seg.first else { return nil }
            let chars = Array(seg.dropFirst())
            if flags & 0x01 != 0 {
                let take = min(chars.count / 2, remaining)
                units.append(contentsOf: utf16leUnits(Array(chars[..<(take * 2)])))
                remaining -= take
            } else {
                let take = min(chars.count, remaining)
                units.append(contentsOf: chars[..<take].map { UInt16($0) })
                remaining -= take
            }
        }
        return utf16String(units)
    }

    /// A reader over `segs` with the first segment's leading `skip` bytes
    /// (the cell header before the string) removed.
    private static func stringReader(_ segs: [[UInt8]], skip: Int) -> SegReader {
        var parts: [[UInt8]] = []
        if let first = segs.first, skip < first.count {
            parts.append(Array(first[skip...]))
        }
        parts.append(contentsOf: segs.dropFirst())
        return SegReader(parts)
    }

    // MARK: - .xlsb (BIFF12)

    private static let brtRowHdr: UInt16 = 0
    private static let brtCellRk: UInt16 = 2
    private static let brtCellError: UInt16 = 3
    private static let brtCellBool: UInt16 = 4
    private static let brtCellReal: UInt16 = 5
    private static let brtCellSt: UInt16 = 6
    private static let brtCellIsst: UInt16 = 7
    private static let brtFmlaString: UInt16 = 8
    private static let brtFmlaNum: UInt16 = 9
    private static let brtFmlaBool: UInt16 = 10
    private static let brtFmlaError: UInt16 = 11
    private static let brtSstItem: UInt16 = 19
    private static let brtFmt: UInt16 = 44
    private static let brtXf: UInt16 = 47
    private static let brtColInfo: UInt16 = 60
    private static let brtCellRstring: UInt16 = 62
    private static let brtWbProp: UInt16 = 153
    private static let brtBundleSh: UInt16 = 156
    private static let brtMergeCell: UInt16 = 176
    private static let brtBeginCellXfs: UInt16 = 617
    private static let brtEndCellXfs: UInt16 = 618

    /// Iterator over a part's record stream: 1-2 byte record type and
    /// 1-4 byte payload size, both 7 bits per byte (MS-XLSB 2.1.4).
    private struct XlsbRecords {
        let data: [UInt8]
        var pos = 0
        var seen: UInt64 = 0

        mutating func next() throws -> (UInt16, [UInt8])? {
            if pos >= data.count { return nil }
            seen += 1
            if seen > Limits.maxRecords {
                throw ConvertError.resourceLimit(
                    limit: "max_records",
                    detail: "record stream exceeds the record budget")
            }
            guard let b0 = byte() else {
                throw ConvertError.malformed(part: nil, detail: "truncated record header")
            }
            let id: UInt16
            if b0 & 0x80 != 0 {
                guard let b1 = byte() else {
                    throw ConvertError.malformed(part: nil, detail: "truncated record header")
                }
                id = UInt16(b0 & 0x7F) | (UInt16(b1 & 0x7F) << 7)
            } else {
                id = UInt16(b0)
            }
            var size = 0
            for i in 0..<4 {
                guard let b = byte() else {
                    throw ConvertError.malformed(part: nil, detail: "truncated record header")
                }
                size |= Int(b & 0x7F) << (7 * i)
                if b & 0x80 == 0 { break }
                if i == 3 {
                    throw ConvertError.malformed(part: nil, detail: "record size runs past four bytes")
                }
            }
            guard pos + size <= data.count else {
                throw ConvertError.malformed(part: nil, detail: "record payload runs past the part")
            }
            let payload = Array(data[pos..<(pos + size)])
            pos += size
            return (id, payload)
        }

        mutating func byte() -> UInt8? {
            guard pos < data.count else { return nil }
            let b = data[pos]
            pos += 1
            return b
        }
    }

    /// Bounds-checked field reads within one record payload.
    private struct XlsbFields {
        let data: [UInt8]
        var pos = 0

        mutating func take(_ n: Int) throws -> [UInt8] {
            guard pos + n <= data.count, pos + n >= pos else {
                throw ConvertError.malformed(part: nil, detail: "truncated record payload")
            }
            let out = Array(data[pos..<(pos + n)])
            pos += n
            return out
        }

        mutating func skip(_ n: Int) throws { _ = try take(n) }
        mutating func u8() throws -> UInt8 { try take(1)[0] }
        mutating func u16() throws -> UInt16 { oleGetU16(try take(2), 0) ?? 0 }
        mutating func u32() throws -> UInt32 { oleGetU32(try take(4), 0) ?? 0 }
        mutating func f64() throws -> Double {
            let b = try take(8)
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(b[i]) << (8 * i) }
            return Double(bitPattern: v)
        }

        /// XLWideString: u32 character count, then UTF-16LE units.
        mutating func wideString() throws -> String {
            let cch = Int(try u32())
            guard cch >= 0, cch <= Int.max / 2 else {
                throw ConvertError.malformed(part: nil, detail: "oversized string length")
            }
            return utf16leString(try take(cch * 2))
        }

        /// XLNullableWideString: 0xFFFFFFFF count is the null string.
        mutating func nullableWideString() throws -> String? {
            if pos + 4 <= data.count, data[pos] == 0xFF, data[pos + 1] == 0xFF,
               data[pos + 2] == 0xFF, data[pos + 3] == 0xFF {
                pos += 4
                return nil
            }
            return try wideString()
        }
    }

    static func parseXlsb(_ pkg: Package, wbPart: String) -> Result<AnyTypDocument, ConvertError> {
        guard let workbookData = try? pkg.requiredPart(wbPart) else {
            return .failure(.missingPart(part: wbPart))
        }
        let workbook = [UInt8](workbookData)
        let (date1904, bundles): (Bool, [(String, String)])
        do {
            (date1904, bundles) = try readXlsbWorkbook(workbook)
        } catch let e as ConvertError {
            return .failure(e)
        } catch {
            return .failure(.io("\(error)"))
        }
        let wbRels = (try? readRels(pkg, relsPartFor(wbPart))) ?? Relationships()

        // Optional binary parts under the unified recovery policy.
        let sharedName = SheetXlsx.siblingPartName(
            wbRels, wbPart, SheetXlsx.sharedStringsRel, "sharedStrings.bin")
        let shared = readOptionalStrings(pkg, sharedName) { try readXlsbSharedStrings($0) }
        let stylesName = SheetXlsx.siblingPartName(wbRels, wbPart, RelType.styles, "styles.bin")
        let xfs = readOptionalFormats(pkg, stylesName) { try readXlsbStyles($0) }

        var sheets: [(String, String)] = []
        for (name, rid) in bundles {
            guard let target = wbRels.internalTarget(rid),
                  let resolved = try? resolvePackageTarget(wbPart, target) else {
                AnyTypLog.warn("skipping sheet \(name.debugDescription) with no worksheet relationship")
                continue
            }
            sheets.append((name, resolved.path))
        }

        let multiSheet = sheets.count > 1
        var doc = AnyTypDocument()
        var failed = 0
        var slots: UInt64 = 0
        for (name, part) in sheets {
            guard let bytesData = try? pkg.optionalPart(part) else {
                AnyTypLog.warn("skipping unreadable sheet \(name.debugDescription)")
                failed += 1
                continue
            }
            let bytes = [UInt8](bytesData)
            var content: SheetContent
            do {
                content = try readXlsbSheet(bytes, shared: shared, xfs: xfs, date1904: date1904)
            } catch let e as ConvertError {
                if e.isFatal { return .failure(e) }
                AnyTypLog.warn("skipping unreadable sheet \(name.debugDescription): \(e)")
                failed += 1
                continue
            } catch {
                AnyTypLog.warn("skipping unreadable sheet \(name.debugDescription): \(error)")
                failed += 1
                continue
            }
            do {
                content.checkboxes = try readVmlCheckboxes(pkg, sheetPart: part)
            } catch {
                content.checkboxes = [:]
            }
            let table: AnyTypTable?
            do {
                table = try sheetBuildTable(content, slots: &slots)
            } catch {
                return .failure(error as? ConvertError ?? .io("\(error)"))
            }
            guard let table else { continue }
            if multiSheet {
                doc.blocks.append(.heading(
                    level: 2, anchor: nil,
                    content: [.text(name, style: .plain)]))
            }
            doc.blocks.append(.table(table))
        }
        if !sheets.isEmpty && failed == sheets.count {
            return .failure(.malformed(part: nil, detail: "no sheet in the workbook could be read"))
        }
        return .success(doc)
    }

    /// Read an optional binary part: absent or corrupt yields the default
    /// with a log; fatal resource-limit errors propagate.
    private static func readOptionalStrings(
        _ pkg: Package, _ part: String,
        read: ([UInt8]) throws -> [String]
    ) -> [String] {
        guard let data = try? pkg.optionalPart(part) else { return [] }
        do {
            return try read([UInt8](data))
        } catch let e as ConvertError {
            if e.isFatal { return [] }
            AnyTypLog.warn("skipping corrupt part \(part): \(e)")
            return []
        } catch {
            AnyTypLog.warn("skipping corrupt part \(part): \(error)")
            return []
        }
    }

    private static func readOptionalFormats(
        _ pkg: Package, _ part: String,
        read: ([UInt8]) throws -> [SheetCellFormat]
    ) -> [SheetCellFormat] {
        guard let data = try? pkg.optionalPart(part) else { return [] }
        do {
            return try read([UInt8](data))
        } catch let e as ConvertError {
            if e.isFatal { return [] }
            AnyTypLog.warn("skipping corrupt part \(part): \(e)")
            return []
        } catch {
            AnyTypLog.warn("skipping corrupt part \(part): \(error)")
            return []
        }
    }

    private static func readXlsbWorkbook(_ data: [UInt8]) throws -> (Bool, [(String, String)]) {
        var date1904 = false
        var sheets: [(String, String)] = []
        var records = XlsbRecords(data: data)
        while let (id, payload) = try records.next() {
            switch id {
            case brtWbProp:
                var f = XlsbFields(data: payload)
                let prop = (try? f.u32()) ?? 0
                date1904 = prop & 1 != 0
            case brtBundleSh:
                var f = XlsbFields(data: payload)
                guard let state = try? f.u32(),
                      (try? f.u32()) != nil else { continue }
                let rid = try? f.nullableWideString()
                guard let name = try? f.wideString() else { continue }
                if state == 1 || state == 2 { continue }
                let clean = SharedText.clean(name)
                if let rid {
                    sheets.append((clean, rid))
                } else {
                    AnyTypLog.warn("skipping sheet \(clean.debugDescription) with no worksheet relationship")
                }
            default: break
            }
        }
        return (date1904, sheets)
    }

    /// `styles.bin` reduced to the ordered cellXfs list. Only BrtXF
    /// records between BrtBeginCellXFs and BrtEndCellXFs are cell XFs.
    private static func readXlsbStyles(_ data: [UInt8]) throws -> [SheetCellFormat] {
        var codes: [UInt32: String] = [:]
        var fmtIds: [UInt32] = []
        var inCellXfs = false
        var records = XlsbRecords(data: data)
        while let (id, payload) = try records.next() {
            switch id {
            case brtBeginCellXfs: inCellXfs = true
            case brtEndCellXfs: inCellXfs = false
            case brtFmt:
                var f = XlsbFields(data: payload)
                if let ifmt = try? f.u16(), let code = try? f.wideString() {
                    codes[UInt32(ifmt)] = code
                }
            case brtXf where inCellXfs:
                var f = XlsbFields(data: payload)
                if (try? f.u16()) != nil, let ifmt = try? f.u16() {
                    fmtIds.append(UInt32(ifmt))
                }
            default: break
            }
        }
        var cache: [UInt32: SheetCellFormat] = [:]
        return fmtIds.map { id in
            if let hit = cache[id] { return hit }
            let fmt = SheetXlsx.resolveFormat(id, custom: codes)
            cache[id] = fmt
            return fmt
        }
    }

    /// `sharedStrings.bin`: one cleaned entry per BrtSSTItem.
    private static func readXlsbSharedStrings(_ data: [UInt8]) throws -> [String] {
        var out: [String] = []
        var records = XlsbRecords(data: data)
        while let (id, payload) = try records.next() {
            if id == brtSstItem {
                var f = XlsbFields(data: payload)
                if (try? f.u8()) != nil, let s = try? f.wideString() {
                    out.append(SharedText.clean(s))
                }
            }
        }
        return out
    }

    /// One worksheet part. Every cell record carries its column and
    /// cellXfs index in the common cell header (MS-XLSB 2.5.10).
    private static func readXlsbSheet(
        _ data: [UInt8], shared: [String], xfs: [SheetCellFormat], date1904: Bool
    ) throws -> SheetContent {
        var out = SheetContent()
        var row: UInt32? = nil
        var records = XlsbRecords(data: data)
        while let (id, payload) = try records.next() {
            var f = XlsbFields(data: payload)
            switch id {
            case brtRowHdr:
                guard let rw = try? f.u32() else { continue }
                if rw >= UInt32(maxRows) {
                    row = nil
                    continue
                }
                row = rw
                _ = try? f.skip(7)
                if (try? f.u8()) ?? 0 & 0x10 != 0 {
                    out.hiddenRows.insert(rw)
                }
            case brtColInfo:
                if let first = try? f.u32(), let last = try? f.u32() {
                    _ = try? f.skip(8)
                    let hidden = ((try? f.u16()) ?? 0) & 1 != 0
                    if hidden && first <= last && first < UInt32(maxCols) {
                        out.hiddenCols.append((first, min(last, UInt32(maxCols) - 1)))
                    }
                }
            case brtMergeCell:
                if let r1 = try? f.u32(), let r2 = try? f.u32(),
                   let c1 = try? f.u32(), let c2 = try? f.u32(),
                   max(r1, r2) < UInt32(maxRows), max(c1, c2) < UInt32(maxCols),
                   r1 != r2 || c1 != c2 {
                    out.merges.append((min(r1, r2), min(c1, c2), max(r1, r2), max(c1, c2)))
                }
            case brtCellRk, brtCellError, brtCellBool, brtCellReal, brtCellSt,
                 brtCellIsst, brtCellRstring, brtFmlaString, brtFmlaNum,
                 brtFmlaBool, brtFmlaError:
                guard let col = try? f.u32(),
                      let style = try? f.u32(),
                      let r = row, col < UInt32(maxCols) else {
                    AnyTypLog.debug("skipping cell record before any row header")
                    continue
                }
                let fmt = xfs.indices.contains(Int(style & 0x00FF_FFFF))
                    ? xfs[Int(style & 0x00FF_FFFF)] : .general
                let text = try xlsbCellText(id, &f, fmt: fmt, shared: shared, date1904: date1904)
                if !text.isEmpty {
                    out.cells[SheetCellKey(row: r, col: col)] = text
                }
            default: break
            }
        }
        return out
    }

    /// A cell's rendered text from the record body after the common
    /// header. Formula records carry their cached result first.
    private static func xlsbCellText(
        _ id: UInt16, _ f: inout XlsbFields, fmt: SheetCellFormat,
        shared: [String], date1904: Bool
    ) throws -> String {
        switch id {
        case brtCellRk:
            return sheetRenderNumber(fmt, rkNumber(try f.u32()), date1904: date1904)
        case brtCellReal, brtFmlaNum:
            return sheetRenderNumber(fmt, try f.f64(), date1904: date1904)
        case brtCellSt, brtFmlaString:
            return sheetFormatAsText(fmt, text: SharedText.clean(try f.wideString()))
        case brtCellRstring:
            _ = try f.u8()
            return sheetFormatAsText(fmt, text: SharedText.clean(try f.wideString()))
        case brtCellIsst:
            let isst = try f.u32()
            guard let i = Int(exactly: isst), shared.indices.contains(i) else {
                AnyTypLog.debug("shared string index \(isst) out of range")
                return ""
            }
            return sheetFormatAsText(fmt, text: shared[i])
        case brtCellBool, brtFmlaBool:
            switch try f.u8() {
            case 1: return "TRUE"
            case 0: return "FALSE"
            default: return ""
            }
        case brtCellError, brtFmlaError:
            let code = try f.u8()
            guard let text = errorLiteral(code) else {
                AnyTypLog.debug("unknown error cell code \(String(format: "0x%02x", code))")
                return ""
            }
            return text
        default:
            return ""
        }
    }
}
