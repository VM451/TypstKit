import Foundation
import TypstSyntax
import TypstUtils

// MARK: - CounterKey

/// Identifies a counter.
///
/// Port of `CounterKey` in `introspection/counter.rs`.
public enum CounterKey: Sendable, Hashable {
    /// The page counter.
    case page
    /// Counts elements matching the given selectors. Only works for
    /// locatable elements or labels.
    case selector(Selector)
    /// Counts through manual counters with the same key.
    case str(Str)
}

extension CounterKey: Castable, IntoValue, FromValue {
    public static var input: CastInfo {
        Str.input + Label.input + Element.input + LocatableSelector.input
    }
    public static var output: CastInfo { input }

    public static func castable(_ value: Value) -> Bool {
        Str.castable(value) || Label.castable(value)
            || Element.castable(value) || LocatableSelector.castable(value)
    }

    public func intoValue() -> Value {
        switch self {
        case .page: return Element(PageElem.self).intoValue()
        case let .selector(v): return v.intoValue()
        case let .str(v): return v.intoValue()
        }
    }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        if case let .str(v) = value { return .success(.str(v)) }
        if case let .label(v) = value {
            return .success(.selector(.label(v)))
        }
        if case .success(let element) = Element.fromValue(value),
           element == Element(PageElem.self) {
            return .success(.page)
        }
        return LocatableSelector.fromValue(value)
            .map { .selector($0.selector) }
    }
}

extension CounterKey: Repr {
    public func repr() -> String {
        switch self {
        case .page: return "page"
        case let .selector(s): return s.repr()
        case let .str(s): return s.repr()
        }
    }
}

// MARK: - CounterState

/// Counts through elements with different levels.
///
/// Port of `CounterState` in `introspection/counter.rs`.
public struct CounterState: Sendable, Hashable {
    /// The numbers of the state, one per level.
    public var numbers: [UInt64]

    public init(_ numbers: [UInt64]) {
        self.numbers = numbers
    }

    /// Get the initial counter state for the key.
    /// Port of `CounterState::init`.
    public static func initial(page: Bool) -> CounterState {
        // Special case, because pages always start at one.
        CounterState([page ? 1 : 0])
    }

    /// Advance the counter and return the numbers for the given heading.
    public mutating func update(
        engine: inout Engine, update: CounterUpdate
    ) -> SourceResult<()> {
        switch update {
        case let .set(state):
            self = state
        case let .step(level):
            self.step(level: level, by: 1)
        case let .function(`func`):
            let args = Args(span: .detached, items: numbers.map {
                Arg(span: .detached, name: nil,
                    value: Spanned(Value.int(Int64($0)), span: .detached))
            })
            let result = `func`.callValue(
                engine: &engine, context: .none,
                args: args, span: `func`.span)
            switch result {
            case let .success(v):
                switch CounterState.fromValue(v).at(`func`.span) {
                case let .success(s): self = s
                case let .failure(e): return .failure(e)
                }
            case let .failure(e):
                return .failure(e)
            }
        }
        return .success(())
    }

    /// Advance the number of the given level by the specified amount.
    public mutating func step(level: NonZeroUsize, by: UInt64) {
        let level = level.value

        while numbers.count < level {
            numbers.append(0)
        }

        numbers[level - 1] = numbers[level - 1]
            .addingReportingOverflow(by).partialValue
        numbers.removeSubrange(level...)
    }

    /// Get the first number of the state.
    public func first() -> UInt64 {
        numbers.first ?? 1
    }

    /// Display the counter state with a numbering.
    public func display(
        engine: inout Engine, context: Context, span: Span,
        numbering: Numbering
    ) -> SourceResult<Value> {
        numbering.apply(engine: &engine, context: context,
                        span: span, numbers: numbers)
    }
}

extension CounterState: Castable, IntoValue, FromValue {
    public static var input: CastInfo {
        .union([.type(Type.of(Int64.self)),
                .type(Type.of(ArrayValue.self))])
    }
    public static var output: CastInfo { input }

    public static func castable(_ value: Value) -> Bool {
        switch value {
        case .int, .array: return true
        default: return false
        }
    }

