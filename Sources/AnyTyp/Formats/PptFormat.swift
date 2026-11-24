import Foundation

/// Legacy PowerPoint 97-2003 binary (.ppt) frontend (port of
/// `formats/ppt/mod.rs`): OLE2 container, record stream. Slides resolve
/// through the persist directory (the only default path); text comes from
/// TextHeaderAtom + TextCharsAtom/TextBytesAtom with StyleTextPropAtom
/// runs and TxMasterStyleAtom defaults applied. Raw stream-order scanning
/// exists only as an explicitly labelled recovery for files whose persist
/// directory is unusable. Speaker notes are included (fixed policy),
/// rendered as a quote after their slide.
enum PptFormat {
    /// One master's per-text-type level defaults, keyed by
    /// TxMasterStyleAtom instance (the text type).
    typealias MasterStyles = [UInt16: [PptMasterLevel]]

    static func parse(_ bytes: [UInt8]) -> Result<AnyTypDocument, ConvertError> {
        guard let ole = try? OleFile(bytes: bytes) else {
            return .failure(.malformed(
                part: nil, detail: "not an OLE2 compound file"))
        }
        let data: [UInt8]
        do {
            data = try readOleStream(ole, "PowerPoint Document")
        } catch {
            return .failure(error as? ConvertError ?? .io("\(error)"))
        }
        let currentUser = (try? readOleStream(ole, "Current User")) ?? []
        if oleGetU32(currentUser, 12) == 0xF3D1_C4DF {
            return .failure(.encrypted)
        }

        var ex = Extractor()
        do {
            if !(try ex.parseSlides(data, currentUser: currentUser)) {
                // Labelled recovery path: the persist directory is
                // unusable, so text is taken in raw stream order (may
                // include superseded edits).
                AnyTypLog.warn("ppt persist directory unusable; recovering text in raw stream order")
                ex = Extractor()
                ex.recovering = true
                try ex.walk(data)
                ex.endSegment(nil)
            }
        } catch let e as ConvertError {
            return .failure(e)
        } catch {
            return .failure(.io("\(error)"))
        }
        if ex.encrypted { return .failure(.encrypted) }

        let assets: [AnyTypAsset]
        do {
            assets = try collectPictures(ole)
        } catch let e as ConvertError {
            return .failure(e)
        } catch {
            return .failure(.io("\(error)"))
        }
        return .success(AnyTypDocument(
            blocks: ex.intoBlocks(), notes: [], assets: assets))
    }

    /// Retain the deck's embedded pictures from the `Pictures` stream
    /// (OfficeArt BStore file blocks). Pictures are document-level
    /// assets; per-slide placement is not resolved. Unsupported formats
    /// degrade with a log.
    private static func collectPictures(_ ole: OleFile) throws -> [AnyTypAsset] {
        guard ole.exists("Pictures"),
              let pictures = try? readOleStream(ole, "Pictures") else {
            return []
        }
        let sink = AssetSink()
        var pos = 0
        var index: UInt32 = 0
        let cap = Int(Limits.maxEntryBytes)
        while let (verInst, recType, body) = officeArtRecordAt(pictures, pos) {
            pos += 8 + body.count
            index += 1
            if index > 100_000 { break }
            let blip = recType == 0xF007
                ? officeArtFbseBlip(Array(body), maxBytes: cap)
                : officeArtDecodeBlip(verInst, recType, Array(body), maxBytes: cap)
            if let blip {
                _ = try sink.add(
                    mediaType: blip.mediaType,
                    originPart: "pictures/\(index).\(blip.ext)",
                    bytes: blip.bytes)
            } else {
                AnyTypLog.debug(String(format: "skipping unsupported Pictures record 0x%04X", recType))
            }
        }
        return sink.assets
    }

    /// Iterate the records laid out back to back in `data`.
    struct PptRecords {
        let data: [UInt8]
        var pos = 0

