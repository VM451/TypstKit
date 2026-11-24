import Foundation

/// Legacy Word 97-2003 binary (.doc) frontend (port of `formats/doc/`):
/// OLE2 container, FIB + piece table (Clx/Plcfpcd), FKP CHPX/PAPX style
/// runs, STSH stylesheet with istdBase chains, PlfLst/PlfLfo list tables,
/// and the text-stream assembler (paragraphs, headings, lists, tables,
/// fields, notes, inline pictures).
enum DocFormat {
    private static let levels = 9

    static func parse(_ bytes: [UInt8]) -> Result<AnyTypDocument, ConvertError> {
        guard let ole = try? OleFile(bytes: bytes) else {
            return .failure(.malformed(part: nil, detail: "not an OLE2 compound file"))
        }
        let wordDoc: [UInt8]
        do {
            wordDoc = try readOleStream(ole, "WordDocument")
        } catch {
            return .failure(error as? ConvertError ?? .io("\(error)"))
        }
        guard oleGetU16(wordDoc, 0) == 0xA5EC else {
            return .failure(.malformedPart("WordDocument", "invalid FIB magic"))
        }
        let flags = oleGetU16(wordDoc, 0x0A) ?? 0
        if flags & 0x0100 != 0 { return .failure(.encrypted) }
        let (tableName, otherTable) = flags & 0x0200 != 0
            ? ("1Table", "0Table") : ("0Table", "1Table")
        var table: [UInt8] = []
        if let t = try? readOleStream(ole, tableName) {
            table = t
        } else if let t = try? readOleStream(ole, otherTable) {
            table = t
        }

        let ccpText = Int(oleGetU32(wordDoc, 0x4C) ?? 0)
        let ccpFtn = Int(oleGetU32(wordDoc, 0x50) ?? 0)
        let ccpHdd = Int(oleGetU32(wordDoc, 0x54) ?? 0)
        let ccpMcr = Int(oleGetU32(wordDoc, 0x58) ?? 0)
        let ccpAtn = Int(oleGetU32(wordDoc, 0x5C) ?? 0)
        let ccpEdn = Int(oleGetU32(wordDoc, 0x60) ?? 0)
        let fcClx = Int(oleGetU32(wordDoc, 0x1A2) ?? 0)
        let lcbClx = Int(oleGetU32(wordDoc, 0x1A6) ?? 0)

        let (pieces, prcs): ([Piece], [[UInt8]])
        if lcbClx > 0 {
            do {
                (pieces, prcs) = try parseClx(table, fc: fcClx, lcb: lcbClx)
            } catch {
                return .failure(error as? ConvertError ?? .malformed("bad Clx"))
            }
        } else {
            (pieces, prcs) = (legacySinglePiece(wordDoc), [])
        }
        let totalCp = ccpText + ccpFtn + ccpHdd + ccpMcr + ccpAtn + ccpEdn
        // Compressed piece text decodes in the document's ANSI code page.
        let lid = flags & 0x4000 != 0
            ? (oleGetU16(wordDoc, 0x3C).flatMap { $0 != 0 ? $0 : nil } ?? oleGetU16(wordDoc, 0x06) ?? 0)
            : oleGetU16(wordDoc, 0x06) ?? 0
        let encoding = lidEncoding(lid)
        let text = extractText(wordDoc, pieces: pieces, totalCp: totalCp, encoding: encoding)

        let data = (try? readOleStream(ole, "Data")) ?? []
        let chpxRuns = parseFkps(wordDoc, table, fibOff: 0xFA, kind: .chpx, data: data)
        let papxRuns = parseFkps(wordDoc, table, fibOff: 0x102, kind: .papx, data: data)
        let stylesheet = parseStylesheet(wordDoc, table)
        let lists = parseLists(wordDoc, table)
        let assets = AssetSink()

        // Note references (CP-indexed) and note body ranges.
        var noteRefs: [Int: String] = [:]
        var noteRanges: [(Int, Int, String, AnyTypNoteKind)] = []
        let ftnBase = ccpText
        let ednBase = ccpText + ccpFtn + ccpHdd + ccpMcr + ccpAtn
        for (refOff, txtOff, base, prefix, kind) in [
            (0xAA, 0xB2, ftnBase, "fn", AnyTypNoteKind.footnote),
            (0x20A, 0x212, ednBase, "en", AnyTypNoteKind.endnote),
        ] {
            let (refCps, nRefs) = parsePlc(wordDoc, table, fibOff: refOff, dataSize: 2)
            let (txtCps, _) = parsePlc(wordDoc, table, fibOff: txtOff, dataSize: 0)
            for i in 0..<nRefs {
                noteRefs[text.indexOfCp(Int(refCps[i]))] = "\(prefix)\(i)"
                if i + 1 < txtCps.count {
                    let lo = text.indexOfCp(base + Int(txtCps[i]))
                    let hi = text.indexOfCp(base + Int(txtCps[i + 1]))
                    noteRanges.append((lo, hi, "\(prefix)\(i)", kind))
                }
            }
        }
        let mainEnd = text.indexOfCp(ccpText)

        let assembler = Assembler(
            text: text, chpx: Runs(chpxRuns), papx: Runs(papxRuns),
            stylesheet: stylesheet, lists: lists, prcs: prcs,
            piecePrcs: pieces.map(\.prmPrc), noteRefs: noteRefs,
            counters: Counters(), data: data, assets: assets)
        do {
            let blocks = try assembler.buildBlocks(0, mainEnd)
            var notes: [AnyTypNote] = []
            for (lo, hi, id, kind) in noteRanges {
                let lo = min(lo, assembler.text.chars.count)
                let hi = min(hi, assembler.text.chars.count)
                if lo >= hi { continue }
                notes.append(.init(id: id, kind: kind,
                                   blocks: try assembler.buildBlocks(lo, hi)))
            }
            return .success(AnyTypDocument(blocks: blocks, notes: notes, assets: assets.assets))
        } catch {
            return .failure(error as? ConvertError ?? .malformed("\(error)"))
        }
    }

    // MARK: - PLC / piece table

    /// Read a PLC's CP array; n is the number of data elements.
    private static func parsePlc(
        _ wordDoc: [UInt8], _ table: [UInt8], fibOff: Int, dataSize: Int
    ) -> ([UInt32], Int) {
        let fc = Int(oleGetU32(wordDoc, fibOff) ?? 0)
        let lcb = Int(oleGetU32(wordDoc, fibOff + 4) ?? 0)
        guard fc + lcb <= table.count, lcb >= 8 else { return ([], 0) }
        let plc = Array(table[fc..<(fc + lcb)])
        let n = dataSize == 0 ? lcb / 4 - 1 : (lcb - 4) / (4 + dataSize)
        var cps: [UInt32] = []
        cps.reserveCapacity(n + 1)
        for i in 0...n {
            cps.append(oleGetU32(plc, i * 4) ?? 0)
        }
        return (cps, n)
    }

    struct Piece {
        var cpStart: Int
        var cpEnd: Int
        var fc: Int
        var compressed: Bool
        var prmPrc: Int?
    }

