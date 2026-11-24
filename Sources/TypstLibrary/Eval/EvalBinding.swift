import Foundation
import TypstSyntax
import TypstUtils

// Port of `typst-eval/src/binding.rs` — let bindings, destructuring
// assignments, and the `destructure` machinery.

extension TypstSyntax.LetBinding {
    /// Evaluate the let binding. Port of `LetBinding::eval`.
    public func eval(_ vm: inout Vm) throws -> Value {
        let value: Value
        if let initExpr = initExpr() {
            value = try initExpr.eval(&vm)
        } else {
            value = .none
        }
        if vm.flow != nil {
            return .none
        }

        switch kind() {
        case .normal(let pattern):
            try destructure(&vm, pattern: pattern, value: value)
        case .closure(let ident):
            vm.define(ident, value)
        }

        return .none
    }
}

extension TypstSyntax.DestructAssignment {
    /// Evaluate the destructuring assignment. Port of
    /// `DestructAssignment::eval`.
    public func eval(_ vm: inout Vm) throws -> Value {
        let value = try self.value().eval(&vm)
        try destructureImpl(&vm, pattern: pattern(), value: value) { vm, expr, val in
            let location = try access(expr, &vm)
            try location.write(&vm, val)
        }
        return .none
    }
}

/// Destructures a value into a pattern (defines new bindings).
/// Port of `destructure` in `binding.rs`.
func destructure(_ vm: inout Vm, pattern: Pattern, value: Value) throws {
    try destructureImpl(&vm, pattern: pattern, value: value) { vm, expr, val in
        guard case let .ident(ident) = expr else {
            throw SourceDiagnostics(SourceDiagnostic.error(
                expr.span, "cannot assign to this expression"))
        }
        vm.define(ident, val)
    }
}

/// Destruct the given value into the pattern and apply the function to
/// each binding. Port of `destructure_impl`.
private func destructureImpl(
    _ vm: inout Vm, pattern: Pattern, value: Value,
    _ f: (inout Vm, Expr, Value) throws -> Void
) throws {
    switch pattern {
    case .normal(let expr):
        try f(&vm, expr, value)
    case .placeholder:
        break
    case .parenthesized(let parenthesized):
        try destructureImpl(&vm, pattern: parenthesized.pattern(),
                            value: value, f)
    case .destructuring(let destruct):
        switch value {
        case .array(let array):
            try destructureArray(&vm, destruct, array: array, f)
        case .dict(let dict):
            try destructureDict(&vm, destruct, dict: dict, f)
        default:
            throw SourceDiagnostics(SourceDiagnostic.error(
                pattern.span, "cannot destructure \(value.type)"))
        }
    }
}

private func destructureArray(
    _ vm: inout Vm, _ destruct: TypstSyntax.Destructuring,
    array: ArrayValue,
    _ f: (inout Vm, Expr, Value) throws -> Void
) throws {
    let len = array.items.count
    let items = destruct.items()
    var i = 0

    for item in items {
        switch item {
        case .pattern(let pattern):
            guard i < len else {
                throw wrongNumberOfElements(destruct, len: len)
            }
            try destructureImpl(&vm, pattern: pattern,
                                value: array.items[i], f)
            i += 1
        case .spread(let spread):
            // `sink_size = (1 + len) - item_count` — the spread absorbs
            // the remaining elements.
            let sinkSize = (1 + len) - items.count
            guard sinkSize >= 0, i + sinkSize <= len else {
                throw wrongNumberOfElements(destruct, len: len)
            }
            if let expr = spread.sinkExpr() {
                let sink = ArrayValue(items: Array(array.items[i..<(i + sinkSize)]))
                try f(&vm, expr, .array(sink))
            }
            i += sinkSize
        case .named(let named):
            throw SourceDiagnostics(SourceDiagnostic.error(
                named.span, "cannot destructure named pattern from an array"))
        }
    }

    if i < len {
        throw wrongNumberOfElements(destruct, len: len)
    }
}

private func destructureDict(
    _ vm: inout Vm, _ destruct: TypstSyntax.Destructuring,
    dict: Dict,
    _ f: (inout Vm, Expr, Value) throws -> Void
) throws {
    var sink: Expr?
    var used = Set<String>()

    for item in destruct.items() {
        switch item {
        // Shorthand for a direct identifier.
        case .pattern(.normal(.ident(let ident))):
            let key = ident.get()
            guard let v = dict.get(key) else {
                throw SourceDiagnostics(SourceDiagnostic.error(
                    ident.span, "dictionary does not contain key \(Str(key).repr())"))
            }
            try f(&vm, .ident(ident), v)
            used.insert(key)
        case .named(let named):
            let name = named.name()
            let key = name.get()
            guard let v = dict.get(key) else {
                throw SourceDiagnostics(SourceDiagnostic.error(
                    name.span, "dictionary does not contain key \(Str(key).repr())"))
            }
            try destructureImpl(&vm, pattern: named.pattern(), value: v, f)
            used.insert(key)
        case .spread(let spread):
            sink = spread.sinkExpr()
        case .pattern(let expr):
            throw SourceDiagnostics(SourceDiagnostic.error(
                expr.span, "cannot destructure unnamed pattern from dictionary"))
        }
    }

    if let expr = sink {
        var sinkDict = Dict()
        for (key, value) in dict.pairs where !used.contains(key.value) {
            sinkDict.insert(key, value)
        }
        try f(&vm, expr, .dict(sinkDict))
    }
}

/// The error message when the number of elements of the destructuring
/// and the array is mismatched. Port of `wrong_number_of_elements`.
private func wrongNumberOfElements(
    _ destruct: TypstSyntax.Destructuring, len: Int
) -> SourceDiagnostics {
    var count = 0
    var spread = false

    for item in destruct.items() {
        switch item {
        case .pattern: count += 1
        case .spread: spread = true
        case .named: break
        }
    }

    let quantifier = len > count ? "too many" : "not enough"
    let expected: String
    switch (spread, count) {
    case (true, 1): expected = "at least 1 element"
    case (true, let c): expected = "at least \(c) elements"
    case (false, 0): expected = "an empty array"
    case (false, 1): expected = "a single element"
    case (false, let c): expected = "\(c) elements"
    }

    var diagnostic = SourceDiagnostic.error(
        destruct.span,
        "\(quantifier) elements to destructure")
    diagnostic.hint(
        "the provided array has a length of \(len), but the pattern expects \(expected)")
    return SourceDiagnostics(diagnostic)
}
