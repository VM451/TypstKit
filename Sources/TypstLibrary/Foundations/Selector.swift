import Foundation
import TypstSyntax

/// Selects elements in the document. Port of `Selector` in `selector.rs`.
public indirect enum Selector: Sendable {
    /// An element, optionally with field constraints.
    case elem(Element, fields: [(UInt8, Value)]?)
    /// A unique location.
    case location(Location)
    /// A label.
    case label(Label)
    /// A regex matched against text content.
    case regex(Regex)
    /// Any element that `can` a capability.
    case can(Capabilities)
    /// Union of selectors.
    case or([Selector])
    /// Intersection of selectors.
    case and([Selector])
    /// Elements before another element.
    case before(selector: Selector, end: Selector, inclusive: Bool)
    /// Elements after another element.
    case after(selector: Selector, start: Selector, inclusive: Bool)
    /// Elements within an ancestor.
    case within(selector: Selector, ancestor: Selector)
}

extension Selector {
    /// A text selector (escaped literal → regex).
    public static func text(_ text: String) -> StrResult<Selector> {
        if text.isEmpty {
            return .failure(StrError("text selector is empty"))
        }
        guard let regex = try? Regex(NSRegularExpression.escapedPattern(for: text)) else {
            return .failure(StrError("failed to build text selector"))
        }
        return .success(.regex(regex))
    }

    /// A regex selector.
    public static func regex(_ regex: Regex) -> StrResult<Selector> {
        if regex.pattern.isEmpty {
            return .failure(StrError("regex selector is empty"))
        }
        if regex.isMatch("") {
            return .failure(StrError("regex matches empty text"))
        }
        return .success(.regex(regex))
    }

    /// Whether the selector matches the content (ignoring positional
    /// selectors, matching upstream).
    public func matches(_ target: Content, styles: StyleChain? = nil) -> Bool {
        switch self {
        case let .elem(element, fields):
            guard target.elem == element else { return false }
            guard let fields else { return true }
            return fields.allSatisfy { id, value in
                guard case .success(let v) = target.get(id, styles: styles) else {
                    return false
                }
                return v == value
            }
        case let .label(label):
            return target.label == label
        case let .can(capability):
            return target.elem.can(capability)
        case let .or(selectors):
            return selectors.contains { $0.matches(target, styles: styles) }
        case let .and(selectors):
            return selectors.allSatisfy { $0.matches(target, styles: styles) }
        case let .location(location):
            return target.location == location
        case .regex, .before, .after, .within:
            return false
        }
    }

    /// `selector.or(others...)`.
    public func or(_ others: [Selector]) -> Selector {
        .or(others + [self])
    }

    /// `selector.and(others...)`.
    public func and(_ others: [Selector]) -> Selector {
        .and(others + [self])
    }

    /// `selector.before(end, inclusive:)`.
    public func before(_ end: Selector, inclusive: Bool = true) -> Selector {
        .before(selector: self, end: end, inclusive: inclusive)
    }

    /// `selector.after(start, inclusive:)`.
    public func after(_ start: Selector, inclusive: Bool = true) -> Selector {
        .after(selector: self, start: start, inclusive: inclusive)
    }

    /// `selector.within(ancestor)`.
    public func within(_ ancestor: Selector) -> Selector {
        .within(selector: self, ancestor: ancestor)
    }
}

extension Selector: Repr {
    public func repr() -> String {
        switch self {
        case let .elem(elem, fields):
            if let fields, !fields.isEmpty {
                var pairs: [(String, Value)] = []
                for (id, value) in fields {
                    if let name = elem.fieldName(id) {
                        pairs.append((name, value))
                    }
                }
                let dict = Dict(pairs.map { ($0.0, $0.1) })
                return "\(elem.name).where\(dict.repr())"
            }
            return elem.name
        case .location:
            return "location" // upstream has no literal repr for locations
        case let .label(label):
            return label.repr()
        case let .regex(regex):
            return regex.repr()
        case .can:
            return "can" // capability selectors repr via type
        case let .or(selectors):
            return "\(selectors.map { $0.repr() }.joined(separator: ", "))"
        case let .and(selectors):
            return selectors.map { $0.repr() }.joined(separator: ", ")
        case let .before(selector, end, inclusive):
            return "\(selector.repr()).before(\(end.repr()), inclusive: \(inclusive))"
        case let .after(selector, start, inclusive):
            return "\(selector.repr()).after(\(start.repr()), inclusive: \(inclusive))"
        case let .within(selector, ancestor):
            return "\(selector.repr()).within(\(ancestor.repr()))"
        }
    }
}

/// A selector restricted to locatable targets. Port of
/// `LocatableSelector`.
public struct LocatableSelector: Sendable, Hashable {
    public var selector: Selector

    public init(_ selector: Selector) {
        self.selector = selector
    }
}

/// A selector restricted to showable targets. Port of `ShowableSelector`.
public struct ShowableSelector: Sendable, Hashable {
    public var selector: Selector

    public init(_ selector: Selector) {
        self.selector = selector
    }
}

extension Selector: Hashable {
    public static func == (lhs: Selector, rhs: Selector) -> Bool {
        switch (lhs, rhs) {
        case let (.elem(a1, f1), .elem(a2, f2)):
            return a1 == a2 && Selector.fieldsEqual(f1, f2)
        case let (.location(a), .location(b)): return a == b
        case let (.label(a), .label(b)): return a == b
        case let (.regex(a), .regex(b)):
            return a.pattern == b.pattern && a.expression.options == b.expression.options
        case let (.can(a), .can(b)): return a == b
        case let (.or(a), .or(b)): return a == b
        case let (.and(a), .and(b)): return a == b
        case let (.before(a1, e1, i1), .before(a2, e2, i2)):
            return a1 == a2 && e1 == e2 && i1 == i2
        case let (.after(a1, s1, i1), .after(a2, s2, i2)):
            return a1 == a2 && s1 == s2 && i1 == i2
        case let (.within(a1, an1), .within(a2, an2)):
            return a1 == a2 && an1 == an2
        default: return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case let .elem(element, fields):
            hasher.combine(0); hasher.combine(element)
            hasher.combine(fields?.count ?? -1)
            for (id, value) in fields ?? [] {
                hasher.combine(id); hasher.combine(value)
            }
        case let .location(l): hasher.combine(1); hasher.combine(l)
        case let .label(l): hasher.combine(2); hasher.combine(l)
        case let .regex(r):
            hasher.combine(3); hasher.combine(r.pattern)
            hasher.combine(r.expression.options.rawValue)
        case let .can(c): hasher.combine(4); hasher.combine(c)
        case let .or(sels): hasher.combine(5); hasher.combine(sels)
        case let .and(sels): hasher.combine(6); hasher.combine(sels)
        case let .before(sel, end, incl):
            hasher.combine(7); hasher.combine(sel); hasher.combine(end); hasher.combine(incl)
        case let .after(sel, start, incl):
            hasher.combine(8); hasher.combine(sel); hasher.combine(start); hasher.combine(incl)
        case let .within(sel, anc):
            hasher.combine(9); hasher.combine(sel); hasher.combine(anc)
        }
    }

    /// Field-constraint lists contain `(UInt8, Value)` tuples, which are not
    /// `Equatable` as collection elements — compare pairwise.
    static func fieldsEqual(
        _ a: [(UInt8, Value)]?, _ b: [(UInt8, Value)]?
    ) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?):
            guard x.count == y.count else { return false }
            return zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }
}
