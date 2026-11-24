import Foundation

/// RTF frontend (port of `formats/rtf/`): a position-explicit lexer
/// feeding a state machine, with the font/style/list tables parsed into
/// typed definitions up front. Numbering comes from the list tables —
/// never guessed from label text. Page headers/footers are excluded
/// (fixed policy). Math zones (`\mmath`) degrade to suppressed content:
/// their OMML structure is not reconstructed.
enum RtfFormat {
    static func parse(_ bytes: [UInt8]) -> Result<AnyTypDocument, ConvertError> {
        guard bytes.starts(with: [0x7B, 0x5C, 0x72, 0x74, 0x66]) else {
            return .failure(.malformed(part: nil, detail: "not an RTF file"))
        }
        // The code page must be known before the font table decodes;
        // scan the header for \ansicpg first.
        let defaultEncoding = scanCodepage(bytes)
        let prelude = parseRtfPrelude(bytes, defaultEncoding: defaultEncoding)
        var parser = Parser(bytes: bytes, prelude: prelude, defaultEncoding: defaultEncoding)
        do {
            try parser.run()
            return .success(try parser.finish())
        } catch let e as ConvertError {
            return .failure(e)
        } catch {
            return .failure(.io("\(error)"))
        }
    }

    private static func scanCodepage(_ bytes: [UInt8]) -> String.Encoding {
        var lexer = RtfLexer(bytes)
        while let token = lexer.next() {
            if case .word(let name, let param?) = token, name == "ansicpg" {
                return rtfCodepageEncoding(Int32(clamping: param))
            }
        }
        return .windowsCP1252
    }
}

// MARK: - Lexer (port of rtf/lexer.rs)

enum RtfToken {
    case open
    case close
    /// Control word with optional numeric parameter.
    case word(String, Int?)
    /// Control symbol (`\~`, `\*`, `\{`, ...).
    case symbol(UInt8)
    /// `\'xx` hex-escaped byte in the current code page.
    case hex(UInt8)
    /// One plain text byte.
    case byte(UInt8)
    /// The raw payload of a `\binN` control.
    case bin([UInt8])
}

/// Position-explicit RTF lexer. `\binN` consumes exactly N raw bytes, so
/// binary payloads can never corrupt group state.
struct RtfLexer {
    let bytes: [UInt8]
    private(set) var pos = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func next() -> RtfToken? {
        while pos < bytes.count {
            let b = bytes[pos]
            pos += 1
            switch b {
            case 0x7B: return .open          // {
            case 0x7D: return .close         // }
            case 0x5C: return control()      // backslash
            case 0x0D, 0x0A, 0x00: continue
            default: return .byte(b)
            }
        }
        return nil
    }

    private mutating func control() -> RtfToken? {
        guard pos < bytes.count else { return nil }
        let b = bytes[pos]
        guard b.isASCIIAlphabeticByte else {
            pos += 1
            // A reader treats `\` before CR or LF as a paragraph mark.
            if b == 0x0D || b == 0x0A { return .word("par", nil) }
            if b == 0x27 { // '\'' hex escape
                if pos + 2 <= bytes.count,
                   let hi = hexDigit(bytes[pos]), let lo = hexDigit(bytes[pos + 1]) {
                    pos += 2
                    return .hex(UInt8(hi * 16 + lo))
                }
                return .byte(0x27)
            }
            return .symbol(b)
        }
        let start = pos
        while pos < bytes.count, bytes[pos].isASCIIAlphabeticByte { pos += 1 }
        let name = String(decoding: bytes[start..<pos], as: UTF8.self)
        var param: Int? = nil
        var negative = false
        if pos < bytes.count, bytes[pos] == 0x2D { // '-'
            negative = true
            pos += 1
        }
        let numStart = pos
        while pos < bytes.count, bytes[pos].isASCIIDigitByte { pos += 1 }
        if pos > numStart {
            let n = Int64(String(decoding: bytes[numStart..<pos], as: UTF8.self)) ?? 0
            param = Int(clamping: negative ? -n : n)
        } else if negative {
            pos -= 1
        }
        // One space after a control word is part of the control.
        if pos < bytes.count, bytes[pos] == 0x20 { pos += 1 }
        if name == "bin" {
            let n = max(param ?? 0, 0)
            let end = min(pos + n, bytes.count)
            let payload = Array(bytes[pos..<end])
            pos = end
            return .bin(payload)
        }
        return .word(name, param)
    }

    private func hexDigit(_ b: UInt8) -> Int? {
        switch b {
        case 0x30...0x39: return Int(b - 0x30)
        case 0x41...0x46: return Int(b - 0x41 + 10)
        case 0x61...0x66: return Int(b - 0x61 + 10)
        default: return nil
        }
    }
}

private extension UInt8 {
    var isASCIIAlphabeticByte: Bool {
        (0x41...0x5A).contains(self) || (0x61...0x7A).contains(self)
    }
    var isASCIIDigitByte: Bool { (0x30...0x39).contains(self) }
}

/// Extract the balanced content of destination groups named `name`
/// (`{\name ...}` or `{\*\name ...}`), bin-aware. Returns the byte
/// ranges of the group bodies including the destination word.
func rtfDestinationGroups(_ bytes: [UInt8], name: String) -> [[UInt8]] {
    var out: [[UInt8]] = []
    var lexer = RtfLexer(bytes)
    var depth = 0
    var expectingWordAt: Int? = nil
    var capture: (depth: Int, start: Int)? = nil
    while let token = lexer.next() {
        let before = lexer.pos
        switch token {
        case .open:
            depth += 1
            expectingWordAt = depth
        case .close:
            if let c = capture, depth == c.depth {
                // `before` is after the '}' byte; the body ends before it.
                out.append(Array(bytes[c.start..<(before - 1)]))
                capture = nil
            }
            depth = max(depth - 1, 0)
            expectingWordAt = nil
        case .symbol(0x2A) where expectingWordAt == depth: // '*'
            break
        case .word(let w, _) where expectingWordAt == depth:
            if w == name, capture == nil {
                capture = (depth, lexer.pos)
            }
            expectingWordAt = nil
        default:
            expectingWordAt = nil
        }
    }
    return out
}

// MARK: - Prelude tables (port of rtf/tables.rs)

let rtfListLevels = 9

struct RtfListLevelDef {
    var marker: AnyTypMarkerKind? = .bullet
    var start: UInt64 = 1
    var pattern = NumberPattern()
}

struct RtfListDef {
    var levels = [RtfListLevelDef](repeating: RtfListLevelDef(), count: rtfListLevels)
}

