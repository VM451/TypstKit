import Foundation
import TypstSyntax

/// Value operators. Port of `ops.rs`.

/// Test for containment (`in` operator).
func ops_contains(guard access: any BindingGuard, lhs: Value, rhs: Value) -> Bool? {
    switch (lhs, rhs) {
    case let (.str(a), .str(b)): return b.value.contains(a.value)
    case let (.dynamic(a), .str(b)):
        if let regex = a.downcast(Regex.self) { return regex.isMatch(b.value) }
        return nil
    case let (.str(a), .dict(b)): return b.contains(a.value)
    case let (.str(a), .module(b)):
        guard let binding = b.scope.get(a.value) else { return false }
        return (try? binding.read(access).get()) != nil
    case let (a, .array(b)): return b.contains(a)
    default: return nil
    }
}

/// Equality. Port of `equal` in `ops.rs`.
func ops_equal(_ lhs: Value, _ rhs: Value) -> Bool {
    switch (lhs, rhs) {
    case (.none, .none), (.auto, .auto): return true
    case let (.bool(a), .bool(b)): return a == b
    case let (.int(a), .int(b)): return a == b
    case let (.float(a), .float(b)): return a == b
    case let (.decimal(a), .decimal(b)): return a == b
    case let (.length(a), .length(b)): return a == b
    case let (.angle(a), .angle(b)): return a == b
    case let (.ratio(a), .ratio(b)): return a == b
    case let (.relative(a), .relative(b)): return a == b
    case let (.fraction(a), .fraction(b)): return a == b
    case let (.color(a), .color(b)): return a == b
    case let (.gradient(a), .gradient(b)): return a == b
    case let (.tiling(a), .tiling(b)): return a == b
    case let (.symbol(a), .symbol(b)): return a == b
    case let (.version(a), .version(b)): return a == b
    case let (.str(a), .str(b)): return a == b
    case let (.bytes(a), .bytes(b)): return a == b
    case let (.label(a), .label(b)): return a == b
    case let (.content(a), .content(b)): return a == b
    case let (.array(a), .array(b)): return a == b
    case let (.dict(a), .dict(b)): return a == b
    case let (.function(a), .function(b)): return a == b
    case let (.arguments(a), .arguments(b)): return a == b
    case let (.type(a), .type(b)): return a == b
    case let (.module(a), .module(b)): return a == b
    case let (.datetime(a), .datetime(b)): return a == b
    case let (.duration(a), .duration(b)): return a == b
    case let (.dynamic(a), .dynamic(b)): return a == b

    // Technically different things that compare equal.
    case let (.int(i), .float(f)), let (.float(f), .int(i)):
        return Double(i) == f
    case let (.int(i), .decimal(d)), let (.decimal(d), .int(i)):
        return Decimal(i) == d
    case let (.length(len), .relative(rel)), let (.relative(rel), .length(len)):
        return len == rel.abs && rel.rel.isZero()
    case let (.ratio(rat), .relative(rel)), let (.relative(rel), .ratio(rat)):
        return rat == rel.rel && rel.abs == .zero
    default: return false
    }
}

