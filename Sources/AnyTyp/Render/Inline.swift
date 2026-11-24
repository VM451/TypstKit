import Foundation

/// A normalized inline run: adjacent same-style text merged, dead links
/// flattened, untargeted anchors dropped.
private enum NormRun {
    case text(String, AnyTypStyle)
    case link(content: [AnyTypInline], target: AnyTypLinkTarget)
    case image(alt: String, source: AnyTypImageSource)
    case anchor(String)
    case noteRef(String)
    case lineBreak
    case math(String)
    case checkbox(Bool)
}

private func normalize(_ inlines: [AnyTypInline], rc: RenderContext) -> [NormRun] {
    var out: [NormRun] = []
    for inline in inlines {
        switch inline {
        case .text(let text, let style):
            if text.isEmpty { continue }
            var style = style
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                style = .plain
            }
            if case .text(let prev, let prevStyle) = out.last, prevStyle == style {
                out[out.count - 1] = .text(prev + text, style)
                continue
            }
            // A styled run wrapped in plain whitespace merges back into the
            // preceding same-style run so emphasis markers don't strand.
            if style != .plain, !style.code, out.count >= 2,
               case .text(let ws, let wsStyle) = out[out.count - 1],
               wsStyle == .plain,
               ws.allSatisfy({ $0.isWhitespace }),
               case .text(_, let prev2Style) = out[out.count - 2],
               prev2Style == style {
                out.removeLast()
                if case .text(let prev, let s) = out[out.count - 1] {
                    out[out.count - 1] = .text(prev + ws + text, s)
                }
                continue
            }
            out.append(.text(text, style))
        case .link(let content, let target):
            if target.isEmpty {
                if !inlinesAreEmpty(content) {
                    out.append(contentsOf: normalize(content, rc: rc))
                }
                continue
            }
            out.append(.link(content: content, target: target))
        case .image(let alt, let source):
            out.append(.image(alt: alt, source: source))
        case .anchor(let id):
            if rc.anchors.inlineLabel(id) == nil { continue }
            out.append(.anchor(id))
        case .noteRef(let id):
            out.append(.noteRef(id))
        case .lineBreak:
            out.append(.lineBreak)
        case .math(let tex):
            let trimmed = tex.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            out.append(.math(trimmed))
        case .checkbox(let checked):
            out.append(.checkbox(checked))
        }
    }
    return out
}

func renderInlines(
    _ inlines: [AnyTypInline],
    _ ctx: InlineContext,
    rc: RenderContext
) -> String {
    renderInlinesInner(inlines, ctx: ctx, stripUnderline: false, rc: rc)
}

private func renderInlinesInner(
    _ inlines: [AnyTypInline],
    ctx: InlineContext,
    stripUnderline: Bool,
    rc: RenderContext
) -> String {
    let runs = normalize(inlines, rc: rc)
    var out = ""
    for (idx, run) in runs.enumerated() {
        switch run {
        case .text(let text, var style):
            if stripUnderline { style.underline = false }
            let prevWord = out.last.map(isWordChar) ?? false
            let nextWord = idx + 1 < runs.count ? startsWithWordChar(runs[idx + 1]) : false
            renderTextRun(text, style: style, prevWord: prevWord, nextWord: nextWord, out: &out)
        case .noteRef(let id):
            rc.renderNoteRef(id, out: &out)
        case .link(let content, let target):
            renderLink(content, target: target, ctx: ctx, rc: rc, out: &out)
        case .image(let alt, let source):
            renderImage(alt: alt, source: source, rc: rc, out: &out)
        case .anchor(let id):
            if let label = rc.anchors.inlineLabel(id) {
                if out.last.map(isIdentContinue) ?? false {
                    out.append(" ")
                }
                out += "#metadata(none) <\(label)>"
            }
        case .lineBreak:
            switch ctx {
            case .heading:
                out.append(" ")
            case .block:
                if !out.hasSuffix(" "), !out.isEmpty {
                    out.append(" ")
                }
                out += "\\\n"
            }
        case .math(let tex):
            let rendered = renderInlineMath(tex)
            if !rendered.isEmpty {
                if rendered.hasPrefix("#"), out.last.map(isIdentContinue) ?? false {
                    out.append(" ")
                }
                out += rendered
            }
        case .checkbox(let checked):
            out += checked ? "[x]" : "[ ]"
            if idx + 1 < runs.count, !startsWithSpace(runs[idx + 1]) {
                out.append(" ")
            }
        }
    }
    return out
}

private func isWordChar(_ c: Character) -> Bool {
    c.isLetter || c.isNumber || c == "_"
}

private func isIdentContinue(_ c: Character) -> Bool {
    c.isLetter || c.isNumber || c == "_" || c == "-"
}

private func startsWithWordChar(_ run: NormRun) -> Bool {
    guard case .text(let text, _) = run, let first = text.first else { return false }
    return isWordChar(first)
}

private func startsWithSpace(_ run: NormRun) -> Bool {
    switch run {
    case .text(let text, _):
        return text.first?.isWhitespace ?? false
    case .lineBreak:
        return true
    default:
        return false
    }
}