struct RtfStyleDef {
    var outline: UInt8? = nil
    var delta = StyleDelta()
    var block: BlockStyle? = nil
}

struct RtfPrelude {
    /// Font number -> encoding, from `\fcharsetN`.
    var fonts: [Int32: String.Encoding] = [:]
    /// Paragraph style id (`\sN`) -> definition.
    var styles: [Int32: RtfStyleDef] = [:]
    /// `\lsN` -> resolved list definition (through the override table).
    var lists: [Int32: RtfListDef] = [:]
}

private func rtfCodepageEncoding(_ cp: Int32) -> String.Encoding {
    switch cp {
    case 932: return .shiftJIS
    case 1250: return .windowsCP1250
    case 1251: return .windowsCP1251
    case 1253: return .windowsCP1253
    case 1254: return .windowsCP1254
    default:
        // Foundation has no GBK/Big5/EUC-KR/CP1255-1258/874 encoding;
        // those codepages degrade to windows-1252 rather than failing.
        if ![936, 949, 950, 1255, 1256, 1257, 1258, 874].contains(cp), cp != 1252 {
            AnyTypLog.debug("rtf codepage \(cp) has no Foundation encoding; using windows-1252")
        }
        return .windowsCP1252
    }
}

/// `\fcharsetN` -> encoding.
private func rtfCharsetEncoding(_ charset: Int32, _ def: String.Encoding) -> String.Encoding {
    switch charset {
    case 0, 1: return def
    case 128: return .shiftJIS
    case 161: return .windowsCP1253
    case 162: return .windowsCP1254
    case 204: return .windowsCP1251
    case 238: return .windowsCP1250
    default:
        // East-Asian and Middle-Eastern charsets have no Foundation
        // encoding; they degrade to the document default.
        return def
    }
}

/// Collector for the byte payloads of `\leveltext` / `\levelnumbers`
/// destinations inside one level group.
private struct RtfLevelTextCollector {
    /// Which destination is currently receiving bytes (true = leveltext).
    var active: Bool? = nil
    var text: [UInt8] = []
    var numbers: [UInt8] = []
    var legal = false

    mutating func byte(_ b: UInt8) {
        if active == true { text.append(b) }
        else if active == false { numbers.append(b) }
    }

    /// The finished pattern for an ordered level; bullets carry glyph
    /// text, not a pattern.
    mutating func finish(marker: AnyTypMarkerKind?, enc: String.Encoding) -> NumberPattern {
        let pattern: NumberPattern
        if let marker, marker.ordered {
            pattern = NumberPattern(text: buildRtfPattern(text, positions: numbers, enc: enc), legal: legal)
        } else {
            pattern = NumberPattern()
        }
        self = RtfLevelTextCollector()
        return pattern
    }
}

/// Build a number pattern from a `\leveltext` payload (first byte =
/// length, then the characters) and the 1-based placeholder positions
/// listed in `\levelnumbers`.
private func buildRtfPattern(_ text: [UInt8], positions: [UInt8], enc: String.Encoding) -> [NumberText] {
    guard let count = text.first else { return [] }
    let chars = Array(text.dropFirst().prefix(Int(count)))
    var out: [NumberText] = []
    var literal: [UInt8] = []
    func flushLiteral() {
        if !literal.isEmpty {
            out.append(.literal(String(bytes: literal, encoding: enc) ?? ""))
            literal = []
        }
    }
    for (i, b) in chars.enumerated() {
        if b <= 8, positions.contains(UInt8(i + 1)) {
            flushLiteral()
            out.append(.level(UInt8(b)))
        } else {
            literal.append(b)
        }
    }
    flushLiteral()
    return out
}

private func parseRtfPrelude(_ bytes: [UInt8], defaultEncoding: String.Encoding) -> RtfPrelude {
    var prelude = RtfPrelude()
    for group in rtfDestinationGroups(bytes, name: "fonttbl") {
        parseRtfFonttbl(group, fonts: &prelude.fonts, defaultEncoding: defaultEncoding)
    }
    for group in rtfDestinationGroups(bytes, name: "stylesheet") {
        parseRtfStylesheet(group, styles: &prelude.styles, enc: defaultEncoding)
    }
    var byListId: [Int32: RtfListDef] = [:]
    for group in rtfDestinationGroups(bytes, name: "listtable") {
        parseRtfListtable(group, byListId: &byListId, enc: defaultEncoding)
    }
    for group in rtfDestinationGroups(bytes, name: "listoverridetable") {
        parseRtfOverrides(group, byListId: byListId, lists: &prelude.lists, enc: defaultEncoding)
    }
    return prelude
}

private func parseRtfFonttbl(
    _ group: [UInt8], fonts: inout [Int32: String.Encoding], defaultEncoding: String.Encoding
) {
    var lexer = RtfLexer(group)
    var current: Int32? = nil
    while let token = lexer.next() {
        if case .word(let name, let param) = token {
            switch name {
            case "f": current = param.map { Int32(clamping: $0) }
            case "fcharset":
                if let f = current, let cs = param {
                    fonts[f] = rtfCharsetEncoding(Int32(clamping: cs), defaultEncoding)
                }
            default: break
            }
        }
    }
}

/// The null style id: `\sbasedon222` means "based on nothing".
private let rtfNullStyle: Int32 = 222

private func parseRtfStylesheet(
    _ group: [UInt8], styles: inout [Int32: RtfStyleDef], enc: String.Encoding
) {
    var lexer = RtfLexer(group)
    var depth = 0
    var current: (id: Int32, def: RtfStyleDef, base: Int32?)? = nil
    var raw: [Int32: (RtfStyleDef, Int32?)] = [:]
    // A style's name is the text at the end of its group, before the `;`.
    var nameBytes: [UInt8] = []
    while let token = lexer.next() {
        switch token {
        case .open:
            depth += 1
        case .close:
            if depth == 1, let cur = current {
                var def = cur.def
                let text = String(bytes: nameBytes, encoding: enc) ?? ""
                def.block = blockStyleFromName(String(text.reversed().drop(while: { $0 == ";" }).reversed()))
                raw[cur.id] = (def, cur.base)
                current = nil
            }
            nameBytes = []
            depth = max(depth - 1, 0)
        case .hex(let b), .byte(let b) where depth == 1 && current != nil:
            nameBytes.append(b)
        case .word(let word, let param):
            switch word {
            case "s":
                current = (Int32(clamping: param ?? 0), RtfStyleDef(), nil)
                nameBytes = []
            case "sbasedon":
                if var cur = current {
                    if let b = param, b != Int(rtfNullStyle) {
                        cur.base = Int32(clamping: b)
                    }
                    current = cur
                }
            case "outlinelevel":
                if var cur = current, let n = param, (0..<9).contains(n) {
                    cur.def.outline = UInt8(n + 1)
                    current = cur
                }
            case "b":
                if var cur = current {
                    cur.def.delta.bold = param != 0
                    current = cur
                }
            case "i":
                if var cur = current {
                    cur.def.delta.italic = param != 0
                    current = cur
                }
            default: break
            }
        default: break
        }
    }
    // Resolve every \sbasedon chain root-to-leaf: the child's own
    // settings win over inherited ones. A cycle is bounded by the
    // visited set and resolves from the acyclic prefix.
    for id in raw.keys {
        var chain: [RtfStyleDef] = []
        var seen = Set<Int32>()
        var cursor: Int32? = id
        while let cur = cursor {
            if !seen.insert(cur).inserted {
                AnyTypLog.warn("style inheritance cycle at rtf style \(cur)")
                break
            }
            guard let (def, base) = raw[cur] else { break }
            chain.append(def)
            cursor = base
        }
        var resolved = RtfStyleDef()
        for def in chain.reversed() {
            resolved.delta = resolved.delta.merge(def.delta)
            resolved.outline = def.outline ?? resolved.outline
            resolved.block = def.block ?? resolved.block
        }
        styles[id] = resolved
    }
}

