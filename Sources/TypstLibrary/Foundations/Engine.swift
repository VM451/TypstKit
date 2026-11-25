import Foundation
import TypstSyntax
import TypstUtils

/// The evaluation engine context.
///
/// Port of `Engine` in `engine.rs`. Upstream uses comemo `Tracked`/
/// `TrackedMut` for incremental dependency tracking; this port keeps the
/// same field layout with Swift-native shared references. Full tracked
/// access lands with the eval phase.
public struct Engine {
    /// The world providing files, fonts, and packages.
    public var world: World

    /// Introspection state (mutable across layout passes).
    public var introspector: any Introspector

    /// Trace points collected during evaluation.
    public var traced: Traced

    /// Diagnostic sink.
    public var sink: Sink

    /// The current route (call stack for recursion detection).
    public var route: Route

    /// Optional hook resolving measurement-mode locators against the
    /// introspector. Populated by the introspection milestone; `nil` falls
    /// back to the base location.
    public var measureLocation: ((Hash128, Location, Span) -> Location?)?

    /// The standard library (convenience accessor over `world.library`).
    public var library: Library { world.library.value }

    public init(world: World) {
        self.world = world
        self.introspector = EmptyIntrospector()
        self.traced = Traced()
        self.sink = Sink()
        self.route = Route()
        self.measureLocation = nil
    }

    /// Handles a result without immediately terminating execution. Instead, it
    /// produces a delayed error that is only promoted to a fatal one if it
    /// remains by the end of the introspection loop.
    ///
    /// Port of `Engine::delay`.
    public mutating func delay<T: DefaultConstructible>(_ result: SourceResult<T>) -> T {
        switch result {
        case let .success(value): return value
        case let .failure(errors):
            sink.delayedErrors(errors.diagnostics)
            return T.defaultValue
        }
    }
}

/// The world: everything outside the compiler that provides input.
///
/// Port of the `World` trait in `engine.rs`.
public protocol World: Sendable {
    /// The standard library.
    var library: LazyHash<Library> { get }

    /// The book of all known fonts.
    var book: LazyHash<FontBook> { get }

    /// The main source file.
    var main: FileId { get }

    /// Get a source file by id.
    func source(_ id: FileId) -> FileResult<Source>

    /// Get a file's bytes by id.
    func file(_ id: FileId) -> FileResult<Bytes>

    /// Get a font by index.
    func font(_ index: Int) -> Font?

    /// Today's date at the given UTC offset, if determinable.
    ///
    /// The offset is a `Duration` (`nil` = auto: local time for the system
    /// clock, UTC for fixed times). See `WorldTime::today`.
    func today(_ offset: Duration?) -> Datetime?
}

/// An export format registered with the library.
///
/// Port of the `Format` trait in `format.rs` — only the surface needed by
/// realization (`elem`) is required so far.
public protocol Format: Sendable {
    /// The format's element.
    var elem: Element { get }
}

/// The standard library: global scope plus module definitions.
///
/// Port of `Library` in `engine.rs`/`lib.rs`.
public struct Library: Sendable, Hashable {
    /// The global scope (all top-level definitions).
    public var scope: Scope

    /// The feature guard for version-gated features.
    public var features: Features

    /// Host-installed evaluation/realization/layout routines.
    public var routines: Routines

    /// Inputs visible through `sys.inputs` (upstream
    /// `LibraryBuilder::with_inputs`).
    public var inputs: Dict

    /// The built-in show rules.
    /// Port of upstream `Library::rules`.
    public var rules: NativeRuleMap

    /// Registered export formats.
    /// Port of upstream `Library::formats`.
    public var formats: [any Format]

    public init(scope: Scope, features: Features = Features(),
                routines: Routines = Routines(), inputs: Dict = Dict(),
                rules: NativeRuleMap = NativeRuleMap(),
                formats: [any Format] = []) {
        self.scope = scope
        self.features = features
        self.routines = routines
        self.inputs = inputs
        self.rules = rules
        self.formats = formats
    }

    /// Configure the inputs visible through `sys.inputs`.
    /// Port of `LibraryBuilder::with_inputs`.
    public func withInputs(_ inputs: Dict) -> Library {
        var copy = self
        copy.inputs = inputs
        return copy
    }
}