    public func intoValue() -> Value {
        .array(ArrayValue(items: numbers.map { .int(Int64($0)) }))
    }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        switch value {
        case let .int(v):
            guard v >= 0 else {
                return .failure(HintedString("number must be non-negative"))
            }
            return .success(CounterState([UInt64(v)]))
        case let .array(array):
            var numbers: [UInt64] = []
            for item in array.items {
                switch UInt64.fromValue(item) {
                case let .success(n): numbers.append(n)
                case let .failure(e): return .failure(e)
                }
            }
            return .success(CounterState(numbers))
        default:
            return .failure(error(value))
        }
    }
}

// MARK: - CounterUpdate

/// An update to perform on a counter.
///
/// Port of `CounterUpdate` in `introspection/counter.rs`.
public enum CounterUpdate: Sendable, Hashable {
    /// Set the counter to the specified state.
    case set(CounterState)
    /// Increase the number for the given level by one.
    case step(NonZeroUsize)
    /// Apply the given function to the counter's state.
    case function(Func)
}

extension CounterUpdate: Castable, IntoValue, FromValue {
    public static var input: CastInfo {
        CounterState.input + Func.input
    }
    public static var output: CastInfo { input }

    public static func castable(_ value: Value) -> Bool {
        CounterState.castable(value) || Func.castable(value)
    }

    public func intoValue() -> Value {
        switch self {
        case let .set(s): return s.intoValue()
        case let .step(l): return l.intoValue()
        case let .function(f): return f.intoValue()
        }
    }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        if Func.castable(value) {
            return Func.fromValue(value).map { .function($0) }
        }
        return CounterState.fromValue(value).map { .set($0) }
    }
}

/// Elements that have special counting behaviour.
/// Port of the `Count` trait in `introspection/counter.rs`.
public protocol Count {
    /// Get the counter update for this element.
    func counterUpdate() -> CounterUpdate?
}

// MARK: - Count impls
//
// Upstream locations: `model/heading.rs`, `model/figure.rs`,
// `model/footnote.rs`. `EquationElem` and `ParLineMarker` impls land with
// the math and layout milestones.

extension HeadingElem: Count {
    /// Steps by the resolved level when the heading is numbered.
    public func counterUpdate() -> CounterUpdate? {
        numbering != nil ? .step(resolveLevel()) : nil
    }
}

extension HeadingElem {
    /// `Packed<HeadingElem>::resolve_level` evaluated with the default
    /// style chain (element-local values), matching the upstream `Count`
    /// impl which passes `StyleChain::default()`.
    func resolveLevel() -> NonZeroUsize {
        if let level = level.custom() {
            return NonZeroUsize(value: max(1, level))
        }
        return NonZeroUsize(value: max(1, offset + depth))
    }
}

extension FigureElem: Count {
    /// Steps by one when the figure is numbered.
    public func counterUpdate() -> CounterUpdate? {
        numbering != nil ? .step(NonZeroUsize(value: 1)) : nil
    }
}

extension FootnoteElem: Count {
    /// Steps by one unless this footnote is a reference.
    public func counterUpdate() -> CounterUpdate? {
        !isRef() ? .step(NonZeroUsize(value: 1)) : nil
    }
}

// MARK: - CounterUpdateElem / CounterDisplayElem

/// Executes an update of a counter.
///
/// Port of `CounterUpdateElem` (`#[elem(Construct, Locatable, Count)]`).
public struct CounterUpdateElem: NativeElement, Count {
    public static let info = ElementInfo(
        name: "update",
        title: "Counter Update",
        fields: [
            FieldInfo(id: 0, name: "key", required: true),
            FieldInfo(id: 1, name: "update", required: true),
        ],
        capabilities: [.locatable]
    )

    /// The key that identifies the counter.
    public var key: CounterKey = .str(Str(""))
    /// The update to perform on the counter.
    public var update: CounterUpdate = .set(CounterState([]))

    public var span: Span = .detached

    public init(key: CounterKey = .str(Str("")),
                update: CounterUpdate = .set(CounterState([]))) {
        self.key = key
        self.update = update
    }