private func parseRtfListtable(
    _ group: [UInt8], byListId: inout [Int32: RtfListDef], enc: String.Encoding
) {
    var lexer = RtfLexer(group)
    var depth = 0
    var listDepth: Int? = nil
    var levels = [RtfListLevelDef](repeating: RtfListLevelDef(), count: rtfListLevels)
    var levelIndex = 0
    var inLevel = false
    var listId: Int32? = nil
    var collector = RtfLevelTextCollector()
    while let token = lexer.next() {
        switch token {
        case .open:
            depth += 1
        case .close:
            collector.active = nil
            if inLevel, let ld = listDepth, depth == ld + 1 {
                inLevel = false
                if levelIndex < rtfListLevels {
                    let marker = levels[levelIndex].marker
                    levels[levelIndex].pattern = collector.finish(marker: marker, enc: enc)
                }
                levelIndex += 1
            }
            if listDepth == depth {
                if let id = listId { byListId[id] = RtfListDef(levels: levels) }
                levels = [RtfListLevelDef](repeating: RtfListLevelDef(), count: rtfListLevels)
                levelIndex = 0
                listDepth = nil
            }
            depth = max(depth - 1, 0)
        case .word(let name, let param):
            switch name {
            case "list":
                listDepth = depth
                listId = nil
                levels = [RtfListLevelDef](repeating: RtfListLevelDef(), count: rtfListLevels)
                levelIndex = 0
            case "listid":
                if listDepth != nil { listId = param.map { Int32(clamping: $0) } }
            case "listlevel":
                inLevel = true
                collector = RtfLevelTextCollector()
            case "levelnfc", "levelnfcn":
                if inLevel, levelIndex < rtfListLevels {
                    levels[levelIndex].marker = rtfMarkerForNfc(param ?? 0)
                }
            case "levelstartat":
                if inLevel, levelIndex < rtfListLevels, let n = param {
                    levels[levelIndex].start = UInt64(max(n, 0))
                }
            case "leveltext" where inLevel: collector.active = true
            case "levelnumbers" where inLevel: collector.active = false
            case "levellegal" where inLevel: collector.legal = param != 0
            default: break
            }
        case .hex(let b), .byte(let b):
            collector.byte(b)
        default: break
        }
    }
}

/// MS-OSHARED numbering formats -> marker kinds. `nil` = no number.
private func rtfMarkerForNfc(_ nfc: Int) -> AnyTypMarkerKind? {
    switch nfc {
    case 0: return .decimal
    case 1: return .upperRoman
    case 2: return .lowerRoman
    case 3: return .upperAlpha
    case 4: return .lowerAlpha
    case 23: return .bullet
    case 255: return nil
    default: return .decimal
    }
}

/// Raw override number text: (`\leveltext` bytes, `\levelnumbers` bytes, legal).
private typealias RtfRawLevelText = (text: [UInt8], numbers: [UInt8], legal: Bool)

private func parseRtfOverrides(
    _ group: [UInt8], byListId: [Int32: RtfListDef], lists: inout [Int32: RtfListDef],
    enc: String.Encoding
) {
    var lexer = RtfLexer(group)
    var depth = 0
    var overDepth: Int? = nil
    var lfoDepth: Int? = nil
    var listId: Int32? = nil
    var ls: Int32? = nil
    var levelIndex = 0
    var starts = [UInt64?](repeating: nil, count: rtfListLevels)
    var markers = [AnyTypMarkerKind??](repeating: nil, count: rtfListLevels)
    var texts = [RtfRawLevelText?](repeating: nil, count: rtfListLevels)
    var collector = RtfLevelTextCollector()

    func flush() {
        if let lsN = ls, let id = listId {
            var def = byListId[id] ?? RtfListDef()
            for level in 0..<rtfListLevels {
                if let m = markers[level] { def.levels[level].marker = m }
                if let s = starts[level] { def.levels[level].start = s }
                if let t = texts[level],
                   let marker = def.levels[level].marker, marker.ordered {
                    def.levels[level].pattern = NumberPattern(
                        text: buildRtfPattern(t.text, positions: t.numbers, enc: enc),
                        legal: t.legal)
                }
            }
            lists[lsN] = def
        }
        ls = nil; listId = nil
        starts = [UInt64?](repeating: nil, count: rtfListLevels)
        markers = [AnyTypMarkerKind??](repeating: nil, count: rtfListLevels)
        texts = [RtfRawLevelText?](repeating: nil, count: rtfListLevels)
    }

    while let token = lexer.next() {
        switch token {
        case .open:
            depth += 1
        case .close:
            collector.active = nil
            if lfoDepth == depth {
                lfoDepth = nil
                if levelIndex < rtfListLevels, !collector.text.isEmpty {
                    texts[levelIndex] = (collector.text, collector.numbers, collector.legal)
                }
                collector = RtfLevelTextCollector()
                levelIndex += 1
            }
            if overDepth == depth {
                flush()
                levelIndex = 0
                overDepth = nil
            }
            depth = max(depth - 1, 0)
        case .word(let name, let param):
            switch name {
            case "listoverride":
                // A previous override group left unclosed still counts.
                flush()
                overDepth = depth
                levelIndex = 0
            case "listid" where overDepth != nil:
                listId = param.map { Int32(clamping: $0) }
            case "ls" where overDepth != nil:
                ls = param.map { Int32(clamping: $0) }
            case "lfolevel":
                lfoDepth = depth
                collector = RtfLevelTextCollector()
            case "levelstartat" where lfoDepth != nil:
                if levelIndex < rtfListLevels, let n = param {
                    starts[levelIndex] = UInt64(max(n, 0))
                }
            case "levelnfc", "levelnfcn" where lfoDepth != nil:
                if levelIndex < rtfListLevels {
                    markers[levelIndex] = .some(rtfMarkerForNfc(param ?? 0))
                }
            case "leveltext" where lfoDepth != nil: collector.active = true
            case "levelnumbers" where lfoDepth != nil: collector.active = false
            case "levellegal" where lfoDepth != nil: collector.legal = param != 0
            default: break
            }
        case .hex(let b), .byte(let b):
            collector.byte(b)
        default: break
        }
    }
    flush()
}