        mutating func next() -> (UInt16, UInt16, ArraySlice<UInt8>)? {
            guard let (v, t, b) = officeArtRecordAt(data, pos) else { return nil }
            pos += 8 + b.count
            return (v, t, b)
        }
    }

    /// A text shape being accumulated: header type, text, then styling.
    struct PendingShape {
        var txType: UInt8
        var text = ""
        var styles: PptStyleRuns? = nil
    }

    /// Finished segments: (blocks, pairing id, is_notes).
    typealias Segment = (blocks: [AnyTypBlock], id: UInt32?, isNotes: Bool)

    final class Extractor {
        var segments: [Segment] = []
        var current: [AnyTypBlock] = []
        var currentIsNotes = false
        var listRun: [ListEntry] = []
        var pending: PendingShape? = nil
        /// Master style tables in master-list order: (masterId, styles).
        var masters: [(UInt32, MasterStyles)] = []
        /// Index into `masters` for the slide being extracted (0
        /// fallback).
        var activeMaster = 0
        var shapeCounter: UInt64 = 0
        var encrypted = false
        /// Raw-stream recovery: no persist lists, so notes descend
        /// inline.
        var recovering = false
        /// Records visited across the whole extraction, capped.
        var records: UInt64 = 0
    }

    /// The persist-resolved layout of the presentation: slide/notes
    /// lists from the current DocumentContainer, persist id -> offset
    /// for every container.
    struct DocLayout {
        var persist: [UInt32: Int]
        var slideList: ArraySlice<UInt8>
        var notesList: ArraySlice<UInt8>?
        var masterList: ArraySlice<UInt8>?
    }

    /// Resolve the UserEditAtom chain into the persist directory and
    /// find the DocumentContainer's SlideListWithText instances. `nil`
    /// means the persist directory is unusable and the caller falls back
    /// to raw-order recovery.
    static func locateDocument(_ data: [UInt8], currentUser: [UInt8]) -> DocLayout? {
        var persist: [UInt32: Int] = [:]
        var docPersist: UInt32? = nil
        var editOff = Int(oleGetU32(currentUser, 16) ?? 0)
        for _ in 0..<100 {
            if editOff == 0 { break }
            guard let (_, recType, body) = officeArtRecordAt(data, editOff),
                  recType == 0x0FF5 else { return nil }
            if docPersist == nil { docPersist = oleGetU32(bodyArr(body), 16) }
            guard let dirOff = oleGetU32(bodyArr(body), 12).map(Int.init),
                  let dirRec = officeArtRecordAt(data, dirOff),
                  dirRec.1 == 0x1772 else {
                return nil
            }
            let dir = dirRec.2
            var d = dir
            while d.count >= 4 {
                guard let head = oleGetU32(Array(d), 0) else { break }
                let id = head & 0xF_FFFF
                let count = Int(head >> 20)
                d = d.dropFirst(4)
                for k in 0..<count {
                    // Newer edits win: keep the first offset seen.
                    if persist[id &+ UInt32(k)] == nil,
                       let off = oleGetU32(Array(d), 0) {
                        persist[id &+ UInt32(k)] = Int(off)
                    }
                    d = d.dropFirst(4)
                }
            }
            let prev = oleGetU32(bodyArr(body), 8).map(Int.init) ?? 0
            if prev == editOff { break }
            editOff = prev
        }
        guard let docOff = persist[docPersist ?? 0] else { return nil }
        guard let docRec = officeArtRecordAt(data, docOff),
              docRec.1 == 0x03E8 else {
            return nil
        }
        let doc = docRec.2
        var recs = PptRecords(data: Array(doc))
        var slideList: ArraySlice<UInt8>? = nil
        var notesList: ArraySlice<UInt8>? = nil
        var masterList: ArraySlice<UInt8>? = nil
        while let (verInst, recType, body) = recs.next() {
            if recType == 0x0FF0 && verInst >> 4 == 0 {
                slideList = body
            } else if recType == 0x0FF0 && verInst >> 4 == 2 {
                notesList = body
            } else if recType == 0x0FF0 && verInst >> 4 == 1 {
                masterList = body
            }
        }
        guard let slideList else { return nil }
        return DocLayout(
            persist: persist, slideList: slideList,
            notesList: notesList, masterList: masterList)
    }

