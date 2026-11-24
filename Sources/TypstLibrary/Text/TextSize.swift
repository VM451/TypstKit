import TypstUtils

/// A text size that can be relative (em) or absolute.
///
/// Port of `TextSize` in `text/mod.rs`. Nested `text(size: ..)` set rules
/// multiply the two linear functions rather than overriding.
public struct TextSize: Numeric, NumericLength, Sendable, Hashable {
    /// The wrapped length (upstream tuple field `.0`).
    public var inner: Length

    public init(_ inner: Length) { self.inner = inner }
    public init(_ abs: Abs) { self.init(Length(abs: abs, em: .zero)) }

    public static let `default` = TextSize(Abs.pt(11.0))

    public static var numericZero: TextSize { TextSize(Length.zero) }
    public var isFinite: Bool { inner.isFinite }
    public func multiplied(by factor: Double) -> TextSize { TextSize(inner * factor) }
    public func added(to other: TextSize) -> TextSize { TextSize(inner + other.inner) }
}

extension TextSize: CustomDebugStringConvertible {
    public var debugDescription: String { "TextSize(\(inner))" }
}

extension TextSize: Repr {
    public func repr() -> String { inner.repr() }
}

extension TextSize: Fold {
    /// Multiply the two linear functions (upstream `Fold for TextSize`).
    /// `inner` is the inner style value, `outer` the outer one.
    public static func fold(_ inner: Self, _ outer: Self) -> Self {
        TextSize(Length(
            abs: inner.inner.em.at(outer.inner.abs) + inner.inner.abs,
            em: inner.inner.em * outer.inner.em.get
        ))
    }
}

extension TextSize: Resolve {
    public typealias Output = Abs
    public func resolve(_ styles: StyleChain) -> Abs {
        inner.resolve(styles)
    }
}

extension TextSize: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Length.self)) }
    public static var output: CastInfo { .type(Type.of(Length.self)) }
    public static func castable(_ value: Value) -> Bool {
        if case .length = value { return true }
        return false
    }
    public func intoValue() -> Value { .length(inner) }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .length(v) = value else { return .failure(error(value)) }
        return .success(TextSize(v))
    }
}

extension StyleChain {
    /// The text size with `#[fold]` semantics applied.
    ///
    /// Port of `styles.resolve(TextElem::size)`: collects all `size`
    /// properties innermost→outermost, folds them, then folds the result
    /// with the default as the outermost value.
    public func textSize() -> Abs {
        textSizeValue().resolve(self)
    }

    /// The folded `TextSize` style value (unresolved).
    public func textSizeValue() -> TextSize {
        var acc: TextSize?
        for property in properties(Element(TextElem.self), TextElem.sizeFieldID) {
            guard case .success(let value) = TextSize.fromValue(property.value)
            else { continue }
            if let inner = acc {
                acc = TextSize.fold(inner, value)
            } else {
                acc = value
            }
        }
        guard let folded = acc else { return .default }
        return TextSize.fold(folded, .default)
    }
}
