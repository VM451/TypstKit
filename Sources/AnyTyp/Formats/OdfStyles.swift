import Foundation

/// ODF style resolution (port of `odf/styles.rs`): text/paragraph style
/// chains as tri-state deltas (so `font-weight: normal` can clear inherited
/// bold), plus list styles with per-level marker kinds and start values.
///
/// Chains are keyed by owned `family\0name` strings because definitions
/// come from two separately parsed trees (`styles.xml` and `content.xml`).
final class OdfStyles {
    static let listLevels = 10

    struct ListLevel {
        var marker: AnyTypMarkerKind = .bullet
        var start: UInt64 = 1
        /// `style:num-prefix` literal text before the number.
        var prefix = ""
        /// `style:num-suffix` literal text after the number; absent means
        /// the bare number is displayed.
        var suffix: String? = nil
        /// `text:display-levels`: how many levels (ending at this one)
        /// display, joined by `.`.
        var displayLevels = 1

        /// The level's number text as the shared pattern IR, referencing
        /// the trailing `displayLevels` levels.
        func pattern(_ depth: Int) -> NumberPattern {
            var text: [NumberText] = []
            if !prefix.isEmpty { text.append(.literal(prefix)) }
            let shown = min(max(displayLevels, 1), depth + 1)
            for (i, level) in ((depth + 1 - shown)...depth).enumerated() {
                if i > 0 { text.append(.literal(".")) }
                text.append(.level(UInt8(level)))
            }
            if let suffix, !suffix.isEmpty { text.append(.literal(suffix)) }
            return NumberPattern(text: text, legal: false)
        }
    }

    /// One named style definition plus its `parent-style-name` chain key.
    private struct RawStyle {
        var def: XmlElement
        var parent: String?
    }

    private var raw: [String: RawStyle] = [:]
    private var memo: [String: StyleDelta] = [:]
    private var listStyles: [String: [ListLevel]] = [:]
    /// `text:outline-style`: heading numbering per outline level.
    private var outline: [ListLevel]? = nil
    /// `style:default-style` per family: the base beneath every named chain
    /// (and the delta for unstyled content of that family).
    private var defaults: [String: StyleDelta] = [:]

    private static func key(_ family: String, _ name: String) -> String {
        "\(family)\u{0}\(name)"
    }

    /// Collect styles from one document tree (`styles.xml` or
    /// `content.xml`). Call for styles.xml first so content.xml definitions
    /// chain onto it.
    func collect(_ tree: XmlElement) {
        for root in tree.childElems {
            for section in root.childElems {
                guard section.is(XmlNS.office, "automatic-styles")
                    || section.is(XmlNS.office, "styles") else { continue }
                for style in section.childElems {
                    if style.is(XmlNS.style, "default-style"),
                       let family = style.attr(XmlNS.style, "family") {
                        defaults[family] = textPropertiesDelta(style)
                    }
                    if style.is(XmlNS.style, "style"),
                       let name = style.attr(XmlNS.style, "name") {
                        let family = style.attr(XmlNS.style, "family") ?? ""
                        let parent = style.attr(XmlNS.style, "parent-style-name")
                            .map { Self.key(family, $0) }
                        raw[Self.key(family, name)] = RawStyle(def: style, parent: parent)
                    }
                    if style.is(XmlNS.text, "list-style"),
                       let name = style.attr(XmlNS.style, "name") {
                        listStyles[name] = parseListStyle(style)
                    }
                    if style.is(XmlNS.text, "outline-style") {
                        outline = parseListStyle(style)
                    }
                }
            }
        }
    }

    /// Cumulative delta of a style through its `parent-style-name` chain,
    /// over the family's `style:default-style` base.
    func delta(_ family: String, _ name: String) throws -> StyleDelta {
        let id = Self.key(family, name)
        if let hit = memo[id] { return hit }
        var chain: [String] = []
        var visited = Set<String>()
        var cursor: String? = raw[id] != nil ? id : nil
        while let current = cursor {
            if !visited.insert(current).inserted {
                throw ConvertError.malformed(
                    part: nil, detail: "style inheritance cycle at \(current)")
            }
            chain.append(current)
            cursor = raw[current]?.parent.flatMap { raw[$0] != nil ? $0 : nil }
        }
        var delta = defaults[family] ?? StyleDelta()
        for current in chain.reversed() {
            guard let def = raw[current]?.def else { continue }
            delta = delta.merge(textPropertiesDelta(def))
            memo[current] = delta
        }
        return delta
    }