    static func bodyArr(_ s: ArraySlice<UInt8>) -> [UInt8] { Array(s) }

    /// One master's TxMasterStyleAtoms, keyed by text-type instance.
    static func masterStyles(_ master: ArraySlice<UInt8>) -> MasterStyles {
        var styles = MasterStyles()
        var recs = PptRecords(data: Array(master))
        while let (verInst, recType, body) = recs.next() {
            if recType == 0x0FA3 {
                let instance = verInst >> 4
                if styles[instance] == nil {
                    styles[instance] = pptParseMasterStyle(Array(body), instance: instance)
                }
            }
        }
        return styles
    }

    /// Masters in master-list order (MasterPersistAtoms: persistIdRef at
    /// 0, masterId at 12); falls back to a persist-directory scan when
    /// the list is absent so single-master decks still get their
    /// defaults.
    static func collectMasters(
        _ masterList: ArraySlice<UInt8>?, persist: [UInt32: Int], data: [UInt8]
    ) -> [(UInt32, MasterStyles)] {
        var out: [(UInt32, MasterStyles)] = []
        if let list = masterList {
            var recs = PptRecords(data: Array(list))
            while let (_, recType, body) = recs.next() {
                if recType != 0x03F3 { continue }
                guard let persistRef = oleGetU32(Array(body), 0),
                      let masterId = oleGetU32(Array(body), 12),
                      let off = persist[persistRef],
                      let masterRec = officeArtRecordAt(data, off),
                      masterRec.1 == 0x03F8 else {
                    continue
                }
                let master = masterRec.2
                out.append((masterId, masterStyles(master)))
            }
        }
        if out.isEmpty {
            for off in persist.values.sorted() {
                if let masterRec = officeArtRecordAt(data, off),
                   masterRec.1 == 0x03F8 {
                    out.append((0, masterStyles(masterRec.2)))
                }
            }
        }
        return out
    }

}

extension PptFormat.Extractor {
        /// Walk slides in presentation order: the UserEditAtom chain
        /// yields the persist directory, the DocumentContainer's
        /// SlideListWithText yields slide order and outline text, each
        /// slide container its own textboxes. `false` means the persist
        /// directory was unusable.
        func parseSlides(_ data: [UInt8], currentUser: [UInt8]) throws -> Bool {
            guard let layout = PptFormat.locateDocument(data, currentUser: currentUser) else {
                return false
            }
            masters = PptFormat.collectMasters(
                layout.masterList, persist: layout.persist, data: data)
            try walkSlideList(
                layout.slideList, persist: layout.persist, data: data,
                isNotes: false, containerType: 0x03EE)
            if let notesList = layout.notesList {
                try walkSlideList(
                    notesList, persist: layout.persist, data: data,
                    isNotes: true, containerType: 0x03F0)
            }
            return true
        }

        func walkSlideList(
            _ list: ArraySlice<UInt8>, persist: [UInt32: Int], data: [UInt8],
            isNotes: Bool, containerType: UInt16
        ) throws {
            // (persistIdRef, slideId) of the page whose container is
            // pending.
            var pending: (UInt32, UInt32)? = nil
            var recs = PptFormat.PptRecords(data: Array(list))
            while let (verInst, recType, body) = recs.next() {
                if recType == 0x03F3 {
                    // SlidePersistAtom: the next slide/notes page begins.
                    let id = try finishSlide(
                        pending, persist: persist, data: data,
                        containerType: containerType, isNotes: isNotes)
                    endSegment(id)
                    currentIsNotes = isNotes
                    let b = Array(body)
                    pending = oleGetU32(b, 0)
                        .map { ($0, oleGetU32(b, 12) ?? 0) }
                    if !isNotes {
                        selectMaster(pending.map { $0.0 }, persist: persist, data: data)
                    }
                } else {
                    try record(verInst, recType: recType, Array(body))
                }
            }
            let id = try finishSlide(
                pending, persist: persist, data: data,
                containerType: containerType, isNotes: isNotes)
            endSegment(id)
        }