// MARK: - Parser state

private enum RtfCapture {
    case none
    case listText
    case fieldInstr
    case bookmark
    /// Inside a `\pict` destination: bytes route to the picture collector.
    case pict
}

private struct RtfCharState {
    var style = AnyTypStyle.plain
    var font: Int32? = nil
    var ucSkip: UInt32 = 1
    var inTable = false
    var itap = 1
    var ilvl = 0
    var ls: Int32? = nil
    var legacyList: AnyTypMarkerKind? = nil
    var outline: UInt8? = nil
    /// The block container this paragraph's style names.
    var block: BlockStyle? = nil
    /// Emphasis the paragraph style itself carries.
    var styleBase = AnyTypStyle.plain
    var suppress = false
    var capture = RtfCapture.none
    var note: AnyTypNoteKind? = nil
}

private struct RtfFieldFrame {
    var depth: Int
    var instr = ""
    var start: Int
}

private struct RtfNoteFrame {
    var depth: Int
    var start: Int
    var kind: AnyTypNoteKind
}

/// Per-instance numbering counters with restart-on-shallower semantics.
private final class RtfCounters {
    private var state: [Int32: (values: [UInt64], started: [Bool])] = [:]

    func next(_ ls: Int32, level: Int, start: UInt64) -> UInt64 {
        let level = min(level, rtfListLevels - 1)
        var (values, started) = state[ls] ?? ([UInt64](repeating: 0, count: rtfListLevels), [Bool](repeating: false, count: rtfListLevels))
        let value: UInt64
        if started[level] {
            value = values[level] &+ 1
        } else {
            value = start
        }
        values[level] = value
        started[level] = true
        for i in (level + 1)..<rtfListLevels { started[i] = false }
        state[ls] = (values, started)
        return value
    }

    /// Advance a table-defined list level and render its composite label
    /// against the live counter values.
    func nextLabeled(_ ls: Int32, level: Int, levels: [RtfListLevelDef]) -> (UInt64, String?) {
        let level = min(level, rtfListLevels - 1)
        let def = levels[level]
        let value = next(ls, level: level, start: def.start)
        var (values, started) = state[ls] ?? ([UInt64](repeating: 0, count: rtfListLevels), [Bool](repeating: false, count: rtfListLevels))
        let label = def.marker.flatMap { marker in
            compositeLabel(
                def.pattern, ownMarker: marker, ownValue: value,
                levelMarker: { l in
                    levels[min(l, rtfListLevels - 1)].marker ?? .decimal
                },
                levelValue: { l in
                    let l = min(l, rtfListLevels - 1)
                    return started[l] ? values[l] : levels[l].start
                })
        }
        state[ls] = (values, started)
        return (value, label)
    }

    /// Pin a counter to a number taken from the source (legacy `\pn` labels).
    func seed(_ ls: Int32, level: Int, value: UInt64) {
        let level = min(level, rtfListLevels - 1)
        var (values, started) = state[ls] ?? ([UInt64](repeating: 0, count: rtfListLevels), [Bool](repeating: false, count: rtfListLevels))
        values[level] = value
        started[level] = true
        for i in (level + 1)..<rtfListLevels { started[i] = false }
        state[ls] = (values, started)
    }
}

/// Byte-level text decoding: pending code-page bytes, `\uN` fallback
/// skips, and surrogate pairing.
private struct RtfTextDecoder {
    var defaultEncoding: String.Encoding
    var pending: [UInt8] = []
    var skip: UInt32 = 0
    var surrogate: UInt16? = nil

    /// Buffer one text byte, honoring an active `\uN` fallback skip.
    mutating func byte(_ b: UInt8) {
        if skip > 0 { skip -= 1 } else { pending.append(b) }
    }

    /// True when an active fallback skip consumed the character.
    mutating func skipChar() -> Bool {
        if skip > 0 { skip -= 1; return true }
        return false
    }

    /// Decode and take the buffered bytes with the current font's encoding.
    mutating func takePending(encoding: String.Encoding?) -> String? {
        if pending.isEmpty { return nil }
        let bytes = pending
        pending = []
        let enc = encoding ?? defaultEncoding
        return String(bytes: bytes, encoding: enc)
            ?? String(decoding: bytes, as: UTF8.self)
    }

    /// `\uN`: the completed scalar (surrogate pairs are held and
    /// combined), arming the `uc_skip`-length fallback skip.
    mutating func unicode(_ param: Int?, ucSkip: UInt32) -> String? {
        // A new \u ends the previous one's fallback range.
        skip = 0
        guard let n = param else { return nil }
        let code = UInt32(n < 0 ? n + 65536 : n)
        var out: String? = nil
        let unit = UInt16(truncatingIfNeeded: code)
        if let high = surrogate {
            surrogate = nil
            if (0xDC00...0xDFFF).contains(unit) {
                let combined = 0x10000 + (UInt32(high) - 0xD800) << 10 + (UInt32(unit) - 0xDC00)
                out = Unicode.Scalar(combined).map { String($0) }
            } else {
                out = Unicode.Scalar(code).map { String($0) }
            }
        } else if (0xD800...0xDBFF).contains(unit) {
            surrogate = unit
        } else {
            out = Unicode.Scalar(code).map { String($0) }
        }
        skip = ucSkip
        return out
    }
}

/// An accumulating `\pict` destination: the payload arrives as ASCII hex
/// characters (or one `\binN` run), typed by a format control word.
private struct RtfPictState {
    /// Group depth of the `\pict` destination itself.
    var depth = 0
    var hex: [UInt8] = []
    var binary: [UInt8]? = nil
    /// (media type, extension); `nil` = unsupported format.
    var format: (String, String)? = nil