/// Three-way comparison. Port of `compare` in `ops.rs`.
func ops_compare(_ lhs: Value, _ rhs: Value) -> StrResult<ComparisonResult> {
    switch (lhs, rhs) {
    case let (.bool(a), .bool(b)):
        return .success(ord3(a, b))
    case let (.int(a), .int(b)):
        return .success(a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame)
    case let (.float(a), .float(b)):
        guard let o = partialCmp(a, b) else {
            return .failure(StrError("cannot compare \(a.repr()) with \(b.repr())"))
        }
        return .success(o)
    case let (.decimal(a), .decimal(b)):
        return .success(a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame)
    case let (.length(a), .length(b)):
        guard let o = partialCmp(a, b) else {
            return .failure(StrError("cannot compare \(a.repr()) with \(b.repr())"))
        }
        return .success(o)
    case let (.angle(a), .angle(b)):
        return .success(a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame)
    case let (.ratio(a), .ratio(b)):
        return .success(a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame)
    case let (.relative(a), .relative(b)):
        guard let o = partialCmp(a, b) else {
            return .failure(StrError("cannot compare \(a.repr()) with \(b.repr())"))
        }
        return .success(o)
    case let (.fraction(a), .fraction(b)):
        return .success(a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame)
    case let (.version(a), .version(b)):
        return .success(a.cmp(b))
    case let (.str(a), .str(b)):
        return .success(a.value < b.value ? .orderedAscending
                        : a.value > b.value ? .orderedDescending : .orderedSame)

    // Technically different things that are comparable.
    case let (.int(a), .float(b)): return ops_compare(.float(Double(a)), .float(b))
    case let (.float(a), .int(b)): return ops_compare(.float(a), .float(Double(b)))
    case let (.int(a), .decimal(b)): return ops_compare(.decimal(Decimal(a)), .decimal(b))
    case let (.decimal(a), .int(b)): return ops_compare(.decimal(a), .decimal(Decimal(b)))
    case let (.length(a), .relative(b)) where b.rel.isZero():
        return ops_compare(.length(a), .length(b.abs))
    case let (.ratio(a), .relative(b)) where b.abs == .zero:
        return .success(a < b.rel ? .orderedAscending : a > b.rel ? .orderedDescending : .orderedSame)
    case let (.relative(a), .length(b)) where a.rel.isZero():
        return ops_compare(.length(a.abs), .length(b))
    case let (.relative(a), .ratio(b)) where a.abs == .zero:
        return .success(a.rel < b ? .orderedAscending : a.rel > b ? .orderedDescending : .orderedSame)

    case let (.duration(a), .duration(b)):
        return .success(a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame)
    case let (.datetime(a), .datetime(b)):
        guard let o = a.partialCmpDatetime(b) else {
            return .failure(StrError("cannot compare \(a.kind) and \(b.kind)"))
        }
        return .success(o)
    case let (.array(a), .array(b)):
        for (x, y) in zip(a.items, b.items) {
            switch ops_compare(x, y) {
            case let .success(o) where o != .orderedSame: return .success(o)
            case .success: continue
            case let .failure(e): return .failure(e)
            }
        }
        return .success(a.items.count < b.items.count ? .orderedAscending
                        : a.items.count > b.items.count ? .orderedDescending : .orderedSame)
    default:
        return .failure(StrError("cannot compare \(lhs.type) and \(rhs.type)"))
    }
}

/// Three-way ordering for `Comparable` types, `nil` when incomparable
/// (e.g. NaN).
private func partialCmp<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult? {
    if a == b { return .orderedSame }
    if a < b { return .orderedAscending }
    if b < a { return .orderedDescending }
    return nil
}

/// Three-way ordering for Bool (false < true).
private func ord3(_ a: Bool, _ b: Bool) -> ComparisonResult {
    a == b ? .orderedSame : (!a && b ? .orderedAscending : .orderedDescending)
}

/// Build an upstream `mismatch!`-style error: literal template with
/// `{0}`/`{1}` placeholders replaced by the values' type names
/// (upstream passes `value.ty()` to `eco_format!`).
private func mismatch(_ fmt: String, _ args: Value...) -> HintedStrResult<Value> {
    var msg = fmt
    for (i, arg) in args.enumerated() {
        msg = msg.replacingOccurrences(of: "{\(i)}", with: "\(arg.type)")
    }
    return .failure(HintedString(msg))
}

private func tooLarge() -> HintedString { HintedString("value is too large") }

private func isZero(_ v: Value) -> Bool {
    switch v {
    case let .int(i): return i == 0
    case let .float(f): return f == 0
    case let .decimal(d): return d.isZero
    case let .length(l): return l == .zero
    case let .angle(a): return a == .zero
    case let .ratio(r): return r.isZero()
    case let .relative(r): return r.isZero()
    case let .fraction(f): return f.get == 0
    case let .duration(d): return d.isZero
    default: return false
    }
}

