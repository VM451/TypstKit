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
    public var introspector: Introspector

    /// Trace points collected during evaluation.
    public var traced: Traced

    /// Diagnostic sink.
    public var sink: Sink

    /// The current route (call stack for recursion detection).
    public var route: Route

    /// The standard library (convenience accessor over `world.library`).
    public var library: Library { world.library.value }

    public init(world: World) {
        self.world = world
        self.introspector = Introspector()
        self.traced = Traced()
        self.sink = Sink()
        self.route = Route()
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

/// The standard library: global scope plus module definitions.
///
/// Port of `Library` in `engine.rs`/`lib.rs`.
public struct Library: Sendable, Hashable {
    /// The global scope (all top-level definitions).
    public var scope: Scope

    /// The feature guard for version-gated features.
    public var features: FeatureGuard

    /// Host-installed evaluation/realization/layout routines.
    public var routines: Routines

    public init(scope: Scope, features: FeatureGuard = FeatureGuard(),
                routines: Routines = Routines()) {
        self.scope = scope
        self.features = features
        self.routines = routines
    }
}

extension Library {
    public static func == (lhs: Library, rhs: Library) -> Bool {
        lhs.scope === rhs.scope && lhs.features == rhs.features
            && lhs.routines === rhs.routines
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(scope))
        hasher.combine(features)
        hasher.combine(ObjectIdentifier(routines))
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

    public init(
        evalClosure: (@Sendable (Func, Closure, inout Engine, Context, Args) -> SourceResult<Value>)? = nil
    ) {
        self.evalClosure = evalClosure
    }
}

/// Trace collector for `trace` points.
public final class Traced: @unchecked Sendable {
    public private(set) var points: [EvalTracepoint] = []
    public func push(_ point: EvalTracepoint) { points.append(point) }
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
    public func warn(_ diagnostic: SourceDiagnostic) { diagnostics.append(diagnostic) }
    public func error(_ diagnostic: SourceDiagnostic) { diagnostics.append(diagnostic) }
}

/// The call route for recursion detection.
public struct Route: Sendable {
    public private(set) var calls: [CallInfo] = []
    public var isEmpty: Bool { calls.isEmpty }
    public mutating func push(_ info: CallInfo) { calls.append(info) }
    public mutating func pop() { _ = calls.popLast() }
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
public struct FontWeight: Sendable, Hashable, Comparable {
    public var value: Int
    public init(_ value: Int) { self.value = value }
    public static let thin = FontWeight(100)
    public static let regular = FontWeight(400)
    public static let bold = FontWeight(700)
    public static func < (a: FontWeight, b: FontWeight) -> Bool { a.value < b.value }
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

/// Feature gate controlling version-gated stdlib features.
public struct FeatureGuard: Sendable, Hashable {
    public private(set) var enabled: Set<String> = []
    public init() {}
    public init(enabled: Set<String>) { self.enabled = enabled }
    public mutating func enable(_ feature: String) { enabled.insert(feature) }
    public func isEnabled(_ feature: String) -> Bool { enabled.contains(feature) }
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
