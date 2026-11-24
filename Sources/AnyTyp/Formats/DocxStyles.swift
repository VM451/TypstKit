import Foundation

/// WordprocessingML style table (port of `formats/docx/styles.rs`).
///
/// Bold/italic/strike are *toggle properties*: within the style hierarchy a
/// `true` specification toggles the inherited value and `false` leaves it
/// unchanged, so style layers contribute a true-count *parity* XORed over
/// the `docDefaults` base. Direct run formatting is absolute on/off.
struct DocxToggles: Equatable {
    var bold = false
    var italic = false
    var strike = false

    func xor(_ other: DocxToggles) -> DocxToggles {
        DocxToggles(bold: bold != other.bold, italic: italic != other.italic,
                    strike: strike != other.strike)
    }

    func applyOver(_ base: AnyTypStyle) -> AnyTypStyle {
        AnyTypStyle(bold: base.bold != bold, italic: base.italic != italic,
                    underline: base.underline, strike: base.strike != strike,
                    superscript: base.superscript, subscriptText: base.subscriptText,
                    code: base.code)
    }
}

final class DocxStyles {
    private var chains = StyleChains()
    /// docDefaults as absolute values (the base the toggles flip over).
    let docDefaults: AnyTypStyle

    private init(chains: StyleChains, docDefaults: AnyTypStyle) {
        self.chains = chains
        self.docDefaults = docDefaults
    }

    static func parseOpt(_ root: XmlElement?) -> DocxStyles {
        guard let root else {
            return DocxStyles(chains: StyleChains(), docDefaults: .plain)
        }
        return parse(root)
    }

    static func parse(_ root: XmlElement) -> DocxStyles {
        var chains = StyleChains()
        for style in root.findAll(XmlNS.w, "style") {
            if let id = style.attr(XmlNS.w, "styleId") {
                let parent = style.find(XmlNS.w, "basedOn")?.attr(XmlNS.w, "val")
                chains.insert(id: id, def: style, parent: parent)
            }
        }
        let docDefaults = root.find(XmlNS.w, "docDefaults")?
            .find(XmlNS.w, "rPrDefault")?
            .find(XmlNS.w, "rPr")
            .map { rprDelta($0).resolve() } ?? .plain
        return DocxStyles(chains: chains, docDefaults: docDefaults)
    }

    /// The parity of `true` toggle specifications along a style's `basedOn`
    /// chain.
    func runToggles(_ id: String) throws -> DocxToggles {
        var parity = DocxToggles()
        _ = try chains.walk(id) { (style: XmlElement) -> DocxToggles? in
            if let rpr = style.find(XmlNS.w, "rPr") {
                parity = parity.xor(DocxToggles(
                    bold: onOff(rpr, "b") == true,
                    italic: onOff(rpr, "i") == true,
                    strike: onOff(rpr, "strike") == true || onOff(rpr, "dstrike") == true))
            }
            return nil
        }
        return parity
    }

    /// Heading level a paragraph style resolves to. `nil` = unspecified
    /// (inherit); `.off` = explicit "no outline level"; `.level(n)` = heading.
    func headingLevel(_ id: String) throws -> DocxHeadingSpec? {
        try chains.walk(id) { (style: XmlElement) -> DocxHeadingSpec? in
            let name = (style.find(XmlNS.w, "name")?.attr(XmlNS.w, "val") ?? "")
                .lowercased()
            if name.hasPrefix("heading "),
               let level = Int(name.dropFirst(8).trimmingCharacters(in: .whitespaces)),
               (1...9).contains(level) {
                return .level(level)
            }
            if name == "title" { return .level(1) }
            guard let ppr = style.find(XmlNS.w, "pPr"),
                  let lvl = ppr.find(XmlNS.w, "outlineLvl"),
                  let val = lvl.attr(XmlNS.w, "val"),
                  let level = Int(val) else { return nil }
            return level < 9 ? .level(level + 1) : .off
        }
    }

    /// The block container a paragraph style names, inherited through
    /// `basedOn`.
    func blockStyle(_ id: String) throws -> BlockStyle? {
        try chains.walk(id) { (style: XmlElement) -> BlockStyle? in
            guard let name = style.find(XmlNS.w, "name")?.attr(XmlNS.w, "val") else {
                return nil
            }
            return blockStyleFromName(name)
        }
    }

    /// The `numId` a paragraph style contributes, inherited through
    /// `basedOn`.
    func styleNumPr(_ id: String) throws -> UInt64? {
        try chains.walk(id) { (style: XmlElement) -> UInt64? in
            style.find(XmlNS.w, "pPr")?
                .find(XmlNS.w, "numPr")?
                .find(XmlNS.w, "numId")?
                .attr(XmlNS.w, "val")
                .flatMap { UInt64($0) }
        }
    }

    /// The numbering level a paragraph style binds to: the first style
    /// along the `basedOn` chain that one of the instance's abstract
    /// levels references via `w:pStyle`.
    func styleNumberingLevel(_ id: String, instance: DocxNumberingInstance) throws -> Int? {
        try chains.walk(id) { (style: XmlElement) -> Int? in
            guard let styleId = style.attr(XmlNS.w, "styleId") else { return nil }
            return instance.styleLevel(styleId)
        }
    }

    /// The `numId` referenced by a numbering style's own `numPr`
    /// (`numStyleLink` contract), without inheritance.
    func directNumId(_ id: String) -> UInt64? {
        guard let style = chains.definition(id) else { return nil }
        return style.find(XmlNS.w, "pPr")?
            .find(XmlNS.w, "numPr")?
            .find(XmlNS.w, "numId")?
            .attr(XmlNS.w, "val")
            .flatMap { UInt64($0) }
    }
}

/// Resolved heading specification from a style chain.
enum DocxHeadingSpec {
    case level(Int)
    case off
}

/// A `w:rPr` element as a tri-state delta - used only for *direct* run
/// formatting, where specifications are absolute on/off.
func rprDelta(_ rpr: XmlElement) -> StyleDelta {
    let s = onOff(rpr, "strike")
    let d = onOff(rpr, "dstrike")
    let underline = rpr.find(XmlNS.w, "u").map {
        !["none", "0", "false", "off"].contains($0.attr(XmlNS.w, "val") ?? "")
    }
    let (superscript, subscriptText): (Bool?, Bool?)
    switch rpr.find(XmlNS.w, "vertAlign")?.attr(XmlNS.w, "val") {
    case "superscript": (superscript, subscriptText) = (true, false)
    case "subscript": (superscript, subscriptText) = (false, true)
    case "baseline": (superscript, subscriptText) = (false, false)
    default: (superscript, subscriptText) = (nil, nil)
    }
    return StyleDelta(
        bold: onOff(rpr, "b"),
        italic: onOff(rpr, "i"),
        underline: underline,
        strike: (s != nil || d != nil) ? (s ?? false) || (d ?? false) : nil,
        superscript: superscript,
        subscriptText: subscriptText,
        code: nil
    )
}

/// ST_OnOff: `1`/`true`/`on` (or no value) are true; `0`/`false`/`off` are
/// false; an absent element is unspecified.
func onOff(_ parent: XmlElement, _ name: String) -> Bool? {
    guard let elem = parent.find(XmlNS.w, name) else { return nil }
    return !["0", "false", "off", "none"].contains(elem.attr(XmlNS.w, "val") ?? "")
}