/// `a in b` / `a not in b`.
func ops_in(_ access: any BindingGuard, _ lhs: Value, _ rhs: Value, negate: Bool) -> HintedStrResult<Value> {
    if let b = ops_contains(guard: access, lhs: lhs, rhs: rhs) {
        return .success(.bool(negate ? !b : b))
    }
    return mismatch(negate ? "cannot apply 'not in' to {0} and {1}" : "cannot apply 'in' to {0} and {1}",
                    lhs, rhs)
}

/// Join a value with another value.
///
/// Port of `ops::join` in `ops.rs`.
func ops_join(_ lhs: Value, _ rhs: Value) -> StrResult<Value> {
    switch (lhs, rhs) {
    case let (a, .none): return .success(a)
    case let (.none, b): return .success(b)
    case let (.symbol(a), .symbol(b)):
        return .success(.str(Str(a.get + b.get)))
    case let (.str(a), .str(b)):
        return .success(.str(Str(a.value + b.value)))
    case let (.str(a), .symbol(b)):
        return .success(.str(Str(a.value + b.get)))
    case let (.symbol(a), .str(b)):
        return .success(.str(Str(a.get + b.value)))
    case let (.bytes(a), .bytes(b)):
        return .success(.bytes(Bytes(a.storage + b.storage)))
    case let (.content(a), .content(b)):
        return .success(.content(a + b))
    case let (.content(a), .symbol(b)):
        return .success(.content(a + SymbolElem.packed(b.get)))
    case let (.content(a), .str(b)):
        return .success(.content(a + TextElem.packed(b.value)))
    case let (.str(a), .content(b)):
        return .success(.content(TextElem.packed(a.value) + b))
    case let (.symbol(a), .content(b)):
        return .success(.content(SymbolElem.packed(a.get) + b))
    case let (.array(a), .array(b)):
        return .success(.array(a + b))
    case let (.dict(a), .dict(b)):
        return .success(.dict(a.merged(with: b)))
    case let (.arguments(a), .arguments(b)):
        return .success(.arguments(a + b))
    default:
        return .failure(StrError(
            "cannot join \(lhs.type) with \(rhs.type)"))
    }
}

