import TypstSyntax

/// Port of `model/outline.rs` — the outline element, outline entries,
/// the `Refable`/`Outlinable`/`LocalName` protocols, and `OutlineIndent`.
///
/// Deferred with the layout milestone (`typst-layout/rules.rs`):
/// - `OUTLINE_RULE` / `OUTLINE_ENTRY_RULE` show rules (`PdfMarkerTag`,
///   `linked`, `SmartQuotes`, `plain_text`)
/// - `OutlineEntry.indented`, `measure_prefix`, `compute_auto_indents`,
///   `determine_prefix_widths`, `PrefixInfo` — all need
///   `routines.layout_frame` → `Frame` (`measure`)
/// - `EquationElem`'s `Outlinable`/`Refable` impls (math milestone)

// MARK: - LocalName

/// The name with which an element is referenced.
///
/// Port of `LocalName` in `text/lang.rs`. The full i18n stack (`Lang`,
/// `Region`, `localized_str`, `TRANSLATIONS`) is deferred with the text
/// milestone; until then `localNameIn` resolves through the English
/// bundle — which is also upstream's ultimate fallback.
public protocol LocalName {
    /// The key of an element in order to get its localized name.
    static var localNameKey: String { get }
}

extension LocalName {
    /// Get the name in the given language and (optionally) region.
    /// Deferred: always resolves English until `Lang`/`Region` land.
    public static func localName(lang: Str?, region: Str?) -> String {
        englishLocalNames[localNameKey] ?? localNameKey
    }

    /// Gets the local name from the style chain (`text.lang`/`text.region`).
    /// Until `Lang`/`Region` land the lookup ignores the actual tags — the
    /// result is the English bundle either way.
    public static func localNameIn(_ styles: StyleChain) -> String {
        localName(lang: nil, region: nil)
    }
}

/// The English translation bundle (`translations/en.txt` upstream).
private let englishLocalNames: [String: String] = [
    "figure": "Figure",
    "table": "Table",
    "equation": "Equation",
    "bibliography": "Bibliography",
    "heading": "Section",
    "outline": "Contents",
    "raw": "Listing",
    "page": "page",
    "footnote": "Footnote",
    "email": "Email",
    "telephone": "Telephone",
]

// MARK: - Refable / Outlinable

/// Marks an element as being able to be referenced. This is used to
/// implement the `@ref` element. Port of `Refable` in
/// `model/reference.rs`.
public protocol Refable {
    /// The supplement, if not overridden by the reference.
    /// Upstream `supplement` — renamed since Swift forbids a method
    /// sharing a name with a stored property.
    func refSupplement() -> Content
    /// Returns the counter of this element. Upstream `counter`.
    func refCounter() -> Counter
    /// Returns the numbering of this element. Upstream `numbering`.
    func refNumbering() -> Numbering?
}

/// Marks an element as being able to be outlined. Port of `Outlinable`
/// in `model/outline.rs`. Method names are prefixed since Swift forbids
/// a method sharing a name with a stored property.
public protocol Outlinable: Refable {
    /// Whether this element should be included in the outline.
    /// Upstream `outlined`.
    func isOutlined() -> Bool
    /// The nesting level of this element. Upstream `level`.
    func outlineLevel() -> NonZeroUsize
    /// Constructs the default prefix given the formatted numbering.
    /// Upstream `prefix`.
    func outlinePrefix(_ numbers: Content) -> Content
    /// The body of the entry. Upstream `body`.
    func outlineBody() -> Content
}

extension Outlinable {
    /// Upstream default: top-level.
    public func outlineLevel() -> NonZeroUsize { NonZeroUsize(value: 1) }
}

// MARK: - OutlineIndent

/// Defines how an outline is indented. Port of `OutlineIndent`.
public enum OutlineIndent: Sendable, Hashable {
    /// Indents by the specified length per level.
    case rel(Rel<Length>)
    /// Resolve the indent for a specific level through the given function.
    case function(Func)
}

