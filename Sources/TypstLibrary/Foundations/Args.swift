import Foundation
import TypstSyntax

/// A single argument: positional or named. Port of `Arg` in `args.rs`.
public struct Arg: Sendable, Hashable {
    /// The span of the argument's value expression.
    public var span: Span
    /// The argument name, if named.
    public var name: Str?
    /// The argument value together with its span.
    public var value: Spanned<Value, Span>

    public init(span: Span, name: Str?, value: Spanned<Value, Span>) {
        self.span = span
        self.name = name
        self.value = value
    }
}

extension Arg: CustomDebugStringConvertible {
    public var debugDescription: String {
        if let name {
            return "\(name): \(value.value)"
        }
        return "\(value.value)"
    }
}

extension Arg: Repr {
    public func repr() -> String {
        if let name {
            return "\(name.repr()): \(value.value.repr())"
        }
        return value.value.repr()
    }
}

/// The key used to access an argument by index or name. Port of
/// `ArgumentKey`.
public enum ArgumentKey: Sendable, Hashable {
    case index(Int64)
    case name(Str)
}

/// Function call arguments. Port of `Args` in `args.rs`.
public struct Args: Sendable, Hashable {
    /// The span of the whole argument list.
    public var span: Span
    /// The argument items.
    public var items: [Arg]

    public init(span: Span, items: [Arg] = []) {
        self.span = span
        self.items = items
    }

    /// Create positional arguments from values.
    public init<T: IntoValue>(span: Span, values: [T]) {
        self.span = span
        self.items = values.map { value in
            Arg(span: span, name: nil, value: Spanned(value.intoValue(), span: span))
        }
    }

    /// Set the span if currently detached.
    public func spanned(_ span: Span) -> Args {
        var copy = self
        if copy.span.isDetached { copy.span = span }
        return copy
    }

    /// The number of remaining positional arguments.
    public var remaining: Int {
        items.filter { $0.name == nil }.count
    }

    /// Insert a positional argument at `index`.
    public mutating func insert(index: Int, span: Span, value: Value) {
        items.insert(
            Arg(span: span, name: nil, value: Spanned(value, span: span)),
            at: Swift.min(Swift.max(index, 0), items.count)
        )
    }

    /// Push a positional argument.
    public mutating func push(span: Span, value: Value) {
        items.append(Arg(span: span, name: nil, value: Spanned(value, span: span)))
    }

    /// Take the next positional argument and cast it, if any.
    public mutating func eat<T: FromValue>() -> SourceResult<T?> {
        for (i, item) in items.enumerated() where item.name == nil {
            let arg = items.remove(at: i)
            let span = arg.value.span
            return T.fromSpannedValue(arg.value).at(span).map { $0 as T? }
        }
        return .success(nil)
    }

    /// Consume `n` positional arguments.
    public mutating func consume(_ n: Int) -> SourceResult<[Arg]> {
        var list: [Arg] = []
        var i = 0
        while i < items.count && list.count < n {
            if items[i].name == nil {
                list.append(items.remove(at: i))
            } else {
                i += 1
            }
        }
        if list.count < n {
            return .failure(SourceDiagnostics(
                SourceDiagnostic.error(span, "not enough arguments")
            ))
        }
        return .success(list)
    }

    /// Take the next positional argument and cast it, or error.
    public mutating func expect<T: FromValue>(_ what: String) -> SourceResult<T> {
        let result: SourceResult<T?> = eat()
        switch result {
        case let .success(value):
            guard let value else {
                return .failure(SourceDiagnostics(missingArgument(what)))
            }
            return .success(value)
        case let .failure(diags):
            return .failure(diags)
        }
    }

    func missingArgument(_ what: String) -> SourceDiagnostic {
        for item in items {
            if let name = item.name?.value, name == what {
                var diag = SourceDiagnostic.error(
                    item.span,
                    "the argument `\(what)` is positional"
                )
                diag.hint("try removing `\(name):`", at: item.span.diag)
                return diag
            }
        }
        return SourceDiagnostic.error(span, "missing argument: \(what)")
    }

