import Foundation
import TypstSyntax
import TypstUtils

/// Introspection for `query` — resolves all elements matching a selector.
///
/// Port of `QueryIntrospection` in `introspection/query.rs`.
public struct QueryIntrospection: Introspect, Hashable {
    public var selector: Selector
    public var span: Span

    public init(selector: Selector, span: Span) {
        self.selector = selector
        self.span = span
    }

    public typealias Output = [Content]

    public func introspect(
        _ engine: inout Engine, _ introspector: any Introspector
    ) -> [Content] {
        introspector.query(selector)
    }

    public func diagnose(_ history: History<[Content]>) -> SourceDiagnostic {
        let lengths = history.map { $0.count }
        let things = formatSelector(selector, kind: "elements")
        let what = lengths.converged()
            ? "query for \(things)" : "number of \(things)"
        return formatConvergenceWarning(span, lengths, what)
    }
}

/// Introspection for `query(..).first()` style lookups.
///
/// Port of `QueryFirstIntrospection`.
public struct QueryFirstIntrospection: Introspect, Hashable {
    public var selector: Selector
    public var span: Span

    public init(selector: Selector, span: Span) {
        self.selector = selector
        self.span = span
    }

    public typealias Output = Content?

    public func introspect(
        _ engine: inout Engine, _ introspector: any Introspector
    ) -> Content? {
        introspector.queryFirst(selector)
    }

    public func diagnose(_ history: History<Content?>) -> SourceDiagnostic {
        let lengths = history.map { $0 != nil ? 1 : 0 }
        let thing = formatSelector(selector, kind: "element")
        return formatConvergenceWarning(
            span, lengths, "query for the first \(thing)")
    }
}

/// Introspection for unique-match queries (`locate`, `query_unique`).
///
/// Port of `QueryUniqueIntrospection`.
public struct QueryUniqueIntrospection: Introspect, Hashable {
    public var selector: Selector
    public var span: Span

    public init(selector: Selector, span: Span) {
        self.selector = selector
        self.span = span
    }

    public typealias Output = StrResult<Content>

    public func introspect(
        _ engine: inout Engine, _ introspector: any Introspector
    ) -> StrResult<Content> {
        introspector.queryUnique(selector)
    }

    public func diagnose(_ history: History<StrResult<Content>>) -> SourceDiagnostic {
        let lengths = history.map { (try? $0.get()) != nil ? 1 : 0 }
        let thing = formatSelector(selector, kind: "element")
        return formatConvergenceWarning(
            span, lengths, "query for a unique \(thing)")
    }
}

/// Introspection for label lookups.
///
/// Port of `QueryLabelIntrospection`.
public struct QueryLabelIntrospection: Introspect, Hashable {
    public var label: Label
    public var span: Span

    public init(label: Label, span: Span) {
        self.label = label
        self.span = span
    }

    public typealias Output = StrResult<Content>

    public func introspect(
        _ engine: inout Engine, _ introspector: any Introspector
    ) -> StrResult<Content> {
        introspector.queryLabel(label)
    }

    public func diagnose(_ history: History<StrResult<Content>>) -> SourceDiagnostic {
        QueryUniqueIntrospection(
            selector: .label(label), span: span
        ).diagnose(history)
    }
}

/// The convergence warning for a `Location`-based introspection.
///
/// Port of `format_convergence_warning` in `introspection/query.rs`.
func formatConvergenceWarning(
    _ span: Span, _ lengths: History<Int>, _ what: String
) -> SourceDiagnostic {
    var diag = SourceDiagnostic.warning(span, "\(what) did not stabilize")
    if !lengths.converged() {
        diag.hint(lengths.hint("numbers of elements") { "\($0)" })
    }
    return diag
}

/// Formats a selector human-readably.
///
/// Port of `format_selector` in `introspection/query.rs`.
func formatSelector(_ selector: Selector, kind: String) -> String {
    switch selector {
    case let .elem(elem, nil):
        return "\(elem.name) \(kind)"
    case let .elem(elem, _):
        return "matching \(elem.name) \(kind)"
    case let .label(label):
        return "\(kind) labelled \(label.repr())"
    default:
        return "\(kind) matching \(selector.repr())"
    }
}

