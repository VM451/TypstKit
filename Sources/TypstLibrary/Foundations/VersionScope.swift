import Foundation
import TypstSyntax
import TypstUtils

// The `version` type's associated scope — port of the `#[scope] impl
// Version` block in upstream `foundations/version.rs`.

/// Build the scope containing all `version` methods.
func versionScope() -> Scope {
    let scope = Scope()
    scope.defineFunc(versionAt)
    return scope
}

/// `version` constructor — port of `Version::construct` (variadic,
/// array arguments flattened).
let versionConstruct = nativeFunc(
    "version",
    title: "Version",
    since: .version([0, 9, 0]),
    docs: """
        Creates a new version.

        It can have any number of components (even zero).
        """,
    params: [
        NativeParamInfo(
            name: "components",
            input: VersionComponents.input,
            positional: true,
            variadic: true,
            required: true)
    ],
    returns: Version.output
) { _, _, args in
    let components: [VersionComponents] = try args.allT()
    try args.finishT()

    var version = Version()
    for c in components {
        switch c {
        case let .single(v): version.push(v)
        case let .multiple(values):
            for v in values { version.push(v) }
        }
    }
    return version
}

/// `version.at` — port of `Version::at`.
let versionAt = nativeFunc(
    "at",
    since: .version([0, 9, 0]),
    docs: """
        Retrieves a component of a version.

        The returned integer is always non-negative. Returns `{0}` if the \
        version isn't specified to the necessary length.
        """,
    params: [
        NativeParamInfo(name: "self", input: Version.input, required: true),
        NativeParamInfo(name: "index", input: Int64.input, required: true),
    ],
    returns: Int64.output
) { _, _, args in
    let version: Version = try args.expectT("self")
    let index: Int64 = try args.expectT("index")
    try args.finishT()
    return try unwrap(version.at(index))
}

extension VersionComponents: Castable, FromValue {
    public static var input: CastInfo {
        Int64.input + ArrayValue.input
    }
    public static var output: CastInfo { Int64.output }
    public static func castable(_ value: Value) -> Bool {
        Int64.castable(value) || ArrayValue.castable(value)
    }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        // Arm order like upstream `cast!`: `u32` first, then `Vec<u32>`;
        // neither castable → union input error.
        if UInt32.castable(value) {
            return UInt32.fromValue(value).map { .single($0) }
        }
        guard case let .array(items) = value else {
            return .failure(error(value))
        }
        var values: [UInt32] = []
        values.reserveCapacity(items.count)
        for item in items {
            switch UInt32.fromValue(item) {
            case let .success(v): values.append(v)
            case let .failure(e): return .failure(e)
            }
        }
        return .success(.multiple(values))
    }
}
