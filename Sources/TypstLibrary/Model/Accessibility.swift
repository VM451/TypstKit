import Foundation
import TypstSyntax
import TypstUtils

// Accessibility elements from upstream `model/accessibility.rs`.
// These are internal realization helpers — upstream does not register
// them in the global scope, so this port doesn't either.

/// The kind of artifact content represents.
///
/// Port of `ArtifactKind` in `model/accessibility.rs`.
public enum ArtifactKind: String, Sendable, Hashable, CaseIterable {
    case header
    case footer
    case watermark
    case pageNumber = "page-number"
    case lineNumber = "line-number"
    case redaction
    case bates
    case page
    case paginationOther = "pagination-other"
    case layout
    case background
    case other
}

extension ArtifactKind: Default {
    public static var `default`: ArtifactKind { .other }
}

extension ArtifactKind: Castable, IntoValue, FromValue {
    public static var input: CastInfo {
        .union(allCases.map { .value(.str(Str($0.rawValue)), doc: "") })
    }
    public static var output: CastInfo { input }
    public static func castable(_ value: Value) -> Bool {
        guard case let .str(s) = value else { return false }
        return ArtifactKind(rawValue: s.value) != nil
    }
    public func intoValue() -> Value { .str(Str(rawValue)) }
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .str(s) = value,
              let v = ArtifactKind(rawValue: s.value) else {
            return .failure(error(value))
        }
        return .success(v)
    }
}

/// Content that should be hidden from assistive technology.
///
/// Port of `ArtifactElem` in `model/accessibility.rs`.
public struct ArtifactElem: NativeElement {
    public static let info = ElementInfo(
        name: "artifact",
        title: "Artifact",
        fields: [
            FieldInfo(id: 0, name: "kind", settable: true),
            FieldInfo(id: 1, name: "body", required: true),
        ],
        capabilities: [.tagged]
    )

    /// The kind of artifact.
    public var kind: ArtifactKind = .other
    /// The artifact's content.
    public var body: Content

    public var span: Span = .detached

    public init(kind: ArtifactKind = .other, body: Content) {
        self.kind = kind
        self.body = body
    }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return kind.intoValue()
        case 1: return body.intoValue()
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch id {
        case 0: kind = try ArtifactKind.fromValue(value).get()
        default: break
        }
    }

    public static func construct(engine: inout Engine, args: inout Args) throws -> Content {
        var elem = ArtifactElem(
            kind: try args.namedT("kind") ?? .other,
            body: try args.expectT("body")
        )
        elem.span = args.span
        try args.finishT()
        return Content(elem)
    }
}