/// The `+` operator.
func ops_add(_ lhs: Value, _ rhs: Value) -> HintedStrResult<Value> {
    switch (lhs, rhs) {
    case let (a, .none): return .success(a)
    case let (.none, b): return .success(b)

    case let (.int(a), .int(b)):
        let (r, o) = a.addingReportingOverflow(b)
        return o ? .failure(tooLarge()) : .success(.int(r))
    case let (.int(a), .float(b)): return .success(.float(Double(a) + b))
    case let (.float(a), .int(b)): return .success(.float(a + Double(b)))
    case let (.float(a), .float(b)): return .success(.float(a + b))

    case let (.decimal(a), .decimal(b)): return .success(.decimal(a + b))
    case let (.decimal(a), .int(b)): return .success(.decimal(a + Decimal(b)))
    case let (.int(a), .decimal(b)): return .success(.decimal(Decimal(a) + b))

    case let (.angle(a), .angle(b)): return .success(.angle(a + b))

    case let (.length(a), .length(b)): return .success(.length(a + b))
    case let (.length(a), .ratio(b)): return .success(.relative(b + a))
    case let (.length(a), .relative(b)): return .success(.relative(b + a))

    case let (.ratio(a), .length(b)): return .success(.relative(a + b))
    case let (.ratio(a), .ratio(b)): return .success(.ratio(a + b))
    case let (.ratio(a), .relative(b)): return .success(.relative(b + a))

    case let (.relative(a), .length(b)): return .success(.relative(a + b))
    case let (.relative(a), .ratio(b)): return .success(.relative(a + b))
    case let (.relative(a), .relative(b)): return .success(.relative(a + b))

    case let (.fraction(a), .fraction(b)): return .success(.fraction(a + b))

    case let (.symbol(a), .symbol(b)): return .success(.str(Str(a.get + b.get)))
    case let (.str(a), .str(b)): return .success(.str(Str(a.value + b.value)))
    case let (.str(a), .symbol(b)): return .success(.str(Str(a.value + b.get)))
    case let (.symbol(a), .str(b)): return .success(.str(Str(a.get + b.value)))
    case let (.bytes(a), .bytes(b)): return .success(.bytes(Bytes(a.storage + b.storage)))
    case let (.content(a), .content(b)): return .success(.content(a + b))
    case let (.content(a), .symbol(b)): return .success(.content(a + SymbolElem.packed(b.get)))
    case let (.content(a), .str(b)): return .success(.content(a + TextElem.packed(b.value)))
    case let (.str(a), .content(b)): return .success(.content(TextElem.packed(a.value) + b))
    case let (.symbol(a), .content(b)): return .success(.content(SymbolElem.packed(a.get) + b))

    case let (.array(a), .array(b)): return .success(.array(ArrayValue(a.items + b.items)))
    case let (.dict(a), .dict(b)): return .success(.dict(a.merged(with: b)))
    case let (.arguments(a), .arguments(b)): return .success(.arguments(a + b))

    case let (.color(color), .length(thickness)), let (.length(thickness), .color(color)):
        return .success(.dynamic(Stroke(color: color, thickness: thickness)))
    case let (.gradient(g), .length(thickness)), let (.length(thickness), .gradient(g)):
        return .success(.dynamic(Stroke(gradient: g, thickness: thickness)))
    case let (.tiling(t), .length(thickness)), let (.length(thickness), .tiling(t)):
        return .success(.dynamic(Stroke(tiling: t, thickness: thickness)))

    case let (.duration(a), .duration(b)): return .success(.duration(a + b))
    case let (.datetime(a), .duration(b)):
        return a.adding(b).map { .datetime($0) }.mapError { HintedString($0.message) }
    case let (.duration(a), .datetime(b)):
        return b.adding(a).map { .datetime($0) }.mapError { HintedString($0.message) }

    case let (.dynamic(a), .dynamic(b)):
        if let x = a.downcast(Alignment.self), let y = b.downcast(Alignment.self) {
            switch x + y {
            case let .success(r): return .success(.dynamic(r))
            case let .failure(e): return .failure(HintedString(e.message))
            }
        }
        return mismatch("cannot add {0} and {1}", .dynamic(a), .dynamic(b))
    default:
        return mismatch("cannot add {0} and {1}", lhs, rhs)
    }
}

/// The `-` operator.
func ops_sub(_ lhs: Value, _ rhs: Value) -> HintedStrResult<Value> {
    switch (lhs, rhs) {
    case let (.int(a), .int(b)):
        let (r, o) = a.subtractingReportingOverflow(b)
        return o ? .failure(tooLarge()) : .success(.int(r))
    case let (.int(a), .float(b)): return .success(.float(Double(a) - b))
    case let (.float(a), .int(b)): return .success(.float(a - Double(b)))
    case let (.float(a), .float(b)): return .success(.float(a - b))

    case let (.decimal(a), .decimal(b)): return .success(.decimal(a - b))
    case let (.decimal(a), .int(b)): return .success(.decimal(a - Decimal(b)))
    case let (.int(a), .decimal(b)): return .success(.decimal(Decimal(a) - b))

    case let (.angle(a), .angle(b)): return .success(.angle(a - b))

    case let (.length(a), .length(b)): return .success(.length(a - b))
    case let (.length(a), .ratio(b)): return .success(.relative((-b) + a))
    case let (.length(a), .relative(b)): return .success(.relative((-b) + a))

    case let (.ratio(a), .length(b)): return .success(.relative(a + (-b)))
    case let (.ratio(a), .ratio(b)): return .success(.ratio(a - b))
    case let (.ratio(a), .relative(b)): return .success(.relative((-b) + a))

    case let (.relative(a), .length(b)): return .success(.relative(a + (-b)))
    case let (.relative(a), .ratio(b)): return .success(.relative(a + (-b)))
    case let (.relative(a), .relative(b)): return .success(.relative(a - b))

    case let (.fraction(a), .fraction(b)): return .success(.fraction(a - b))

    case let (.duration(a), .duration(b)): return .success(.duration(a - b))
    case let (.datetime(a), .duration(b)):
        return a.subtracting(b).map { .datetime($0) }.mapError { HintedString($0.message) }
    case let (.datetime(a), .datetime(b)):
        return a.subtracting(b).map { .duration($0) }.mapError { HintedString($0.message) }
    default:
        return mismatch("cannot subtract {1} from {0}", lhs, rhs)
    }
}

