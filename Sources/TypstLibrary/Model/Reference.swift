import TypstSyntax

/// Reference realization — port of `model/reference.rs` realize logic.
///
/// The native `REF_RULE` lives in the target crates upstream and is
/// dispatched through the realize pipeline's native show rules; that
/// wiring is deferred with the native-rule milestone. This file ports
/// the realization logic itself, callable directly.
///
/// Deferred: bibliography fallback (`to_citation` needs
/// `BibliographyElem`/`Works` — hayagriva milestone).

// MARK: - RefForm

/// The form of the reference. Port of `RefForm` in `model/reference.rs`.
public enum RefForm: String, Sendable, Hashable, CaseIterable {
    /// Produces a textual reference to a label.
    case normal
    /// Produces a page reference to a label.
    case page
}

extension RefForm: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Str.self)) }
    public static var output: CastInfo { .type(Type.of(Str.self)) }
    public static func castable(_ value: Value) -> Bool {
        guard case let .str(s) = value else { return false }
        return RefForm(rawValue: s.value) != nil
    }
    public func intoValue() -> Value { .str(Str(rawValue)) }
    public static func fromValue(_ value: Value) -> HintedStrResult<RefForm> {
        guard case let .str(s) = value,
              let form = RefForm(rawValue: s.value)
        else { return .failure(error(value)) }
        return .success(form)
    }
}

// MARK: - RefElem realize

extension RefElem {
    /// Port of `Packed<RefElem>::realize` in `model/reference.rs`.
    ///
    /// Divergences: the bibliography-citation fallback is absent until
    /// the hayagriva milestone; missing labels therefore always error.
    public func realize(
        engine: inout Engine, styles: StyleChain
    ) -> SourceResult<Content> {
        let span = self.span
        let elemResult = engine.introspect(
            QueryLabelIntrospection(label: target, span: span))

        let resolvedForm: RefForm
        if let v = styles.get(Element(RefElem.self), 2),
           case let .success(f) = RefForm.fromValue(v) {
            resolvedForm = f
        } else {
            resolvedForm = form
        }

        if resolvedForm == .page {
            guard case let .success(elem) = elemResult else {
                if case let .failure(err) = elemResult {
                    return .failure(SourceDiagnostics(
                        SourceDiagnostic.error(span, err.message)))
                }
                return .failure(SourceDiagnostics(
                    SourceDiagnostic.error(span, "label not found")))
            }
            guard let loc = elem.location else {
                return .failure(SourceDiagnostics(SourceDiagnostic.error(
                    span, "cannot reference element without location")))
            }
            let numbering = engine.introspect(
                PageNumberingIntrospection(location: loc, span: span))
            guard let numbering else {
                var diag = SourceDiagnostic.error(
                    span, "cannot reference without page numbering")
                diag.hint(
                    "you can enable page numbering with `#set page(numbering: \"1\")`")
                return .failure(SourceDiagnostics(diag))
            }
            let supplement = engine.introspect(
                PageSupplementIntrospection(location: loc, span: span))
            return realizeReference(
                engine: &engine, styles: styles,
                counter: Counter(.page), numbering: numbering,
                supplement: supplement, elem: elem)
        }

        // RefForm.normal — bibliography fallback deferred.
        guard case let .success(elem) = elemResult else {
            if case let .failure(err) = elemResult {
                return .failure(SourceDiagnostics(
                    SourceDiagnostic.error(span, err.message)))
            }
            return .failure(SourceDiagnostics(
                SourceDiagnostic.error(span, "label not found")))
        }

        if let footnote = elem.to(FootnoteElem.self) {
            return .success(
                Content(footnote.intoRef(target)).spanned(span))
        }

        guard let refable = elem.packed.element as? any Refable else {
            let name = elem.elem.info.name
            let message: String
            if elem.packed.element is any Figurable {
                message = "cannot reference \(name) directly, "
                    + "try putting it into a figure"
            } else {
                message = "cannot reference \(name)"
            }
            return .failure(SourceDiagnostics(
                SourceDiagnostic.error(span, message)))
        }

        guard let numbering = refable.refNumbering() else {
            let name = elem.elem.info.name
            var diag = SourceDiagnostic.error(
                span, "cannot reference \(name) without numbering")
            diag.hint(
                "you can enable \(name) numbering with `#set \(name)(numbering: \"1.\")`")
            return .failure(SourceDiagnostics(diag))
        }

        return realizeReference(
            engine: &engine, styles: styles,
            counter: refable.refCounter(), numbering: numbering,
            supplement: refable.refSupplement(), elem: elem)
    }

    /// Port of `realize_reference` in `model/reference.rs`.
    private func realizeReference(
        engine: inout Engine, styles: StyleChain,
        counter: Counter, numbering: Numbering,
        supplement: Content, elem: Content
    ) -> SourceResult<Content> {
        let span = self.span
        guard let loc = elem.location else {
            return .failure(SourceDiagnostics(SourceDiagnostic.error(
                span, "cannot reference element without location")))
        }
        let numbers: Content
        switch counter.displayAt(
            engine: &engine, loc: loc, styles: styles,
            numbering: numbering.trimmed(), span: span) {
        case let .success(c): numbers = c
        case let .failure(err): return .failure(err)
        }

        let resolvedSupplement: Content
        let ownSupplement = supplementValue(styles)
        switch ownSupplement {
        case .auto:
            resolvedSupplement = supplement
        case .custom(nil):
            resolvedSupplement = .empty
        case let .custom(.some(supp)):
            switch supp.resolve(
                engine: &engine, styles: styles,
                args: [elem.intoValue()]) {
            case let .success(c): resolvedSupplement = c
            case let .failure(err): return .failure(err)
            }
        }

        let alt = "\(resolvedSupplement.plainText) \(numbers.plainText)"

        var content = numbers
        if !resolvedSupplement.isEmpty {
            content = resolvedSupplement
                + TextElem.packed("\u{a0}")
                + content
        }
        content = content.spanned(span)

        return .success(
            DirectLinkElem(loc: loc, body: content, alt: Str(alt))
                .pack().spanned(span))
    }

    /// Chain-first/own-fallback resolution of the reference's supplement
    /// field (the port's `Settable` union pattern).
    private func supplementValue(_ styles: StyleChain) -> Smart<Supplement?> {
        if let v = styles.get(Element(RefElem.self), 1),
           case let .success(s) = Smart<Supplement?>.fromValue(v) {
            return s
        }
        return supplement.value
    }
}

// MARK: - Native rule registration

/// Registers the built-in show rules ported so far. Port of the rule
/// registration upstream performs in the target crates
/// (`typst-layout`/`typst-html` `rules.rs`). Both targets share the
/// reference rule shape (`elem.realize(engine, styles)`).
public func defineNativeRules(_ rules: NativeRuleMap) {
    for target in [Target.paged, Target.html] {
        rules.register(elem: Element(RefElem.self), target: target) {
            content, engine, styles in
            guard let ref = content.to(RefElem.self) else {
                return .success(content)
            }
            return ref.realize(engine: &engine, styles: styles)
        }
    }
}