    private static func parseClx(
        _ table: [UInt8], fc: Int, lcb: Int
    ) throws -> ([Piece], [[UInt8]]) {
        guard fc >= 0, lcb >= 0, fc + lcb <= table.count else {
            throw ConvertError.malformed(part: nil, detail: "Clx out of bounds")
        }
        let clx = Array(table[fc..<(fc + lcb)])
        var prcs: [[UInt8]] = []
        var pos = 0
        while pos < clx.count {
            let tag = clx[pos]
            if tag == 1 {
                guard pos + 3 <= clx.count,
                      let cb = oleGetU16(clx, pos + 1) else {
                    throw ConvertError.malformed(part: nil, detail: "bad Prc")
                }
                let end = min(pos + 3 + Int(cb), clx.count)
                prcs.append(Array(clx[(pos + 3)..<end]))
                pos += 3 + Int(cb)
            } else if tag == 2 {
                guard pos + 5 <= clx.count,
                      let lcbPlc = oleGetU32(clx, pos + 1) else {
                    throw ConvertError.malformed(part: nil, detail: "bad Pcdt")
                }
                let plcStart = pos + 5
                guard plcStart + Int(lcbPlc) <= clx.count else {
                    throw ConvertError.malformed(part: nil, detail: "PlcPcd out of bounds")
                }
                let plc = Array(clx[plcStart..<(plcStart + Int(lcbPlc))])
                return (try parsePlcPcd(plc, prcs: &prcs), prcs)
            } else {
                throw ConvertError.malformed(part: nil, detail: "malformed Clx")
            }
        }
        throw ConvertError.malformed(part: nil, detail: "malformed Clx")
    }

    private static func parsePlcPcd(_ plc: [UInt8], prcs: inout [[UInt8]]) throws -> [Piece] {
        guard plc.count >= 4 + 12 else {
            throw ConvertError.malformed(part: nil, detail: "empty piece table")
        }
        let n = (plc.count - 4) / 12
        var pieces: [Piece] = []
        pieces.reserveCapacity(n)
        for i in 0..<n {
            guard let cpStart = oleGetU32(plc, i * 4),
                  let cpEnd = oleGetU32(plc, (i + 1) * 4) else {
                throw ConvertError.malformed(part: nil, detail: "bad cp")
            }
            let pcdOff = (n + 1) * 4 + i * 8
            guard let fcRaw = oleGetU32(plc, pcdOff + 2) else {
                throw ConvertError.malformed(part: nil, detail: "bad pcd")
            }
            let prm = oleGetU16(plc, pcdOff + 6) ?? 0
            let compressed = (fcRaw & 0x4000_0000) != 0
            var fc = Int(fcRaw & 0x3FFF_FFFF)
            if compressed { fc /= 2 }
            // Prm: complex form indexes the Prc array; Prm0 decodes to a
            // one-sprm grpprl.
            var prmPrc: Int? = nil
            if (prm & 1) != 0 {
                let idx = Int(prm >> 1)
                prmPrc = idx < prcs.count ? idx : nil
            } else if prm != 0 {
                if let grpprl = prm0Grpprl(prm) {
                    prcs.append(grpprl)
                    prmPrc = prcs.count - 1
                } else {
                    AnyTypLog.debug("Prm0 sprm outside the converted model: 0x\(String(prm, radix: 16))")
                }
            }
            pieces.append(Piece(cpStart: Int(cpStart), cpEnd: Int(cpEnd),
                                fc: fc, compressed: compressed, prmPrc: prmPrc))
        }
        return pieces
    }

    /// Decode a `Prm0`: 7-bit isprm + 1-byte val -> one-sprm grpprl.
    private static func prm0Grpprl(_ prm: UInt16) -> [UInt8]? {
        let isprm = Int((prm >> 1) & 0x7F)
        let val = UInt8(truncatingIfNeeded: prm >> 8)
        let sprm: UInt16
        switch isprm {
        case 0x0C: sprm = 0x260A // sprmPIlvl
        case 0x18: sprm = 0x2416 // sprmPFInTable
        case 0x19: sprm = 0x2417 // sprmPFTtp
        case 0x55: sprm = 0x0835 // sprmCFBold
        case 0x56: sprm = 0x0836 // sprmCFItalic
        case 0x57: sprm = 0x0837 // sprmCFStrike
        case 0x78: sprm = 0x2640 // sprmPOutLvl
        default: return nil
        }
        return [UInt8(sprm & 0xFF), UInt8(sprm >> 8), val]
    }

    private static func legacySinglePiece(_ wordDoc: [UInt8]) -> [Piece] {
        let fcMin = Int(oleGetU32(wordDoc, 0x18) ?? 0)
        let fcMac = Int(oleGetU32(wordDoc, 0x1C) ?? 0)
        if fcMac <= fcMin { return [] }
        return [Piece(cpStart: 0, cpEnd: fcMac - fcMin, fc: fcMin,
                      compressed: true, prmPrc: nil)]
    }

    // MARK: - Text stream

    struct TextStream {
        var chars: [Character] = []
        var fcs: [UInt32] = []
        /// CP of each char (running UTF-16 unit count).
        var cps: [UInt32] = []
        /// Piece index of each char, for Prm application.
        var pieceOf: [UInt32] = []

        /// First char index at or after the given CP.
        func indexOfCp(_ cp: Int) -> Int {
            var lo = 0, hi = cps.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if Int(cps[mid]) < cp { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }
    }

    /// The ANSI code page for a Word language id.
    private static func lidEncoding(_ lid: UInt16) -> String.Encoding {
        switch lid & 0x03FF {
        case 0x11: return .shiftJIS
        case 0x12, 0x01, 0x20, 0x29: return .windowsCP1252 // EUC-KR/Arabic -> degrade
        case 0x04:
            switch lid {
            case 0x0404, 0x0C04, 0x1404, 0x7C04: return .windowsCP1252 // BIG5 -> degrade
            default: return .windowsCP1252 // GBK -> degrade
            }
        case 0x02, 0x19, 0x22, 0x23: return .windowsCP1251
        case 0x05, 0x0E, 0x15, 0x18, 0x1A, 0x1B, 0x24: return .windowsCP1250
        case 0x08: return .windowsCP1253
        case 0x0D: return .windowsCP1252 // Hebrew 1255 -> degrade
        case 0x1E: return .windowsCP1252 // Thai 874 -> degrade
        case 0x1F, 0x2C: return .windowsCP1254
        case 0x25...0x27: return .windowsCP1252 // Baltic 1257 -> degrade
        case 0x2A: return .windowsCP1252 // CP1258 -> degrade
        default: return .windowsCP1252
        }
    }

    /// Whether `b` starts a two-byte sequence in a double-byte code page.
    private static func isLeadByte(_ enc: String.Encoding, _ b: UInt8) -> Bool {
        if enc == .shiftJIS {
            return (0x81...0x9F).contains(b) || (0xE0...0xFC).contains(b)
        }
        return false // GBK/BIG5/EUC-KR degraded to single-byte
    }

