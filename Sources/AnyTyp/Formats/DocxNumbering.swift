import Foundation

/// WordprocessingML numbering: `numId -> w:num` (with level overrides) `->
/// abstractNum` (with `numStyleLink` indirection) `-> level`, plus the
/// document-order counters (port of `formats/docx/numbering.rs`).
let docxLevels = 9

struct DocxLevelDef {
    /// `nil` = suppressed numbering (`numFmt` of `none`).
    var marker: AnyTypMarkerKind?
    var start: UInt64
    /// `w:lvlRestart`: `nil` = restart when any shallower level appears,
    /// `0` = never restart, `n` = restart when a level with `ilvl < n` appears.
    var restart: UInt32?
    /// `w:lvlText` (with `w:isLgl`) as the shared pattern IR.
    var pattern: NumberPattern

    static let `default` = DocxLevelDef(
        marker: .bullet, start: 1, restart: nil, pattern: NumberPattern())
}

private struct DocxAbstractNum {
    var levels: [DocxLevelDef]
    /// Paragraph style each level binds to via `w:lvl > w:pStyle`.
    var pstyles: [String?]
    var numStyleLink: String?
}

final class DocxNumberingInstance {
    let levels: [DocxLevelDef]
    private let pstyles: [String?]

    init(levels: [DocxLevelDef], pstyles: [String?]) {
        self.levels = levels
        self.pstyles = pstyles
    }

    /// The level bound to a paragraph style through the abstract levels'
    /// `w:pStyle` references.
    func styleLevel(_ styleId: String) -> Int? {
        pstyles.firstIndex { $0 == styleId }
    }
}

struct DocxNumbering {
    private var instances: [UInt64: DocxNumberingInstance] = [:]

    func instance(_ numId: UInt64) -> DocxNumberingInstance? {
        instances[numId]
    }

    /// `styleNumId` maps a numbering style id to the `numId` its own `numPr`
    /// references (the `numStyleLink`/`styleLink` indirection contract).
    static func parse(
        _ root: XmlElement,
        styleNumId: (String) -> UInt64?
    ) throws -> DocxNumbering {
        var abstracts: [String: DocxAbstractNum] = [:]
        for abs in root.findAll(XmlNS.w, "abstractNum") {
            guard let id = abs.attr(XmlNS.w, "abstractNumId") else { continue }
            var levels = [DocxLevelDef](repeating: .default, count: docxLevels)
            var pstyles = [String?](repeating: nil, count: docxLevels)
            for lvl in abs.findAll(XmlNS.w, "lvl") {
                let ilvl = Int(lvl.attr(XmlNS.w, "ilvl") ?? "0") ?? 0
                if ilvl < docxLevels {
                    levels[ilvl] = parseLevel(lvl)
                    pstyles[ilvl] = levelPStyle(lvl)
                }
            }
            let numStyleLink = abs.find(XmlNS.w, "numStyleLink")?.attr(XmlNS.w, "val")
            abstracts[id] = DocxAbstractNum(levels: levels, pstyles: pstyles,
                                          numStyleLink: numStyleLink)
        }

        // First pass: direct abstract references per numId.
        var direct: [UInt64: (absId: String, elem: XmlElement)] = [:]
        for num in root.findAll(XmlNS.w, "num") {
            guard let numIdStr = num.attr(XmlNS.w, "numId"),
                  let numId = UInt64(numIdStr),
                  let absId = num.find(XmlNS.w, "abstractNumId")?.attr(XmlNS.w, "val")
            else { continue }
            direct[numId] = (absId, num)
        }

        var numbering = DocxNumbering()
        for (numId, entry) in direct {
            guard let abs = try resolveAbstract(entry.absId, abstracts: abstracts,
                                                direct: direct, styleNumId: styleNumId)
            else {
                AnyTypLog.debug("numbering instance \(numId) references unknown abstract \(entry.absId)")
                continue
            }
            var levels = abs.levels
            var pstyles = abs.pstyles
            for over in entry.elem.findAll(XmlNS.w, "lvlOverride") {
                let ilvl = Int(over.attr(XmlNS.w, "ilvl") ?? "0") ?? 0
                if ilvl >= docxLevels { continue }
                // A nested w:lvl replaces the level wholesale; startOverride
                // is applied last so it survives the replacement.
                if let lvl = over.find(XmlNS.w, "lvl") {
                    levels[ilvl] = parseLevel(lvl)
                    pstyles[ilvl] = levelPStyle(lvl)
                }
                if let startStr = over.find(XmlNS.w, "startOverride")?.attr(XmlNS.w, "val"),
                   let start = parseStart(startStr) {
                    levels[ilvl].start = start
                }
            }
            numbering.instances[numId] = DocxNumberingInstance(levels: levels, pstyles: pstyles)
        }
        return numbering
    }