extension LocatableSelector {
    /// Resolve this selector into a unique location.
    ///
    /// Port of `LocatableSelector::resolve_unique` in
    /// `foundations/selector.rs`.
    public func resolveUnique(
        engine: inout Engine, context: Context, span: Span
    ) throws -> Location {
        if case let .location(loc) = selector { return loc }
        _ = try context.introspect().get()
        let result = engine.introspect(
            QueryUniqueIntrospection(selector: selector, span: span))
        let content = try result.get()
        guard let location = content.location else {
            throw HintedString("element does not have a location")
        }
        return location
    }
}

/// `query` — finds elements in the document.
///
/// Port of `query` in `introspection/query.rs`.
let queryFunc = nativeFunc(
    "query",
    title: "Query",
    since: .version([0, 1, 0]),
    docs: """
        Finds elements in the document. The `query` function lets you search \
        your document for elements of a particular type or with a particular \
        label. To use it, you first need to ensure that context is available.
        """,
    contextual: true,
    params: [
        NativeParamInfo(
            name: "target",
            docs: """
                Can be an element function like a `heading` or `figure`, a \
                `{<label>}`, a more complex selector like \
                `{heading.where(level: 1)}`, or \
                `{selector(heading).before(here())}`. Only locatable \
                element functions are supported.
                """,
            input: LocatableSelector.input,
            defaultValue: nil,
            positional: true),
    ],
    returns: .type(Type.of(ArrayValue.self))
) { engine, context, args in
    _ = try context.introspect().get()
    let target: LocatableSelector = try args.expectT("target")
    let vec = engine.introspect(QueryIntrospection(
        selector: target.selector, span: args.span))
    return ArrayValue(items: vec.map { $0.intoValue() })
}

/// `locate` — determines the location of an element.
///
/// Port of `locate` in `introspection/locate.rs`.
let locateFunc = nativeFunc(
    "locate",
    title: "Locate",
    since: .version([0, 1, 0]),
    docs: """
        Determines the location of an element in the document. Takes a \
        selector that must match exactly one element and returns that \
        element's location.
        """,
    contextual: true,
    params: [
        NativeParamInfo(
            name: "selector",
            docs: """
                A selector that should match exactly one element. This \
                element will be located.
                """,
            input: LocatableSelector.input,
            defaultValue: nil,
            positional: true),
    ],
    returns: .type(Type.of(Location.self))
) { engine, context, args in
    let selector: LocatableSelector = try args.expectT("selector")
    return try selector.resolveUnique(
        engine: &engine, context: context, span: args.span)
}

/// `here` — provides the current location in the document.
///
/// Port of `here` in `introspection/here.rs`.
let hereFunc = nativeFunc(
    "here",
    title: "Here",
    since: .version([0, 8, 0]),
    docs: """
        Provides the current location in the document. You can think of \
        `here` as a low-level building block that directly extracts the \
        current location from the active context.
        """,
    contextual: true,
    params: [],
    returns: .type(Type.of(Location.self))
) { engine, context, args in
    try context.requireLocation().get()
}

/// `metadata` — exposes a value to the query system.
///
/// Port of `MetadataElem` in `introspection/metadata.rs`.
public struct MetadataElem: NativeElement {
    public static let info = ElementInfo(
        name: "metadata",
        title: "Metadata",
        fields: [
            FieldInfo(id: 0, name: "value", required: true),
        ],
        capabilities: [.locatable]
    )

    /// The value to embed into the document.
    public var value: Value = .none

    public var span: Span = .detached

    public func field(_ id: UInt8) -> Value? {
        id == 0 ? value : nil
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        if id == 0 { self.value = value }
    }
}

extension MetadataElem {
    public static func construct(engine: inout Engine, args: inout Args) throws -> Content {
        var elem = MetadataElem()
        elem.value = try args.expectT("value")
        elem.span = args.span
        try args.finishT()
        return Content(elem)
    }
}

/// Port of upstream `introspection/mod.rs` global registration.
func defineIntrospection(into global: Scope) {
    global.defineType(Location.self)
    global.defineType(State.self)
    global.defineFunc(queryFunc)
    global.defineFunc(locateFunc)
    global.defineFunc(hereFunc)
    let element = Element(MetadataElem.self)
    global.define(element.name, .function(element.function))
}