/// The `*` operator.
func ops_mul(_ lhs: Value, _ rhs: Value) -> HintedStrResult<Value> {
    switch (lhs, rhs) {
    case let (.int(a), .int(b)):
        let (r, o) = a.multipliedReportingOverflow(by: b)
        return o ? .failure(tooLarge()) : .success(.int(r))
    case let (.int(a), .float(b)): return .success(.float(Double(a) * b))
    case let (.float(a), .int(b)): return .success(.float(a * Double(b)))
    case let (.float(a), .float(b)): return .success(.float(a * b))

    case let (.decimal(a), .decimal(b)): return .success(.decimal(a * b))
    case let (.decimal(a), .int(b)): return .success(.decimal(a * Decimal(b)))
    case let (.int(a), .decimal(b)): return .success(.decimal(Decimal(a) * b))

    case let (.length(a), .int(b)): return .success(.length(a * Double(b)))
    case let (.length(a), .float(b)): return .success(.length(a * b))
    case let (.length(a), .ratio(b)): return .success(.length(a * b.get))
    case let (.int(a), .length(b)): return .success(.length(b * Double(a)))
    case let (.float(a), .length(b)): return .success(.length(b * a))
    case let (.ratio(a), .length(b)): return .success(.length(b * a.get))

    case let (.angle(a), .int(b)): return .success(.angle(a * Double(b)))
    case let (.angle(a), .float(b)): return .success(.angle(a * b))
    case let (.angle(a), .ratio(b)): return .success(.angle(a * b.get))
    case let (.int(a), .angle(b)): return .success(.angle(b * Double(a)))
    case let (.float(a), .angle(b)): return .success(.angle(b * a))
    case let (.ratio(a), .angle(b)): return .success(.angle(b * a.get))

    case let (.ratio(a), .ratio(b)): return .success(.ratio(a * b))
    case let (.ratio(a), .int(b)): return .success(.ratio(a * Double(b)))
    case let (.ratio(a), .float(b)): return .success(.ratio(a * b))
    case let (.int(a), .ratio(b)): return .success(.ratio(b * Double(a)))
    case let (.float(a), .ratio(b)): return .success(.ratio(b * a))

    case let (.relative(a), .int(b)): return .success(.relative(a * Double(b)))
    case let (.relative(a), .float(b)): return .success(.relative(a * b))
    case let (.relative(a), .ratio(b)): return .success(.relative(a * b.get))
    case let (.int(a), .relative(b)): return .success(.relative(b * Double(a)))
    case let (.float(a), .relative(b)): return .success(.relative(b * a))
    case let (.ratio(a), .relative(b)): return .success(.relative(b * a.get))

    case let (.fraction(a), .int(b)): return .success(.fraction(a * Double(b)))
    case let (.fraction(a), .float(b)): return .success(.fraction(a * b))
    case let (.fraction(a), .ratio(b)): return .success(.fraction(a * b.get))
    case let (.int(a), .fraction(b)): return .success(.fraction(b * Double(a)))
    case let (.float(a), .fraction(b)): return .success(.fraction(b * a))
    case let (.ratio(a), .fraction(b)): return .success(.fraction(b * a.get))

    case let (.str(a), .int(b)):
        return a.repeated(Int(b)).map { .str($0) }.mapError { HintedString($0.message) }
    case let (.int(a), .str(b)):
        return b.repeated(Int(a)).map { .str($0) }.mapError { HintedString($0.message) }
    case let (.array(a), .int(b)):
        return a.repeat(Int(b)).map { .array($0) }.mapError { HintedString($0.message) }
    case let (.int(a), .array(b)):
        return b.repeat(Int(a)).map { .array($0) }.mapError { HintedString($0.message) }
    case let (.content(a), .int(b)):
        return a.repeat(times: Int(b)).map { .content($0) }.mapError { HintedString($0.message) }
    case let (.int(a), .content(b)):
        return b.repeat(times: Int(a)).map { .content($0) }.mapError { HintedString($0.message) }

    case let (.int(a), .duration(b)): return .success(.duration(b * Double(a)))
    case let (.float(a), .duration(b)): return .success(.duration(b * a))
    case let (.duration(a), .int(b)): return .success(.duration(a * Double(b)))
    case let (.duration(a), .float(b)): return .success(.duration(a * b))
    default:
        return mismatch("cannot multiply {0} with {1}", lhs, rhs)
    }
}