    /// `CounterUpdateElem::new(key, update).pack()`.
    public func pack() -> Content { Content(self) }

    /// `Count::update`.
    public func counterUpdate() -> CounterUpdate? { update }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return key.intoValue()
        case 1: return update.intoValue()
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch id {
        case 0: key = try CounterKey.fromValue(value).get()
        case 1: update = try CounterUpdate.fromValue(value).get()
        default: break
        }
    }
}

extension CounterUpdateElem {
    /// Upstream `Construct` bails.
    public static func construct(engine: inout Engine, args: inout Args) throws -> Content {
        throw HintedString("cannot be constructed manually")
    }
}

/// Executes a display of a counter.
///
/// Port of `CounterDisplayElem` (`#[elem(Construct, Unqueriable,
/// Locatable)]`). `COUNTER_DISPLAY_RULE` is deferred with native show
/// rules.
public struct CounterDisplayElem: NativeElement {
    public static let info = ElementInfo(
        name: "display",
        title: "Counter Display",
        fields: [
            FieldInfo(id: 0, name: "counter", required: true),
            FieldInfo(id: 1, name: "numbering", required: true),
            FieldInfo(id: 2, name: "both", required: true),
        ],
        capabilities: [.locatable, .unqueriable]
    )

    /// The counter.
    public var counter: Counter = Counter(.str(Str("")))
    /// The numbering to display the counter with.
    public var numbering: Smart<Numbering> = .auto
    /// Whether to display both the current and final value.
    public var both: Bool = false

    public var span: Span = .detached

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return counter.intoValue()
        case 1: return numbering.intoValue()
        case 2: return both.intoValue()
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch id {
        case 0: counter = try Counter.fromValue(value).get()
        case 1: numbering = try Smart<Numbering>.fromValue(value).get()
        case 2: both = try Bool.fromValue(value).get()
        default: break
        }
    }
}

extension CounterDisplayElem {
    /// Upstream `Construct` bails.
    public static func construct(engine: inout Engine, args: inout Args) throws -> Content {
        throw HintedString("cannot be constructed manually")
    }
}

// MARK: - Counter

/// A counter that can be updated and displayed.
///
/// Port of `Counter` in `introspection/counter.rs`.
public struct Counter: Sendable, Hashable {
    /// The counter's key.
    public var key: CounterKey

    /// Create a new counter identified by a key.
    public init(_ key: CounterKey) {
        self.key = key
    }

    /// The counter for the given element.
    public static func of(_ element: Element) -> Counter {
        Counter(.selector(.elem(element, fields: nil)))
    }

    /// Selects all counter updates.
    public static func selectAny() -> Selector {
        Element(CounterUpdateElem.self).select()
    }

    /// The selector relevant for this counter's updates.
    public func select(
        _ introspector: any Introspector, _ loc: Location
    ) -> Selector {
        var selector = Element(CounterUpdateElem.self).whereFields(
            [(0, key.intoValue())])

        switch key {
        case .page:
            // In bundle export, we only want the page counter updates in
            // the current document.
            if let docLocation = introspector.document(loc) {
                selector = .within(
                    selector: selector, ancestor: .location(docLocation))
            }
        case let .selector(key):
            selector = .or([selector, key])
        case .str:
            break
        }

        return selector
    }

    /// Whether this is the page counter.
    public var isPage: Bool { key == .page }

    /// Displays the value of the counter at the given location.
    /// Port of `Counter::display_at`.
    public func displayAt(
        engine: inout Engine, loc: Location, styles: StyleChain,
        numbering: Numbering, span: Span
    ) -> SourceResult<Content> {
        let context = Context(location: loc, styles: styles)
        switch engine.introspect(
            CounterAtIntrospection(counter: self, location: loc, span: span)
        ) {
        case let .success(state):
            switch state.display(engine: &engine, context: context,
                                 span: span, numbering: numbering) {
            case let .success(value): return .success(value.display)
            case let .failure(e): return .failure(e)
            }
        case let .failure(e): return .failure(e)
        }
    }

