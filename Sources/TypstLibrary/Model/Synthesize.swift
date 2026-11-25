import TypstSyntax

/// `Synthesize` capability implementations — port of the synthesize
/// bodies in `model/heading.rs` and `model/figure.rs`.
///
/// Divergences (tracked):
/// - `FigureElem` kind detection falls back to `Name("image")` when no
///   `Figurable` descendant exists, since `ImageElem` is unported
///   (upstream default is `Elem(ImageElem)`).
/// - Kind local names resolve through a fixed table for ported kinds
///   (table/raw) rather than upstream's `func.local_name` trait lookup.
/// - The synthesized `locale` field needs `Lang`/`Region` (deferred).
/// - Chain resolution uses the port's chain-first/own-fallback union
///   convention.

// MARK: - Chain resolution helpers

/// Chain value if set, else own — the port's `Settable` union pattern.
private func chainOrOwn<T: FromValue>(
    _ styles: StyleChain, _ elem: Element, _ field: UInt8, _ own: T
) -> T {
    if let v = styles.get(elem, field),
       case let .success(parsed) = T.fromValue(v) {
        return parsed
    }
    return own
}

// MARK: - HeadingElem

extension HeadingElem: SynthesizeCapable {
    /// Port of `Synthesize for Packed<HeadingElem>`.
    public mutating func synthesize(
        engine: inout Engine, styles: StyleChain, location: Location?
    ) throws {
        let supplementContent: Content
        let ownSupplement = supplement.value
        let resolved: Smart<Supplement?>
        if let v = styles.get(Element(HeadingElem.self), 5),
           case let .success(s) = Smart<Supplement?>.fromValue(v) {
            resolved = s
        } else {
            resolved = ownSupplement
        }
        switch resolved {
        case .auto:
            supplementContent =
                TextElem.packed(HeadingElem.localNameIn(styles))
        case .custom(nil):
            supplementContent = .empty
        case let .custom(.some(supp)):
            supplementContent = try supp.resolve(
                engine: &engine, styles: styles,
                args: [pack().intoValue()]).get()
        }

        // Synthesize the numbers if numbered and located. Errors are not
        // propagated early because of upstream issue #7428.
        let resolvedNumbering = chainOrOwn(
            styles, Element(HeadingElem.self), 3, numbering)
        if let numbering = resolvedNumbering, let location {
            let ctr = Counter.of(Element(HeadingElem.self))
            if case let .success(numbers) = ctr.displayAt(
                engine: &engine, loc: location, styles: styles,
                numbering: numbering, span: span) {
                self.numbers = Str(numbers.plainText)
            }
        }

        level = .custom(resolveLevel().value)
        supplement = Spanned(
            .custom(.content(supplementContent)), span: supplement.span)
    }
}

// MARK: - FigureElem

extension FigureElem: SynthesizeCapable {
    /// Port of `Synthesize for Packed<FigureElem>` minus the `locale`
    /// field (needs `Lang`/`Region`).
    public mutating func synthesize(
        engine: inout Engine, styles: StyleChain, location: Location?
    ) throws {
        let span = self.span
        let resolvedNumbering = chainOrOwn(
            styles, Element(FigureElem.self), 7, numbering)

        // Determine the figure's kind.
        let kind: FigureKind
        if let v = styles.get(Element(FigureElem.self), 5),
           case let .success(.custom(k)) = Smart<FigureKind>.fromValue(v) {
            kind = k
        } else if case let .custom(k) = self.kind {
            kind = k
        } else if let found = body.queryFirstNaive({
            $0.packed.element is any Figurable
        }) {
            kind = .elem(found.packed.elem)
        } else {
            // Upstream default: `Elem(ImageElem)` — the image element is
            // unported; the name form is used instead.
            kind = .name(Str("image"))
        }

        // Resolve the supplement.
        let supplementContent: Content?
        let resolvedSupplement: Smart<Supplement?>
        if let v = styles.get(Element(FigureElem.self), 6),
           case let .success(s) = Smart<Supplement?>.fromValue(v) {
            resolvedSupplement = s
        } else {
            resolvedSupplement = self.supplement
        }
        switch resolvedSupplement {
        case .auto:
            // Default to the local name for the kind, if available.
            let name = figureKindLocalName(kind).map { TextElem.packed($0) }
            if resolvedNumbering != nil && name == nil {
                throw SourceDiagnostics(SourceDiagnostic.error(
                    span, "please specify the figure's supplement"))
            }
            supplementContent = name ?? .empty
        case .custom(nil):
            supplementContent = nil
        case let .custom(.some(supp)):
            // Resolve the supplement with the first descendant of the
            // kind or just the body, if none was found.
            var target = body
            if case let .elem(elemFunc) = kind,
               let descendant = body.queryFirstNaive({
                   $0.packed.elem == elemFunc
               }) {
                target = descendant
            }
            supplementContent = try supp.resolve(
                engine: &engine, styles: styles,
                args: [target.intoValue()]).get()
        }

        // Construct the figure's counter.
        let counter = Counter(.selector(.elem(
            Element(FigureElem.self),
            fields: [(5, kind.intoValue())])))

        // Fill the figure's caption.
        if var cap = caption {
            try cap.synthesize(
                engine: &engine, styles: styles, location: location)
            cap.kind = kind
            cap.supplement = supplementContent
            cap.numbering = resolvedNumbering
            cap.counter = counter
            cap.figureLocation = location
            caption = cap
        }

        self.kind = .custom(kind)
        supplement = .custom(
            supplementContent.map { Supplement.content($0) })
        self.counter = counter
    }
}

/// The local name for a figure kind's element. Stands in for upstream's
/// `func.local_name` until elements expose their `LocalName` key through
/// `Element` — covers the ported `Figurable` kinds.
private func figureKindLocalName(_ kind: FigureKind) -> String? {
    switch kind {
    case let .elem(elem):
        if elem == Element(TableElem.self) { return "Table" }
        if elem == Element(RawElem.self) { return "Listing" }
        return nil
    case let .name(name):
        // The port's ImageElem fallback — upstream's default kind is
        // Elem(ImageElem) whose local name is "figure".
        return name.value == "image" ? "figure" : nil
    }
}

// MARK: - FigureCaption

extension FigureCaption: SynthesizeCapable {
    /// Port of `Synthesize for Packed<FigureCaption>`.
    public mutating func synthesize(
        engine: inout Engine, styles: StyleChain, location: Location?
    ) throws {
        separator = .custom(resolveSeparator(styles: styles))
    }
}