extension Library {
    public static func == (lhs: Library, rhs: Library) -> Bool {
        lhs.scope === rhs.scope && lhs.features == rhs.features
            && lhs.routines === rhs.routines && lhs.rules === rhs.rules
            && lhs.formats.map(\.elem) == rhs.formats.map(\.elem)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(scope))
        hasher.combine(features)
        hasher.combine(ObjectIdentifier(routines))
        hasher.combine(ObjectIdentifier(rules))
        hasher.combine(formats.map(\.elem))
    }
}

/// Host-installed routines the library calls back into.
///
/// Port of `Routines` in `routines.rs`. Upstream fills these with `fn`
/// pointers from the `typst` facade crate; the Swift port uses closures.
/// Fields for phases not yet ported are added as those phases land.
public final class Routines: @unchecked Sendable {
    /// Call the closure in the context with the arguments.
    /// Port of `routines::eval_closure`.
    public var evalClosure:
        (@Sendable (Func, Closure, inout Engine, Context, Args) -> SourceResult<Value>)?

    /// Realizes content into a flat list of well-known, styled items.
    /// Port of `routines::realize`.
    public var realize:
        (@Sendable (RealizationKind, inout Engine, SplitLocator, Content, StyleChain)
            -> SourceResult<[RealizePair]>)?

    public init(
        evalClosure: (@Sendable (Func, Closure, inout Engine, Context, Args) -> SourceResult<Value>)? = evalClosureImpl,
        realize: (@Sendable (RealizationKind, inout Engine, SplitLocator, Content, StyleChain)
            -> SourceResult<[RealizePair]>)? = { kind, engine, locator, content, styles in
            TypstLibrary.realize(
                kind: kind, engine: &engine, locator: locator,
                content: content, styles: styles)
        }
    ) {
        self.evalClosure = evalClosure
        self.realize = realize
    }
}

/// Trace collector for `trace` points.
public final class Traced: @unchecked Sendable {
    public private(set) var points: [EvalTracepoint] = []
    /// Spans under inspection per file (upstream `Traced::inspect` map).
    public private(set) var inspected: [FileId: Span] = [:]
    public func push(_ point: EvalTracepoint) { points.append(point) }

    /// The span under inspection in the given file, if any.
    /// Port of upstream `Traced::get`.
    public func get(_ id: FileId) -> Span? { inspected[id] }

    /// Mark a span as inspected.
    /// Port of upstream `Traced::inspect`.
    public func inspect(_ span: Span) {
        if let id = span.id { inspected[id] = span }
    }
}

/// A trace point emitted during evaluation.
public struct EvalTracepoint: Sendable, Hashable {
    public var span: Span
    public var value: Value
    public init(span: Span, value: Value) {
        self.span = span; self.value = value
    }
}

/// Diagnostic sink collecting warnings/errors during evaluation.
public final class Sink: @unchecked Sendable {
    public private(set) var diagnostics: [SourceDiagnostic] = []
    /// Errors that are only promoted to fatal ones if they remain by the end
    /// of the introspection loop (upstream `Sink::delayed`).
    public private(set) var delayed: [SourceDiagnostic] = []
    public func warn(_ diagnostic: SourceDiagnostic) { diagnostics.append(diagnostic) }
    public func error(_ diagnostic: SourceDiagnostic) { diagnostics.append(diagnostic) }

    /// Add delayed errors.
    /// Port of upstream `Sink::delayed_errors`.
    public func delayedErrors(_ errors: [SourceDiagnostic]) {
        delayed.append(contentsOf: errors)
    }

    /// Take the stored delayed errors.
    /// Port of upstream `Sink::delayed`.
    @discardableResult
    public func takeDelayed() -> [SourceDiagnostic] {
        defer { delayed.removeAll() }
        return delayed
    }
}

