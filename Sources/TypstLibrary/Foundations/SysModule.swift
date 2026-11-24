import Foundation
import TypstSyntax
import TypstUtils

// Port of `foundations/sys.rs` — the `sys` module exposing the compiler
// version and CLI inputs.

/// The Typst version this port targets (upstream 0.15.1).
public let typstVersion = Version(components: [0, 15, 1])

/// A module with system-related things.
///
/// Port of `sys::module` in `foundations/sys.rs`.
public func sysModule(inputs: Dict) -> Module {
    let scope = Scope()
    scope.define("version", .version(typstVersion))
    scope.define("inputs", .dict(inputs))
    return Module(name: Str("sys"), scope: scope)
}
