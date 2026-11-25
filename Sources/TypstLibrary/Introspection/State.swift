import Foundation
import TypstSyntax
import TypstUtils

/// A state value: a named, document-ordered mutable value.
///
/// Port of `State` in `introspection/state.rs` (the large doc comment is
/// omitted; see upstream for user-facing documentation).
public struct State: Sendable, Hashable {
    /// The key that identifies the state.
    public var key: Str
    /// The initial value of the state.
    public var initial: Value

    /// Create a new state identified by a key.
    public init(key: Str, initial: Value = .none) {
        self.key = key
        self.initial = initial
    }

    /// The selector for this state's updates.
    /// Port of `State::select` (`select_where!` on `key`).
    public func select() -> Selector {
        Element(StateUpdateElem.self).whereFields([(0, key.intoValue())])
    }

    /// Selects all state updates.
    /// Port of `State::select_any`.
    public static func selectAny() -> Selector {
        Element(StateUpdateElem.self).select()
    }
}

extension State: Repr {
    public func repr() -> String {
        "state(\(key.repr()), \(initial.repr()))"
    }
}

extension State: CustomDebugStringConvertible {
    public var debugDescription: String { repr() }
}

extension State: NativeType {
    public static let typeInfo = TypeInfo(
        name: "state", longName: "state", title: "State",
        since: .version([0, 1, 0]),
        constructor: { Func(native: stateConstruct) },
        scope: { stateScope() })
}

/// Locations store `State` values as `Value.dynamic`.
extension State: DynamicValue {}

/// `state(key, init:)` — port of `State::construct` (`#[func(constructor)]`).
let stateConstruct = nativeFunc(
    "state",
    title: "State",
    since: .version([0, 1, 0]),
    docs: """
        Creates a state value that is mutable throughout your document.
        """,
    params: [
        NativeParamInfo(
            name: "key",
            docs: "The key that identifies this state.",
            input: Str.input,
            defaultValue: nil,
            positional: true,
            required: true),
        NativeParamInfo(
            name: "init",
            docs: "The initial value of the state.",
            input: Value.input,
            defaultValue: { .none },
            positional: true),
    ],
    returns: State.output
) { _, _, args in
    let key: Str = try args.expectT("key")
    let initial: Value = try args.eatT() ?? .none
    try args.finishT()
    return State(key: key, initial: initial)
}

/// `state.get()` — port of `State::get`.
let stateGet = nativeFunc(
    "get",
    title: "Get",
    since: .version([0, 1, 0]),
    docs: """
        Retrieves the value of the state at the current location. This is \
        equivalent to `{state.at(here())}`.
        """,
    contextual: true,
    params: [
        NativeParamInfo(name: "self", input: State.input, required: true),
    ],
    returns: Value.output
) { engine, context, args in
    let state: State = try args.expectT("self")
    try args.finishT()
    let loc = try context.requireLocation().at(args.span).get()
    return try engine.introspect(
        StateAtIntrospection(state: state, location: loc, span: args.span))
        .get()
}

/// `state.at(selector)` — port of `State::at`.
let stateAt = nativeFunc(
    "at",
    title: "At",
    since: .version([0, 2, 0]),
    docs: """
        Retrieves the value of the state at the given selector's unique \
        match.
        """,
    contextual: true,
    params: [
        NativeParamInfo(name: "self", input: State.input, required: true),
        NativeParamInfo(
            name: "selector",
            docs: "The place at which the state's value should be retrieved.",
            input: LocatableSelector.input,
            defaultValue: nil,
            positional: true),
    ],
    returns: Value.output
) { engine, context, args in
    let state: State = try args.expectT("self")
    let selector: LocatableSelector = try args.expectT("selector")
    try args.finishT()
    let loc = try selector.resolveUnique(
        engine: &engine, context: context, span: args.span)
    return try engine.introspect(
        StateAtIntrospection(state: state, location: loc, span: args.span))
        .get()
}

/// `state.final()` — port of `State::final_` (upstream `final` is a
/// keyword, hence the underscore).
let stateFinal = nativeFunc(
    "final",
    title: "Final",
    since: .version([0, 8, 0]),
    docs: """
        Retrieves the value of the state at the end of the document.
        """,
    contextual: true,
    params: [
        NativeParamInfo(name: "self", input: State.input, required: true),
    ],
    returns: Value.output
) { engine, context, args in
    let state: State = try args.expectT("self")
    try args.finishT()
    _ = try context.introspect().at(args.span).get()
    return try engine.introspect(
        StateFinalIntrospection(state: state, span: args.span)).get()
}

/// `state.update(update)` — port of `State::update`.
let stateUpdateFunc = nativeFunc(
    "update",
    title: "Update",
    since: .version([0, 1, 0]),
    docs: """
        Updates the value of the state. Returns invisible content that must \
        be inserted into the document to take effect.
        """,
    params: [
        NativeParamInfo(name: "self", input: State.input, required: true),
        NativeParamInfo(
            name: "update",
            docs: """
                A value to update to or a function to update with. If given \
                a function, it receives the state's previous value and has \
                to return the new value.
                """,
            input: StateUpdate.input,
            defaultValue: nil,
            positional: true),
    ],
    returns: Content.output
) { _, _, args in
    let state: State = try args.expectT("self")
    let update: StateUpdate = try args.expectT("update")
    try args.finishT()
    return StateUpdateElem(key: state.key, update: update)
        .pack()
        .spanned(args.span)
}