extension OutlineIndent {
    /// Resolve the indent for an entry with the given level.
    /// Port of `OutlineIndent::resolve`.
    func resolve(
        engine: inout Engine, context: Context, level: NonZeroUsize,
        span: Span
    ) -> SourceResult<Rel<Length>> {
        let depth = level.value - 1
        switch self {
        case let .rel(length):
            return .success(length * Double(depth))
        case let .function(`func`):
            let args = Args(span: span, values: [Value.int(Int64(depth))])
            return `func`.callValue(
                engine: &engine, context: context, args: args, span: span)
                .flatMap { Rel<Length>.fromValue($0).at(span) }
        }
    }
}

extension OutlineIndent: Repr {
    public func repr() -> String {
        switch self {
        case let .rel(v): return v.repr()
        case let .function(f): return f.repr()
        }
    }
}

extension OutlineIndent: Castable, IntoValue, FromValue {
    public static var input: CastInfo {
        .union([Rel<Length>.input, Func.input])
    }
    public static var output: CastInfo {
        .union([Rel<Length>.output, Func.output])
    }

    public static func castable(_ value: Value) -> Bool {
        Rel<Length>.castable(value) || Func.castable(value)
    }

    public func intoValue() -> Value {
        switch self {
        case let .rel(v): return v.intoValue()
        case let .function(f): return f.intoValue()
        }
    }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        if Func.castable(value) {
            return Func.fromValue(value).map { .function($0) }
        }
        return Rel<Length>.fromValue(value).map { .rel($0) }
    }
}

// MARK: - OutlineElem

/// An outline of the document's headings (or other outlineable elements).
/// Port of `OutlineElem` in `model/outline.rs`.
public struct OutlineElem: NativeElement {
    public static let info = ElementInfo(
        name: "outline",
        title: "Outline",
        keywords: ["Table of Contents", "toc"],
        scope: OutlineElem.entryScope,
        fields: [
            FieldInfo(id: 0, name: "title", settable: true),
            FieldInfo(id: 1, name: "target", settable: true),
            FieldInfo(id: 2, name: "depth", settable: true),
            FieldInfo(id: 3, name: "indent", settable: true),
        ],
        capabilities: [.locatable, .tagged]
    )

    /// The title of the outline.
    public var title: Smart<Content?> = .auto

    /// The type of element to include in the outline.
    public var target: LocatableSelector =
        LocatableSelector(.elem(Element(HeadingElem.self), fields: nil))

    /// The maximum level up to which elements are included.
    public var depth: NonZeroUsize? = nil

    /// How to indent the outline's entries.
    public var indent: Smart<OutlineIndent> = .auto

    public var span: Span = .detached

    public init() {}

    public func pack() -> Content { Content(self) }

    // MARK: Style-chain resolution
    //
    // The port stores field values directly (no `Settable` wrapper), so a
    // chain value wins over the own value where one exists — matching the
    // union semantics of the port's other elements.

    /// `self.title.get_cloned(styles)` — stays `Smart` (no auto resolution).
    func resolvedTitle(_ styles: StyleChain) -> Smart<Content?> {
        if let v = styles.get(Element(OutlineElem.self), 0),
           case let .success(s) = Smart<Content?>.fromValue(v) {
            return s
        }
        return title
    }

    /// `self.target.get_cloned(styles)`.
    func resolvedTarget(_ styles: StyleChain) -> LocatableSelector {
        if let v = styles.get(Element(OutlineElem.self), 1),
           case let .success(s) = LocatableSelector.fromValue(v) {
            return s
        }
        return target
    }

    /// `self.depth.get(styles).unwrap_or(NonZeroUsize::MAX)`.
    func resolvedDepth(_ styles: StyleChain) -> NonZeroUsize {
        if let v = styles.get(Element(OutlineElem.self), 2),
           case let .success(s) = Optional<NonZeroUsize>.fromValue(v),
           let d = s {
            return d
        }
        return depth ?? NonZeroUsize(value: Int.max)
    }