    /// The decoded payload bytes.
    func payload() -> [UInt8] {
        if let binary { return binary }
        var out: [UInt8] = []
        out.reserveCapacity(hex.count / 2)
        var high: UInt8? = nil
        for b in hex {
            guard let digit = rtfHexValue(b) else { continue }
            if let h = high {
                out.append((h << 4) | digit)
                high = nil
            } else {
                high = digit
            }
        }
        return out
    }
}

/// Single-byte hex digit value (for `\pict` payload decoding).
private func rtfHexValue(_ b: UInt8) -> UInt8? {
    switch b {
    case 0x30...0x39: return b - 0x30
    case 0x41...0x46: return b - 0x41 + 10
    case 0x61...0x66: return b - 0x61 + 10
    default: return nil
    }
}

/// Destinations whose content is excluded: headers/footers by fixed
/// policy, metadata and binary destinations because they carry no
/// document text.
private let rtfSuppressedDestinations: Set<String> = [
    "fonttbl", "colortbl", "stylesheet", "info", "object",
    "header", "footer", "headerl", "headerr", "headerf",
    "footerl", "footerr", "footerf",
    "ftnsep", "ftnsepc", "aftnsep", "aftnsepc",
    "xmlnstbl", "themedata", "colorschememapping", "datastore",
    "latentstyles", "listtable", "listoverridetable", "rsidtbl",
    "generator", "filetbl", "revtbl", "datafield", "bkmkend",
    "annotation", "atnid", "atnauthor", "template",
    "defchp", "defpap", "panose", "falt", "objdata", "blipuid",
    "nonshppict", "wgrffmtfilter", "pgdsctbl", "docvar",
    "sp", "sn", "sv", "shpinst", "background", "userprops",
    "operator", "author", "title", "subject", "keywords",
    "doccomm", "creatim", "revtim", "printim",
]

// MARK: - Table state (port of rtf/table.rs)

private struct RtfRowBuild {
    var cells: [(blocks: [AnyTypBlock], prop: CellProp)] = []
    var header = false
}

private struct RtfTableBuild {
    var rows: [RtfRowBuild] = []
    /// Props declared by the current `\trowd ... \cellx` run.
    var rowProps: [CellProp] = []
    var propCursor = 0
    var pendingProp = CellProp()
    var row = RtfRowBuild()
    var rowHeader = false
}

/// Table builders indexed by nesting depth - 1, plus the per-depth
/// pending cell content.
private struct RtfTableState {
    var tables: [RtfTableBuild] = []
    var cellBlocks: [[AnyTypBlock]] = [[]]
    var cellRuns: [StyledRun] = [.empty]

    /// Deepest depth with a builder allocated.
    var depth: Int { tables.count }

    private mutating func tableAt(_ depth: Int) -> Int {
        while tables.count < depth { tables.append(RtfTableBuild()) }
        ensureCellDepth(depth)
        return depth - 1
    }

    private mutating func ensureCellDepth(_ depth: Int) {
        while cellBlocks.count < depth { cellBlocks.append([]) }
        while cellRuns.count < depth { cellRuns.append(.empty) }
    }

    /// `\trowd`: reset the row's declared properties.
    mutating func beginRow(_ depth: Int) {
        let i = tableAt(depth)
        tables[i].rowProps = []
        tables[i].propCursor = 0
        tables[i].pendingProp = CellProp()
        tables[i].rowHeader = false
    }

    /// `\trhdr`: the row repeats as a header.
    mutating func markHeaderRow(_ depth: Int) {
        tables[tableAt(depth)].rowHeader = true
    }

    /// The property slot the next `\cellx` will seal.
    mutating func withPendingProp(_ depth: Int, _ f: (inout CellProp) -> Void) {
        let i = tableAt(depth)
        f(&tables[i].pendingProp)
    }

    /// `\cellxN`: seal the pending properties with the right boundary.
    mutating func declareCell(_ depth: Int, right: Int64) {
        let i = tableAt(depth)
        var prop = tables[i].pendingProp
        tables[i].pendingProp = CellProp()
        prop.right = right
        tables[i].rowProps.append(prop)
    }

    /// A paragraph ended inside a cell at `depth`.
    mutating func pushCellParagraph(_ depth: Int, style: BlockStyle?, inlines: [AnyTypInline]) {
        ensureCellDepth(depth)
        if let style {
            cellRuns[depth - 1].push(style, inlines, &cellBlocks[depth - 1])
        } else {
            cellRuns[depth - 1].flush(&cellBlocks[depth - 1])
            if !inlinesAreEmpty(inlines) {
                cellBlocks[depth - 1].append(.paragraph(inlines))
            }
        }
    }

    /// Whether unfinished cell content is pending at `depth`.
    mutating func hasPendingCell(_ depth: Int) -> Bool {
        ensureCellDepth(depth)
        cellRuns[depth - 1].flush(&cellBlocks[depth - 1])
        return !cellBlocks[depth - 1].isEmpty
    }

    /// Whether a row at `depth` is partially built.
    mutating func hasPartialRow(_ depth: Int) -> Bool {
        hasPendingCell(depth)
            || (depth - 1 < tables.count && !tables[depth - 1].row.cells.isEmpty)
    }

    /// `\cell` / `\nestcell`: close the cell, folding in any completed
    /// deeper table.
    mutating func endCell(_ depth: Int, style: BlockStyle?, inlines: [AnyTypInline]) throws {
        pushCellParagraph(depth, style: style, inlines: inlines)
        ensureCellDepth(depth)
        cellRuns[depth - 1].flush(&cellBlocks[depth - 1])
        // A deeper completed table belongs inside this cell.
        try flushIntoCell(depth + 1, into: depth)
        let blocks = cellBlocks[depth - 1]
        cellBlocks[depth - 1] = []
        let i = tableAt(depth)
        let prop = tables[i].propCursor < tables[i].rowProps.count
            ? tables[i].rowProps[tables[i].propCursor] : CellProp()
        tables[i].propCursor += 1
        tables[i].row.cells.append((blocks, prop))
    }

    /// `\row` / `\nestrow`: close the row.
    mutating func endRow(_ depth: Int) {
        let i = tableAt(depth)
        var row = tables[i].row
        row.header = tables[i].rowHeader
        tables[i].propCursor = 0
        tables[i].row = RtfRowBuild()
        if !row.cells.isEmpty { tables[i].rows.append(row) }
    }

    /// Take the finished table at `depth` as a block, if it has rows.
    mutating func takeTable(_ depth: Int) throws -> AnyTypBlock? {
        guard depth - 1 < tables.count, !tables[depth - 1].rows.isEmpty else {
            return nil
        }
        let t = tables[depth - 1]
        tables[depth - 1] = RtfTableBuild()
        let rows = t.rows.map { r in
            GridRowInput(cells: r.cells, header: r.header)
        }
        return try buildEdgeTable(rows)
    }