private func renderTextRun(
    _ text: String,
    style: AnyTypStyle,
    prevWord: Bool,
    nextWord: Bool,
    out: inout String
) {
    if style == .plain {
        let atLineStart = out.isEmpty || out.hasSuffix("\n")
        out += escapeMarkup(text, atLineStart: atLineStart)
        return
    }

    // Split leading/trailing whitespace from the styled core.
    let leadLen = text.prefix(while: { $0.isWhitespace }).count
    let trailLen = text.reversed().prefix(while: { $0.isWhitespace }).count
    let lead = String(text.prefix(leadLen))
    let core = String(text.dropFirst(leadLen).dropLast(trailLen))
    let trail = String(text.suffix(trailLen))

    if !lead.isEmpty {
        let atLineStart = out.isEmpty || out.hasSuffix("\n")
        out += escapeMarkup(lead, atLineStart: atLineStart)
    }

    if !core.isEmpty {
        var inner: String
        if style.code {
            let single = core.replacingOccurrences(of: "\n", with: " ")
            if !single.contains("`") && !single.hasPrefix(" ") && !single.hasSuffix(" ") {
                inner = "`\(single)`"
            } else {
                inner = "#raw(\"\(escapeString(single))\")"
            }
        } else {
            inner = escapeMarkup(core, atLineStart: false)
        }

        let leftClear = !lead.isEmpty || !prevWord
        let rightClear = !trail.isEmpty || !nextWord
        let asciiBoundarySafe = leftClear && rightClear && !core.contains("\n")
            && core.first.map { $0.isASCII || $0.isLetter } ?? false
            && !hasCJK(core)

        if style.code {
            // Apply outer semantic wrappers around raw code if combined.
            if style.italic { inner = "#emph[\(inner)]" }
            if style.bold { inner = "#strong[\(inner)]" }
        } else {
            if style.italic {
                if asciiBoundarySafe && !style.underline && !style.strike
                    && !style.superscript && !style.subscriptText {
                    inner = "_\(inner)_"
                } else {
                    inner = "#emph[\(inner)]"
                }
            }
            if style.bold {
                if asciiBoundarySafe && !style.underline && !style.strike
                    && !style.superscript && !style.subscriptText && !inner.hasPrefix("#") {
                    inner = "*\(inner)*"
                } else {
                    inner = "#strong[\(inner)]"
                }
            }
        }

        if style.underline { inner = "#underline[\(inner)]" }
        if style.strike { inner = "#strike[\(inner)]" }
        if style.superscript {
            inner = "#super[\(inner)]"
        } else if style.subscriptText {
            inner = "#sub[\(inner)]"
        }

        // `#foo` immediately following `#bar[x]` is fine, and `#foo` after a
        // word is fine, EXCEPT after `#label` or bare code expr without
        // brackets. Keep separation clean when needed.
        if inner.hasPrefix("#"), out.hasSuffix(">") {
            out.append(" ")
        }
        out += inner
        // A `#func[...]` call with no `[...]` tail (e.g. `#raw("...")`)
        // immediately followed by `[` or `(` needs `;` so Typst does not
        // parse the trailing `[` as an argument.
        if inner.hasPrefix("#raw("), trail.isEmpty, nextWord {
            out.append(";")
        }
    }

    if !trail.isEmpty {
        out += escapeMarkup(trail, atLineStart: false)
    }
}

/// CJK ranges that make `_`/`*` emphasis markers unsafe (Typst word rules).
private func hasCJK(_ s: String) -> Bool {
    s.unicodeScalars.contains { scalar in
        switch scalar.value {
        case 0x3000...0x303F, 0x3040...0x30FF, 0x3400...0x4DBF,
             0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }
}

private func renderLink(
    _ content: [AnyTypInline],
    target: AnyTypLinkTarget,
    ctx: InlineContext,
    rc: RenderContext,
    out: inout String
) {
    // Strip default link underline so links emit cleanly.
    let label = renderInlinesInner(content, ctx: ctx, stripUnderline: true, rc: rc)
    switch target {
    case .anchor(let id):
        guard let typstLabel = rc.anchors.labelForTarget(id) else {
            AnyTypLog.debug("unresolved internal link target: \(id)")
            out += label
            return
        }
        if label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        out += "#link(<\(typstLabel)>)[\(label.trimmingCharacters(in: .whitespacesAndNewlines))]"
    case .external(let url), .relative(let url):
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let escapedURL = escapeString(trimmed)
        if label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let display = escapeMarkup(trimmed, atLineStart: false)
            out += "#link(\"\(escapedURL)\")[\(display)]"
        } else {
            out += "#link(\"\(escapedURL)\")[\(label.trimmingCharacters(in: .whitespacesAndNewlines))]"
        }
    }
}

private func renderImage(
    alt: String,
    source: AnyTypImageSource,
    rc: RenderContext,
    out: inout String
) {
    let cleanAlt = alt.trimmingCharacters(in: .whitespacesAndNewlines)
    switch source {
    case .asset(let id):
        if let relPath = rc.assetPaths[id] {
            let escapedPath = escapeString(relPath)
            if cleanAlt.isEmpty {
                out += "#image(\"\(escapedPath)\")"
            } else {
                out += "#image(\"\(escapedPath)\", alt: \"\(escapeString(cleanAlt))\")"
            }
            return
        }
        if !cleanAlt.isEmpty {
            out += escapeMarkup(cleanAlt, atLineStart: out.isEmpty || out.hasSuffix("\n"))
        }
    case .external(let url):
        // Typst `#image` only loads local project/package files, never remote
        // URLs; `#link` keeps standalone `typst compile` valid while
        // preserving both URL and alt.
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = cleanAlt.isEmpty
            ? escapeMarkup(trimmed, atLineStart: false)
            : escapeMarkup(cleanAlt, atLineStart: false)
        out += "#link(\"\(escapeString(trimmed))\")[\(label)]"
    case .unavailable:
        if !cleanAlt.isEmpty {
            out += escapeMarkup(cleanAlt, atLineStart: out.isEmpty || out.hasSuffix("\n"))
        }
    }
}