/// The `/` operator.
func ops_div(_ lhs: Value, _ rhs: Value) -> HintedStrResult<Value> {
    if isZero(rhs) {
        return .failure(HintedString("cannot divide by zero"))
    }
    switch (lhs, rhs) {
    case let (.int(a), .int(b)): return .success(.float(Double(a) / Double(b)))
    case let (.int(a), .float(b)): return .success(.float(Double(a) / b))
    case let (.float(a), .int(b)): return .success(.float(a / Double(b)))
    case let (.float(a), .float(b)): return .success(.float(a / b))

    case let (.decimal(a), .decimal(b)): return .success(.decimal(a / b))
    case let (.decimal(a), .int(b)): return .success(.decimal(a / Decimal(b)))
    case let (.int(a), .decimal(b)): return .success(.decimal(Decimal(a) / b))

    case let (.length(a), .int(b)): return .success(.length(a / Double(b)))
    case let (.length(a), .float(b)): return .success(.length(a / b))
    case let (.length(a), .length(b)):
        guard let r = a.tryDiv(b) else {
            return .failure(HintedString("cannot divide these two lengths"))
        }
        return .success(.float(r))
    case let (.length(a), .relative(b)) where b.rel.isZero():
        guard let r = a.tryDiv(b.abs) else {
            return .failure(HintedString("cannot divide these two lengths"))
        }
        return .success(.float(r))

    case let (.angle(a), .int(b)): return .success(.angle(a / Double(b)))
    case let (.angle(a), .float(b)): return .success(.angle(a / b))
    case let (.angle(a), .angle(b)): return .success(.float(a / b))

    case let (.ratio(a), .int(b)): return .success(.ratio(a / Double(b)))
    case let (.ratio(a), .float(b)): return .success(.ratio(a / b))
    case let (.ratio(a), .ratio(b)): return .success(.float(a / b))
    case let (.ratio(a), .relative(b)) where b.abs == .zero:
        return .success(.float(a / b.rel))

    case let (.relative(a), .int(b)): return .success(.relative(a / Double(b)))
    case let (.relative(a), .float(b)): return .success(.relative(a / b))
    case let (.relative(a), .length(b)) where a.rel.isZero():
        guard let r = a.abs.tryDiv(b) else {
            return .failure(HintedString("cannot divide these two lengths"))
        }
        return .success(.float(r))
    case let (.relative(a), .ratio(b)) where a.abs == .zero:
        return .success(.float(a.rel / b))
    case let (.relative(a), .relative(b)):
        guard let r = a.tryDiv(b) else {
            return .failure(HintedString("cannot divide these two relative lengths"))
        }
        return .success(.float(r))

    case let (.fraction(a), .int(b)): return .success(.fraction(a / Double(b)))
    case let (.fraction(a), .float(b)): return .success(.fraction(a / b))
    case let (.fraction(a), .fraction(b)): return .success(.float(a / b))

    case let (.duration(a), .int(b)): return .success(.duration(a / Double(b)))
    case let (.duration(a), .float(b)): return .success(.duration(a / b))
    case let (.duration(a), .duration(b)): return .success(.float(a / b))
    default:
        return mismatch("cannot divide {0} by {1}", lhs, rhs)
    }
}