/// The call route for recursion detection.
public struct Route: Sendable {
    /// The parent route segment's length contribution.
    /// Port of upstream `Route::len` — incremented by `extend`.
    public private(set) var len: Int = 0
    public private(set) var calls: [CallInfo] = []
    /// File ids in the route chain (upstream's linked `id`/`outer` chain,
    /// flattened for cyclic import/eval detection).
    public private(set) var ids: [FileId] = []
    public var isEmpty: Bool { calls.isEmpty }

    /// Whether the given file id is part of the route.
    /// Port of upstream `Route::contains`.
    public func contains(_ id: FileId) -> Bool { ids.contains(id) }

    /// Attach a file id to the route segment.
    /// Port of upstream `Route::with_id`.
    public func withId(_ id: FileId) -> Route {
        var copy = self
        copy.ids.append(id)
        return copy
    }
    public mutating func push(_ info: CallInfo) { calls.append(info) }
    public mutating func pop() { _ = calls.popLast() }

    /// Extend the route with a new segment of length 1.
    /// Port of `Route::extend`.
    public func extend() -> Route {
        var copy = self
        copy.len += 1
        return copy
    }

    /// Increase the nesting depth for this route segment.
    /// Port of `Route::increase`.
    public mutating func increase() { len += 1 }

    /// Decrease the nesting depth for this route segment.
    /// Port of `Route::decrease`.
    public mutating func decrease() { len -= 1 }

    /// Whether the route's depth is within `depth`.
    /// Port of `Route::within`.
    public func within(_ depth: Int) -> Bool { len <= depth }

    /// Maximum function call nesting depth.
    public static let maxCallDepth = 80
    /// Maximum show rule depth.
    public static let maxShowRuleDepth = 64
    /// Maximum layout depth.
    public static let maxLayoutDepth = 72
    /// Maximum HTML nesting depth.
    public static let maxHTMLDepth = 72

    /// Ensures that we are within the maximum function call depth.
    /// Port of `Route::check_call_depth`.
    public func checkCallDepth() -> StrResult<()> {
        within(Route.maxCallDepth)
            ? .success(())
            : .failure(StrError("maximum function call depth exceeded"))
    }

    /// Ensures that we are within the maximum show rule depth.
    public func checkShowDepth() -> HintedStrResult<()> {
        within(Route.maxShowRuleDepth) ? .success(()) : .failure(HintedString(
            message: "maximum show rule depth exceeded",
            hints: ["maybe a show rule matches its own output",
                    "maybe there are too deeply nested elements"]))
    }

    /// Ensures that we are within the maximum layout depth.
    public func checkLayoutDepth() -> HintedStrResult<()> {
        within(Route.maxLayoutDepth) ? .success(()) : .failure(HintedString(
            message: "maximum layout depth exceeded",
            hints: ["try to reduce the amount of nesting in your layout"]))
    }

    /// Ensures that we are within the maximum HTML depth.
    public func checkHTMLDepth() -> HintedStrResult<()> {
        within(Route.maxHTMLDepth) ? .success(()) : .failure(HintedString(
            message: "maximum HTML depth exceeded",
            hints: ["try to reduce the amount of nesting of your HTML"]))
    }
}

/// A call in the route stack.
public struct CallInfo: Sendable, Hashable {
    public var funcName: String?
    public var span: Span
    public init(funcName: String?, span: Span) {
        self.funcName = funcName; self.span = span
    }
}

/// Font metadata book.
///
/// Port of `FontBook` — full font handling lands with the layout phase;
/// this holds the index of known fonts.
public struct FontBook: Sendable, Hashable {
    public private(set) var infos: [FontInfo] = []
    public init() {}
    public mutating func push(_ info: FontInfo) { infos.append(info) }
    public var count: Int { infos.count }
}

/// Metadata for a single font.
public struct FontInfo: Sendable, Hashable {
    public var index: Int
    public var family: Str
    public var variant: FontVariant
    public var flags: FontFlags
    public var coverage: FontCoverage

    public init(index: Int, family: Str, variant: FontVariant = .normal,
                flags: FontFlags = [], coverage: FontCoverage = .`default`) {
        self.index = index; self.family = family
        self.variant = variant; self.flags = flags; self.coverage = coverage
    }
}

/// Font style variant (weight + stretch + style).
public struct FontVariant: Sendable, Hashable {
    public var style: FontStyle
    public var weight: FontWeight
    public var stretch: FontStretch