    /// Resolves the numbering for this counter track.
    ///
    /// Port of `Counter::matching_numbering`. The `EquationElem` arm is
    /// deferred with the math milestone.
    func matchingNumbering(
        engine: inout Engine, styles: StyleChain?, loc: Location,
        span: Span
    ) -> Numbering? {
        switch key {
        case .page:
            return loc.pageNumbering(engine: &engine, span: span)
        case let .selector(.elem(element, _)):
            let content = engine.introspect(QueryFirstIntrospection(
                selector: .location(loc), span: span))
            var resolved: Numbering?
            if element == Element(HeadingElem.self) {
                resolved = content?.to(HeadingElem.self)?.numbering
            } else if element == Element(FigureElem.self) {
                resolved = content?.to(FigureElem.self)?.numbering
            } else if element == Element(FootnoteElem.self) {
                resolved = content?.to(FootnoteElem.self)?.numbering
            }
            if resolved != nil { return resolved }

            // Style fallback.
            guard let styles else { return nil }
            if element == Element(HeadingElem.self) {
                return numberingFromStyle(styles, HeadingElem.self, 3)
            } else if element == Element(FigureElem.self) {
                return numberingFromStyle(styles, FigureElem.self, 7)
            } else if element == Element(FootnoteElem.self) {
                return numberingFromStyle(styles, FootnoteElem.self, 0)
            }
            return nil
        default:
            return nil
        }
    }
}

/// Extract a `Numbering` from a style-chain field value (`.none`/invalid
/// → nil).
private func numberingFromStyle<T: NativeElement>(
    _ styles: StyleChain, _ type: T.Type, _ field: UInt8
) -> Numbering? {
    guard let value = styles.get(Element(T.self), field) else { return nil }
    return try? Numbering.fromValue(value).get()
}

extension Counter: Repr {
    public func repr() -> String { "counter(\(key.repr()))" }
}

extension Counter: CustomDebugStringConvertible {
    public var debugDescription: String { repr() }
}

extension Counter: NativeType {
    public static let typeInfo = TypeInfo(
        name: "counter", longName: "counter", title: "Counter",
        since: .version([0, 1, 0]),
        constructor: { Func(native: counterConstruct) },
        scope: { counterScope() })
}

/// Counters are `#[ty]` values stored as `Value.dynamic`.
extension Counter: DynamicValue {}

/// `counter(key)` — port of `Counter::construct`.
let counterConstruct = nativeFunc(
    "counter",
    title: "Counter",
    since: .version([0, 1, 0]),
    docs: """
        Creates a new counter identified by a key.
        """,
    params: [
        NativeParamInfo(
            name: "key",
            docs: """
                The key that identifies this counter globally. If it is a \
                string, creates a custom counter. If it is the `page` \
                function, counts through pages. If it is a selector, counts \
                through elements that match the selector.
                """,
            input: CounterKey.input,
            defaultValue: nil,
            positional: true,
            required: true),
    ],
    returns: Counter.output
) { _, _, args in
    let key: CounterKey = try args.expectT("key")
    try args.finishT()
    return Counter(key)
}

/// `counter.get()` — port of `Counter::get`.
let counterGet = nativeFunc(
    "get",
    title: "Get",
    since: .version([0, 1, 0]),
    docs: """
        Retrieves the value of the counter at the current location. Always \
        returns an array of integers.
        """,
    contextual: true,
    params: [
        NativeParamInfo(name: "self", input: Counter.input, required: true),
    ],
    returns: CounterState.output
) { engine, context, args in
    let counter: Counter = try args.expectT("self")
    try args.finishT()
    let loc = try context.requireLocation().at(args.span).get()
    return try engine.introspect(
        CounterAtIntrospection(counter: counter, location: loc,
                               span: args.span)).get()
}