/// Logical `not`.
func ops_not(_ value: Value) -> HintedStrResult<Value> {
    switch value {
    case let .bool(b): return .success(.bool(!b))
    default: return mismatch("cannot apply 'not' to {0}", value)
    }
}

/// Logical `and`.
func ops_and(_ lhs: Value, _ rhs: Value) -> HintedStrResult<Value> {
    guard case let .bool(a) = lhs, case let .bool(b) = rhs else {
        return mismatch("cannot apply 'and' to {0} and {1}", lhs, rhs)
    }
    return .success(.bool(a && b))
}

/// Logical `or`.
func ops_or(_ lhs: Value, _ rhs: Value) -> HintedStrResult<Value> {
    guard case let .bool(a) = lhs, case let .bool(b) = rhs else {
        return mismatch("cannot apply 'or' to {0} and {1}", lhs, rhs)
    }
    return .success(.bool(a || b))
}

/// `==`.
func ops_eq(_ lhs: Value, _ rhs: Value) -> HintedStrResult<Value> {
    .success(.bool(ops_equal(lhs, rhs)))
}

/// `!=`.
func ops_neq(_ lhs: Value, _ rhs: Value) -> HintedStrResult<Value> {
    .success(.bool(!ops_equal(lhs, rhs)))
}

func ops_lt(_ lhs: Value, _ rhs: Value) -> HintedStrResult<Value> {
    ops_compare(lhs, rhs)
        .map { .bool($0 == .orderedAscending) }
        .mapError { HintedString($0.message) }
}
func ops_leq(_ lhs: Value, _ rhs: Value) -> HintedStrResult<Value> {
    ops_compare(lhs, rhs)
        .map { .bool($0 != .orderedDescending) }
        .mapError { HintedString($0.message) }
}
func ops_gt(_ lhs: Value, _ rhs: Value) -> HintedStrResult<Value> {
    ops_compare(lhs, rhs)
        .map { .bool($0 == .orderedDescending) }
        .mapError { HintedString($0.message) }
}
func ops_geq(_ lhs: Value, _ rhs: Value) -> HintedStrResult<Value> {
    ops_compare(lhs, rhs)
        .map { .bool($0 != .orderedAscending) }
        .mapError { HintedString($0.message) }
}

/// Unary `+`.
func ops_pos(_ value: Value) -> HintedStrResult<Value> {
    switch value {
    case .int, .float, .decimal, .length, .angle, .ratio, .relative, .fraction:
        return .success(value)
    case .symbol, .str, .bytes, .content, .array, .dict, .datetime:
        return mismatch("cannot apply unary '+' to {0}", value)
    case let .dynamic(d):
        if d.is(Alignment.self) {
            return mismatch("cannot apply unary '+' to {0}", value)
        }
        return mismatch("cannot apply '+' to {0}", value)
    default:
        return mismatch("cannot apply '+' to {0}", value)
    }
}

/// Unary `-`.
func ops_neg(_ value: Value) -> HintedStrResult<Value> {
    switch value {
    case let .int(v):
        if v == Int64.min { return .failure(tooLarge()) }
        return .success(.int(-v))
    case let .float(v): return .success(.float(-v))
    case let .decimal(v): return .success(.decimal(-v))
    case let .length(v): return .success(.length(-v))
    case let .angle(v): return .success(.angle(-v))
    case let .ratio(v): return .success(.ratio(-v))
    case let .relative(v): return .success(.relative(-v))
    case let .fraction(v): return .success(.fraction(-v))
    case let .duration(v): return .success(.duration(-v))
    case .datetime:
        return mismatch("cannot apply unary '-' to {0}", value)
    default:
        return mismatch("cannot apply '-' to {0}", value)
    }
}
