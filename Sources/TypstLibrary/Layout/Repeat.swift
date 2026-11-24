import TypstSyntax
import TypstUtils

/// Repeats content to fill the available space.
///
/// Port of `RepeatElem` in `layout/repeat.rs`.
public struct RepeatElem: NativeElement {
    public static let info = ElementInfo(
        name: "repeat",
        title: "Repeat",
        fields: [
            FieldInfo(id: 0, name: "body", required: true),
            FieldInfo(id: 1, name: "gap", settable: true),
            FieldInfo(id: 2, name: "justify", settable: true),
        ],
        capabilities: [.tagged]
    )

    /// The content to repeat.
    public var body: Content = .empty
    /// The gap between each instance of the body.
    public var gap: Length = .zero
    /// Whether to increase the gap to completely fill the available space.
    public var justify: Bool = true

    public var span: Span = .detached

    public init(body: Content, gap: Length = .zero, justify: Bool = true) {
        self.body = body
        self.gap = gap
        self.justify = justify
    }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return body.intoValue()
        case 1: return gap.intoValue()
        case 2: return .bool(justify)
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch (id, value) {
        case (1, .length(let l)): gap = l
        case (2, .bool(let b)): justify = b
        default: break
        }
    }

    public static func construct(engine: inout Engine, args: inout Args) throws -> Content {
        var elem = RepeatElem(
            body: try args.expectT("body"),
            gap: try args.namedT("gap") ?? .zero,
            justify: try args.namedT("justify") ?? true
        )
        elem.span = args.span
        try args.finishT()
        return Content(elem)
    }
}
