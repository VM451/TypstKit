import TypstSyntax

/// A path in bundle output.
///
/// Unlike `PathOrStr`, a string cast through this is always an absolute
/// path instead of being resolved relative to a file. Port of
/// `BundlePath` in `foundations/path.rs`.
public struct BundlePath: Sendable, Hashable {
    /// The wrapped virtual path (upstream tuple field `.0`).
    public var path: VirtualPath

    /// Wraps a virtual path, ensuring it has at least one component.
    public init(path: VirtualPath) { self.path = path }

    /// Port of `BundlePath::new`.
    public static func new(_ path: VirtualPath) -> StrResult<BundlePath> {
        if path.isRoot {
            return .failure(StrError("path must have at least one component"))
        }
        return .success(BundlePath(path: path))
    }
}

extension BundlePath: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Str.self)) }
    public static var output: CastInfo { input }

    public static func castable(_ value: Value) -> Bool {
        Str.castable(value)
    }

    public func intoValue() -> Value { .str(Str(path.withSlash)) }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .str(v) = value else { return .failure(error(value)) }
        let path: VirtualPath
        do {
            path = try VirtualPath(v.value)
        } catch let err as PathError {
            return .failure(formatBundleError(err, v.value))
        } catch {
            return .failure(HintedString("invalid path"))
        }
        return new(path).mapError { HintedString($0.description) }
    }
}

/// Format the user-facing error message for virtual path casts.
/// Port of `format_bundle_error` in `foundations/path.rs`.
private func formatBundleError(_ err: PathError, _ path: String) -> HintedString {
    switch err {
    case .escapes:
        return HintedString("path `\(path)` would escape the bundle root")
    case .backslash:
        return HintedString(
            message: "path must not contain a backslash",
            hints: ["use forward slashes instead: `\(path.replacingOccurrences(of: "\\", with: "/"))`"])
    case .nul:
        return HintedString("path must not contain a NUL byte")
    case .invalid(let segment):
        return HintedString("invalid path segment '\(segment)'")
    case .message(let m):
        return HintedString(m)
    }
}
