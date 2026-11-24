import Foundation
import TypstSyntax
import TypstUtils

// Port of upstream `foundations/path.rs`: the `path` type
// (`RootedPath` as a `#[ty]` dynamic value), the `path()` constructor,
// and the `PathOrStr` union accepted by all loading functions.

extension RootedPath: CustomDebugStringConvertible {
    public var debugDescription: String { repr() }
}

/// Marker conformance: rooted paths are `#[ty]` values stored as
/// `Value.dynamic`.
extension RootedPath: DynamicBounds {}

extension RootedPath: Repr {
    public func repr() -> String {
        // Always absolute; the package spec is not exposed in the repr.
        "path(\(vpath.withSlash.typstRepr))"
    }
}

extension RootedPath: NativeType {
    public static let typeInfo = TypeInfo(name: "path", longName: "path",
        title: "Path", since: .version([0, 15, 0]),
        constructor: { Func(native: pathConstruct) },
        scope: { pathScope() })
}

extension RootedPath: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(RootedPath.self)) }
    public static var output: CastInfo { input }

    public static func castable(_ value: Value) -> Bool {
        guard case let .dynamic(d) = value else { return false }
        return d.is(RootedPath.self)
    }

    public func intoValue() -> Value { .dynamic(self) }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .dynamic(d) = value, let v = d.downcast(RootedPath.self)
        else { return .failure(error(value)) }
        return .success(v)
    }
}

/// A string or a path. Port of upstream's `PathOrStr`.
public enum PathOrStr: Sendable, Hashable {
    case path(RootedPath)
    case str(Str)

    /// Resolves this path or string relative to the file at `within`.
    /// Port of `PathOrStr::resolve`.
    public func resolve(within: FileId) -> HintedStrResult<RootedPath> {
        switch self {
        case .path(let v):
            return .success(v)
        case .str(let v):
            let root = within.path.root
            let base = within.vpath
            let joined: VirtualPath
            do {
                joined = try (base.parent ?? base).join(v.value)
            } catch {
                return .failure(formatResolveError(error, root: root, path: v.value))
            }
            return .success(RootedPath(root: root, vpath: joined))
        }
    }

    /// Resolves if `within` is available, else errors — port of
    /// `resolve_if_some`.
    public func resolveIfSome(within: FileId?) -> HintedStrResult<RootedPath> {
        guard let within else {
            return .failure(HintedString("cannot access file system from here"))
        }
        return resolve(within: within)
    }
}

extension PathOrStr: CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
        case .path(let p): return p.description
        case .str(let s): return s.value
        }
    }
}

extension PathOrStr: Castable, IntoValue, FromValue {
    public static var input: CastInfo {
        RootedPath.input + Str.input
    }
    public static var output: CastInfo { input }

    public static func castable(_ value: Value) -> Bool {
        RootedPath.castable(value) || Str.castable(value)
    }

    public func intoValue() -> Value {
        switch self {
        case .path(let p): return p.intoValue()
        case .str(let s): return s.intoValue()
        }
    }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        if RootedPath.castable(value) {
            return RootedPath.fromValue(value).map { .path($0) }
        }
        return Str.fromValue(value).map { .str($0) }
    }
}

/// Format the user-facing error for path resolution failures.
/// Port of upstream's `format_resolve_error`.
func formatResolveError(_ error: Error, root: VirtualRoot, path: String) -> HintedString {
    guard let pathError = error as? PathError else {
        return HintedString("\(error)")
    }
    switch pathError {
    case .escapes:
        let kind: String
        switch root {
        case .project: kind = "project"
        case .package: kind = "package"
        }
        var diag = HintedString(
            message: "path \(Str(path).repr()) would escape the \(kind) root",
            hints: ["cannot access files outside of the \(kind) sandbox"])
        if root == .project {
            diag.hint("you can adjust the project root with the `--root` argument")
        }
        return diag
    case .backslash:
        return HintedString(
            message: "path must not contain a backslash",
            hints: [
                "use forward slashes instead: \(Str(path.replacingOccurrences(of: "\\", with: "/")).repr())",
                "in earlier Typst versions, backslashes indicated path separators on Windows",
                "this behavior is no longer supported as it is not portable",
            ])
    default:
        return HintedString("\(pathError)")
    }
}

/// `path(path-or-str)` — port of `RootedPath::construct`.
let pathConstruct = nativeFunc(
    "path",
    since: .version([0, 15, 0]),
    docs: "Creates a path from a string.",
    params: [
        NativeParamInfo(name: "path", input: PathOrStr.input, required: true),
    ],
    returns: RootedPath.output
) { _, _, args in
    let path: Spanned<PathOrStr, Span> = try args.expectT("path")
    try args.finishT()
    switch path.value.resolveIfSome(within: path.span.id) {
    case .success(let resolved): return resolved
    case .failure(let e): throw bailSpan(path.span, e.message, hints: e.hints)
    }
}

/// Build the scope for the `path` type (currently just the constructor).
func pathScope() -> Scope {
    let scope = Scope()
    scope.defineFunc(pathConstruct)
    return scope
}
