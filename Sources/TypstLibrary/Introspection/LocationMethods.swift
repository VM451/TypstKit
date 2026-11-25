import Foundation
import TypstSyntax
import TypstUtils

// MARK: - Location methods (port of `#[func]` methods in location.rs)

/// `location.page()` — port of `Location::page`.
let locationPage = nativeFunc(
    "page",
    title: "Page",
    since: .version([0, 1, 0]),
    docs: """
        Returns the page number for this location. The page number starts \
        at one.
        """,
    params: [
        NativeParamInfo(name: "self", input: Location.input, required: true),
    ],
    returns: Int64.output
) { engine, _, args in
    let location: Location = try args.expectT("self")
    try args.finishT()
    return Int64(engine.introspect(PageIntrospection(location: location, span: args.span)))
}

/// `location.position()` — port of `Location::position`.
let locationPosition = nativeFunc(
    "position",
    title: "Position",
    since: .version([0, 1, 0]),
    docs: """
        Returns a dictionary with the page number and the x, y position \
        for this location.
        """,
    params: [
        NativeParamInfo(name: "self", input: Location.input, required: true),
    ],
    returns: PagedPosition.output
) { engine, _, args in
    let location: Location = try args.expectT("self")
    try args.finishT()
    return engine.introspect(PositionIntrospection(location: location, span: args.span))
}

/// `location.page-numbering()` — port of `Location::page_numbering`.
let locationPageNumbering = nativeFunc(
    "page-numbering",
    title: "Page Numbering",
    since: .version([0, 2, 0]),
    docs: """
        Returns the page numbering pattern of the page at this location.
        """,
    params: [
        NativeParamInfo(name: "self", input: Location.input, required: true),
    ],
    returns: Numbering.output
) { engine, _, args in
    let location: Location = try args.expectT("self")
    try args.finishT()
    return engine.introspect(
        PageNumberingIntrospection(location: location, span: args.span))
}

/// The scope containing all `location` methods.
/// Port of upstream's `#[scope] impl Location`.
func locationScope() -> Scope {
    let scope = Scope()
    scope.defineFunc(locationPage)
    scope.defineFunc(locationPosition)
    scope.defineFunc(locationPageNumbering)
    return scope
}

// MARK: - Internal helpers used by counter/outline

extension Location {
    /// `Location::page_numbering` — the introspection behind both the
    /// `location.page-numbering()` method and counter numbering resolution.
    func pageNumbering(engine: inout Engine, span: Span) -> Numbering? {
        engine.introspect(PageNumberingIntrospection(location: self, span: span))
    }
}

// MARK: - Introspection structs (private upstream, ported as internal)

/// Retrieves the position for a location.
/// Port of `PositionIntrospection`.
struct PositionIntrospection: Introspect, Hashable {
    var location: Location
    var span: Span

    typealias Output = PagedPosition

    func introspect(
        _ engine: inout Engine, _ introspector: any Introspector
    ) -> Output {
        switch introspector.position(location) {
        case let .some(.paged(pos)): return pos
        // Maybe error here instead?
        case .some(.html), .none: return .origin
        }
    }

    func diagnose(_ history: History<Output>) -> SourceDiagnostic {
        locationConvergenceWarning(
            location, span: span, history: history,
            what: "positions",
            formatKind: { "\($0) position" },
            formatOutput: { pos in
                func coord(_ v: Abs) -> String {
                    displayFloat(v.toPt()) + "pt"
                }
                return "page \(pos.page.value) at (\(coord(pos.point.x)), \(coord(pos.point.y)))"
            })
    }
}

/// Retrieves the page number for a location.
/// Port of `PageIntrospection`.
struct PageIntrospection: Introspect, Hashable {
    var location: Location
    var span: Span

    typealias Output = Int

    func introspect(
        _ engine: inout Engine, _ introspector: any Introspector
    ) -> Output {
        // Maybe error here instead of calling `unwrap_or`?
        introspector.page(location) ?? 1
    }

