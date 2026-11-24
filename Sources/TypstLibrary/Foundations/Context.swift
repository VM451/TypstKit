import Foundation
import TypstSyntax

/// The context in which a function is called: the current location and
/// style chain, if known. Port of `Context` in `context.rs`.
public struct Context: Sendable {
    /// The current location, if inside located content.
    public var location: Location?
    /// The current style chain, if styles are known.
    public var styles: StyleChain?

    public init(location: Location? = nil, styles: StyleChain? = nil) {
        self.location = location
        self.styles = styles
    }

    /// An empty context (neither location nor styles known).
    public static let none = Context()

    /// The current location, or an error explaining context is needed.
    public func requireLocation() -> HintedStrResult<Location> {
        require(location)
    }

    /// The current style chain, or an error explaining context is needed.
    public func requireStyles() -> HintedStrResult<StyleChain> {
        require(styles)
    }

    /// Whether any context information is available.
    public func introspect() -> HintedStrResult<()> {
        require(location.map { _ in () } ?? styles.map { _ in () })
    }
}

private func require<T>(_ value: T?) -> HintedStrResult<T> {
    guard let value else {
        return .failure(HintedString("can only be used when context is known")
            .withHint("try wrapping this in a `context` expression")
            .withHint("the `context` expression should wrap everything that depends on this function"))
    }
    return .success(value)
}

/// Executes a `context` block. Port of `ContextElem` in
/// `foundations/context.rs`.
public struct ContextElem: NativeElement {
    public static let info = ElementInfo(
        name: "context",
        fields: [FieldInfo(id: 0, name: "func", required: true)],
        capabilities: [.locatable]
    )

    /// The function to call with the context.
    public var `func`: Func

    public var span: Span = .detached

    public init(`func`: Func) { self.`func` = `func` }

    /// Pack into content.
    public func pack() -> Content { Content(self) }

    public func field(_ id: UInt8) -> Value? {
        id == 0 ? .function(`func`) : nil
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        guard id == 0, case let .function(f) = value else { return }
        self.`func` = f
    }
}