    /// The block container a paragraph style names, walking
    /// `parent-style-name`: an automatic style carries the name on the
    /// named style it derives from.
    func blockStyle(_ name: String) -> BlockStyle? {
        var id = Self.key("paragraph", name)
        var visited = Set<String>()
        while visited.insert(id).inserted {
            guard let entry = raw[id] else { return nil }
            if let hit = entry.def.attr(XmlNS.style, "name")
                .flatMap(blockStyleFromName) {
                return hit
            }
            guard let parent = entry.parent else { return nil }
            id = parent
        }
        return nil
    }

    func listLevel(_ styleName: String, depth: Int) -> ListLevel {
        guard let levels = listStyles[styleName],
              depth < levels.count else { return ListLevel() }
        return levels[depth]
    }

    /// The full level array of a list style, for composite-label
    /// rendering.
    func listLevels(_ styleName: String) -> [ListLevel]? {
        listStyles[styleName]
    }

    /// The document's heading numbering (`text:outline-style`) levels.
    func outlineLevels() -> [ListLevel]? {
        outline
    }
}

/// Clamp an untrusted start value so counters can never overflow.
func odfParseStart(_ v: String) -> UInt64? {
    UInt64(v).map { min($0, UInt64(UInt32.max)) }
}

/// Levels of a `text:list-style` or `text:outline-style` (the level
/// elements differ in name, not in shape).
private func parseListStyle(_ style: XmlElement) -> [OdfStyles.ListLevel] {
    var levels = [OdfStyles.ListLevel](
        repeating: OdfStyles.ListLevel(), count: OdfStyles.listLevels)
    for lvl in style.childElems {
        guard let n = lvl.attr(XmlNS.text, "level").flatMap(Int.init),
              (1...OdfStyles.listLevels).contains(n) else { continue }
        let slot = n - 1
        if lvl.is(XmlNS.text, "list-level-style-number")
            || lvl.is(XmlNS.text, "outline-level-style") {
            switch lvl.attr(XmlNS.style, "num-format") {
            case "a": levels[slot].marker = .lowerAlpha
            case "A": levels[slot].marker = .upperAlpha
            case "i": levels[slot].marker = .lowerRoman
            case "I": levels[slot].marker = .upperRoman
            case "": levels[slot].marker = .bullet
            default: levels[slot].marker = .decimal
            }
            levels[slot].start = lvl.attr(XmlNS.text, "start-value")
                .flatMap(odfParseStart) ?? 1
            levels[slot].prefix = lvl.attr(XmlNS.style, "num-prefix") ?? ""
            levels[slot].suffix = lvl.attr(XmlNS.style, "num-suffix")
            levels[slot].displayLevels = lvl.attr(XmlNS.text, "display-levels")
                .flatMap(Int.init) ?? 1
        }
    }
    return levels
}

/// Delta carried by a style's `style:text-properties`.
func textPropertiesDelta(_ elem: XmlElement) -> StyleDelta {
    guard let props = elem.find(XmlNS.style, "text-properties") else {
        return StyleDelta()
    }
    var superscript: Bool? = nil
    var subscriptText: Bool? = nil
    if let pos = props.attr(XmlNS.style, "text-position") {
        let first = pos.split(whereSeparator: { $0.isWhitespace }).first
            .map(String.init) ?? ""
        let pct = first.hasSuffix("%")
            ? Double(first.dropLast()) : nil
        if first == "super" || (pct ?? 0) > 0 {
            superscript = true; subscriptText = false
        } else if first == "sub" || (pct ?? 0) < 0 {
            superscript = false; subscriptText = true
        } else {
            superscript = false; subscriptText = false
        }
    }
    var d = StyleDelta()
    d.bold = props.attr(XmlNS.fo, "font-weight").map {
        $0 == "bold" || (UInt32($0).map { $0 >= 600 } ?? false)
    }
    d.italic = props.attr(XmlNS.fo, "font-style").map {
        $0 == "italic" || $0 == "oblique"
    }
    d.underline = props.attr(XmlNS.style, "text-underline-style").map { $0 != "none" }
    d.strike = props.attr(XmlNS.style, "text-line-through-style").map { $0 != "none" }
    d.superscript = superscript
    d.subscriptText = subscriptText
    return d
}