    /// Find the first positional argument castable to `T`.
    public mutating func find<T: FromValue>() -> SourceResult<T?> {
        for (i, item) in items.enumerated() {
            if item.name == nil && T.castable(item.value.value) {
                let arg = items.remove(at: i)
                let span = arg.value.span
                return T.fromSpannedValue(arg.value).at(span).map { $0 as T? }
            }
        }
        return .success(nil)
    }

    /// Cast all remaining positional arguments.
    public mutating func all<T: FromValue>() -> SourceResult<[T]> {
        var list: [T] = []
        var errors: [SourceDiagnostic] = []
        var i = 0
        while i < items.count {
            let item = items[i]
            guard item.name == nil else {
                i += 1
                continue
            }
            items.remove(at: i)
            let span = item.value.span
            let spanned = Spanned(item.value.value, span: span)
            switch T.fromSpannedValue(spanned).at(span) {
            case let .success(value): list.append(value)
            case let .failure(diags): errors.append(contentsOf: diags.diagnostics)
            }
        }
        if !errors.isEmpty {
            return .failure(SourceDiagnostics(errors))
        }
        return .success(list)
    }

    /// Take all arguments with the given name (last wins).
    public mutating func named<T: FromValue>(_ name: String) -> SourceResult<T?> {
        var i = 0
        var found: Spanned<Value, Span>?
        while i < items.count {
            if items[i].name?.value == name {
                found = items.remove(at: i).value
            } else {
                i += 1
            }
        }
        guard let found else { return .success(nil) }
        return T.fromSpannedValue(found).at(found.span).map { $0 as T? }
    }

    /// Take a named argument, falling back to `find`.
    public mutating func namedOrFind<T: FromValue>(_ name: String) -> SourceResult<T?> {
        let result: SourceResult<T?> = named(name)
        switch result {
        case let .success(value) where value != nil:
            return .success(value)
        case let .failure(diags):
            return .failure(diags)
        default:
            let found: SourceResult<T?> = find()
            return found
        }
    }

    /// Take all remaining items, leaving `self` empty.
    public mutating func take() -> Args {
        let taken = items
        items = []
        return Args(span: span, items: taken)
    }

    /// Finish argument consumption; errors on leftovers.
    public func finish() -> SourceResult<()> {
        if let arg = items.first {
            if let name = arg.name {
                return .failure(SourceDiagnostics(SourceDiagnostic.error(
                    arg.span, "unexpected argument: \(name.value)"
                )))
            }
            return .failure(SourceDiagnostics(SourceDiagnostic.error(
                arg.span, "unexpected argument"
            )))
        }
        return .success(())
    }

    /// Whether there are no arguments at all.
    public var isEmpty: Bool { items.isEmpty }

    /// Access a named argument as a field.
    public func field(_ field: String) -> StrResult<Value> {
        for item in items.reversed() {
            if item.name?.value == field {
                return .success(item.value.value)
            }
        }
        return .failure(StrError("no named argument \(Str(field).repr())"))
    }
}

/// Look up an argument by index (negative = from back) or name.
public func get(_ args: Args, _ key: ArgumentKey) -> Value? {
    switch key {
    case let .index(index):
        let positional = args.items.filter { $0.name == nil }
        // 0-based from front; negative counts from the back (-1 = last).
        let idx = index >= 0 ? index : Int64(positional.count) + index
        guard idx >= 0, let i = Int(exactly: idx), i < positional.count else {
            return nil
        }
        return positional[i].value.value
    case let .name(name):
        // Accept the last argument with the right name.
        return args.items.reversed().first { $0.name == name }?.value.value
    }
}