    /// `self.indent.get_ref(styles)` — stays `Smart` (no auto resolution).
    func resolvedIndent(_ styles: StyleChain) -> Smart<OutlineIndent> {
        if let v = styles.get(Element(OutlineElem.self), 3),
           case let .success(s) = Smart<OutlineIndent>.fromValue(v) {
            return s
        }
        return indent
    }

    // MARK: Realize helpers

    /// Produces the heading for the outline, if any.
    /// Port of `Packed<OutlineElem>::realize_title`.
    public func realizeTitle(_ styles: StyleChain) -> Content? {
        let span = self.span
        let title: Content?
        switch resolvedTitle(styles) {
        case .auto:
            title = TextElem.packed(OutlineElem.localNameIn(styles))
        case let .custom(inner):
            title = inner
        }
        return title.map {
            HeadingElem(body: $0)
                .withDepth(NonZeroUsize(value: 1).value)
                .pack()
                .spanned(span)
        }
    }

    /// Realizes the entries in a flat fashion.
    /// Port of `Packed<OutlineElem>::realize_flat`.
    public func realizeFlat(
        engine: inout Engine, styles: StyleChain
    ) -> SourceResult<[Content]> {
        var entries: [Content] = []
        for result in realizeIter(engine: &engine, styles: styles) {
            switch result {
            case let .success((entry, _, included)):
                if included { entries.append(entry) }
            case let .failure(e): return .failure(e)
            }
        }
        return .success(entries)
    }

    /// Realizes the entries in a tree fashion.
    /// Port of `Packed<OutlineElem>::realize_tree`.
    public func realizeTree(
        engine: inout Engine, styles: StyleChain
    ) -> SourceResult<[OutlineNode]> {
        var flat: [(Content, NonZeroUsize, Bool)] = []
        for result in realizeIter(engine: &engine, styles: styles) {
            switch result {
            case let .success(triple): flat.append(triple)
            case let .failure(e): return .failure(e)
            }
        }
        return .success(OutlineNode.buildTree(flat: flat))
    }

    /// Realizes the entries as a list.
    /// Port of `Packed<OutlineElem>::realize_iter` (upstream is a lazy
    /// iterator; the port collects eagerly).
    func realizeIter(
        engine: inout Engine, styles: StyleChain
    ) -> [SourceResult<(Content, NonZeroUsize, Bool)>] {
        let span = self.span
        let elems = engine.introspect(QueryIntrospection(
            selector: resolvedTarget(styles).selector, span: span))
        let depth = resolvedDepth(styles)
        return elems.map { elem in
            guard let outlinable = elem.packed.element as? any Outlinable
            else {
                return .failure(SourceDiagnostics(SourceDiagnostic.error(
                    span, "cannot outline \(elem.name)")))
            }
            let level = outlinable.outlineLevel()
            let include = outlinable.isOutlined() && level.value <= depth.value
            let entry = OutlineEntry(level: level, element: elem)
            return .success((entry.pack().spanned(span), level, include))
        }
    }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return title.intoValue()
        case 1: return target.intoValue()
        case 2: return depth?.intoValue() ?? .none
        case 3: return indent.intoValue()
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch id {
        case 0: title = try Smart<Content?>.fromValue(value).get()
        case 1: target = try LocatableSelector.fromValue(value).get()
        case 2: depth = try Optional<NonZeroUsize>.fromValue(value).get()
        case 3: indent = try Smart<OutlineIndent>.fromValue(value).get()
        default: break
        }
    }
}

extension OutlineElem {
    /// Upstream auto-generated `Construct` — all fields optional named.
    public static func construct(
        engine: inout Engine, args: inout Args
    ) throws -> Content {
        var elem = OutlineElem()
        elem.title = try args.namedT("title") ?? .auto
        elem.target = try args.namedT("target") ?? elem.target
        elem.depth = try args.namedOpt("depth")
        elem.indent = try args.namedT("indent") ?? .auto
        try args.finishT()
        return elem.pack().spanned(args.span)
    }
}

