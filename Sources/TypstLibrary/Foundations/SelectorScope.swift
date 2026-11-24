import Foundation
import TypstSyntax
import TypstUtils

// The `selector` type's scope and casts — port of `foundations/selector.rs`.
// Like upstream, selectors are `#[ty]` values stored as `Value.dynamic`;
// the cast additionally accepts strings, element functions, labels,
// regexes, and locations.

extension Selector: CustomDebugStringConvertible {
    public var debugDescription: String { repr() }
}

/// Marker conformance: selectors are stored as `Value.dynamic`.
extension Selector: DynamicBounds {}

extension Selector: Castable, IntoValue, FromValue {
    public static var input: CastInfo {
        Str.input + Func.input + Label.input + Regex.input
            + .type(Type.of(Selector.self))
    }
    public static var output: CastInfo { .type(Type.of(Selector.self)) }

    public static func castable(_ value: Value) -> Bool {
        switch value {
        case .str, .function, .label:
            return true
        case let .dynamic(d):
            return d.is(Selector.self) || d.is(Regex.self) || d.is(Location.self)
        default:
            return false
        }
    }

    public func intoValue() -> Value { .dynamic(self) }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        switch value {
        case let .str(s):
            return Selector.text(s.value).mapError {
                HintedString($0.message)
            }
        case let .function(f):
            guard let element = f.element else {
                return .failure(HintedString(
                    "only element functions can be used as selectors"))
            }
            return .success(element.select())
        case let .label(label):
            return .success(.label(label))
        case let .dynamic(d):
            if let selector = d.downcast(Selector.self) {
                return .success(selector)
            }
            if let regex = d.downcast(Regex.self) {
                return Selector.regex(regex).mapError {
                    HintedString($0.message)
                }
            }
            if let location = d.downcast(Location.self) {
                return .success(.location(location))
            }
            return .failure(error(value))
        default:
            return .failure(error(value))
        }
    }
}

extension LocatableSelector: CustomDebugStringConvertible {
    public var debugDescription: String { selector.repr() }
}

extension LocatableSelector: Castable, IntoValue, FromValue {
    public static var input: CastInfo {
        Label.input + Func.input + .type(Type.of(Selector.self))
    }
    public static var output: CastInfo { .type(Type.of(Selector.self)) }

    public static func castable(_ value: Value) -> Bool {
        Label.castable(value) || Func.castable(value)
            || Selector.castable(value)
    }

    public func intoValue() -> Value { selector.intoValue() }

    /// Validate that the selector only contains locatable targets.
    /// Port of upstream's private `validate` in `LocatableSelector::from_value`.
    private static func validate(_ selector: Selector) -> StrResult<()> {
        switch selector {
        case let .elem(element, _):
            if !element.isLocatable || element.isUnqueriable {
                return .failure(StrError("\(element.name) is not locatable"))
            }
        case .location, .label:
            break
        case .regex:
            return .failure(StrError("text is not locatable"))
        case .can:
            return .failure(StrError("capability is not locatable"))
        case let .or(list), let .and(list):
            for s in list {
                if case .failure(let e) = validate(s) { return .failure(e) }
            }
        case let .before(selector, end, _), let .after(selector, start: end, _):
            if case .failure(let e) = validate(selector) { return .failure(e) }
            if case .failure(let e) = validate(end) { return .failure(e) }
        case let .within(selector, ancestor):
            if case .failure(let e) = validate(selector) { return .failure(e) }
            if case .failure(let e) = validate(ancestor) { return .failure(e) }
        }
        return .success(())
    }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard castable(value) else { return .failure(error(value)) }
        let selector: Selector
        switch Selector.fromValue(value) {
        case .success(let s): selector = s
        case .failure(let e): return .failure(e)
        }
        return validate(selector)
            .map { _ in LocatableSelector(selector) }
            .mapError { HintedString($0.message) }
    }
}

/// `selector(target)` — port of `Selector::construct`.
let selectorConstruct = nativeFunc(
    "selector",
    since: .version([0, 3, 0]),
    docs: """
        Turns a value into a selector. The following values are accepted:
        - An element function like a `heading` or `figure`.
        - A string or regular expression.
        - A label.
        - A location.
        - A more complex selector like `heading.where(level: 1)`.
        """,
    params: [
        NativeParamInfo(name: "target", input: Selector.input, required: true),
    ],
    returns: Selector.output
) { _, _, args in
    let target: Selector = try args.expectT("target")
    try args.finishT()
    return target
}

