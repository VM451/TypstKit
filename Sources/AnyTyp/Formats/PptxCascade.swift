import Foundation

/// PresentationML text-property cascade (port of `pptx/cascade.rs`): run
/// properties resolve through paragraph `pPr` -> shape `lstStyle` -> layout
/// placeholder -> master placeholder / `txStyles` -> presentation
/// `defaultTextStyle`, with explicit-off states honored at every layer.
enum PptxCascade {
    static let levels = 9

    enum Bullet: Equatable {
        /// Not specified at this layer; inherit from the next one.
        case inherit
        /// Explicitly no bullet (`a:buNone`).
        case none
        /// Character bullet (`a:buChar`).
        case char
        /// Auto-numbered (`a:buAutoNum`).
        case autoNum(marker: AnyTypMarkerKind, start: UInt64, wrap: NumWrap)
    }

    /// The punctuation an `ST_TextAutoNumberScheme` wraps around the ordinal.
    enum NumWrap: Equatable {
        /// `1.` — matches the renderer's default label.
        case period
        /// `1)`
        case parenR
        /// `(1)`
        case parenBoth
        /// Bare `1`.
        case plain

        /// The literal marker label for ordinal `n`; `nil` when the default
        /// label (`n.`) is already faithful.
        func label(_ marker: AnyTypMarkerKind, _ n: UInt64) -> String? {
            switch self {
            case .period: return nil
            case .parenR: return "\(marker.ordinal(n)))"
            case .parenBoth: return "(\(marker.ordinal(n)))"
            case .plain: return marker.ordinal(n)
            }
        }
    }

    struct TextProps {
        var delta = StyleDelta()
        var bullet: Bullet = .inherit

        /// Overlay `over` on `self`: explicit values win, `inherit` falls
        /// through.
        func merge(_ over: TextProps) -> TextProps {
            TextProps(
                delta: delta.merge(over.delta),
                bullet: over.bullet == .inherit ? bullet : over.bullet
            )
        }
    }

    /// Per-level text properties from a `lstStyle`-shaped element
    /// (`a:lvl1pPr`..`a:lvl9pPr` children).
    struct LevelStyle {
        var levels: [TextProps] =
            Array(repeating: TextProps(), count: PptxCascade.levels)

        func level(_ lvl: Int) -> TextProps {
            levels[min(lvl, levels.count - 1)]
        }
    }

    static func parseLevelStyles(_ elem: XmlElement?) -> LevelStyle {
        var out = LevelStyle()
        guard let elem else { return out }
        for (i, _) in out.levels.enumerated() {
            let name = "lvl\(i + 1)pPr"
            if let ppr = elem.childElems.first(where: { $0.is(XmlNS.a, name) }) {
                out.levels[i] = paragraphProps(ppr)
            }
        }
        return out
    }

    /// Properties carried by one `pPr`-shaped element (direct paragraph
    /// properties or one `lvlNpPr` level).
    static func paragraphProps(_ ppr: XmlElement) -> TextProps {
        let bullet: Bullet
        if ppr.find(XmlNS.a, "buNone") != nil {
            bullet = .none
        } else if let auto = ppr.find(XmlNS.a, "buAutoNum") {
            let scheme = auto.attr(XmlNS.a, "type") ?? ""
            let marker: AnyTypMarkerKind
            if scheme.hasPrefix("alphaLc") { marker = .lowerAlpha }
            else if scheme.hasPrefix("alphaUc") { marker = .upperAlpha }
            else if scheme.hasPrefix("romanLc") { marker = .lowerRoman }
            else if scheme.hasPrefix("romanUc") { marker = .upperRoman }
            else { marker = .decimal }
            let wrap: NumWrap
            if scheme.hasSuffix("ParenBoth") { wrap = .parenBoth }
            else if scheme.hasSuffix("ParenR") { wrap = .parenR }
            else if scheme.hasSuffix("Plain") { wrap = .plain }
            else { wrap = .period }
            // ST_TextBulletStartAtNum: 1..=32767; untrusted values are
            // clamped so counters can never overflow.
            let start = auto.attr(XmlNS.a, "startAt")
                .flatMap(UInt64.init)
                .map { min(max($0, 1), 32767) } ?? 1
            bullet = .autoNum(marker: marker, start: start, wrap: wrap)
        } else if ppr.find(XmlNS.a, "buChar") != nil {
            bullet = .char
        } else {
            bullet = .inherit
        }
        let delta = ppr.find(XmlNS.a, "defRPr").map(rprDelta) ?? StyleDelta()
        return TextProps(delta: delta, bullet: bullet)
    }

    /// Delta from an `a:rPr`/`a:defRPr` element's attributes.
    static func rprDelta(_ rpr: XmlElement) -> StyleDelta {
        func onOff(_ name: String) -> Bool? {
            rpr.attr(XmlNS.a, name).map { ["1", "true", "on"].contains($0) }
        }
        var d = StyleDelta()
        d.bold = onOff("b")
        d.italic = onOff("i")
        d.underline = rpr.attr(XmlNS.a, "u").map { !["none", "0", "false"].contains($0) }
        d.strike = rpr.attr(XmlNS.a, "strike").map { ["sngStrike", "dblStrike"].contains($0) }
        if let b = rpr.attr(XmlNS.a, "baseline").flatMap(Int.init) {
            if b > 0 { d.superscript = true; d.subscriptText = false }
            else if b < 0 { d.superscript = false; d.subscriptText = true }
            else { d.superscript = false; d.subscriptText = false }
        }
        return d
    }

    /// A placeholder shape's identity and level styles inside a layout/master.
    struct Placeholder {
        var phType: String
        var idx: String?
        var styles: LevelStyle
    }

    static func collectPlaceholders(_ spTree: XmlElement) -> [Placeholder] {
        spTree.descendants(XmlNS.p, "sp").compactMap { sp in
            guard let ph = sp.firstDescendant(XmlNS.p, "ph") else { return nil }
            let styles = parseLevelStyles(
                sp.find(XmlNS.p, "txBody")?.find(XmlNS.a, "lstStyle"))
            return Placeholder(
                phType: ph.attr(XmlNS.p, "type") ?? "body",
                idx: ph.attr(XmlNS.p, "idx"),
                styles: styles)
        }
    }

    /// Find the placeholder a shape inherits from: match by `idx` first,
    /// then by type (title variants unify).
    static func matchPlaceholder(
        _ placeholders: [Placeholder], phType: String, idx: String?
    ) -> Placeholder? {
        if let idx,
           let hit = placeholders.first(where: { $0.idx == idx }) {
            return hit
        }
        let cls = titleClass(phType)
        return placeholders.first {
            titleClass($0.phType) == cls && (cls == .title || $0.phType == phType)
        } ?? placeholders.first { titleClass($0.phType) == cls }
    }

    enum TitleClass { case title, body }

    static func titleClass(_ phType: String) -> TitleClass {
        switch phType {
        case "title", "ctrTitle": return .title
        default: return .body
        }
    }
}