extension OutlineElem: ShowSetCapable {
    /// Port of `ShowSet for Packed<OutlineElem>`.
    public func showSet(styles: StyleChain) -> Styles {
        func prop(_ elem: Element, _ field: UInt8, _ value: Value) -> Style {
            .property(Property(elem: elem, field: field, value: value))
        }
        // `styles.get(ParElem::leading)` — chain value or the field default.
        var leading = Length(Em(0.65))
        if let v = styles.get(Element(ParElem.self), 0),
           case .length(let l) = v {
            leading = l
        }
        return Styles([
            prop(Element(HeadingElem.self), 6, .bool(false)),
            prop(Element(HeadingElem.self), 3, .none),
            prop(Element(ParElem.self), 2, .bool(false)),
            prop(Element(BlockElem.self), 8,
                 Smart<Spacing>.custom(.rel(Rel<Length>(leading))).intoValue()),
            // Makes the outline itself available to its entries. Should be
            // superseded by a proper ancestry mechanism in the future.
            prop(Element(OutlineEntry.self), 3,
                 Content(self).intoValue()),
        ])
    }
}

extension OutlineElem: LocalName {
    public static let localNameKey = "outline"
}

// MARK: - OutlineNode

/// A node in a tree of outline entries.
/// Port of `OutlineNode` (upstream is generic over the packed entry;
/// the port uses `Content`).
public struct OutlineNode {
    /// The entry itself.
    public var entry: Content
    /// The entry's level.
    public var level: NonZeroUsize
    /// Its descendants.
    public var children: [OutlineNode]

    /// Turns a flat list of entries into a tree.
    /// Port of `OutlineNode::build_tree`.
    public static func buildTree(
        flat: [(Content, NonZeroUsize, Bool)]
    ) -> [OutlineNode] {
        // Stores the level of the topmost skipped ancestor of the next
        // included heading.
        var lastSkippedLevel: Int? = nil
        var tree: [OutlineNode] = []

        for (entry, level, include) in flat {
            if include {
                // Descend the tree through the latest included heading of
                // each level until a sibling position is reached (see the
                // upstream comment for the full case analysis). Since
                // arrays are value types in Swift, the descent computes an
                // index path and the insertion walks it.
                var path: [Int] = []
                var children = tree
                while let last = children.last,
                      lastSkippedLevel.map({ last.level.value < $0 }) ?? true,
                      last.level.value < level.value {
                    path.append(children.count - 1)
                    children = last.children
                }
                let node = OutlineNode(entry: entry, level: level,
                                       children: [])
                appendNode(&tree, path: path, node: node)
                // Since this heading was bookmarked, the next heading (if
                // it is a child of this one) won't have a skipped direct
                // ancestor.
                lastSkippedLevel = nil
            } else if lastSkippedLevel.map({ level.value < $0 }) ?? true {
                // Only the topmost / lowest-level skipped heading matters
                // when we have consecutive skipped headings.
                lastSkippedLevel = level.value
            }
        }
        return tree
    }

    /// Append `node` into the nested `children` array reached by `path`.
    private static func appendNode(
        _ nodes: inout [OutlineNode], path: [Int], node: OutlineNode
    ) {
        guard let first = path.first else {
            nodes.append(node)
            return
        }
        appendNode(&nodes[first].children, path: Array(path.dropFirst()),
                   node: node)
    }
}

// MARK: - OutlineEntry

/// Represents an entry line in an outline.
/// Port of `OutlineEntry` in `model/outline.rs`.
public struct OutlineEntry: NativeElement {
    public static let info = ElementInfo(
        name: "entry",
        title: "Outline Entry",
        scope: OutlineEntry.entryScope,
        fields: [
            FieldInfo(id: 0, name: "level", required: true),
            FieldInfo(id: 1, name: "element", required: true),
            FieldInfo(id: 2, name: "fill", settable: true),
            FieldInfo(id: 3, name: "parent"),
        ],
        capabilities: [.locatable, .tagged]
    )