    private static func decodeBytes(_ bytes: [UInt8], _ enc: String.Encoding) -> String {
        String(bytes: bytes, encoding: enc)
            ?? String(bytes: bytes, encoding: .windowsCP1252)
            ?? ""
    }

    private static func extractText(
        _ wordDoc: [UInt8], pieces: [Piece], totalCp: Int, encoding: String.Encoding
    ) -> TextStream {
        var text = TextStream()
        var cp = 0
        for (pieceIdx, piece) in pieces.enumerated() {
            if cp >= totalCp { break }
            let len = min(piece.cpEnd - piece.cpStart, totalCp - cp)
            if piece.compressed {
                guard piece.fc >= 0, piece.fc + len <= wordDoc.count else { continue }
                let bytes = Array(wordDoc[piece.fc..<(piece.fc + len)])
                // Byte-accurate accounting: each CP is one byte; a
                // double-byte character occupies two CPs.
                var i = 0
                while i < bytes.count {
                    let seq = isLeadByte(encoding, bytes[i]) && i + 1 < bytes.count ? 2 : 1
                    let s = decodeBytes(Array(bytes[i..<(i + seq)]), encoding)
                    for c in s {
                        text.chars.append(c)
                        text.fcs.append(UInt32(piece.fc + i))
                        text.cps.append(UInt32(cp))
                        text.pieceOf.append(UInt32(pieceIdx))
                    }
                    cp += seq
                    i += seq
                }
            } else {
                guard piece.fc >= 0, piece.fc + len * 2 <= wordDoc.count else { continue }
                let bytes = Array(wordDoc[piece.fc..<(piece.fc + len * 2)])
                let units = utf16leUnits(bytes)
                var unitIdx = 0
                for scalar in decodeUtf16(units) {
                    let s = String(scalar)
                    for c in s {
                        text.chars.append(c)
                        text.fcs.append(UInt32(piece.fc + unitIdx * 2))
                        text.cps.append(UInt32(cp))
                        text.pieceOf.append(UInt32(pieceIdx))
                    }
                    unitIdx += s.utf16.count
                    cp += s.utf16.count
                }
            }
        }
        return text
    }

    /// UTF-16 units to Characters with unpaired surrogates -> U+FFFD.
    private static func decodeUtf16(_ units: [UInt16]) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        var i = 0
        while i < units.count {
            let u = units[i]
            if (0xD800...0xDBFF).contains(u), i + 1 < units.count,
               (0xDC00...0xDFFF).contains(units[i + 1]) {
                let cp = 0x10000 + ((UInt32(u) - 0xD800) << 10) + (UInt32(units[i + 1]) - 0xDC00)
                out.append(Unicode.Scalar(cp) ?? "\u{FFFD}")
                i += 2
            } else if (0xD800...0xDFFF).contains(u) {
                out.append("\u{FFFD}")
                i += 1
            } else {
                out.append(Unicode.Scalar(u) ?? "\u{FFFD}")
                i += 1
            }
        }
        return out
    }

    // MARK: - Sprm walking (port of doc/sprm.rs)

    private static func sprmOperandLen(_ sprm: UInt16, _ operand: [UInt8]) -> Int {
        switch sprm >> 13 {
        case 0, 1: return 1
        case 2, 4, 5: return 2
        case 3: return 4
        case 7: return 3
        default:
            if sprm == 0xD608 {
                return operand.count >= 2
                    ? Int(oleGetU16(operand, 0) ?? 0) + 1 : 0
            }
            return operand.first.map { Int($0) + 1 } ?? 0
        }
    }

    private static func walkSprms(_ grpprl: [UInt8], _ f: (UInt16, [UInt8]) -> Void) {
        var pos = 0
        while pos + 2 <= grpprl.count {
            let sprm = oleGetU16(grpprl, pos) ?? 0
            pos += 2
            let len = sprmOperandLen(sprm, Array(grpprl[pos...]))
            guard pos + len <= grpprl.count else { break }
            f(sprm, Array(grpprl[pos..<(pos + len)]))
            pos += len
        }
    }

    /// Resolve a toggle operand against the style-chain base value.
    private static func toggle(_ operand: [UInt8], _ base: Bool) -> Bool? {
        switch operand.first {
        case 0: return false
        case 1: return true
        case 0x80: return base
        case 0x81: return !base
        default: return nil
        }
    }

    private static func chpxIstd(_ grpprl: [UInt8]) -> UInt16? {
        var istd: UInt16? = nil
        walkSprms(grpprl) { sprm, operand in
            if sprm == 0x4A30 { istd = oleGetU16(operand, 0) }
        }
        return istd
    }

    private static func chpxPicLocation(_ grpprl: [UInt8]) -> UInt32? {
        var loc: UInt32? = nil
        walkSprms(grpprl) { sprm, operand in
            if sprm == 0x6A03 { loc = oleGetU32(operand, 0) }
        }
        return loc
    }

    /// Apply a CHPX grpprl over `current`, toggles resolving against
    /// `styleBase` (the style chain's value).
    private static func applyChpx(
        _ grpprl: [UInt8], _ current: AnyTypStyle, styleBase: AnyTypStyle
    ) -> AnyTypStyle {
        var style = current
        walkSprms(grpprl) { sprm, operand in
            switch sprm {
            case 0x0835:
                if let v = toggle(operand, styleBase.bold) { style.bold = v }
            case 0x0836:
                if let v = toggle(operand, styleBase.italic) { style.italic = v }
            case 0x0837:
                if let v = toggle(operand, styleBase.strike) { style.strike = v }
            case 0x2A3E:
                if let kul = operand.first { style.underline = kul != 0 }
            case 0x2A48:
                switch operand.first {
                case 1: style.superscript = true; style.subscriptText = false
                case 2: style.superscript = false; style.subscriptText = true
                case 0: style.superscript = false; style.subscriptText = false
                default: break
                }
            default: break
            }
        }
        return style
    }

    // MARK: - PAP deltas (port of doc/sprm.rs PapDelta)

    struct TapCell {
        var horzFirst = false
        var horzCont = false
        var vertRestart = false
        var vertCont = false
    }

    struct Tap {
        var boundaries: [Int16] = []
        var cells: [TapCell] = []
        var header = false
    }

    struct PapDelta {
        var inTable: Bool? = nil
        var ttp: Bool? = nil
        /// Outer: set?; inner: heading level (nil = no outline).
        var outline: UInt8?? = nil
        var ilfo: UInt16? = nil
        var ilvl: UInt8? = nil
        var itap: Int32? = nil
        var innerCell: Bool? = nil
        var innerTtp: Bool? = nil
        var tap: Tap? = nil

        func merged(_ over: PapDelta) -> PapDelta {
            PapDelta(
                inTable: over.inTable ?? inTable,
                ttp: over.ttp ?? ttp,
                outline: over.outline ?? outline,
                ilfo: over.ilfo ?? ilfo,
                ilvl: over.ilvl ?? ilvl,
                itap: over.itap ?? itap,
                innerCell: over.innerCell ?? innerCell,
                innerTtp: over.innerTtp ?? innerTtp,
                tap: over.tap ?? tap)
        }
    }