/// Build the scope containing all `state` methods.
/// Port of upstream's `#[scope] impl State`.
func stateScope() -> Scope {
    let scope = Scope()
    scope.defineFunc(stateGet)
    scope.defineFunc(stateAt)
    scope.defineFunc(stateFinal)
    scope.defineFunc(stateUpdateFunc)
    return scope
}

/// An update to perform on a state.
/// Port of `StateUpdate` in `introspection/state.rs`.
public enum StateUpdate: Sendable, Hashable {
    /// Set the state to the specified value.
    case set(Value)
    /// Apply the given function to the state.
    case function(Func)
}

extension StateUpdate: Castable, IntoValue, FromValue {
    public static var input: CastInfo {
        Func.input + Value.input
    }
    public static var output: CastInfo { input }

    public static func castable(_ value: Value) -> Bool {
        // Upstream `cast!` tries `Func` first, then any `Value`.
        true
    }

    public func intoValue() -> Value {
        switch self {
        case let .set(v): return v
        case let .function(f): return f.intoValue()
        }
    }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        if case let .function(f) = value {
            return .success(.function(f))
        }
        return .success(.set(value))
    }
}

/// Executes an update of a state.
///
/// Port of `StateUpdateElem` in `introspection/state.rs`
/// (`#[elem(Construct, Locatable)]`).
public struct StateUpdateElem: NativeElement {
    public static let info = ElementInfo(
        name: "update",
        title: "State Update",
        fields: [
            FieldInfo(id: 0, name: "key", required: true),
            FieldInfo(id: 1, name: "update", required: true),
        ],
        capabilities: [.locatable]
    )

    /// The key that identifies the state.
    public var key: Str = Str("")
    /// The update to perform on the state.
    public var update: StateUpdate = .set(.none)

    public var span: Span = .detached

    public init(key: Str = Str(""), update: StateUpdate = .set(.none)) {
        self.key = key
        self.update = update
    }

    /// `StateUpdateElem::new(key, update).pack()`.
    public func pack() -> Content { Content(self) }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return key.intoValue()
        case 1: return update.intoValue()
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch id {
        case 0: key = try Str.fromValue(value).get()
        case 1: update = try StateUpdate.fromValue(value).get()
        default: break
        }
    }
}

extension StateUpdateElem {
    /// Upstream `Construct` bails: state updates cannot be constructed
    /// manually.
    public static func construct(engine: inout Engine, args: inout Args) throws -> Content {
        throw HintedString("cannot be constructed manually")
    }
}

/// Retrieves a state at a specific location.
/// Port of `StateAtIntrospection` (private upstream).
struct StateAtIntrospection: Introspect, Hashable {
    var state: State
    var location: Location
    var span: Span

    typealias Output = SourceResult<Value>

    func introspect(
        _ engine: inout Engine, _ introspector: any Introspector
    ) -> Output {
        let sequence = stateSequence(state, engine: &engine)
        switch sequence {
        case .failure(let e):
            return .failure(e)
        case let .success(stops):
            let offset = introspector.queryCountBefore(
                state.select(), end: location)
            return .success(stops[offset])
        }
    }

    func diagnose(_ history: History<Output>) -> SourceDiagnostic {
        stateConvergenceWarning(state, span: span, history: history)
    }
}

/// Retrieves the final value of a state.
/// Port of `StateFinalIntrospection` (private upstream).
struct StateFinalIntrospection: Introspect, Hashable {
    var state: State
    var span: Span

    typealias Output = SourceResult<Value>

    func introspect(
        _ engine: inout Engine, _ introspector: any Introspector
    ) -> Output {
        switch stateSequence(state, engine: &engine) {
        case .failure(let e): return .failure(e)
        case let .success(stops): return .success(stops[stops.count - 1])
        }
    }

    func diagnose(_ history: History<Output>) -> SourceDiagnostic {
        stateConvergenceWarning(state, span: span, history: history)
    }
}

/// Produces the whole sequence of a state.
///
/// Port of `sequence`/`sequence_impl` in `introspection/state.rs`.
/// Upstream memoizes via comemo; the Swift port recomputes per call until
/// the compile driver lands memoization.
func stateSequence(
    _ state: State, engine: inout Engine
) -> SourceResult<[Value]> {
    var current = state.initial
    var stops = [current]

    for content in engine.introspector.query(state.select()) {
        guard let elem = content.to(StateUpdateElem.self) else { continue }
        switch elem.update {
        case let .set(value):
            current = value
        case let .function(`func`):
            let args = Args(span: .detached, items: [
                Arg(span: .detached, name: nil,
                    value: Spanned(current, span: .detached)),
            ])
            let result: SourceResult<Value> = `func`.call(
                engine: &engine, context: Context(),
                args: args, span: .detached
            )
            switch result {
            case let .success(v): current = v
            case let .failure(e): return .failure(e)
            }
        }
        stops.append(current)
    }

    return .success(stops)
}

/// The warning when a state failed to converge.
/// Port of `format_convergence_warning`.
func stateConvergenceWarning(
    _ state: State, span: Span, history: History<SourceResult<Value>>
) -> SourceDiagnostic {
    var warning = SourceDiagnostic.warning(
        span, "value of `state(\(state.key.repr()))` did not converge")
    warning.hint(history.hint("values") { ret in
        switch ret {
        case let .success(v): return "`\(v.repr())`"
        case .failure: return "(errored)"
        }
    })
    warning.hint("see https://typst.app/help/state-convergence for help")
    return warning
}