        /// Emit a slide's own textboxes after its outline text. Returns
        /// the segment's pairing id: the slideId for slides, or the
        /// owning slide's id (NotesAtom slideIdRef) for notes pages.
        func finishSlide(
            _ pending: (UInt32, UInt32)?, persist: [UInt32: Int], data: [UInt8],
            containerType: UInt16, isNotes: Bool
        ) throws -> UInt32? {
            guard let (persistRef, slideId) = pending else { return nil }
            var id: UInt32? = isNotes ? nil : (slideId != 0 ? slideId : nil)
            if let off = persist[persistRef],
               let (_, t, body) = officeArtRecordAt(data, off),
               t == containerType {
                if isNotes {
                    // NotesAtom.slideIdRef names the owning slide
                    // (0 = none).
                    var recs = PptFormat.PptRecords(data: Array(body))
                    while let (_, rt, atom) = recs.next() {
                        if rt == 0x03F1 {
                            let v = oleGetU32(Array(atom), 0) ?? 0
                            id = v != 0 ? v : nil
                            break
                        }
                    }
                }
                try walk(Array(body))
            }
            return id
        }

        func endSegment(_ id: UInt32?) {
            flushShape()
            flushList(&current, &listRun)
            if !current.isEmpty {
                segments.append((blocks: current, id: id, isNotes: currentIsNotes))
                current = []
            }
        }

        func intoBlocks() -> [AnyTypBlock] {
            endSegment(nil)
            var slides: [(UInt32?, [AnyTypBlock])] = []
            var notes: [(UInt32?, [AnyTypBlock])] = []
            for seg in segments {
                if seg.isNotes {
                    notes.append((seg.id, seg.blocks))
                } else {
                    slides.append((seg.id, seg.blocks))
                }
            }
            // Notes pages pair to slides by their stored slide id, not
            // by list position: the notes list may be sparse (notes on
            // only some slides), which order-based zipping would
            // misattribute.
            var used = [Bool](repeating: false, count: notes.count)
            var out: [AnyTypBlock] = []
            for (sid, blocks) in slides {
                out.append(contentsOf: blocks)
                for i in notes.indices where !used[i] && sid != nil && notes[i].0 == sid {
                    used[i] = true
                    out.append(.blockQuote(notes[i].1))
                    notes[i].1 = []
                }
            }
            // Notes without a resolvable owner keep document order at
            // the end.
            for i in notes.indices where !used[i] && !notes[i].1.isEmpty {
                out.append(.blockQuote(notes[i].1))
            }
            return out
        }

        /// Pick the master the slide references (SlideAtom.masterIdRef
        /// at offset 12); the first listed master is the deterministic
        /// fallback.
        func selectMaster(_ slide: UInt32?, persist: [UInt32: Int], data: [UInt8]) {
            activeMaster = slide
                .flatMap { persist[$0] }
                .flatMap { officeArtRecordAt(data, $0) }
                .flatMap { v, t, body in t == 0x03EE ? body : nil }
                .flatMap { body -> UInt32? in
                    var recs = PptFormat.PptRecords(data: Array(body))
                    while let (_, rt, atom) = recs.next() {
                        if rt == 0x03EF { return oleGetU32(Array(atom), 12) }
                    }
                    return nil
                }
                .flatMap { mid in masters.firstIndex { $0.0 == mid } }
                ?? 0
        }