    /// The nesting level of this outline entry. Starts at 1.
    public var level: NonZeroUsize

    /// The element this entry refers to.
    public var element: Content

    /// Content to fill the space between the title and the page number.
    public var fill: Content? =
        Content(RepeatElem(
            body: TextElem.packed("."),
            gap: Length(Em(0.15))
        ))

    /// Lets outline entries access the outline they are part of. Upstream
    /// stores `Packed<OutlineElem>`; the port stores it as content —
    /// a superset, since `Packed` carries no label or location either
    /// (ghost + internal upstream).
    public var parent: Content? = nil

    public var span: Span = .detached

    public init(level: NonZeroUsize, element: Content) {
        self.level = level
        self.element = element
    }

    public func pack() -> Content { Content(self) }

    /// The outlinable element behind this entry, or an error.
    /// Port of `OutlineEntry::outlinable`.
    func outlinable() -> HintedStrResult<any Outlinable> {
        guard let outlinable = element.packed.element as? any Outlinable
        else {
            return .failure(HintedString(
                "cannot outline \(element.name)"))
        }
        return .success(outlinable)
    }

    /// Returns the location of the outlined element.
    /// Port of `OutlineEntry::element_location`.
    public func elementLocation() -> HintedStrResult<Location> {
        guard let loc = element.location else {
            if element.packed.element is any Outlinable {
                return .failure(HintedString(
                    "\(element.name) must have a location")
                    .withHint("try using a show rule to customize the "
                              + "outline.entry instead"))
            }
            return .failure(HintedString(
                "cannot outline \(element.name)"))
        }
        return .success(loc)
    }

    /// Creates the default inner content of the entry.
    /// Port of `OutlineEntry::build_inner`.
    func buildInner(
        context: Context, span: Span, body: Content, page: Content
    ) -> SourceResult<Content> {
        let styles: StyleChain
        switch context.requireStyles().at(span) {
        case let .success(s): styles = s
        case let .failure(e): return .failure(e)
        }

        var seq: [Content] = []

        // Isolate the entry body in RTL because the page number is
        // typically LTR (see the upstream comment for the full rationale).
        let rtl = TextElem.dirValue(styles) == .rtl
        if rtl {
            // "Right-to-Left Embedding"
            seq.append(TextElem.packed("\u{202B}"))
        }
        seq.append(body)
        if rtl {
            // "Pop Directional Formatting"
            seq.append(TextElem.packed("\u{202C}"))
        }

        // Add the filler between the section name and page number.
        if let filler = resolvedFill(styles) {
            seq.append(SpaceElem.shared)
            var box = BoxElem(width: .fr(.one), body: filler)
            box.span = span
            seq.append(Content(box).spanned(span))
            seq.append(SpaceElem.shared)
        } else {
            var h = HElem(amount: .fr(.one))
            h.span = span
            seq.append(Content(h).spanned(span))
        }

        // Add the page number. The word joiner in front ensures that the
        // page number doesn't stand alone in its line.
        seq.append(TextElem.packed("\u{2060}"))
        seq.append(page)

        return .success(Content.sequence(seq))
    }

    /// `self.fill.get_cloned(styles)` — chain value wins over own.
    func resolvedFill(_ styles: StyleChain) -> Content? {
        if let v = styles.get(Element(OutlineEntry.self), 2),
           case let .success(f) = Optional<Content>.fromValue(v) {
            return f
        }
        return fill
    }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return level.intoValue()
        case 1: return element.intoValue()
        case 2: return fill?.intoValue() ?? .none
        case 3: return parent?.intoValue() ?? .none
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch id {
        case 0: level = try NonZeroUsize.fromValue(value).get()
        case 1: element = try Content.fromValue(value).get()
        case 2: fill = try Optional<Content>.fromValue(value).get()
        case 3: parent = try Optional<Content>.fromValue(value).get()
        default: break
        }
    }
}