    /// Build a finished table at `depth` into cell blocks one level up.
    private mutating func flushIntoCell(_ depth: Int, into: Int) throws {
        if let block = try takeTable(depth) {
            ensureCellDepth(into)
            cellRuns[into - 1].flush(&cellBlocks[into - 1])
            cellBlocks[into - 1].append(block)
        }
    }

    /// Collapse any dangling nested tables outward into their parent cells.
    mutating func collapseNested() throws {
        for depth in stride(from: tables.count, through: 2, by: -1) {
            try flushIntoCell(depth, into: depth - 1)
        }
    }
}

// MARK: - Parser

private final class RtfParser {
    private var lexer: RtfLexer
    private var stack: [RtfCharState] = []
    private var state = RtfCharState()
    private let prelude: RtfPrelude
    private var decoder: RtfTextDecoder
    private var recovered = false

    private var inlines: [AnyTypInline] = []
    private var blocks: [AnyTypBlock] = []
    private var listRun: [ListEntry] = []
    private var styled: StyledRun = .empty
    private let counters = RtfCounters()
    private var table = RtfTableState()
    private var fields: [RtfFieldFrame] = []
    private var noteFrames: [RtfNoteFrame] = []
    private var notes: [AnyTypNote] = []
    private var bookmark = ""
    private var listtext: String? = nil
    private var pict: RtfPictState? = nil
    private let assets = AssetSink()

    init(bytes: [UInt8], prelude: RtfPrelude, defaultEncoding: String.Encoding) {
        lexer = RtfLexer(bytes)
        self.prelude = prelude
        decoder = RtfTextDecoder(defaultEncoding: defaultEncoding)
    }

    func run() throws {
        while let token = lexer.next() {
            switch token {
            case .open:
                flushPending()
                stack.append(state)
            case .close:
                flushPending()
                if stack.isEmpty {
                    recovered = true
                } else {
                    state = stack.removeLast()
                }
                let depth = stack.count
                closeFields(depth: depth)
                closeNotes(depth: depth)
                closeBookmark(stillCapturing: state.capture == .bookmark)
                // The pict destination finishes when the stack unwinds
                // past its own group.
                if let p = pict, stack.count < p.depth {
                    try finishPict()
                }
            case .word(let name, let param):
                try controlWord(name, param: param)
            case .symbol(let b):
                controlSymbol(b)
            case .hex(let b), .byte(let b):
                if state.capture == .pict {
                    if var p = pict, stack.count == p.depth {
                        p.hex.append(b)
                        pict = p
                    }
                } else if acceptsText() {
                    decoder.byte(b)
                }
            case .bin(let payload):
                if state.capture == .pict, var p = pict, stack.count == p.depth {
                    p.binary = payload
                    pict = p
                } else {
                    AnyTypLog.debug("skipping \(payload.count) bytes of embedded binary data")
                }
            }
        }
        if !stack.isEmpty { recovered = true }
        if recovered { AnyTypLog.warn("recovered unbalanced rtf groups") }
        flushPending()
        try endParagraph()
    }

    private func acceptsText() -> Bool {
        if case .none = state.capture { return !state.suppress }
        return true
    }

    private func controlSymbol(_ b: UInt8) {
        switch b {
        case 0x7E: pushChar("\u{A0}")          // '~'
        case 0x2D: break                        // '-' soft hyphen: dropped
        case 0x5F: pushChar("-")                // '_'
        case 0x2A: state.suppress = true        // '*'
        case 0x5C, 0x7B, 0x7D: pushChar(String(decoding: [b], as: UTF8.self))
        default: break
        }
    }

    /// Dispatch a control word to its subsystem handler; unhandled words
    /// that name a suppressed destination silence their group.
    private func controlWord(_ word: String, param: Int?) throws {
        if try textControl(word, param: param) { return }
        if try tableControl(word, param: param) { return }
        if listControl(word, param: param) { return }
        if objectControl(word) { return }
        if word == "mmath" {
            // Math zones degrade to suppressed content: their OMML
            // structure is not reconstructed, and suppressing also skips
            // the \mmathPict fallback picture.
            flushPending()
            state.suppress = true
            return
        }
        if rtfSuppressedDestinations.contains(word) {
            flushPending()
            state.suppress = true
            state.capture = .none
        }
    }

    /// Character- and paragraph-level controls.
    private func textControl(_ word: String, param: Int?) throws -> Bool {
        let on = param != 0
        switch word {
        case "u":
            if acceptsText() {
                flushPending()
                if let c = decoder.unicode(param, ucSkip: state.ucSkip) {
                    pushText(c)
                }
            }
        case "uc":
            state.ucSkip = UInt32(clamping: max(param ?? 1, 0))
        case "f":
            flushPending()
            state.font = param.map { Int32(clamping: $0) }
        case "b": setStyle { $0.bold = on }
        case "i": setStyle { $0.italic = on }
        case "ul", "uld", "uldash", "uldb", "ulth", "ulw", "ulwave":
            setStyle { $0.underline = on }
        case "ulnone": setStyle { $0.underline = false }
        case "strike", "striked": setStyle { $0.strike = on }
        case "super":
            setStyle {
                $0.superscript = on
                if on { $0.subscriptText = false }
            }
        case "sub":
            setStyle {
                $0.subscriptText = on
                if on { $0.superscript = false }
            }
        case "nosupersub":
            setStyle {
                $0.superscript = false
                $0.subscriptText = false
            }
        case "plain":
            flushPending()
            let font = state.font
            state.style = .plain
            state.font = font
        case "s":
            // Paragraph style: outline level for headings plus its
            // formatting delta as the new base.
            if let id = param, let def = prelude.styles[Int32(clamping: id)] {
                flushPending()
                state.outline = def.outline
                state.block = def.block
                state.style = def.delta.apply(state.style)
                state.styleBase = state.style
            }
        case "par", "sect":
            flushPending()
            if state.note != nil {
                inlines.append(.lineBreak)
            } else if !state.suppress {
                try endParagraph()
            }
        case "pard":
            flushPending()
            state.inTable = false
            state.itap = 1
            state.ilvl = 0
            state.ls = nil
            state.legacyList = nil
            state.outline = nil
            state.block = nil
            state.styleBase = .plain
        // \page and \column break the flow without ending the
        // paragraph; the page they start is unrepresentable, the word
        // boundary they carry is not.
        case "line", "lbr", "page", "column":
            flushPending()
            if !state.suppress { inlines.append(.lineBreak) }
        case "tab": pushChar(" ")
        case "emdash": pushChar("\u{2014}")
        case "endash": pushChar("\u{2013}")
        case "lquote": pushChar("\u{2018}")
        case "rquote": pushChar("\u{2019}")
        case "ldblquote": pushChar("\u{201C}")
        case "rdblquote": pushChar("\u{201D}")
        case "bullet": pushChar("\u{2022}")
        case "enspace", "emspace", "qmspace": pushChar(" ")
        default: return false
        }
        return true
    }

