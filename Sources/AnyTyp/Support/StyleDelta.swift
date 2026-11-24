import Foundation

/// Tri-state style deltas used during cascade resolution (port of
/// `shared/delta.rs`). A property is explicitly on, explicitly off, or unset
/// (inherit); only after the full cascade is a delta collapsed into the
/// model's resolved `AnyTypStyle`.
struct StyleDelta: Equatable {
    var bold: Bool?
    var italic: Bool?
    var underline: Bool?
    var strike: Bool?
    var superscript: Bool?
    var subscriptText: Bool?
    var code: Bool?

    /// Overlay `child` on `self`: an explicit child value wins; unset inherits.
    func merge(_ child: StyleDelta) -> StyleDelta {
        StyleDelta(
            bold: child.bold ?? bold,
            italic: child.italic ?? italic,
            underline: child.underline ?? underline,
            strike: child.strike ?? strike,
            superscript: child.superscript ?? superscript,
            subscriptText: child.subscriptText ?? subscriptText,
            code: child.code ?? code
        )
    }

    func apply(_ base: AnyTypStyle) -> AnyTypStyle {
        AnyTypStyle(
            bold: bold ?? base.bold,
            italic: italic ?? base.italic,
            underline: underline ?? base.underline,
            strike: strike ?? base.strike,
            superscript: superscript ?? base.superscript,
            subscriptText: subscriptText ?? base.subscriptText,
            code: code ?? base.code
        )
    }

    func resolve() -> AnyTypStyle {
        apply(.plain)
    }
}

/// Drop from every run the emphasis `base` already carries (headings carry
/// their own typography).
func rebaseEmphasis(_ inlines: inout [AnyTypInline], base: AnyTypStyle) {
    if base == .plain { return }
    for i in inlines.indices {
        switch inlines[i] {
        case .text(let t, let style):
            inlines[i] = .text(t, style: AnyTypStyle(
                bold: style.bold && !base.bold,
                italic: style.italic && !base.italic,
                underline: style.underline && !base.underline,
                strike: style.strike && !base.strike,
                superscript: style.superscript,
                subscriptText: style.subscriptText,
                code: style.code
            ))
        case .link(let content, let target):
            var inner = content
            rebaseEmphasis(&inner, base: base)
            inlines[i] = .link(content: inner, target: target)
        default:
            break
        }
    }
}