extension Args {
    /// Access an argument by index or name with optional default.
    public func at(_ key: ArgumentKey, default defaultValue: Value? = nil) -> StrResult<Value> {
        if let value = get(self, key) { return .success(value) }
        if let defaultValue { return .success(defaultValue) }
        switch key {
        case let .index(i):
            return .failure(StrError(
                "no positional argument at index \(i) and no default value was specified"
            ))
        case let .name(name):
            return .failure(StrError(
                "no named argument \(name.repr()) and no default value was specified"
            ))
        }
    }

    /// The positional arguments as an array.
    public var toPos: ArrayValue {
        ArrayValue(items.filter { $0.name == nil }.map { $0.value.value })
    }

    /// The named arguments as a dictionary.
    public var toNamed: Dict {
        var dict = Dict()
        for item in items {
            if let name = item.name {
                dict.insert(name.value, item.value.value)
            }
        }
        return dict
    }

    /// Filter arguments by a predicate function.
    public func filter(
        _ test: Func,
        engine: inout Engine,
        context: Context
    ) -> SourceResult<Args> {
        var result = Args(span: span)
        for arg in items {
            let callArgs = Args(span: arg.span, items: [
                Arg(span: arg.value.span, name: nil, value: arg.value)
            ])
            let keepResult: SourceResult<Bool> = test.call(
                engine: &engine, context: context, args: callArgs, span: arg.span)
            switch keepResult {
            case let .success(keep):
                if keep { result.items.append(arg) }
            case let .failure(diags):
                return .failure(diags)
            }
        }
        return .success(result)
    }

    /// Map each argument's value through a function.
    public func map(
        _ mapper: Func,
        engine: inout Engine,
        context: Context
    ) -> SourceResult<Args> {
        var result = Args(span: span)
        for arg in items {
            let callArgs = Args(span: arg.span, items: [
                Arg(span: arg.value.span, name: nil, value: arg.value)
            ])
            let mappedResult: SourceResult<Value> = mapper.call(
                engine: &engine,
                context: context,
                args: callArgs,
                span: arg.span
            )
            switch mappedResult {
            case let .success(mapped):
                result.items.append(Arg(
                    span: arg.span,
                    name: arg.name,
                    value: Spanned(mapped, span: arg.span)
                ))
            case let .failure(diags):
                return .failure(diags)
            }
        }
        return .success(result)
    }
}

extension Args: CustomDebugStringConvertible {
    public var debugDescription: String {
        "arguments\(prettyArrayLike(items.map { $0.repr() }, trailingComma: false))"
    }
}

extension Args: Repr {
    public func repr() -> String {
        "arguments\(prettyArrayLike(items.map { $0.repr() }, trailingComma: false))"
    }
}

extension Args: Equatable {
    public static func == (lhs: Args, rhs: Args) -> Bool {
        lhs.toPos == rhs.toPos && lhs.toNamed == rhs.toNamed
    }
}

extension Args {
    /// Concatenate two argument lists; named args in `rhs` shadow `lhs`.
    public static func + (lhs: Args, rhs: Args) -> Args {
        var items = lhs.items
        let rhsNames = Set(rhs.items.compactMap { $0.name?.value })
        items.removeAll { item in
            guard let name = item.name?.value else { return false }
            return rhsNames.contains(name)
        }
        items.append(contentsOf: rhs.items)
        return Args(span: .detached, items: items)
    }
}

extension Args: Sequence {
    public func makeIterator() -> IndexingIterator<[Arg]> {
        items.makeIterator()
    }
}

/// Conversion into `Args`. Port of `IntoArgs`.
public protocol IntoArgs {
    func intoArgs(fallback: Span) -> Args
}

extension Args: IntoArgs {
    public func intoArgs(fallback: Span) -> Args {
        spanned(fallback)
    }
}

extension Array: IntoArgs where Element: IntoValue {
    public func intoArgs(fallback: Span) -> Args {
        Args(span: fallback, values: self)
    }
}