/// `counter.display(..)` — port of `Counter::display`.
let counterDisplay = nativeFunc(
    "display",
    title: "Display",
    since: .version([0, 1, 0]),
    docs: """
        Displays the value of the counter.
        """,
    contextual: true,
    params: [
        NativeParamInfo(name: "self", input: Counter.input, required: true),
        NativeParamInfo(
            name: "numbering",
            docs: """
                A numbering pattern or a function specifying how to display \
                the counter.
                """,
            input: Smart<Numbering>.input,
            defaultValue: { .auto },
            positional: true),
        NativeParamInfo(
            name: "at",
            docs: """
                The place at which the counter should be displayed.
                """,
            input: Smart<LocatableSelector>.input,
            defaultValue: { .auto },
            positional: false,
            named: true),
        NativeParamInfo(
            name: "both",
            docs: """
                If enabled, displays the current and final top-level count \
                together.
                """,
            input: Bool.input,
            defaultValue: { .bool(false) },
            positional: false,
            named: true),
    ],
    returns: Value.output
) { engine, context, args in
    let counter: Counter = try args.expectT("self")
    let numbering: Smart<Numbering> = try args.eatT() ?? .auto
    let at: Smart<LocatableSelector> = try args.namedT("at") ?? .auto
    let both: Bool = try args.namedT("both") ?? false
    try args.finishT()
    let span = args.span

    let location: Location
    switch at {
    case .auto:
        location = try context.requireLocation().at(span).get()
    case let .custom(selector):
        location = try selector.resolveUnique(
            engine: &engine, context: context, span: span)
    }

    let state: CounterState
    if both {
        state = try engine.introspect(CounterBothIntrospection(
            counter: counter, location: location, span: span)).get()
    } else {
        state = try engine.introspect(CounterAtIntrospection(
            counter: counter, location: location, span: span)).get()
    }

    let resolvedNumbering: Numbering
    if let custom = numbering.custom() {
        resolvedNumbering = custom
    } else if let matched = counter.matchingNumbering(
        engine: &engine, styles: context.styles,
        loc: location, span: span
    ) {
        resolvedNumbering = matched
    } else {
        resolvedNumbering = .pattern(try NumberingPattern(parsing: "1.1"))
    }

    if at.isCustom {
        let newContext = Context(
            location: location, styles: context.styles)
        return try state.display(
            engine: &engine, context: newContext,
            span: span, numbering: resolvedNumbering).get()
    }
    return try state.display(
        engine: &engine, context: context,
        span: span, numbering: resolvedNumbering).get()
}

/// `counter.at(selector)` — port of `Counter::at`.
let counterAt = nativeFunc(
    "at",
    title: "At",
    since: .version([0, 2, 0]),
    docs: """
        Retrieves the value of the counter at the given location.
        """,
    contextual: true,
    params: [
        NativeParamInfo(name: "self", input: Counter.input, required: true),
        NativeParamInfo(
            name: "selector",
            docs: "The place at which the counter's value should be retrieved.",
            input: LocatableSelector.input,
            defaultValue: nil,
            positional: true),
    ],
    returns: CounterState.output
) { engine, context, args in
    let counter: Counter = try args.expectT("self")
    let selector: LocatableSelector = try args.expectT("selector")
    try args.finishT()
    let loc = try selector.resolveUnique(
        engine: &engine, context: context, span: args.span)
    return try engine.introspect(
        CounterAtIntrospection(counter: counter, location: loc,
                               span: args.span)).get()
}

/// `counter.final()` — port of `Counter::final_`.
let counterFinal = nativeFunc(
    "final",
    title: "Final",
    since: .version([0, 8, 0]),
    docs: """
        Retrieves the value of the counter at the end of the document.
        """,
    contextual: true,
    params: [
        NativeParamInfo(name: "self", input: Counter.input, required: true),
    ],
    returns: CounterState.output
) { engine, context, args in
    let counter: Counter = try args.expectT("self")
    try args.finishT()
    let loc = try context.requireLocation().at(args.span).get()
    return try engine.introspect(
        CounterFinalIntrospection(counter: counter, location: loc,
                                  span: args.span)).get()
}