        /// Iterative container walk over an explicit stack with fixed
        /// depth and record-count bounds — nesting or record counts
        /// beyond any real presentation are attack shapes and
        /// hard-fail.
        func walk(_ data: [UInt8]) throws {
            // (buffer, position) ranges.
            var stack: [([UInt8], Int)] = [(data, 0)]
            while let top = stack.last {
                let (buf, pos0) = top
                guard let (verInst, recType, body) = officeArtRecordAt(
                    buf, pos0) else {
                    stack.removeLast()
                    continue
                }
                let pos = pos0 + 8 + body.count
                stack[stack.count - 1].1 = pos
                try chargeRecord()
                if verInst & 0xF != 0xF {
                    atom(recType, Array(body))
                    continue
                }
                switch recType {
                // CryptSession10Container: the stream is encrypted.
                case 0x2F14:
                    encrypted = true
                // Notes containers are walked via the notes list;
                // recovery has no lists, so their text is taken inline
                // (as notes). A NotesAtom slideIdRef in the masters
                // range (high bit set) marks the notes master:
                // template chrome, excluded.
                case 0x03F0 where recovering:
                    var recs = PptFormat.PptRecords(data: Array(body))
                    var isMaster = false
                    while let (_, rt, atom) = recs.next() {
                        if rt == 0x03F1 {
                            let id = oleGetU32(Array(atom), 0) ?? 0
                            isMaster = id & 0x8000_0000 != 0
                            break
                        }
                    }
                    if !isMaster {
                        endSegment(nil)
                        currentIsNotes = true
                        try walk(Array(body))
                        endSegment(nil)
                        currentIsNotes = false
                    }
                // Notes, master, and handout containers are walked via
                // their own lists, not inline.
                case 0x03F0, 0x03F8, 0x0FC9:
                    break
                // Only instance 0 of SlideListWithText holds slide text
                // here.
                case 0x0FF0 where verInst >> 4 != 0:
                    break
                default:
                    if stack.count >= Limits.maxRecordDepth {
                        throw ConvertError.resourceLimit(
                            limit: "max_record_depth",
                            detail: "record nesting exceeds \(Limits.maxRecordDepth)")
                    }
                    stack.append((Array(body), 0))
                }
            }
        }

        /// One record outside `walk` (slide-list traversal): containers
        /// descend through the bounded walk, atoms extract directly.
        func record(_ verInst: UInt16, recType: UInt16, _ body: [UInt8]) throws {
            try chargeRecord()
            if verInst & 0xF == 0xF {
                switch recType {
                case 0x2F14: encrypted = true
                case 0x03F0, 0x03F8, 0x0FC9: break
                case 0x0FF0 where verInst >> 4 != 0: break
                default: try walk(body)
                }
            } else {
                atom(recType, body)
            }
        }

        func chargeRecord() throws {
            records += 1
            if records > Limits.maxRecords {
                throw ConvertError.resourceLimit(
                    limit: "max_records",
                    detail: "record stream exceeds \(Limits.maxRecords) records")
            }
        }

        func atom(_ recType: UInt16, _ body: [UInt8]) {
            switch recType {
            // TextHeaderAtom: a new text shape begins.
            case 0x0F9F:
                flushShape()
                pending = PptFormat.PendingShape(txType: body.first ?? 1)
            // TextCharsAtom: UTF-16LE.
            case 0x0FA0:
                pushText(utf16leString(body))
            // TextBytesAtom: low bytes of UTF-16 code units.
            case 0x0FA8:
                pushText(String(bytes: body, encoding: .isoLatin1) ?? "")
            // StyleTextPropAtom: styling for the pending shape's text.
            case 0x0FA1:
                if var p = pending {
                    let len = p.text.utf16.count
                    p.styles = pptParseStyleText(body, textLen: len)
                    pending = p
                }
            // ExHyperlinkAtom: explicit degradation — hyperlink targets
            // in the legacy record stream are not resolved to link
            // inlines.
            case 0x0FD3:
                AnyTypLog.debug("ppt hyperlink records present; targets are not resolved")
            default:
                break
            }
        }

        func pushText(_ text: String) {
            if pending != nil {
                pending?.text += text
            } else {
                pending = PptFormat.PendingShape(txType: 1, text: text)
            }
        }