    /// Table controls, delegated to the per-depth `RtfTableState`.
    private func tableControl(_ word: String, param: Int?) throws -> Bool {
        switch word {
        case "intbl": state.inTable = true
        case "itap":
            state.itap = min(max(param ?? 1, 0), 8)
            if state.itap > 1 { state.inTable = true }
        case "trowd":
            if tableActive() {
                table.beginRow(max(state.itap, 1))
            }
        case "trhdr":
            if tableActive() {
                table.markHeaderRow(max(state.itap, 1))
            }
        case "clmgf": pendingCellProp { $0.mergeFirst = true }
        case "clmrg": pendingCellProp { $0.mergeCont = true }
        case "clvmgf": pendingCellProp { $0.vmergeFirst = true }
        case "clvmrg": pendingCellProp { $0.vmergeCont = true }
        case "cellx":
            if tableActive() {
                table.declareCell(max(state.itap, 1), right: Int64(param ?? 0))
            }
        case "cell":
            flushPending()
            if tableActive() { try endCell(1) }
        case "nestcell":
            flushPending()
            if tableActive() { try endCell(max(state.itap, 2)) }
        case "row":
            flushPending()
            if tableActive() { try endRow(1) }
        case "nestrow":
            flushPending()
            if tableActive() { try endRow(max(state.itap, 2)) }
        // Nested row properties arrive in a `{\*\nesttableprops ...}`
        // destination; its \trowd/\cellx/\nestrow must still act.
        case "nesttableprops": state.suppress = false
        default: return false
        }
        return true
    }

    /// List and outline controls.
    private func listControl(_ word: String, param: Int?) -> Bool {
        switch word {
        case "outlinelevel":
            if let n = param, (0..<9).contains(n) {
                state.outline = UInt8(n + 1)
            }
        case "ilvl": state.ilvl = min(max(param ?? 0, 0), 8)
        case "ls": state.ls = param.map { Int32(clamping: $0) }
        case "listtext", "pntext":
            flushPending()
            state.capture = .listText
            if listtext == nil { listtext = "" }
        case "pnlvlblt": state.legacyList = .bullet
        case "pnlvlbody", "pndec": state.legacyList = .decimal
        default: return false
        }
        return true
    }

    /// Field, footnote, and bookmark controls.
    private func objectControl(_ word: String) -> Bool {
        switch word {
        case "field":
            flushPending()
            if !state.suppress {
                fields.append(RtfFieldFrame(
                    depth: stack.count, instr: "", start: inlines.count))
            }
        case "fldinst":
            flushPending()
            if !fields.isEmpty { state.capture = .fieldInstr }
            state.suppress = true
        case "fldrslt":
            flushPending()
            state.capture = .none
        case "footnote":
            flushPending()
            state.note = .footnote
            state.suppress = false
            state.capture = .none
            noteFrames.append(RtfNoteFrame(
                depth: stack.count, start: inlines.count, kind: .footnote))
        case "ftnalt":
            // Marks the enclosing \footnote as an endnote.
            if !noteFrames.isEmpty { noteFrames[noteFrames.count - 1].kind = .endnote }
        case "chftn": break
        case "bkmkstart":
            flushPending()
            state.capture = .bookmark
            state.suppress = false
        // `{\*\shppict {\pict ...}}` wraps the preferred picture; the
        // `\nonshppict` fallback duplicate stays suppressed.
        case "shppict": state.suppress = false
        // `\shpinst` itself is suppressed, but its `\shptxt` destination
        // holds the shape's real text.
        case "shptxt": state.suppress = false
        // Likewise `\object` is suppressed, but `\result` is the
        // object's displayable rendering.
        case "result": state.suppress = false
        case "pict":
            // A pict inside a suppressed destination is not extracted.
            if !state.suppress {
                flushPending()
                state.capture = .pict
                pict = RtfPictState(depth: stack.count)
            }
        case "pngblip": setPictFormat("image/png", "png")
        case "jpegblip": setPictFormat("image/jpeg", "jpg")
        case "emfblip": setPictFormat("image/emf", "emf")
        case "wmetafile": setPictFormat("image/wmf", "wmf")
        case "macpict", "dibitmap", "wbitmap": setPictFormat(nil, nil)
        default: return false
        }
        return true
    }

    private func setPictFormat(_ mediaType: String?, _ ext: String?) {
        if state.capture == .pict, pict != nil {
            pict?.format = mediaType.map { ($0, ext ?? "bin") }
        }
    }

    /// Finalize a closed `\pict` destination: retain the payload as an
    /// asset and emit its inline reference. Unsupported formats degrade
    /// with a log.
    private func finishPict() throws {
        guard let p = pict else { return }
        pict = nil
        guard let (mediaType, ext) = p.format else {
            AnyTypLog.debug("skipping picture in an unsupported format")
            return
        }
        let bytes = p.payload()
        if bytes.isEmpty { return }
        let part = "pict/\(assets.assets.count).\(ext)"
        let id = try assets.add(mediaType: mediaType, originPart: part, bytes: bytes)
        inlines.append(.image(alt: "", source: .asset(id)))
    }

    /// Table controls act outside suppressed groups and note bodies.
    private func tableActive() -> Bool {
        !state.suppress && state.note == nil
    }

    private func pendingCellProp(_ f: (inout CellProp) -> Void) {
        if tableActive() {
            let depth = max(state.itap, 1)
            table.withPendingProp(depth, f)
        }
    }

    private func setStyle(_ f: (inout AnyTypStyle) -> Void) {
        flushPending()
        f(&state.style)
    }

    private func pushChar(_ c: String) {
        if !acceptsText() { return }
        if decoder.skipChar() { return }
        flushPending()
        pushText(c)
    }

    private func flushPending() {
        let encoding = state.font.flatMap { prelude.fonts[$0] }
        if let text = decoder.takePending(encoding: encoding) {
            pushText(text)
        }
    }