    private static func parseTdefTable(_ operand: [UInt8]) -> Tap? {
        let tc80Size = 20
        guard operand.count > 2 else { return nil }
        let columns = Int(operand[2])
        if columns > 63 { return nil }
        var boundaries: [Int16] = []
        for i in 0...columns {
            guard let b = oleGetU16(operand, 3 + i * 2) else { return nil }
            boundaries.append(Int16(bitPattern: b))
        }
        var cells = [TapCell](repeating: TapCell(), count: columns)
        let tcBase = 3 + (columns + 1) * 2
        for i in 0..<columns {
            guard let tcgrf = oleGetU16(operand, tcBase + i * tc80Size) else { break }
            let horz = tcgrf & 0x3
            cells[i].horzCont = horz == 1
            cells[i].horzFirst = horz >= 2
            let vert = (tcgrf >> 5) & 0x3
            cells[i].vertCont = vert == 1
            cells[i].vertRestart = vert == 3
        }
        return Tap(boundaries: boundaries, cells: cells, header: false)
    }

    private static func applyPapSprms(
        _ grpprl: [UInt8], data: [UInt8], _ delta: inout PapDelta
    ) {
        walkSprms(grpprl) { sprm, operand in
            switch sprm {
            case 0x2416:
                delta.inTable = operand.first.map { $0 != 0 }
            case 0x2417:
                delta.ttp = operand.first.map { $0 != 0 }
            case 0x6646:
                // sprmPHugePapx: real grpprl lives length-prefixed in Data.
                if let off = oleGetU32(operand, 0).map(Int.init),
                   off + 2 <= data.count,
                   let cb = oleGetU16(data, off).map(Int.init),
                   off + 2 + cb <= data.count {
                    applyPapSprms(Array(data[(off + 2)..<(off + 2 + cb)]), data: [], &delta)
                }
            case 0x2640:
                if let v = operand.first {
                    delta.outline = v < 9 ? .some(UInt8(v + 1)) : .some(nil)
                }
            case 0x260A:
                delta.ilvl = operand.first
            case 0x460B:
                delta.ilfo = oleGetU16(operand, 0)
            case 0x6649:
                delta.itap = oleGetU32(operand, 0).map { Int32(bitPattern: $0) }
            case 0x664A:
                if let d = oleGetU32(operand, 0).map({ Int32(bitPattern: $0) }) {
                    delta.itap = (delta.itap ?? 0) &+ d
                }
            case 0x244B:
                delta.innerCell = operand.first.map { $0 != 0 }
            case 0x244C:
                delta.innerTtp = operand.first.map { $0 != 0 }
            case 0xD608:
                if var tap = parseTdefTable(operand) {
                    tap.header = delta.tap?.header ?? false
                    delta.tap = tap
                }
            case 0x3404:
                let on = operand.first.map { $0 != 0 } ?? false
                if delta.tap != nil {
                    delta.tap?.header = on
                } else if on {
                    delta.tap = Tap(header: true)
                }
            case 0xD62B:
                if operand.count > 2, delta.tap != nil {
                    let itc = Int(operand[1])
                    let flag = operand[2]
                    if itc < (delta.tap?.cells.count ?? 0) {
                        delta.tap?.cells[itc].vertCont = flag == 0x01
                        delta.tap?.cells[itc].vertRestart = flag == 0x03
                    }
                }
            default: break
            }
        }
    }

    // MARK: - FKP runs (CHPX / PAPX)

    private enum FkpKind { case chpx, papx }

    struct RunProps {
        var chpx: [UInt8] = []
        var istd: UInt16 = 0
        var pap = PapDelta()
    }

    struct Run {
        var fcStart: UInt32
        var fcEnd: UInt32
        var props: RunProps
    }

    struct Runs {
        var runs: [Run]

        init(_ runs: [Run]) {
            self.runs = runs.sorted { $0.fcStart < $1.fcStart }
        }