        /// Emit the pending shape: paragraphs split on CR, styled by the
        /// character runs, listed by paragraph depth/bullet with master
        /// defaults.
        func flushShape() {
            guard let shape = pending else { return }
            pending = nil
            if shape.text.isEmpty { return }
            shapeCounter += 1
            let shapeId = shapeCounter
            let isTitle = shape.txType == 0 || shape.txType == 6
            let styles = shape.styles ?? PptStyleRuns()
            // The active master's per-level defaults for this text
            // type; local exceptions are tri-state and resolve over
            // these.
            let masterLevels = masters[safe: activeMaster]?
                .1[UInt16(shape.txType)] ?? []
            func levelDefault(_ depth: Int) -> PptMasterLevel {
                masterLevels[safe: depth] ?? PptMasterLevel()
            }

            // Cursors over the style runs, counted in UTF-16 units.
            var charRuns = styles.chars.makeIterator()
            var charRun = charRuns.next()
            var charLeft = charRun?.count ?? Int.max
            var paraRuns = styles.paragraphs.makeIterator()
            var paraRun = paraRuns.next()
            var paraLeft = paraRun?.count ?? Int.max

            var paragraphs: [(inlines: [AnyTypInline], depth: UInt16, bullet: Bool?)] = []
            var inlines: [AnyTypInline] = []
            var runText = ""
            var runStyle = AnyTypStyle.plain
            func paraProps(_ r: PptParaProps?) -> (UInt16, Bool?) {
                (r?.depth ?? 0, r?.bullet ?? nil)
            }

            func flushRun() {
                if !runText.isEmpty {
                    let text = SharedText.clean(runText)
                    runText = ""
                    if !text.isEmpty {
                        inlines.append(.text(text, style: runStyle))
                    }
                }
            }

            for c in shape.text {
                let d = levelDefault(Int(paraProps(paraRun).0))
                var style = AnyTypStyle.plain
                style.bold = charRun?.bold ?? d.bold ?? false
                style.italic = charRun?.italic ?? d.italic ?? false
                if c == "\r" {
                    flushRun()
                    let (depth, bullet) = paraProps(paraRun)
                    paragraphs.append((inlines, depth, bullet))
                    inlines = []
                } else if c == "\u{0B}" {
                    flushRun()
                    inlines.append(.lineBreak)
                } else {
                    if style != runStyle && !runText.isEmpty {
                        flushRun()
                    }
                    runStyle = style
                    runText.append(c)
                }
                // Advance run cursors by the character's UTF-16 width.
                let width = String(c).utf16.count
                charLeft = max(charLeft &- width, 0)
                if charLeft == 0 {
                    charRun = charRuns.next()
                    charLeft = charRun?.count ?? Int.max
                }
                paraLeft = max(paraLeft &- width, 0)
                if paraLeft == 0 {
                    paraRun = paraRuns.next()
                    paraLeft = paraRun?.count ?? Int.max
                }
            }
            flushRun()
            if !inlines.isEmpty {
                let (depth, bullet) = paraProps(paraRun)
                paragraphs.append((inlines, depth, bullet))
            }

            for (var paraInlines, depth, bullet) in paragraphs {
                if inlinesAreEmpty(paraInlines) {
                    flushList(&current, &listRun)
                    continue
                }
                if isTitle {
                    flushList(&current, &listRun)
                    let d = levelDefault(Int(depth))
                    var base = StyleDelta()
                    base.bold = d.bold
                    base.italic = d.italic
                    rebaseEmphasis(&paraInlines, base: base.resolve())
                    current.append(.heading(
                        level: 2, anchor: inlinesToPlainText(paraInlines),
                        content: paraInlines))
                    continue
                }
                let bulletOn = bullet ?? levelDefault(Int(depth)).bullet ?? false
                if bulletOn {
                    listRun.append(ListEntry(
                        level: Int(depth),
                        key: ListKey(instance: shapeId, marker: .bullet),
                        number: 0, label: nil,
                        blocks: [.paragraph(paraInlines)]))
                } else {
                    flushList(&current, &listRun)
                    current.append(.paragraph(paraInlines))
                }
            }
        }
    }

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