extension OutlineEntry {
    /// Upstream auto-generated `Construct` (level/element required,
    /// fill optional named; `parent` is ghost+internal upstream and not
    /// parsed).
    public static func construct(
        engine: inout Engine, args: inout Args
    ) throws -> Content {
        let level: NonZeroUsize = try args.expectT("level")
        let element: Content = try args.expectT("element")
        // Tri-state: absent keeps the default, explicit `none` clears.
        let fill: Content?? = try args.namedT("fill")
        try args.finishT()
        var elem = OutlineEntry(level: level, element: element)
        if let fill { elem.fill = fill }
        return elem.pack().spanned(args.span)
    }
}

extension OutlineEntry: Castable, IntoValue, FromValue {
    /// Port of `cast! { OutlineEntry, v: Content => v.unpack::<Self>() }`.
    public static var input: CastInfo { Content.input }
    public static var output: CastInfo { Content.output }
    public static func castable(_ value: Value) -> Bool {
        Content.castable(value)
    }
    public func intoValue() -> Value { .content(Content(self)) }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .content(c) = value else {
            return .failure(error(value))
        }
        guard let elem = c.packed(OutlineEntry.self) else {
            return .failure(HintedString("expected outline entry"))
        }
        return .success(elem)
    }
}

// MARK: - Scopes

extension OutlineElem {
    /// Upstream `#[scope] impl OutlineElem { #[elem] type OutlineEntry }`.
    static var entryScope: Scope {
        let scope = Scope()
        scope.define("entry",
                     .function(Element(OutlineEntry.self).function))
        return scope
    }
}

extension OutlineEntry {
    /// Upstream `#[scope] impl OutlineEntry` minus `indented`
    /// (deferred — needs `measure` / `layout_frame`).
    static var entryScope: Scope {
        let scope = Scope()
        scope.defineFunc(entryPrefix)
        scope.defineFunc(entryInner)
        scope.defineFunc(entryBody)
        scope.defineFunc(entryPage)
        return scope
    }
}

// MARK: - OutlineEntry scope functions

/// `outline.entry.prefix()` — formats the element's numbering.
/// Port of `OutlineEntry::prefix`.
let entryPrefix = nativeFunc(
    "prefix",
    title: "Prefix",
    since: .version([0, 11, 0]),
    docs: """
        Formats the element's numbering (if any).

        This also appends the element's supplement in case of figures or
        equations.
        """,
    contextual: true,
    params: [
        NativeParamInfo(name: "self", input: OutlineEntry.input,
                        required: true),
    ],
    returns: Value.output
) { engine, context, args in
    let entry: OutlineEntry = try args.expectT("self")
    try args.finishT()
    let span = args.span
    let outlinable = try entry.outlinable().at(span).get()
    guard let numbering = outlinable.refNumbering() else {
        return Value.none
    }
    let loc = try entry.elementLocation().at(span).get()
    let styles = try context.requireStyles().at(span).get()
    let numbers = try outlinable.refCounter().displayAt(
        engine: &engine, loc: loc, styles: styles,
        numbering: numbering, span: span).get()
    return outlinable.outlinePrefix(numbers).intoValue()
}

/// `outline.entry.inner()` — default inner content.
/// Port of `OutlineEntry::inner`.
let entryInner = nativeFunc(
    "inner",
    title: "Inner",
    since: .version([0, 11, 0]),
    docs: """
        Creates the default inner content of the entry.

        This includes the body, the fill, and page number.
        """,
    contextual: true,
    params: [
        NativeParamInfo(name: "self", input: OutlineEntry.input,
                        required: true),
    ],
    returns: Content.output
) { engine, context, args in
    let entry: OutlineEntry = try args.expectT("self")
    try args.finishT()
    let span = args.span
    let body = try entryBodyValue(entry).at(span).get()
    let page = try entryPageValue(
        entry, engine: &engine, context: context, span: span).get()
    return try entry.buildInner(
        context: context, span: span, body: body, page: page).get()
}