    private func pushText(_ text: String) {
        let text = SharedText.clean(text)
        if text.isEmpty { return }
        switch state.capture {
        case .listText:
            listtext = (listtext ?? "") + text
        case .fieldInstr:
            if !fields.isEmpty {
                fields[fields.count - 1].instr += text
            }
        case .bookmark:
            bookmark += text
        case .pict:
            break // Picture payload bytes are collected raw in the token loop.
        case .none:
            if !state.suppress {
                inlines.append(.text(text, style: state.style))
            }
        }
    }

    /// Close field frames opened deeper than `depth`, folding their
    /// results back into the inline stream.
    private func closeFields(depth: Int) {
        while let f = fields.last, f.depth > depth {
            fields.removeLast()
            let start = min(f.start, inlines.count)
            let content = Array(inlines[start...])
            inlines.removeSubrange(start...)
            inlines.append(contentsOf: fieldResult(f.instr, content: content))
        }
    }

    /// Close note frames opened deeper than `depth`, replacing their
    /// content with a reference to the collected note.
    private func closeNotes(depth: Int) {
        while let f = noteFrames.last, f.depth > depth {
            noteFrames.removeLast()
            let start = min(f.start, inlines.count)
            let content = Array(inlines[start...])
            inlines.removeSubrange(start...)
            if !inlinesAreEmpty(content) {
                let id = "rtf\(notes.count)"
                notes.append(AnyTypNote(id: id, kind: f.kind, blocks: [.paragraph(content)]))
                inlines.append(.noteRef(id))
            }
        }
    }

    /// Emit a completed bookmark capture as an anchor.
    private func closeBookmark(stillCapturing: Bool) {
        if !stillCapturing, !bookmark.isEmpty {
            let name = bookmark.trimmingCharacters(in: .whitespacesAndNewlines)
            bookmark = ""
            if !name.isEmpty { inlines.append(.anchor(name)) }
        }
    }

    /// Flush the finished top-level table, if any, into the block stream.
    private func flushTopTable() throws {
        if let block = try table.takeTable(1) {
            flushRuns()
            blocks.append(block)
        }
    }

    private func endParagraph() throws {
        let paraInlines = inlines
        inlines = []
        let capturedListtext = listtext
        listtext = nil

        if state.inTable {
            let depth = max(state.itap, 1)
            table.pushCellParagraph(depth, style: state.block, inlines: paraInlines)
            return
        }
        try flushTopTable()

        // A styled container absorbs its blank paragraphs: they are the
        // blank lines of a code block.
        if let style = state.block {
            flushList(&blocks, &listRun)
            styled.push(style, paraInlines, &blocks)
            return
        }
        if inlinesAreEmpty(paraInlines) {
            flushRuns()
            return
        }
        // Numbering identity comes from the list tables; the captured
        // label text only seeds legacy Word-95 numbering. Numbered
        // headings advance the sequence and keep their number visible.
        let entry = listEntry(listtext: capturedListtext)
        if let level = state.outline {
            flushRuns()
            var content = paraInlines
            rebaseEmphasis(&content, base: state.styleBase)
            if let e = entry, e.key.marker.ordered {
                let text = "\(e.label ?? e.key.marker.label(e.number)) "
                content.insert(.text(text, style: .plain), at: 0)
            }
            blocks.append(.heading(level: Int(level), anchor: nil, content: content))
            return
        }
        if let e = entry {
            listRun.append(ListEntry(
                level: e.level, key: e.key, number: e.number,
                label: e.label, blocks: [.paragraph(paraInlines)]))
            return
        }
        flushRuns()
        blocks.append(.paragraph(paraInlines))
    }

    /// A captured `\listtext` as a literal marker label.
    private static func trimmedLabel(_ listtext: String?) -> String? {
        guard let t = listtext?.trimmingCharacters(in: .whitespacesAndNewlines),
              !t.isEmpty else { return nil }
        return t
    }

    private func listEntry(listtext: String?)
        -> (key: ListKey, level: Int, number: UInt64, label: String?)? {
        if let ls = state.ls {
            let level = state.ilvl
            if let list = prelude.lists[ls] {
                let def = list.levels[min(level, rtfListLevels - 1)]
                guard let marker = def.marker else { return nil }
                if marker.ordered {
                    let (number, label) = counters.nextLabeled(ls, level: level, levels: list.levels)
                    return (ListKey(instance: UInt64(bitPattern: Int64(ls)), marker: marker), level, number, label)
                }
                return (ListKey(instance: UInt64(bitPattern: Int64(ls)), marker: marker), level, 0, nil)
            }
            // No table definition behind the \ls: the captured \listtext
            // is the only surviving evidence of the real marker.
            return (
                ListKey(instance: UInt64(bitPattern: Int64(ls)), marker: .bullet),
                level, 0, RtfParser.trimmedLabel(listtext))
        }
        if let marker = state.legacyList {
            let number: UInt64
            if marker.ordered {
                // Legacy \pn numbering: the label text carries the
                // number, clamped so a crafted label cannot overflow.
                if let t = listtext {
                    let digits = String(t.prefix { $0.isNumber && $0.isASCII })
                    if let n = UInt64(digits), n <= UInt64(UInt32.max) {
                        counters.seed(Int32.max, level: state.ilvl, value: n)
                        number = n
                    } else {
                        number = counters.next(Int32.max, level: state.ilvl, start: 1)
                    }
                } else {
                    number = counters.next(Int32.max, level: state.ilvl, start: 1)
                }
            } else {
                number = 0
            }
            return (ListKey(instance: UInt64.max, marker: marker), state.ilvl, number, nil)
        }
        // A bare \listtext with no list state still marks a list
        // paragraph; its text is the literal marker.
        if let label = RtfParser.trimmedLabel(listtext) {
            return (
                ListKey(instance: UInt64.max - 1, marker: .bullet),
                state.ilvl, 0, label)
        }
        return nil
    }

    private func endCell(_ depth: Int) throws {
        let paraInlines = inlines
        inlines = []
        listtext = nil
        try table.endCell(depth, style: state.block, inlines: paraInlines)
    }

    private func endRow(_ depth: Int) throws {
        if table.hasPendingCell(depth) || !inlinesAreEmpty(inlines) {
            try endCell(depth)
        }
        table.endRow(depth)
    }

    /// Close every open block run before something else is emitted.
    private func flushRuns() {
        styled.flush(&blocks)
        flushList(&blocks, &listRun)
    }

    func finish() throws -> AnyTypDocument {
        for depth in stride(from: table.depth, through: 1, by: -1) {
            if table.hasPartialRow(depth) {
                try endRow(depth)
            }
        }
        try table.collapseNested()
        try flushTopTable()
        flushRuns()
        return AnyTypDocument(blocks: blocks, notes: notes, assets: assets.assets)
    }
}

private typealias Parser = RtfParser