    func diagnose(_ history: History<Output>) -> SourceDiagnostic {
        locationConvergenceWarning(
            location, span: span, history: history,
            what: "page numbers",
            formatKind: { "page number of the \($0)" },
            formatOutput: { "page \($0)" })
    }
}

/// Retrieves the page numbering for a location.
/// Port of `PageNumberingIntrospection`.
struct PageNumberingIntrospection: Introspect, Hashable {
    var location: Location
    var span: Span

    typealias Output = Numbering?

    func introspect(
        _ engine: inout Engine, _ introspector: any Introspector
    ) -> Output {
        introspector.pageNumbering(location)
    }

    func diagnose(_ history: History<Output>) -> SourceDiagnostic {
        locationConvergenceWarning(
            location, span: span, history: history,
            what: "numberings",
            formatKind: { "numbering of the page on which the \($0) is located" },
            formatOutput: { numbering in
                "`\((numbering?.intoValue() ?? .none).repr())`"
            })
    }
}

/// Retrieves the page supplement for a location.
/// Port of `PageSupplementIntrospection`.
struct PageSupplementIntrospection: Introspect, Hashable {
    var location: Location
    var span: Span

    typealias Output = Content

    func introspect(
        _ engine: inout Engine, _ introspector: any Introspector
    ) -> Output {
        // Maybe returns `None` here instead of empty content if no
        // supplement was specified?
        introspector.pageSupplement(location) ?? .empty
    }

    func diagnose(_ history: History<Output>) -> SourceDiagnostic {
        locationConvergenceWarning(
            location, span: span, history: history,
            what: "supplements",
            formatKind: { "supplement of the page on which the \($0) is located" },
            formatOutput: { "`\($0.repr())`" })
    }
}

/// Retrieves the file path for a location.
/// Port of `PathIntrospection`.
struct PathIntrospection: Introspect, Hashable {
    var location: Location
    var span: Span

    typealias Output = BundlePath?

    func introspect(
        _ engine: inout Engine, _ introspector: any Introspector
    ) -> Output {
        introspector.path(location).map { BundlePath(path: $0) }
    }

    func diagnose(_ history: History<Output>) -> SourceDiagnostic {
        locationConvergenceWarning(
            location, span: span, history: history,
            what: "path",
            formatKind: { "document in which the \($0) is located" },
            formatOutput: { _ in "TODO" })
    }
}

/// Retrieves the document location for a location.
/// Port of `DocumentIntrospection`.
struct DocumentIntrospection: Introspect, Hashable {
    var location: Location
    var span: Span

    typealias Output = Location?

    func introspect(
        _ engine: inout Engine, _ introspector: any Introspector
    ) -> Output {
        introspector.document(location)
    }

    func diagnose(_ history: History<Output>) -> SourceDiagnostic {
        locationConvergenceWarning(
            location, span: span, history: history,
            what: "documents",
            formatKind: { "document in which the \($0) is located" },
            formatOutput: { _ in "TODO" })
    }
}

// MARK: - Convergence warning

/// The warning when an introspection on a [`Location`] did not converge.
/// Port of `format_convergence_warning` in `introspection/location.rs`.
func locationConvergenceWarning<T: Hashable & Sendable>(
    _ loc: Location,
    span: Span,
    history: History<T>,
    what: String,
    formatKind: (String) -> String,
    formatOutput: (T) -> String
) -> SourceDiagnostic {
    let elem = history.finalIntrospector.queryFirst(
        .location(loc))
    let kind = elem?.name ?? "element"

    var diag = SourceDiagnostic.warning(
        span, "\(formatKind(kind)) did not stabilize")

    if let elem, !elem.span.isDetached {
        diag.hint("\(kind) was created here", at: elem.span.diag)
    }

    diag.hint(history.hint(what, formatOutput))
    return diag
}