/// `counter.step(..)` — port of `Counter::step`.
let counterStep = nativeFunc(
    "step",
    title: "Step",
    since: .version([0, 1, 0]),
    docs: """
        Increases the value of the counter by one.
        """,
    params: [
        NativeParamInfo(name: "self", input: Counter.input, required: true),
        NativeParamInfo(
            name: "level",
            docs: "The depth at which to step the counter.",
            input: NonZeroUsize.input,
            defaultValue: { .int(1) },
            positional: false,
            named: true),
    ],
    returns: Content.output
) { _, _, args in
    let counter: Counter = try args.expectT("self")
    let level: NonZeroUsize = try args.namedT("level")
        ?? NonZeroUsize(value: 1)
    try args.finishT()
    return counter.update(.step(level)).pack()
        .spanned(args.span)
}

/// `counter.update(update)` — port of `Counter::update`.
let counterUpdateFunc = nativeFunc(
    "update",
    title: "Update",
    since: .version([0, 1, 0]),
    docs: """
        Updates the value of the counter.
        """,
    params: [
        NativeParamInfo(name: "self", input: Counter.input, required: true),
        NativeParamInfo(
            name: "update",
            docs: """
                If given an integer or array of integers, sets the counter \
                to that value. If given a function, that function receives \
                the previous counter value and has to return the new value.
                """,
            input: CounterUpdate.input,
            defaultValue: nil,
            positional: true),
    ],
    returns: Content.output
) { _, _, args in
    let counter: Counter = try args.expectT("self")
    let update: CounterUpdate = try args.expectT("update")
    try args.finishT()
    return counter.update(update).pack()
        .spanned(args.span)
}

extension Counter {
    /// `CounterUpdateElem::new(key, update)` — shared body of
    /// `step`/`update`.
    func update(_ update: CounterUpdate) -> CounterUpdateElem {
        CounterUpdateElem(key: key, update: update)
    }
}

/// Build the scope containing all `counter` methods.
/// Port of upstream's `#[scope] impl Counter`.
func counterScope() -> Scope {
    let scope = Scope()
    scope.defineFunc(counterGet)
    scope.defineFunc(counterDisplay)
    scope.defineFunc(counterAt)
    scope.defineFunc(counterFinal)
    scope.defineFunc(counterStep)
    scope.defineFunc(counterUpdateFunc)
    return scope
}

// MARK: - Introspection structs

/// Retrieves a counter at a specific location.
/// Port of `CounterAtIntrospection`.
struct CounterAtIntrospection: Introspect, Hashable {
    var counter: Counter
    var location: Location
    var span: Span

    typealias Output = SourceResult<CounterState>

    func introspect(
        _ engine: inout Engine, _ introspector: any Introspector
    ) -> Output {
        let selector = counter.select(introspector, location)
        let sequence = counterSequence(
            counter, selector: selector, engine: &engine,
            introspector: introspector)
        switch sequence {
        case .failure(let e): return .failure(e)
        case let .success(stops):
            let offset = introspector.queryCountBefore(
                selector, end: location)
            var (state, page) = stops[offset]
            if counter.isPage {
                let delta = (introspector.page(location) ?? 1)
                    .subtractingReportingOverflow(page.value).partialValue
                state.step(level: NonZeroUsize(value: 1), by: UInt64(delta))
            }
            return .success(state)
        }
    }

    func diagnose(_ history: History<Output>) -> SourceDiagnostic {
        counterConvergenceWarning(counter, span: span, history: history)
    }
}

/// Retrieves the first number of a counter at a specific location and the
/// first number of the final state.
/// Port of `CounterBothIntrospection`.
struct CounterBothIntrospection: Introspect, Hashable {
    var counter: Counter
    var location: Location
    var span: Span

    typealias Output = SourceResult<CounterState>

    func introspect(
        _ engine: inout Engine, _ introspector: any Introspector
    ) -> Output {
        let selector = counter.select(introspector, location)
        let sequence = counterSequence(
            counter, selector: selector, engine: &engine,
            introspector: introspector)
        switch sequence {
        case .failure(let e): return .failure(e)
        case let .success(stops):
            let offset = introspector.queryCountBefore(
                selector, end: location)
            var (atState, atPage) = stops[offset]
            var (finalState, finalPage) = stops[stops.count - 1]
            if counter.isPage {
                let atDelta = (introspector.page(location) ?? 1)
                    .subtractingReportingOverflow(atPage.value).partialValue
                atState.step(level: NonZeroUsize(value: 1),
                             by: UInt64(atDelta))
                let finalDelta = (introspector.pages(location) ?? 1)
                    .subtractingReportingOverflow(finalPage.value).partialValue
                finalState.step(level: NonZeroUsize(value: 1),
                                by: UInt64(finalDelta))
            }
            return .success(CounterState([atState.first(),
                                          finalState.first()]))
        }
    }

