import Foundation
import TypstSyntax
import TypstUtils

// Divider from upstream `model/divider.rs`.

/// A horizontal divider line.
///
/// Port of `DividerElem` in `model/divider.rs`.
public struct DividerElem: NativeElement {
    public static let info = ElementInfo(
        name: "divider",
        title: "Divider",
        fields: [],
        capabilities: [.locatable]
    )

    public var span: Span = .detached

    public init() {}

    public func field(_ id: UInt8) -> Value? { nil }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {}

    public static func construct(engine: inout Engine, args: inout Args) throws -> Content {
        var elem = DividerElem()
        elem.span = args.span
        try args.finishT()
        return Content(elem)
    }
}

extension DividerElem: ShowSetCapable {
    /// Port of `ShowSet for Packed<DividerElem>` — spacing above/below and
    /// a thin full-width line stroke.
    public func showSet(styles: StyleChain) -> Styles {
        func prop(_ elem: Element, _ field: UInt8, _ value: Value) -> Style {
            .property(Property(elem: elem, field: field, value: value))
        }
        let blockElem = Element(BlockElem.self)
        let lineElem = Element(LineElem.self)
        let em = { (v: Double) in Length(Em(v)) }
        return Styles([
            prop(blockElem, 8, Smart<Spacing>.custom(.rel(
                Rel<Length>(em(2.0)))).intoValue()),
            prop(blockElem, 9, Smart<Spacing>.custom(.rel(
                Rel<Length>(em(2.0)))).intoValue()),
            prop(lineElem, 2, Rel<Length>(Ratio.one).intoValue()),
            prop(lineElem, 4, Stroke<Length>(
                thickness: .custom(Length(Em(0.05)))
            ).intoValue()),
        ])
    }
}