/// `outline.entry.body()` — the referred element's body.
/// Port of `OutlineEntry::body`.
let entryBody = nativeFunc(
    "body",
    title: "Body",
    since: .version([0, 11, 0]),
    docs: """
        The content which is displayed in place of the referred element at
        its entry in the outline. For a heading, this is its body; for a
        figure a caption and for equations, it is empty.
        """,
    params: [
        NativeParamInfo(name: "self", input: OutlineEntry.input,
                        required: true),
    ],
    returns: Content.output
) { _, _, args in
    let entry: OutlineEntry = try args.expectT("self")
    try args.finishT()
    return try entryBodyValue(entry).at(args.span).get()
}

/// `outline.entry.page()` — the formatted page number.
/// Port of `OutlineEntry::page`.
let entryPage = nativeFunc(
    "page",
    title: "Page",
    since: .version([0, 11, 0]),
    docs: """
        The page number of this entry's element, formatted with the
        numbering set for the referenced page.
        """,
    contextual: true,
    params: [
        NativeParamInfo(name: "self", input: OutlineEntry.input,
                        required: true),
    ],
    returns: Content.output
) { engine, context, args in
    let entry: OutlineEntry = try args.expectT("self")
    try args.finishT()
    return try entryPageValue(
        entry, engine: &engine, context: context, span: args.span).get()
}

/// Shared body of `entry.body`/`entry.inner`.
private func entryBodyValue(_ entry: OutlineEntry) -> HintedStrResult<Content> {
    entry.outlinable().map { $0.outlineBody() }
}

/// Shared body of `entry.page`/`entry.inner`.
private func entryPageValue(
    _ entry: OutlineEntry, engine: inout Engine, context: Context,
    span: Span
) -> SourceResult<Content> {
    switch entry.elementLocation().at(span) {
    case let .failure(e): return .failure(e)
    case let .success(loc):
        switch context.requireStyles().at(span) {
        case let .failure(e): return .failure(e)
        case let .success(styles):
            let numbering = engine.introspect(
                PageNumberingIntrospection(location: loc, span: span))
                ?? .pattern((try? NumberingPattern(parsing: "1"))!)
            return Counter(.page).displayAt(
                engine: &engine, loc: loc, styles: styles,
                numbering: numbering, span: span)
        }
    }
}

// MARK: - Refable / Outlinable impls

extension HeadingElem: Refable {
    /// Port of `Refable for Packed<HeadingElem>`.
    public func refSupplement() -> Content {
        // After synthesis, this should always be custom content.
        guard case let .custom(.some(s)) = supplement.value,
              case let .content(c) = s else {
            return .empty
        }
        return c
    }

    public func refCounter() -> Counter {
        Counter.of(Element(HeadingElem.self))
    }

    public func refNumbering() -> Numbering? { numbering }
}

extension HeadingElem: Outlinable {
    public func isOutlined() -> Bool { outlined }

    public func outlineLevel() -> NonZeroUsize { resolveLevel() }

    public func outlinePrefix(_ numbers: Content) -> Content { numbers }

    public func outlineBody() -> Content { body }
}

extension HeadingElem: LocalName {
    public static let localNameKey = "heading"
}

extension FigureElem: Refable {
    /// Port of `Refable for Packed<FigureElem>`.
    public func refSupplement() -> Content {
        // After synthesis, this should always be custom content.
        guard case let .custom(.some(s)) = supplement,
              case let .content(c) = s else {
            return .empty
        }
        return c
    }

    public func refCounter() -> Counter {
        counter ?? Counter.of(Element(FigureElem.self))
    }

    public func refNumbering() -> Numbering? { numbering }
}

extension FigureElem: Outlinable {
    public func isOutlined() -> Bool {
        outlined && (caption != nil || numbering != nil)
    }

    public func outlinePrefix(_ numbers: Content) -> Content {
        let supp = refSupplement()
        if !supp.isEmpty {
            return supp + TextElem.packed("\u{a0}") + numbers
        }
        return numbers
    }

    public func outlineBody() -> Content {
        caption?.body ?? .empty
    }
}

extension FigureElem: LocalName {
    public static let localNameKey = "figure"
}