    func diagnose(_ history: History<Output>) -> SourceDiagnostic {
        counterConvergenceWarning(counter, span: span, history: history)
    }
}

/// Retrieves the final state of a counter.
/// Port of `CounterFinalIntrospection`.
struct CounterFinalIntrospection: Introspect, Hashable {
    var counter: Counter
    var location: Location
    var span: Span

    typealias Output = SourceResult<CounterState>

    func introspect(
        _ engine: inout Engine, _ introspector: any Introspector
    ) -> Output {
        let selector = counter.select(introspector, location)
        let sequence = counterSequence(
            counter, selector: selector, engine: &engine,
            introspector: introspector)
        switch sequence {
        case .failure(let e): return .failure(e)
        case let .success(stops):
            var (state, page) = stops[stops.count - 1]
            if counter.isPage {
                let delta = (introspector.pages(location) ?? 1)
                    .subtractingReportingOverflow(page.value).partialValue
                state.step(level: NonZeroUsize(value: 1), by: UInt64(delta))
            }
            return .success(state)
        }
    }

    func diagnose(_ history: History<Output>) -> SourceDiagnostic {
        counterConvergenceWarning(counter, span: span, history: history)
    }
}

// MARK: - Sequence

/// Produces the whole sequence of a counter.
///
/// Port of `sequence`/`sequence_impl` in `introspection/counter.rs`.
/// Upstream memoizes via comemo; the Swift port recomputes per call until
/// the compile driver lands memoization.
func counterSequence(
    _ counter: Counter, selector: Selector,
    engine: inout Engine, introspector: any Introspector
) -> SourceResult<[(CounterState, NonZeroUsize)]> {
    var current = CounterState.initial(page: counter.isPage)
    var page = NonZeroUsize(value: 1)
    var stops: [(CounterState, NonZeroUsize)] = [(current, page)]

    for content in introspector.query(selector) {
        // Introspectable elements always carry a location; upstream
        // unwraps it here.
        guard let elemLocation = content.location else { continue }
        if counter.isPage {
            let prev = page
            page = NonZeroUsize(value: introspector.page(elemLocation) ?? 1)

            let delta = page.value - prev.value
            if delta > 0 {
                current.step(level: NonZeroUsize(value: 1), by: UInt64(delta))
            }
        }

        let update: CounterUpdate?
        if let countable = content.packed.element as? any Count {
            update = countable.counterUpdate()
        } else {
            update = .step(NonZeroUsize(value: 1))
        }

        if let update {
            switch current.update(engine: &engine, update: update) {
            case .success: break
            case let .failure(e): return .failure(e)
            }
        }

        stops.append((current, page))
    }

    return .success(stops)
}

// MARK: - Convergence warning

/// The warning when a counter failed to converge.
/// Port of `format_convergence_warning` in `introspection/counter.rs`.
func counterConvergenceWarning(
    _ counter: Counter, span: Span,
    history: History<SourceResult<CounterState>>
) -> SourceDiagnostic {
    var diag = SourceDiagnostic.warning(
        span, "value of \(formatCounterKey(counter)) did not converge")
    diag.hint(history.hint("values") { ret in
        switch ret {
        case let .success(v): return formatCounterState(v)
        case .failure: return "(errored)"
        }
    })
    return diag
}

/// Formats a counter's key human-readably.
/// Port of `format_key`.
func formatCounterKey(_ counter: Counter) -> String {
    switch counter.key {
    case .page: return "the page counter"
    default: return "`\(counter.repr())`"
    }
}

/// Formats a counter's state human-readably.
/// Port of `format_counter_state`.
func formatCounterState(_ state: CounterState) -> String {
    state.numbers.map { "\($0)" }.joined(separator: ", ")
}