        func lookup(_ fc: UInt32) -> RunProps? {
            // First run with fcStart > fc, minus one.
            var lo = 0, hi = runs.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if runs[mid].fcStart <= fc { lo = mid + 1 } else { hi = mid }
            }
            guard lo > 0 else { return nil }
            let run = runs[lo - 1]
            return fc < run.fcEnd ? run.props : nil
        }
    }

    private static func parseFkps(
        _ wordDoc: [UInt8], _ table: [UInt8], fibOff: Int, kind: FkpKind, data: [UInt8]
    ) -> [Run] {
        var runs: [Run] = []
        let fc = Int(oleGetU32(wordDoc, fibOff) ?? 0)
        let lcb = Int(oleGetU32(wordDoc, fibOff + 4) ?? 0)
        guard fc + lcb <= table.count, lcb >= 8 else { return runs }
        let plc = Array(table[fc..<(fc + lcb)])
        let n = (plc.count - 4) / 8
        for i in 0..<n {
            guard let pnRaw = oleGetU32(plc, (n + 1) * 4 + i * 4) else { continue }
            let pn = Int(pnRaw & 0x3F_FFFF)
            guard pn * 512 + 512 <= wordDoc.count else { continue }
            let page = Array(wordDoc[(pn * 512)..<(pn * 512 + 512)])
            parseFkpPage(page, kind: kind, data: data, runs: &runs)
        }
        return runs
    }

    private static func parseFkpPage(
        _ page: [UInt8], kind: FkpKind, data: [UInt8], runs: inout [Run]
    ) {
        let count = Int(page[511])
        if count == 0 { return }
        let entrySize = kind == .papx ? 13 : 1
        for k in 0..<count {
            guard let fcStart = oleGetU32(page, k * 4),
                  let fcEnd = oleGetU32(page, (k + 1) * 4) else { continue }
            let bOffsetPos = (count + 1) * 4 + k * entrySize
            guard bOffsetPos < page.count else { continue }
            let bOffset = Int(page[bOffsetPos])
            var props = RunProps()
            if bOffset != 0 {
                let off = bOffset * 2
                switch kind {
                case .chpx:
                    if off < page.count {
                        let cb = page[off]
                        if off + 1 + Int(cb) <= page.count {
                            props.chpx = Array(page[(off + 1)..<(off + 1 + Int(cb))])
                        }
                    }
                case .papx:
                    if off < page.count {
                        let cb = page[off]
                        let (start, len): (Int, Int)
                        if cb == 0 {
                            guard off + 1 < page.count else { break }
                            let cb2 = Int(page[off + 1])
                            (start, len) = (off + 2, cb2 * 2)
                        } else {
                            (start, len) = (off + 1, Int(cb) * 2 - 1)
                        }
                        if start + len <= page.count, len >= 2 {
                            let grpprl = Array(page[start..<(start + len)])
                            props.istd = oleGetU16(grpprl, 0) ?? 0
                            applyPapSprms(Array(grpprl[2...]), data: data, &props.pap)
                        }
                    }
                }
            }
            runs.append(Run(fcStart: fcStart, fcEnd: fcEnd, props: props))
        }
    }

    // MARK: - STSH stylesheet (port of doc/stsh.rs)

    struct ResolvedStyle {
        var chp = AnyTypStyle.plain
        var pap = PapDelta()
        var heading: UInt8? = nil
        var block: BlockStyle? = nil
    }

    struct Std {
        var sti: UInt16
        var istdBase: UInt16
        var block: BlockStyle?
        var upxPapx: [UInt8]
        var upxChpx: [UInt8]
        var isParagraph: Bool
    }

    struct Stylesheet {
        var resolved: [UInt16: ResolvedStyle] = [:]
        var `default` = ResolvedStyle()

        func get(_ istd: UInt16) -> ResolvedStyle {
            resolved[istd] ?? `default`
        }
    }

    private static let istdNil: UInt16 = 0x0FFF

    private static func parseStylesheet(_ wordDoc: [UInt8], _ table: [UInt8]) -> Stylesheet {
        var sheet = Stylesheet()
        let fc = Int(oleGetU32(wordDoc, 0xA2) ?? 0)
        let lcb = Int(oleGetU32(wordDoc, 0xA6) ?? 0)
        guard fc + lcb <= table.count, lcb >= 5 else { return sheet }
        let stsh = Array(table[fc..<(fc + lcb)])
        guard let cbSthci = oleGetU16(stsh, 0),
              let cstd = oleGetU16(stsh, 2),
              let cbStdBase = oleGetU16(stsh, 4) else { return sheet }

        var stds: [UInt16: Std] = [:]
        var pos = 2 + Int(cbSthci)
        for istd in 0..<Int(cstd) {
            guard pos + 2 <= stsh.count, let cbStd = oleGetU16(stsh, pos) else { break }
            pos += 2
            if cbStd == 0 { continue }
            guard pos + Int(cbStd) <= stsh.count else { break }
            let record = Array(stsh[pos..<(pos + Int(cbStd))])
            pos += Int(cbStd)
            if let std = parseStd(record, cbStdBase: Int(cbStdBase)) {
                stds[UInt16(istd)] = std
            }
        }

        var memo: [UInt16: ResolvedStyle] = [:]
        for istd in stds.keys {
            sheet.resolved[istd] = resolveStyle(istd, stds: stds, memo: &memo)
        }
        return sheet
    }

    private static func parseStd(_ record: [UInt8], cbStdBase: Int) -> Std? {
        guard let first = oleGetU16(record, 0), let second = oleGetU16(record, 2) else { return nil }
        let sti = first & 0x0FFF
        let sgc = second & 0x000F
        let istdBase = (second >> 4) & 0x0FFF
        let cupx = oleGetU16(record, 4).map { Int($0 & 0x000F) } ?? 0

        // The name (Xstz) follows the fixed STDF area; UPX payloads follow.
        let nameOff = max(cbStdBase, 10)
        guard nameOff + 2 <= record.count,
              let nameLen = oleGetU16(record, nameOff) else { return nil }
        let nameBytes = Int(nameLen) * 2
        let nameSlice = record.count > nameOff + 2
            ? Array(record[(nameOff + 2)..<min(record.count, nameOff + 2 + nameBytes)])
            : []
        let name = utf16leString(nameSlice)
        var upxPos = nameOff + 4 + nameBytes
        guard upxPos <= record.count else { return nil }

        var upx: [[UInt8]] = []
        for _ in 0..<cupx {
            if upxPos % 2 == 1 { upxPos += 1 }
            guard upxPos + 2 <= record.count,
                  let cb = oleGetU16(record, upxPos) else { return nil }
            let payloadEnd = min(upxPos + 2 + Int(cb), record.count)
            upx.append(Array(record[(upxPos + 2)..<payloadEnd]))
            upxPos += 2 + Int(cb)
        }

        let isParagraph = sgc == 1
        let (upxPapx, upxChpx): ([UInt8], [UInt8])
        if isParagraph {
            upxPapx = upx.first ?? []
            upxChpx = upx.count > 1 ? upx[1] : []
        } else {
            upxPapx = []
            upxChpx = upx.first ?? []
        }
        return Std(sti: sti, istdBase: istdBase,
                   block: blockStyleFromName(name),
                   upxPapx: upxPapx, upxChpx: upxChpx,
                   isParagraph: isParagraph)
    }

    /// Resolve one style's istdBase chain, memoized. Cycles cut via a
    /// visited set and resolve from the acyclic prefix.
    private static func resolveStyle(
        _ istd: UInt16, stds: [UInt16: Std], memo: inout [UInt16: ResolvedStyle]
    ) -> ResolvedStyle {
        if let hit = memo[istd] { return hit }
        var chain: [UInt16] = []
        var visiting = Set<UInt16>()
        var base = ResolvedStyle()
        var cursor: UInt16? = istd
        while let cur = cursor {
            if let hit = memo[cur] {
                base = hit
                break
            }
            if !visiting.insert(cur).inserted {
                AnyTypLog.warn("style istdBase cycle at istd \(cur)")
                break
            }
            guard let std = stds[cur] else { break }
            chain.append(cur)
            cursor = std.istdBase != istdNil && std.istdBase != cur ? std.istdBase : nil
        }
        for cur in chain.reversed() {
            guard let std = stds[cur] else { continue }
            if std.isParagraph && std.upxPapx.count >= 2 {
                var delta = PapDelta()
                applyPapSprms(Array(std.upxPapx[2...]), data: [], &delta)
                base.pap = base.pap.merged(delta)
            }
            base.chp = applyChpx(std.upxChpx, base.chp, styleBase: base.chp)
            if (1...9).contains(std.sti) { base.heading = UInt8(std.sti) }
            if base.block == nil { base.block = std.block }
            memo[cur] = base
        }
        return base
    }

    // MARK: - List tables (port of doc/lists.rs)

    struct LevelDef {
        var marker: AnyTypMarkerKind? = .bullet
        var start: UInt64 = 1
        /// Restart rule: nil = restart after any more significant level;
        /// Some(0) = never; Some(n) = restart when ilvl < n is used.
        var restart: UInt32? = nil
        var pattern = NumberPattern()
    }

    struct ListDef {
        var lsid: UInt32
        var levels: [LevelDef]
        var startOverride: [UInt64?]

        static func unknown(_ ilfo: UInt16) -> ListDef {
            ListDef(lsid: UInt32.max ^ UInt32(ilfo),
                    levels: [LevelDef](repeating: LevelDef(), count: DocFormat.levels),
                    startOverride: [UInt64?](repeating: nil, count: DocFormat.levels))
        }
    }

    struct Lists {
        var byIlfo: [UInt16: ListDef] = [:]

        func get(_ ilfo: UInt16) -> ListDef? { byIlfo[ilfo] }
    }

    private static let lstfSize = 28

    private static func parseLists(_ wordDoc: [UInt8], _ table: [UInt8]) -> Lists {
        var lists = Lists()
        let lstFc = Int(oleGetU32(wordDoc, 0x2E2) ?? 0)
        let lstLcb = Int(oleGetU32(wordDoc, 0x2E6) ?? 0)
        let lfoFc = Int(oleGetU32(wordDoc, 0x2EA) ?? 0)
        let lfoLcb = Int(oleGetU32(wordDoc, 0x2EE) ?? 0)
        guard lstLcb > 0 else { return lists }
        let byLsid = parsePlfLst(table, fc: lstFc, lcb: lstLcb)
        guard lfoFc + lfoLcb <= table.count else { return lists }
        parsePlfLfo(Array(table[lfoFc..<(lfoFc + lfoLcb)]), byLsid: byLsid, lists: &lists)
        return lists
    }

    private static func parsePlfLst(
        _ table: [UInt8], fc: Int, lcb: Int
    ) -> [UInt32: [LevelDef]] {
        var out: [UInt32: [LevelDef]] = [:]
        guard fc >= 0, fc <= table.count else { return out }
        let plf = Array(table[fc...])
        guard plf.count >= 2, let count = oleGetU16(plf, 0) else { return out }
        var lstfs: [(UInt32, Bool)] = []
        var pos = 2
        for _ in 0..<Int(count) {
            guard pos + lstfSize <= plf.count,
                  let lsid = oleGetU32(plf, pos) else { return out }
            let simple = plf[pos + 26] & 0x01 != 0
            lstfs.append((lsid, simple))
            pos += lstfSize
        }
        // The LVL array begins where lcbPlfLst ends, relative to `plf`.
        pos = lcb
        for (lsid, simple) in lstfs {
            let nLevels = simple ? 1 : levels
            var defs = [LevelDef](repeating: LevelDef(), count: DocFormat.levels)
            var ok = true
            for slot in 0..<nLevels {
                guard let (def, next) = parseLvl(plf, pos: pos) else { ok = false; break }
                defs[slot] = def
                pos = next
            }
            if !ok { return out }
            if simple {
                let def = defs[0]
                defs = [LevelDef](repeating: def, count: DocFormat.levels)
            }
            out[lsid] = defs
        }
        return out
    }

    /// One LVL: LVLF header + PAPX/CHPX grpprls + number text.
    private static func parseLvl(_ plf: [UInt8], pos: Int) -> (LevelDef, Int)? {
        let lvlSize = 28
        guard pos + lvlSize <= plf.count else { return nil }
        let record = plf
        guard let start = oleGetU32(record, pos),
              pos + lvlSize <= record.count else { return nil }
        let header = Array(record[pos..<(pos + lvlSize)])
        let nfc = header[4]
        let flags = header[5]
        let legal = (flags & 0x04) != 0
        let noRestart = (flags & 0x08) != 0
        let placeholderOffsets = header[6..<15].prefix { $0 != 0 }
        let restartLim = header[26]
        let cbPapx = Int(header[25])
        let cbChpx = Int(header[24])
        var next = lvlSize + cbPapx + cbChpx
        guard pos + next + 2 <= record.count else { return nil }
        let xchCount = Int(oleGetU16(record, pos + next) ?? 0)
        next += 2
        let marker = markerForNfc(nfc)
        var text: [NumberText] = []
        if marker?.ordered == true {
            for i in 0..<xchCount {
                let unit = pos + next + i * 2
                guard unit + 2 <= record.count,
                      let ch = oleGetU16(record, unit) else { break }
                if ch <= 0x08 && placeholderOffsets.contains(UInt8(ch &+ 1)) {
                    text.append(.level(UInt8(ch)))
                } else if let scalar = Unicode.Scalar(ch), !CharacterSet.controlCharacters.contains(scalar) {
                    let c = Character(scalar)
                    if case .literal(let s) = text.last {
                        text[text.count - 1] = .literal(s + String(c))
                    } else {
                        text.append(.literal(String(c)))
                    }
                }
            }
        }
        next += xchCount * 2
        let restart = noRestart ? UInt32(restartLim) : nil
        return (LevelDef(marker: marker, start: UInt64(start), restart: restart,
                         pattern: NumberPattern(text: text, legal: legal)),
                pos + next)
    }

    private static let lfoSize = 16

    private static func parsePlfLfo(
        _ plf: [UInt8], byLsid: [UInt32: [LevelDef]], lists: inout Lists
    ) {
        guard plf.count >= 4, let count = oleGetU32(plf, 0).map(Int.init) else { return }
        var lfos: [(UInt32, Int)] = []
        var pos = 4
        for _ in 0..<count {
            guard pos + lfoSize <= plf.count,
                  let lsid = oleGetU32(plf, pos) else { return }
            let clfolvl = Int(plf[pos + 12])
            lfos.append((lsid, clfolvl))
            pos += lfoSize
        }
        for (i, (lsid, clfolvl)) in lfos.enumerated() {
            let ilfo = UInt16(i + 1)
            var def: ListDef
            if let levels = byLsid[lsid] {
                def = ListDef(lsid: lsid, levels: levels,
                              startOverride: [UInt64?](repeating: nil, count: self.levels))
            } else {
                def = ListDef.unknown(ilfo)
            }
            for _ in 0..<clfolvl {
                guard pos + 8 <= plf.count,
                      let startAt = oleGetU32(plf, pos) else { break }
                let bits = plf[pos + 4]
                let ilvl = Int(bits & 0x0F)
                let fStartAt = (bits & 0x10) != 0
                let fFormatting = (bits & 0x20) != 0
                pos += 8
                if fFormatting {
                    // The override embeds a full LVL; its own start wins.
                    guard let (lvlDef, next) = parseLvl(plf, pos: pos) else { break }
                    if ilvl < levels {
                        if fStartAt { def.startOverride[ilvl] = UInt64(startAt) }
                        def.levels[ilvl] = lvlDef
                    }
                    pos = next
                } else if fStartAt && ilvl < levels {
                    def.levels[ilvl].start = UInt64(startAt)
                    def.startOverride[ilvl] = UInt64(startAt)
                }
            }
            lists.byIlfo[ilfo] = def
        }
    }

    /// MS-OSHARED numbering format codes.
    private static func markerForNfc(_ nfc: UInt8) -> AnyTypMarkerKind? {
        switch nfc {
        case 0: return .decimal
        case 1: return .upperRoman
        case 2: return .lowerRoman
        case 3: return .upperAlpha
        case 4: return .lowerAlpha
        case 23: return .bullet
        case 0xFF: return nil
        default: return .decimal
        }
    }

    // MARK: - Assembly (port of doc/mod.rs Assembler)

    private struct EffectivePap {
        var istd: UInt16
        var effective: PapDelta
    }

    private final class ParaBuilder {
        var inlines: [AnyTypInline] = []
        var fields: [FieldFrame] = []
        var text = ""
        var style = AnyTypStyle.plain

        func flushText() {
            if text.isEmpty { return }
            let t = text
            text = ""
            let inline = AnyTypInline.text(t, style: style)
            if let last = fields.indices.last {
                if !fields[last].inResult {
                    fields[last].instr += inlinesToPlainText([inline])
                } else {
                    fields[last].inlines.append(inline)
                }
            } else {
                inlines.append(inline)
            }
        }

        func pushChar(_ c: Character, style: AnyTypStyle) {
            if style != self.style {
                flushText()
                self.style = style
            }
            text.append(c)
        }

        func pushInline(_ inline: AnyTypInline) {
            flushText()
            if let last = fields.indices.last {
                if fields[last].inResult { fields[last].inlines.append(inline) }
            } else {
                inlines.append(inline)
            }
        }

        func fieldBegin() {
            flushText()
            fields.append(FieldFrame())
        }

        func fieldSeparate() {
            flushText()
            if let last = fields.indices.last { fields[last].inResult = true }
        }

        func fieldEnd() {
            flushText()
            guard let frame = fields.popLast() else { return }
            for inline in fieldResult(frame.instr, content: frame.inlines) {
                if let last = fields.indices.last {
                    if fields[last].inResult { fields[last].inlines.append(inline) }
                } else {
                    inlines.append(inline)
                }
            }
        }

        func finish() -> [AnyTypInline] {
            flushText()
            while !fields.isEmpty { fieldEnd() }
            return inlines
        }
    }

    /// Numbering state keyed by list identity (lsid).
    private final class Counters {
        var state: [UInt32: ([UInt64], [Bool])] = [:]
        var overridden: Set<UInt64> = []

        /// Advance the sequence for (`ilfo`, `level`); returns the value
        /// and, when not reproducible from the marker alone, the label.
        func next(
            _ ilfo: UInt16, _ list: ListDef, _ level: Int
        ) -> (UInt64, String?) {
            let level = min(level, levels - 1)
            let def = list.levels[level]
            let firstUse = !overridden.contains(UInt64(ilfo) * 16 + UInt64(level))
            overridden.insert(UInt64(ilfo) * 16 + UInt64(level))
            let entry = state[list.lsid] ?? ([UInt64](repeating: 0, count: levels),
                                             [Bool](repeating: false, count: levels))
            var values = entry.0
            var started = entry.1
            let value: UInt64
            if let s = list.startOverride[level], firstUse {
                value = s
            } else if started[level] {
                value = values[level] &+ 1
            } else {
                value = def.start
            }
            values[level] = value
            started[level] = true
            for deeper in (level + 1)..<levels {
                let deeperDef = list.levels[deeper]
                let triggered = deeperDef.restart.map { UInt32(level) < $0 } ?? true
                if triggered { started[deeper] = false }
            }
            state[list.lsid] = (values, started)
            let label = compositeLabel(
                def.pattern,
                ownMarker: def.marker ?? .bullet,
                ownValue: value,
                levelMarker: { l in list.levels[min(l, levels - 1)].marker ?? .bullet },
                levelValue: { l in
                    let l = min(l, levels - 1)
                    return started[l] ? values[l] : list.levels[l].start
                })
            return (value, label)
        }
    }

    private struct DocRow {
        var cells: [[AnyTypBlock]]
        var tap: Tap?

        func intoGridRow() -> GridRowInput {
            let header = tap?.header ?? false
            let tap = tap ?? Tap()
            let cells = self.cells.enumerated().map { (k, blocks) -> (blocks: [AnyTypBlock], prop: CellProp) in
                let tc = k < tap.cells.count ? tap.cells[k] : TapCell()
                let right = k + 1 < tap.boundaries.count
                    ? Int64(tap.boundaries[k + 1]) : Int64(k + 1) * 1000
                return (blocks, CellProp(
                    mergeFirst: tc.horzFirst, mergeCont: tc.horzCont,
                    vmergeFirst: tc.vertRestart, vmergeCont: tc.vertCont,
                    right: right))
            }
            return GridRowInput(cells: cells, header: header)
        }
    }

    private struct Assembler {
        var text: TextStream
        var chpx: Runs
        var papx: Runs
        var stylesheet: Stylesheet
        var lists: Lists
        var prcs: [[UInt8]]
        var piecePrcs: [Int?]
        var noteRefs: [Int: String]
        var counters = Counters()
        var data: [UInt8]
        var assets: AssetSink

        /// Effective character style: style chain -> CHPX -> piece Prm.
        func charStyle(_ fc: UInt32, charIndex: Int) -> AnyTypStyle {
            let paraIstd = papx.lookup(fc)?.istd ?? 0
            let chpx = chpx.lookup(fc)?.chpx ?? []
            let istd = chpxIstd(chpx) ?? paraIstd
            let base = stylesheet.get(istd).chp
            var style = applyChpx(chpx, base, styleBase: base)
            if charIndex < text.pieceOf.count {
                let pieceIdx = Int(text.pieceOf[charIndex])
                if pieceIdx < piecePrcs.count,
                   let prcIdx = piecePrcs[pieceIdx],
                   prcIdx >= 0, prcIdx < prcs.count {
                    style = applyChpx(prcs[prcIdx], style, styleBase: base)
                }
            }
            return style
        }

        /// Paragraph properties: style chain -> PAPX -> piece Prm.
        func effectivePap(_ fc: UInt32, charIndex: Int) -> EffectivePap {
            let props = papx.lookup(fc)
            let istd = props?.istd ?? 0
            var effective = stylesheet.get(istd).pap.merged(props?.pap ?? PapDelta())
            if charIndex < text.pieceOf.count {
                let pieceIdx = Int(text.pieceOf[charIndex])
                if pieceIdx < piecePrcs.count, let prcIdx = piecePrcs[pieceIdx],
                   prcIdx >= 0, prcIdx < prcs.count {
                    var prmDelta = PapDelta()
                    applyPapSprms(prcs[prcIdx], data: [], &prmDelta)
                    effective = effective.merged(prmDelta)
                }
            }
            return EffectivePap(istd: istd, effective: effective)
        }

        func buildBlocks(_ lo: Int, _ hi: Int) throws -> [AnyTypBlock] {
            var blocks: [AnyTypBlock] = []
            var listRun: [ListEntry] = []
            var styled = StyledRun.empty
            var cellBlocks: [AnyTypBlock] = []
            var cellStyled = StyledRun.empty
            var row: [[AnyTypBlock]] = []
            var tableRows: [DocRow] = []
            var para = ParaBuilder()

            func flushTable() throws {
                if !cellBlocks.isEmpty { row.append(cellBlocks); cellBlocks = [] }
                if !row.isEmpty {
                    tableRows.append(DocRow(cells: row, tap: nil)); row = []
                }
                if tableRows.isEmpty { return }
                let rows = tableRows.map { $0.intoGridRow() }
                tableRows = []
                if let block = try buildEdgeTable(rows) {
                    blocks.append(block)
                }
            }

            var i = lo
            let end = min(hi, text.chars.count)
            while i < end {
                let c = text.chars[i]
                let fc = text.fcs[i]
                if let id = noteRefs[i] {
                    para.pushInline(.noteRef(id))
                    i += 1
                    continue
                }
                switch c {
                case "\r", "\u{7}", "\u{c}", "\u{e}":
                    let pap = effectivePap(fc, charIndex: i)
                    let inlines = para.finish()
                    para = ParaBuilder()
                    let isCellMark = c == "\u{7}"
                    if pap.effective.inTable == true || isCellMark {
                        styled.flush(&blocks)
                        flushList(&blocks, &listRun)
                        let inner = (pap.effective.itap ?? 1) > 1
                            || pap.effective.innerCell == true
                            || pap.effective.innerTtp == true
                        if inner {
                            emitCellParagraph(pap, inlines, &cellBlocks, &cellStyled)
                        } else if isCellMark && pap.effective.ttp == true {
                            cellStyled.flush(&cellBlocks)
                            if !row.isEmpty {
                                tableRows.append(DocRow(
                                    cells: row, tap: pap.effective.tap))
                                row = []
                            }
                        } else if isCellMark {
                            emitCellParagraph(pap, inlines, &cellBlocks, &cellStyled)
                            cellStyled.flush(&cellBlocks)
                            row.append(cellBlocks)
                            cellBlocks = []
                        } else {
                            emitCellParagraph(pap, inlines, &cellBlocks, &cellStyled)
                        }
                    } else {
                        try flushTable()
                        try emitParagraph(pap, inlines, &blocks, &listRun, &styled)
                    }
                case "\u{b}":
                    para.pushInline(.lineBreak)
                case "\u{13}":
                    para.fieldBegin()
                case "\u{14}":
                    para.fieldSeparate()
                case "\u{15}":
                    para.fieldEnd()
                case "\t":
                    let style = charStyle(fc, charIndex: i)
                    para.pushChar(" ", style: style)
                case "\u{1e}":
                    let style = charStyle(fc, charIndex: i)
                    para.pushChar("-", style: style)
                case "\u{1}":
                    if let image = try pictureAt(fc) {
                        para.pushInline(image)
                    }
                case "\u{2}", "\u{5}", "\u{8}", "\u{1f}":
                    break
                default:
                    if c.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { break }
                    let style = charStyle(fc, charIndex: i)
                    para.pushChar(c, style: style)
                }
                i += 1
            }
            let inlines = para.finish()
            cellStyled.flush(&cellBlocks)
            try flushTable()
            if !inlinesAreEmpty(inlines) {
                styled.flush(&blocks)
                flushList(&blocks, &listRun)
                blocks.append(.paragraph(inlines))
            }
            styled.flush(&blocks)
            flushList(&blocks, &listRun)
            return blocks
        }

        func emitParagraph(
            _ pap: EffectivePap, _ inlines: [AnyTypInline],
            _ blocks: inout [AnyTypBlock], _ listRun: inout [ListEntry],
            _ styled: inout StyledRun
        ) throws {
            let style = stylesheet.get(pap.istd)
            if let blockStyle = style.block {
                flushList(&blocks, &listRun)
                styled.push(blockStyle, inlines, &blocks)
                return
            }
            if inlinesAreEmpty(inlines) {
                styled.flush(&blocks)
                flushList(&blocks, &listRun)
                return
            }
            let heading = style.heading ?? pap.effective.outline.flatMap { $0 }
            if let level = heading {
                styled.flush(&blocks)
                flushList(&blocks, &listRun)
                var content = inlines
                rebaseEmphasis(&content, base: style.chp)
                if let label = headingLabel(pap) {
                    content.insert(.text(label, style: .plain), at: 0)
                }
                blocks.append(.heading(level: Int(level), anchor: nil, content: content))
                return
            }
            // ilfo 0xF801 marks suppressed list numbering.
            let ilfo = pap.effective.ilfo ?? 0
            if ilfo != 0 && ilfo != 0xF801 {
                let ilvl = Int(pap.effective.ilvl ?? 0)
                let fallback = lists.get(ilfo) ?? ListDef.unknown(ilfo)
                let list = lists.get(ilfo) ?? fallback
                let def = list.levels[min(ilvl, levels - 1)]
                if let marker = def.marker {
                    var number: UInt64 = 0
                    var label: String? = nil
                    if marker.ordered {
                        (number, label) = counters.next(ilfo, list, ilvl)
                    }
                    styled.flush(&blocks)
                    listRun.append(ListEntry(
                        level: ilvl,
                        key: ListKey(instance: UInt64(list.lsid), marker: marker),
                        number: number, label: label,
                        blocks: [.paragraph(inlines)]))
                    return
                }
            }
            styled.flush(&blocks)
            flushList(&blocks, &listRun)
            blocks.append(.paragraph(inlines))
        }

        func emitCellParagraph(
            _ pap: EffectivePap, _ inlines: [AnyTypInline],
            _ blocks: inout [AnyTypBlock], _ styled: inout StyledRun
        ) {
            if let blockStyle = stylesheet.get(pap.istd).block {
                styled.push(blockStyle, inlines, &blocks)
            } else {
                styled.flush(&blocks)
                if !inlinesAreEmpty(inlines) {
                    blocks.append(.paragraph(inlines))
                }
            }
        }

        /// Extract the inline picture the character's CHPX points at
        /// (`sprmCPicLocation`), retaining it as an asset.
        func pictureAt(_ fc: UInt32) throws -> AnyTypInline? {
            guard let props = chpx.lookup(fc),
                  let location = chpxPicLocation(props.chpx) else { return nil }
            let offset = Int(location)
            guard offset + 6 <= data.count,
                  let lcb = oleGetU32(data, offset).map(Int.init),
                  offset + lcb <= data.count else {
                AnyTypLog.debug("picture data out of bounds in the Data stream")
                return nil
            }
            guard let cbHeader = oleGetU16(data, offset + 4).map(Int.init),
                  cbHeader <= lcb else { return nil }
            let picf = Array(data[offset..<(offset + lcb)])
            let art = Array(picf[min(cbHeader, picf.count)...])
            guard let blip = officeArtFirstBlip(art, maxBytes: Int(Limits.maxEntryBytes)) else {
                AnyTypLog.debug("skipping picture with no supported blip payload")
                return nil
            }
            let part = "data/pic\(offset).\(blip.ext)"
            let id = try assets.add(mediaType: blip.mediaType, originPart: part, bytes: blip.bytes)
            return .image(alt: "", source: .asset(id))
        }

        /// The visible number label of a numbered heading paragraph.
        func headingLabel(_ pap: EffectivePap) -> String? {
            let ilfo = pap.effective.ilfo ?? 0
            if ilfo == 0 || ilfo == 0xF801 { return nil }
            let ilvl = Int(pap.effective.ilvl ?? 0)
            guard let list = lists.get(ilfo) else { return nil }
            let def = list.levels[min(ilvl, levels - 1)]
            guard let marker = def.marker, marker.ordered else { return nil }
            let (number, label) = counters.next(ilfo, list, ilvl)
            return "\(label ?? marker.label(number)) "
        }
    }
}