/// `selector.or(others...)` — port of `Selector::or`.
let selectorOr = nativeFunc(
    "or",
    since: .version([0, 3, 0]),
    docs: "Selects all elements that match this or any of the other selectors.",
    params: [
        NativeParamInfo(name: "self", input: Selector.input, required: true),
        NativeParamInfo(name: "others", input: Selector.input, variadic: true),
    ],
    returns: Selector.output
) { _, _, args in
    let selfValue: Selector = try args.expectT("self")
    let others: [Selector] = try args.allT()
    try args.finishT()
    return selfValue.or(others)
}

/// `selector.and(others...)` — port of `Selector::and`.
let selectorAnd = nativeFunc(
    "and",
    since: .version([0, 3, 0]),
    docs: "Selects all elements that match this and all of the other selectors.",
    params: [
        NativeParamInfo(name: "self", input: Selector.input, required: true),
        NativeParamInfo(name: "others", input: Selector.input, variadic: true),
    ],
    returns: Selector.output
) { _, _, args in
    let selfValue: Selector = try args.expectT("self")
    let others: [Selector] = try args.allT()
    try args.finishT()
    return selfValue.and(others)
}

/// `selector.before(end, inclusive:)` — port of `Selector::before`.
let selectorBefore = nativeFunc(
    "before",
    since: .version([0, 3, 0]),
    docs: """
        Returns a modified selector that will only match elements that \
        occur before the first match of `end`.
        """,
    params: [
        NativeParamInfo(name: "self", input: Selector.input, required: true),
        NativeParamInfo(name: "end", input: LocatableSelector.input, required: true),
        NativeParamInfo(
            name: "inclusive",
            input: Bool.input,
            defaultValue: { .bool(true) },
            positional: false,
            named: true),
    ],
    returns: Selector.output
) { _, _, args in
    let selfValue: Selector = try args.expectT("self")
    let end: LocatableSelector = try args.expectT("end")
    let inclusive: Bool = try args.namedT("inclusive") ?? true
    try args.finishT()
    return selfValue.before(end.selector, inclusive: inclusive)
}

/// `selector.after(start, inclusive:)` — port of `Selector::after`.
let selectorAfter = nativeFunc(
    "after",
    since: .version([0, 3, 0]),
    docs: """
        Returns a modified selector that will only match elements that \
        occur after the first match of `start`.
        """,
    params: [
        NativeParamInfo(name: "self", input: Selector.input, required: true),
        NativeParamInfo(name: "start", input: LocatableSelector.input, required: true),
        NativeParamInfo(
            name: "inclusive",
            input: Bool.input,
            defaultValue: { .bool(true) },
            positional: false,
            named: true),
    ],
    returns: Selector.output
) { _, _, args in
    let selfValue: Selector = try args.expectT("self")
    let start: LocatableSelector = try args.expectT("start")
    let inclusive: Bool = try args.namedT("inclusive") ?? true
    try args.finishT()
    return selfValue.after(start.selector, inclusive: inclusive)
}

/// `selector.within(ancestor)` — port of `Selector::within`.
let selectorWithin = nativeFunc(
    "within",
    since: .version([0, 15, 0]),
    docs: """
        Returns a modified selector that will only match elements that \
        are contained within any elements matching the `ancestor` selector.
        """,
    params: [
        NativeParamInfo(name: "self", input: Selector.input, required: true),
        NativeParamInfo(name: "ancestor", input: LocatableSelector.input, required: true),
    ],
    returns: Selector.output
) { _, _, args in
    let selfValue: Selector = try args.expectT("self")
    let ancestor: LocatableSelector = try args.expectT("ancestor")
    try args.finishT()
    return selfValue.within(ancestor.selector)
}

/// Build the scope containing all `selector` methods.
func selectorScope() -> Scope {
    let scope = Scope()
    scope.defineFunc(selectorConstruct)
    scope.defineFunc(selectorOr)
    scope.defineFunc(selectorAnd)
    scope.defineFunc(selectorBefore)
    scope.defineFunc(selectorAfter)
    scope.defineFunc(selectorWithin)
    return scope
}
