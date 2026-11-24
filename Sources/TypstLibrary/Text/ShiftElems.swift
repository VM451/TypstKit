import Foundation
import TypstSyntax
import TypstUtils

// Sub/superscript and smallcaps elements from upstream
// `text/{shift,smallcaps}.rs`.

/// Subscript text.
///
/// Port of `SubElem` in `text/shift.rs`.
public struct SubElem: NativeElement {
    public static let info = ElementInfo(
        name: "sub",
        title: "Subscript",
        fields: [
            FieldInfo(id: 0, name: "typographic", settable: true),
            FieldInfo(id: 1, name: "baseline", settable: true),
            FieldInfo(id: 2, name: "size", settable: true),
            FieldInfo(id: 3, name: "body", required: true),
        ],
        capabilities: [.tagged]
    )

    /// Whether to use font-dependent subscript metrics.
    public var typographic: Bool = true
    /// The subscript's baseline shift.
    public var baseline: Smart<Length> = .auto
    /// The subscript's text size.
    public var size: Smart<TextSize> = .auto
    /// The content to subscript.
    public var body: Content

    public var span: Span = .detached

    public init(typographic: Bool = true,
                baseline: Smart<Length> = .auto,
                size: Smart<TextSize> = .auto,
                body: Content) {
        self.typographic = typographic
        self.baseline = baseline
        self.size = size
        self.body = body
    }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return .bool(typographic)
        case 1: return baseline.intoValue()
        case 2: return size.intoValue()
        case 3: return body.intoValue()
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch id {
        case 0:
            if case .bool(let b) = value { typographic = b }
        case 1: baseline = try Smart<Length>.fromValue(value).get()
        case 2: size = try Smart<TextSize>.fromValue(value).get()
        default: break
        }
    }

    public static func construct(engine: inout Engine, args: inout Args) throws -> Content {
        var elem = SubElem(
            typographic: try args.namedT("typographic") ?? true,
            baseline: try args.namedT("baseline") ?? .auto,
            size: try args.namedT("size") ?? .auto,
            body: try args.expectT("body")
        )
        elem.span = args.span
        try args.finishT()
        return Content(elem)
    }
}

/// Superscript text.
///
/// Port of `SuperElem` in `text/shift.rs`.
public struct SuperElem: NativeElement {
    public static let info = ElementInfo(
        name: "super",
        title: "Superscript",
        fields: [
            FieldInfo(id: 0, name: "typographic", settable: true),
            FieldInfo(id: 1, name: "baseline", settable: true),
            FieldInfo(id: 2, name: "size", settable: true),
            FieldInfo(id: 3, name: "body", required: true),
        ],
        capabilities: [.tagged]
    )

    /// Whether to use font-dependent superscript metrics.
    public var typographic: Bool = true
    /// The superscript's baseline shift.
    public var baseline: Smart<Length> = .auto
    /// The superscript's text size.
    public var size: Smart<TextSize> = .auto
    /// The content to superscript.
    public var body: Content

    public var span: Span = .detached

    public init(typographic: Bool = true,
                baseline: Smart<Length> = .auto,
                size: Smart<TextSize> = .auto,
                body: Content) {
        self.typographic = typographic
        self.baseline = baseline
        self.size = size
        self.body = body
    }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return .bool(typographic)
        case 1: return baseline.intoValue()
        case 2: return size.intoValue()
        case 3: return body.intoValue()
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch id {
        case 0:
            if case .bool(let b) = value { typographic = b }
        case 1: baseline = try Smart<Length>.fromValue(value).get()
        case 2: size = try Smart<TextSize>.fromValue(value).get()
        default: break
        }
    }

    public static func construct(engine: inout Engine, args: inout Args) throws -> Content {
        var elem = SuperElem(
            typographic: try args.namedT("typographic") ?? true,
            baseline: try args.namedT("baseline") ?? .auto,
            size: try args.namedT("size") ?? .auto,
            body: try args.expectT("body")
        )
        elem.span = args.span
        try args.finishT()
        return Content(elem)
    }
}

/// Small capitals text.
///
/// Port of `SmallcapsElem` in `text/smallcaps.rs`.
public struct SmallcapsElem: NativeElement {
    public static let info = ElementInfo(
        name: "smallcaps",
        title: "Small Capitals",
        fields: [
            FieldInfo(id: 0, name: "all", settable: true),
            FieldInfo(id: 1, name: "body", required: true),
        ],
        capabilities: []
    )

    /// Whether all letters are transformed.
    public var all: Bool = false
    /// The content to transform.
    public var body: Content

    public var span: Span = .detached

    public init(all: Bool = false, body: Content) {
        self.all = all
        self.body = body
    }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return .bool(all)
        case 1: return body.intoValue()
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        if id == 0, case .bool(let b) = value { all = b }
    }

    public static func construct(engine: inout Engine, args: inout Args) throws -> Content {
        var elem = SmallcapsElem(
            all: try args.namedT("all") ?? false,
            body: try args.expectT("body")
        )
        elem.span = args.span
        try args.finishT()
        return Content(elem)
    }
}
