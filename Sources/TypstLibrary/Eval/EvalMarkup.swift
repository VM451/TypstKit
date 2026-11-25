import Foundation
import TypstSyntax
import TypstUtils

// Port of `typst-eval/src/markup.rs` — markup stream evaluation and the
// leaf markup node evaluators (text, space, breaks, quotes, strong/emph,
// raw, link, label, ref, heading, list items). List/enum/terms containers
// are built during realization, not evaluation.

/// Evaluate a stream of markup expressions.
/// Port of `eval_markup` in `markup.rs`.
func evalMarkupStream(_ vm: inout Vm, _ exprs: [Expr],
                      _ index: inout Int) throws -> Content {
    let outerFlow = vm.flow
    vm.flow = nil
    var seq: [Content] = []

    markupLoop: while index < exprs.count {
        let expr = exprs[index]
        index += 1

        switch expr {
        case .setRule(let set):
            let styles = try set.eval(&vm)
            if vm.flow != nil { break markupLoop }
            seq.append(try evalMarkupStream(&vm, exprs, &index)
                .styledWithMap(styles))
        case .showRule(let show):
            let recipe = try show.eval(&vm)
            if vm.flow != nil { break markupLoop }
            let tail = try evalMarkupStream(&vm, exprs, &index)
            seq.append(try tail.styledWithRecipe(
                engine: &vm.engine, context: vm.context, recipe: recipe))
        default:
            let value = try expr.eval(&vm)
            if case let .label(label) = value {
                if let pos = seq.lastIndex(where: {
                    !$0.elem.can(.unlabellable)
                }) {
                    if seq[pos].label != nil {
                        var warning = SourceDiagnostic.warning(
                            seq[pos].span,
                            "content labelled multiple times")
                        warning.hint(
                            "only the last label is used, the rest are ignored")
                        vm.engine.sink.warn(warning)
                    }
                    seq[pos] = seq[pos].labelled(label)
                } else {
                    let warning = SourceDiagnostic.warning(
                        expr.span,
                        "label `\(label.resolved)` is not attached to anything")
                    vm.engine.sink.warn(warning)
                }
            } else {
                seq.append(value.display.spanned(expr.span))
            }
        }

        if vm.flow != nil { break markupLoop }
    }

    if let flow = outerFlow {
        vm.flow = flow
    }

    return Content.sequence(seq)
}

extension Markup {
    /// Evaluate the markup body. Port of `Markup::eval`.
    public func eval(_ vm: inout Vm) throws -> Content {
        var index = 0
        return try evalMarkupStream(&vm, exprs(), &index)
    }
}

// MARK: - Leaf evaluators

extension TypstSyntax.Text {
    /// Port of `Text::eval`.
    public func eval(_ vm: inout Vm) throws -> Content {
        TextElem.packed(get())
    }
}

extension TypstSyntax.Space {
    /// Port of `Space::eval`.
    public func eval(_ vm: inout Vm) throws -> Content {
        hadNewline ? SpaceElem.sharedWithNewline : SpaceElem.shared
    }
}

extension TypstSyntax.Linebreak {
    /// Port of `Linebreak::eval`.
    public func eval(_ vm: inout Vm) throws -> Content {
        LinebreakElem.shared
    }
}

extension TypstSyntax.Parbreak {
    /// Port of `Parbreak::eval`.
    public func eval(_ vm: inout Vm) throws -> Content {
        ParbreakElem.shared
    }
}

extension TypstSyntax.Escape {
    /// Port of `Escape::eval`.
    public func eval(_ vm: inout Vm) throws -> Value {
        .symbol(Symbol.runtimeChar(String(get()).first!))
    }
}

extension TypstSyntax.Shorthand {
    /// Port of `Shorthand::eval`.
    public func eval(_ vm: inout Vm) throws -> Value {
        .symbol(Symbol.runtimeChar(String(get()).first!))
    }
}

extension TypstSyntax.SmartQuote {
    /// Port of `SmartQuote::eval`.
    public func eval(_ vm: inout Vm) throws -> Content {
        SmartQuoteElem(double: isDouble).pack()
    }
}

extension TypstSyntax.Strong {
    /// Port of `Strong::eval`.
    public func eval(_ vm: inout Vm) throws -> Content {
        let body = try self.body().eval(&vm)
        return StrongElem(body: body).pack()
    }
}

extension TypstSyntax.Emph {
    /// Port of `Emph::eval`.
    public func eval(_ vm: inout Vm) throws -> Content {
        let body = try self.body().eval(&vm)
        return EmphElem(body: body).pack()
    }
}

extension TypstSyntax.Raw {
    /// Port of `Raw::eval`.
    public func eval(_ vm: inout Vm) throws -> Content {
        let lines = self.lines().map { (Str($0.get()), $0.span) }
        var elem = RawElem(.lines(lines), block: block())
        if let lang = self.lang() {
            elem.lang = Str(lang.get())
        }
        return elem.pack()
    }
}

extension TypstSyntax.Link {
    /// Port of `Link::eval`.
    public func eval(_ vm: inout Vm) throws -> Content {
        let url = try unwrap(Url.new(Str(get())).at(span))
        return LinkElem.fromUrl(url).pack()
    }
}

extension TypstSyntax.Label {
    /// Port of `Label::eval` — produces a `Value::Label`, not content.
    public func eval(_ vm: inout Vm) throws -> Value {
        // Label syntax guarantees a non-empty name.
        .label(Label(name: InternedString.intern(get()))!)
    }
}

extension TypstSyntax.Ref {
    /// Port of `Ref::eval`.
    public func eval(_ vm: inout Vm) throws -> Content {
        let target = Label(name: InternedString.intern(self.target()))!
        var elem = RefElem(target: target)
        if let supplement = self.supplement() {
            let content = try supplement.eval(&vm)
            elem.supplement = Spanned(
                .custom(.content(content)), span: supplement.span)
        }
        return elem.pack()
    }
}

extension TypstSyntax.Heading {
    /// Port of `Heading::eval`.
    public func eval(_ vm: inout Vm) throws -> Content {
        let body = try self.body().eval(&vm)
        return HeadingElem(body: body).withDepth(depth()).pack()
    }
}

extension TypstSyntax.ListItem {
    /// Port of `ListItem::eval`.
    public func eval(_ vm: inout Vm) throws -> Content {
        ListItem(body: try self.body().eval(&vm)).pack()
    }
}

extension TypstSyntax.EnumItem {
    /// Port of `EnumItem::eval`.
    public func eval(_ vm: inout Vm) throws -> Content {
        let body = try self.body().eval(&vm)
        var elem = EnumItem(body: body)
        if let number = self.number() {
            elem.number = .custom(number)
        }
        return elem.pack()
    }
}

extension TypstSyntax.TermItem {
    /// Port of `TermItem::eval`.
    public func eval(_ vm: inout Vm) throws -> Content {
        let term = try self.term().eval(&vm)
        let description = try self.description().eval(&vm)
        return TermItem(term: term, description: description).pack()
    }
}