    public init(style: FontStyle = .normal, weight: FontWeight = .regular,
                stretch: FontStretch = .normal) {
        self.style = style; self.weight = weight; self.stretch = stretch
    }

    public static let normal = FontVariant()
}

public enum FontStyle: String, Sendable, Hashable, CaseIterable {
    case normal, italic, oblique
}

/// Font weight 100-900.
///
/// Port of `FontWeight` in `text/font/variant.rs`.
public struct FontWeight: Sendable, Hashable, Comparable {
    /// The weight value between 100 and 900 (upstream tuple field `.0`).
    public var value: Int
    public init(_ value: Int) { self.value = value }

    /// Thin weight (100).
    public static let thin = FontWeight(100)
    /// Extra light weight (200).
    public static let extralight = FontWeight(200)
    /// Light weight (300).
    public static let light = FontWeight(300)
    /// Regular weight (400).
    public static let regular = FontWeight(400)
    /// Medium weight (500).
    public static let medium = FontWeight(500)
    /// Semibold weight (600).
    public static let semibold = FontWeight(600)
    /// Bold weight (700).
    public static let bold = FontWeight(700)
    /// Extrabold weight (800).
    public static let extrabold = FontWeight(800)
    /// Black weight (900).
    public static let black = FontWeight(900)

    /// Create from a number, clamping to 100...900 (upstream `from_number`).
    public static func fromNumber(_ weight: Int) -> FontWeight {
        FontWeight(Swift.max(100, Swift.min(900, weight)))
    }

    /// The number between 100 and 900.
    public var number: Int { value }

    /// Add (or remove) weight, saturating at 100 and 900 (upstream `thicken`).
    public func thicken(_ delta: Int) -> FontWeight {
        FontWeight.fromNumber(value + delta)
    }

    /// The absolute number distance to another weight (upstream `distance`).
    public func distance(_ other: FontWeight) -> Int {
        abs(value - other.value)
    }

    public static func < (a: FontWeight, b: FontWeight) -> Bool { a.value < b.value }
}

extension FontWeight: Default {
    public static var `default`: FontWeight { .regular }
}

/// Font stretch percentage.
public struct FontStretch: Sendable, Hashable, Comparable {
    public var value: Double
    public init(_ value: Double) { self.value = value }
    public static let ultraCondensed = FontStretch(50)
    public static let normal = FontStretch(100)
    public static func < (a: FontStretch, b: FontStretch) -> Bool { a.value < b.value }
}

/// Font feature flags.
public struct FontFlags: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let monospace = FontFlags(rawValue: 1 << 0)
    public static let serif = FontFlags(rawValue: 1 << 1)
    public static let symbol = FontFlags(rawValue: 1 << 2)
    public static let emoji = FontFlags(rawValue: 1 << 3)
}

/// Per-script font coverage info.
public struct FontCoverage: Sendable, Hashable {
    public var `default`: Bool
    public init(isDefault: Bool = true) { `default` = isDefault }
    public static let `default` = FontCoverage()
}

/// A loaded font.
///
/// Font parsing/shaping lands with the layout phase; this wraps raw font
/// data plus its index in the book.
public struct Font: Sendable {
    public var index: Int
    public var data: Bytes
    public init(index: Int, data: Bytes) {
        self.index = index; self.data = data
    }
}

/// File access result.
public typealias FileResult<T> = Result<T, FileError>

/// File system error.
public struct FileError: Error, Sendable, Hashable, CustomStringConvertible {
    public enum Kind: Sendable, Hashable {
        case notFound, accessDenied, isDirectory, other
    }
    public var kind: Kind
    public var message: String
    public init(_ message: String, kind: Kind = .other) {
        self.message = message; self.kind = kind
    }
    public var description: String { message }
}


/// `Scope` hashes by identity: upstream relies on `LazyHash` over an
/// effectively immutable library scope, and a stable per-instance hash
/// preserves that contract without hashing mutable binding state.
extension Scope: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
    public static func == (lhs: Scope, rhs: Scope) -> Bool { lhs === rhs }
}
