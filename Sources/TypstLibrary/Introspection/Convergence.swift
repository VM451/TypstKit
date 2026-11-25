import Foundation
import TypstSyntax
import TypstUtils

/// The maximum number of layout iterations for introspection convergence.
/// Port of `MAX_ITERS` in `introspection/convergence.rs`.
public let maxIters = 5

/// Display names for each iteration.
public let iterNames = [
    "iter (1)", "iter (2)", "iter (3)", "iter (4)", "iter (5)",
]

/// Number of stored introspector instances (`MAX_ITERS + 1`).
public let introspectionInstances = maxIters + 1

/// An introspection whose output should stabilize across layout iterations.
///
/// Port of the `Introspect` trait in `introspection/convergence.rs`.
/// Upstream runs under comemo tracking; the Swift port passes the
/// introspector existential directly (incremental memoization lands with
/// the compile driver).
public protocol Introspect: Hashable & Sendable {
    /// The kind of output the introspection produces.
    associatedtype Output: Hashable & Sendable

    /// Resolves the output value against the introspector.
    func introspect(
        _ engine: inout Engine, _ introspector: any Introspector
    ) -> Output

    /// Produces a diagnostic for non-convergence.
    func diagnose(_ history: History<Output>) -> SourceDiagnostic
}

extension Introspect {
    /// Computes the history across all introspector instances and returns
    /// the convergence diagnostic, if any. Port of `Bounds::diagnose`.
    func diagnoseWorld(
        world: World, introspectors: [any Introspector]
    ) -> SourceDiagnostic? {
        let history = History<Output>.compute(
            world: world, introspectors: introspectors
        ) { engine, introspector in
            introspect(&engine, introspector)
        }
        return history.converged() ? nil : diagnose(history)
    }
}

/// A type-erased introspection recorded in the sink.
///
/// Port of `Introspection` (the `Arc<dyn Bounds>` wrapper). Equality and
/// hashing use the concrete value's `hash128`, matching upstream's
/// `TypeId + Hash` combination closely enough for dedup purposes.
public struct Introspection: Sendable, Hashable {
    /// Hash of the concrete introspection value (upstream `dyn_hash`).
    public let hash: Hash128

    /// The convergence diagnostic producer.
    let diagnoseImpl: @Sendable (
        World, [any Introspector]
    ) -> SourceDiagnostic?

    /// Type-erase a strongly-typed introspection.
    public init<I: Introspect>(_ inner: I) {
        hash = hash128(inner)
        diagnoseImpl = { world, introspectors in
            inner.diagnoseWorld(world: world, introspectors: introspectors)
        }
    }

    /// Produces a diagnostic for non-convergence.
    /// Port of `Bounds::diagnose` via `Introspect::diagnoseWorld`.
    public func diagnose(
        world: World, introspectors: [any Introspector]
    ) -> SourceDiagnostic? {
        diagnoseImpl(world, introspectors)
    }

    public static func == (a: Introspection, b: Introspection) -> Bool {
        a.hash == b.hash
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(hash)
    }
}

/// The recorded outputs of an introspection across all layout iterations.
///
/// Port of `History<'a, T>`.
public struct History<T: Hashable & Sendable>: Sendable {
    /// `(introspector, value)` pairs, one per iteration instance.
    public var entries: [(any Introspector, T)]

    public init(entries: [(any Introspector, T)]) {
        self.entries = entries
    }

    /// Computes the value for each introspector with an ad-hoc engine.
    /// Port of `History::compute`.
    public static func compute(
        world: World,
        introspectors: [any Introspector],
        _ f: (inout Engine, any Introspector) -> T
    ) -> History<T> {
        History(entries: introspectors.map { introspector in
            var engine = Engine(world: world)
            engine.introspector = introspector
            return (introspector, f(&engine, introspector))
        })
    }

    /// Whether the final and pre-final values hash the same.
    public func converged() -> Bool {
        hash128(entries[entries.count - 2].1)
            == hash128(entries[entries.count - 1].1)
    }

    /// Transforms the contained values.
    public func map<U: Hashable & Sendable>(_ f: (T) -> U) -> History<U> {
        History<U>(entries: entries.map { ($0.0, f($0.1)) })
    }

    /// Accesses the final iteration's introspector.
    public var finalIntrospector: any Introspector {
        entries[entries.count - 1].0
    }

    /// Produces a hint listing the observed values per iteration.
    public func hint(_ what: String, _ f: (T) -> String) -> String {
        var hint = "the following \(what) were observed:"
        for (i, entry) in entries.enumerated() {
            let attempt: String
            switch i {
            case 0..<maxIters: attempt = "run \(i + 1)"
            case maxIters: attempt = "final"
            default: attempt = "run \(i + 1)"
            }
            hint += "\n- \(attempt): \(f(entry.1))"
        }
        return hint
    }
}

/// Analyzes recorded introspections for convergence warnings.
///
/// Port of `analyze` in `introspection/convergence.rs`. Returns the
/// diagnostics that should be emitted (summary first when non-empty).
public func analyze(
    world: World,
    introspectors: [any Introspector],
    introspections: [Introspection]
) -> [SourceDiagnostic] {
    let sink = Sink()
    for introspection in introspections {
        if let warning = introspection.diagnose(
            world: world, introspectors: introspectors
        ) {
            sink.warn(warning)
        }
    }

    var diags = sink.diagnostics.filter { $0.severity == .warning }
    if !diags.isEmpty {
        var summary = SourceDiagnostic.warning(
            Span.detached,
            "document did not converge within five attempts")
        summary.hint("see \(diags.count) additional warning\(diags.count > 1 ? "s" : "") for more details")
        summary.hint("see https://typst.app/help/convergence for help")
        diags.insert(summary, at: 0)
    }
    return diags
}