    /// Resolve an abstract definition, following `numStyleLink`
    /// indirection: abstract -> numbering style -> that style's `numId` ->
    /// its abstract.
    private static func resolveAbstract(
        _ absId: String,
        abstracts: [String: DocxAbstractNum],
        direct: [UInt64: (absId: String, elem: XmlElement)],
        styleNumId: (String) -> UInt64?
    ) throws -> DocxAbstractNum? {
        var seen: [String] = []
        var current = absId
        while true {
            if seen.contains(current) {
                throw ConvertError.malformed(part: nil,
                    detail: "numbering indirection cycle at abstract \(current)")
            }
            seen.append(current)
            guard let abs = abstracts[current] else { return nil }
            guard let styleId = abs.numStyleLink else { return abs }
            let linked = styleNumId(styleId).flatMap { direct[$0]?.absId }
            guard let next = linked else { return abs }
            current = next
        }
    }

    /// The paragraph style a `w:lvl` binds to (`w:pStyle`).
    private static func levelPStyle(_ lvl: XmlElement) -> String? {
        lvl.find(XmlNS.w, "pStyle")?.attr(XmlNS.w, "val")
    }

    /// `ST_DecimalNumber` is `xsd:int`; values are clamped to the
    /// non-negative range so untrusted starting values can never overflow.
    private static func parseStart(_ v: String) -> UInt64? {
        guard let n = Int64(v) else { return nil }
        return UInt64(max(0, min(n, Int64(Int32.max))))
    }

    private static func parseLevel(_ lvl: XmlElement) -> DocxLevelDef {
        let fmt = lvl.find(XmlNS.w, "numFmt")?.attr(XmlNS.w, "val") ?? "bullet"
        let marker: AnyTypMarkerKind? = switch fmt {
        case "none": nil
        case "bullet": .bullet
        case "lowerLetter": .lowerAlpha
        case "upperLetter": .upperAlpha
        case "lowerRoman": .lowerRoman
        case "upperRoman": .upperRoman
        default: .decimal
        }
        let start = lvl.find(XmlNS.w, "start")?.attr(XmlNS.w, "val")
            .flatMap(parseStart) ?? 1
        let restart = lvl.find(XmlNS.w, "lvlRestart")?.attr(XmlNS.w, "val")
            .flatMap { UInt32($0) }
        // The number text pattern applies to ordered levels; bullet lvlText
        // is the glyph itself, not a pattern.
        let text: [NumberText] = {
            guard let m = marker, m.ordered,
                  let lvlText = lvl.find(XmlNS.w, "lvlText")?.attr(XmlNS.w, "val")
            else { return [] }
            return parsePercentPattern(lvlText)
        }()
        let legal = onOff(lvl, "isLgl") == true
        return DocxLevelDef(marker: marker, start: start, restart: restart,
                            pattern: NumberPattern(text: text, legal: legal))
    }
}

/// Document-order numbering state: one counter array per instance, shared
/// across interruptions so continuation works, with `lvlRestart` semantics.
final class DocxCounters {
    private struct InstanceState {
        var value = [UInt64](repeating: 0, count: docxLevels)
        var initialized = [Bool](repeating: false, count: docxLevels)
        var restartPending = [Bool](repeating: false, count: docxLevels)
    }
    private var state: [UInt64: InstanceState] = [:]

    /// Advance the counter for a paragraph at (`numId`, `ilvl`) and return
    /// its effective number plus, when the level's number text is not
    /// reproducible from the marker kind alone, the composite label.
    func next(_ numId: UInt64, _ ilvl: Int,
              instance: DocxNumberingInstance) -> (UInt64, String?) {
        let ilvl = min(ilvl, docxLevels - 1)
        var st = state[numId] ?? InstanceState()
        let def = instance.levels[ilvl]
        if !st.initialized[ilvl] || st.restartPending[ilvl] {
            st.value[ilvl] = def.start
            st.initialized[ilvl] = true
            st.restartPending[ilvl] = false
        } else {
            st.value[ilvl] = st.value[ilvl] &+ 1
        }
        // Using level `ilvl` schedules restarts for deeper levels.
        for deeper in (ilvl + 1)..<docxLevels {
            let levelDef = instance.levels[deeper]
            let triggered: Bool
            switch levelDef.restart {
            case .none: triggered = true
            case .some(0): triggered = false
            case .some(let n): triggered = UInt32(ilvl) < n
            }
            if triggered { st.restartPending[deeper] = true }
        }
        let value = st.value[ilvl]
        state[numId] = st
        let label = def.marker.flatMap { marker -> String? in
            compositeLabel(
                def.pattern, ownMarker: marker, ownValue: value,
                levelMarker: { l in
                    instance.levels[min(l, docxLevels - 1)].marker ?? .decimal
                },
                levelValue: { l in
                    let li = min(l, docxLevels - 1)
                    // Read back the (possibly just-mutated) state.
                    let s = self.state[numId] ?? st
                    return s.initialized[li] && !s.restartPending[li]
                        ? s.value[li] : instance.levels[li].start
                })
        }
        return (value, label)
    }
}
