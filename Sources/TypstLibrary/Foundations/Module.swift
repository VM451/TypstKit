import Foundation
import TypstSyntax

/// A module: a named scope of definitions.
///
/// Port of `Module` in `module.rs`.
public struct Module: Sendable {
    /// The module's name.
    public var name: Str

    /// The module's content (for `#import` display purposes).
    public var content: Content

    /// The module's scope.
    public var scope: Scope

    /// The file the module was loaded from, if any.
    public var fileId: FileId?

    public init(name: Str, scope: Scope, fileId: FileId? = nil, content: Content = .empty) {
        self.name = name
        self.scope = scope
        self.fileId = fileId
        self.content = content
    }

    /// Access a field on the module.
    public func field(_ field: String, guard access: any BindingGuard) -> HintedStrResult<Value> {
        guard let binding = scope.get(field) else {
            return .failure(HintedString("module does not contain \(field.typstRepr)"))
        }
        return binding.read(access)
            .mapError { $0.cannot("access variable `\(field)`") }
    }

    /// Look up a definition without access checks (internal use).
    public func get(_ field: String) -> Binding? {
        scope.get(field)
    }
}

extension Module: CustomDebugStringConvertible {
    public var debugDescription: String { "Module(\(name.value))" }
}

extension Module: Repr {
    public func repr() -> String { "module(\(name.value.typstRepr), ..)" }
}

extension Module: Hashable {
    public static func == (lhs: Module, rhs: Module) -> Bool {
        lhs.name == rhs.name && lhs.fileId == rhs.fileId
            && lhs.content == rhs.content && lhs.scope === rhs.scope
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(fileId)
        hasher.combine(content)
        hasher.combine(ObjectIdentifier(scope))
    }
}
