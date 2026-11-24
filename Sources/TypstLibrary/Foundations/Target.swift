import Foundation
import TypstSyntax
import TypstUtils

// Port of `foundations/target.rs` — the `Target` cast enum, the internal
// `TargetElem` style host, and the contextual `target()` function.

/// The compilation target.
///
/// Port of `Target` in `target.rs` — a plain `#[derive(Cast)]` enum that
/// casts to/from strings, not a `#[ty]` dynamic type.
public enum Target: String, Sendable, Hashable {
    /// Paged, fully laid-out content (PDF/PNG/SVG export).
    case paged
    /// HTML export.
    case html
    /// Bundle export (multiple documents and assets).
    case bundle

    /// Whether this is the HTML target.
    public var isHtml: Bool { self == .html }
}

extension Target: Repr {
    public func repr() -> String { rawValue }
}

extension Target: Castable {
    public static var input: CastInfo { Str.input }
    public static var output: CastInfo { Str.output }

    public static func castable(_ value: Value) -> Bool {
        if case .str(let s) = value { return Target(rawValue: s.value) != nil }
        return false
    }
}

extension Target: IntoValue {
    public func intoValue() -> Value { .str(Str(rawValue)) }
}

extension Target: FromValue {
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case .str(let s) = value else {
            return .failure(Str.input.error(value))
        }
        guard let target = Target(rawValue: s.value) else {
            return .failure(HintedString(
                "expected \"paged\", \"html\", or \"bundle\", found \(s.repr())"))
        }
        return .success(target)
    }
}

extension Target: CustomDebugStringConvertible {
    public var debugDescription: String { repr() }
}

/// This element exists solely to host the `target` style chain field.
/// It is never constructed and not visible to users.
///
/// Port of `TargetElem` in `target.rs`.
public struct TargetElem: NativeElement {
    public static let info = ElementInfo(
        name: "target",
        fields: [
            FieldInfo(id: 0, name: "target"),
        ]
    )

    /// The compilation target.
    public var target: Target

    public var span: Span = .detached

    public init(target: Target = .paged) { self.target = target }

    public func field(_ id: UInt8) -> Value? {
        id == 0 ? target.intoValue() : nil
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        guard id == 0, case .str = value else { return }
        target = try unwrap(Target.fromValue(value))
    }
}

/// Returns the current export target.
///
/// Port of `target` in `target.rs` — contextual because the target can
/// vary within a single compilation (e.g. `paged` inside `html.frame`).
let targetFunc = nativeFunc(
    "target",
    title: "Target",
    since: .version([0, 13, 0]),
    docs: """
        Returns the current export target.

        This function returns
        - `{"paged"}` in @pdf[PDF], @format.png[PNG], and
          @format.svg[SVG] export, or within an @html.frame[HTML frame]
        - `{"html"}` in @html[HTML] export
        - `{"bundle"}` in @format.bundle[Bundle] export
        """,
    contextual: true,
    params: [],
    returns: Str.output
) { _, context, args in
    try args.finishT()
    let chain = try unwrap(context.requireStyles())
    let value = chain.get(Element(TargetElem.self), 0)
    if let value {
        return try unwrap(Target.fromValue(value))
    }
    return Target.paged
}
