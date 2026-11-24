import TypstUtils
import Foundation

/// Metadata for a Typst type. Port of `NativeTypeData` in `ty.rs`.
///
/// Upstream generates one `static NativeTypeData` per `#[ty]` type via a
/// proc macro. In Swift, each type exposes a `static let typeInfo` built by
/// `TypeInfo(...)`, and `NativeType` conformance wires it up.
public final class TypeInfo: @unchecked Sendable {
    /// Short name, e.g. `"int"`.
    public let name: String
    /// Long name, e.g. `"integer"`.
    public let longName: String
    /// Title-cased name for documentation, e.g. `"Integer"`.
    public let title: String
    /// The version the type was introduced in.
    public let since: Since?
    /// Documentation string.
    public let docs: String
    /// Definition site for IDE tooling.
    public let defSite: DefSite?
    /// Search keywords.
    public let keywords: [String]
    /// Lazily-built constructor function, if the type is constructible.
    public let constructor: () -> Func?
    /// Lazily-built associated scope (static methods/constants).
    public let scopeBuilder: () -> Scope
    /// Cached scope (built on first access).
    private var scopeStorage: Scope?
    private let scopeLock = NSLock()

    public init(
        name: String,
        longName: String? = nil,
        title: String? = nil,
        since: Since? = nil,
        docs: String = "",
        defSite: DefSite? = nil,
        keywords: [String] = [],
        constructor: @escaping () -> Func? = { nil },
        scope: @escaping () -> Scope = { Scope() }
    ) {
        self.name = name
        self.longName = longName ?? name
        self.title = title ?? name.prefix(1).uppercased() + name.dropFirst()
        self.since = since
        self.docs = docs
        self.defSite = defSite
        self.keywords = keywords
        self.constructor = constructor
        self.scopeBuilder = scope
    }

    /// The type's associated scope, built lazily.
    public func scope() -> Scope {
        scopeLock.lock()
        defer { scopeLock.unlock() }
        if let scopeStorage { return scopeStorage }
        let scope = scopeBuilder()
        scopeStorage = scope
        return scope
    }
}

/// A Typst type value (`int`, `str`, ...). Port of `Type` in `ty.rs`.
public struct Type: Sendable {
    /// The underlying type metadata. Identity is by object identity of the
    /// `TypeInfo`, matching upstream's `Static<NativeTypeData>` pointer eq.
    public let info: TypeInfo

    public init(_ info: TypeInfo) {
        self.info = info
    }
}

extension Type: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(info))
    }

    public static func == (lhs: Type, rhs: Type) -> Bool {
        lhs.info === rhs.info
    }
}

extension Type: Comparable {
    /// Types order by long name, matching upstream `Ord`.
    public static func < (lhs: Type, rhs: Type) -> Bool {
        lhs.info.longName < rhs.info.longName
    }
}

extension Type: CustomStringConvertible {
    public var description: String { info.longName }
}

extension Type: Repr {
    public func repr() -> String {
        if self == Type.of(AutoValue.self) {
            return "type(auto)"
        } else if self == Type.of(NoneValue.self) {
            return "type(none)"
        }
        return info.name
    }
}

extension Type {
    /// The type of a `NativeType`.
    public static func of<T: NativeType>(_ type: T.Type = T.self) -> Type {
        Type(T.typeInfo)
    }

    /// Short name (`"int"`).
    public var shortName: String { info.name }

    /// Long name (`"integer"`).
    public var longName: String { info.longName }

    /// Title-cased name.
    public var title: String { info.title }

    /// When the type was introduced.
    public var since: Since? { info.since }

    /// Documentation.
    public var docs: String { info.docs }

    /// Definition site.
    public var defSite: DefSite? { info.defSite }

    /// Keywords.
    public var keywords: [String] { info.keywords }

    /// The constructor function, if any.
    public func constructor() -> StrResult<Func> {
        if let f = info.constructor() { return .success(f) }
        return .failure(StrError("type \(self) does not have a constructor"))
    }

    /// The associated scope.
    public func scope() -> Scope { info.scope() }

    /// Look up a field (static method/constant) on the type.
    public func field(_ field: String, guard access: any BindingGuard) -> HintedStrResult<Value> {
        guard let binding = scope().get(field) else {
            return .failure(HintedString("type \(self) does not contain field `\(field)`"))
        }
        switch binding.read(access) {
        case let .success(value): return .success(value)
        case let .failure(error): return .failure(error.cannot("access field `\(field)` on type \(self)"))
        }
    }
}

/// Types that carry Typst type metadata. Port of `NativeType`.
public protocol NativeType: Sendable {
    /// The type's metadata.
    static var typeInfo: TypeInfo { get }
}

extension NativeType {
    /// The `Type` for this native type.
    public static var typstType: Type { Type(typeInfo) }
}

/// Helper to build a `TypeInfo` with sensible defaults.
public func typeInfo(
    _ name: String,
    longName: String? = nil,
    title: String? = nil,
    since: Since? = nil,
    docs: String = "",
    keywords: [String] = [],
    constructor: @escaping () -> Func? = { nil },
    scope: @escaping () -> Scope = { Scope() }
) -> TypeInfo {
    TypeInfo(
        name: name,
        longName: longName,
        title: title,
        since: since,
        docs: docs,
        keywords: keywords,
        constructor: constructor,
        scope: scope
    )
}
