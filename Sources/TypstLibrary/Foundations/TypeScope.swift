import Foundation
import TypstSyntax
import TypstUtils

// The `type` type's associated scope — port of the `#[scope] impl Type`
// block in upstream `foundations/ty.rs`.

/// `type(..)` — port of `Type::construct`: returns the type of a value.
let typeConstruct = nativeFunc(
    "type",
    title: "Type",
    since: .version([0, 8, 0]),
    docs: "Determines the type of a value.",
    params: [
        NativeParamInfo(
            name: "value",
            input: Value.input,
            positional: true,
            required: true),
    ],
    returns: Type.output
) { _, _, args in
    let value: Value = try args.expectT("value")
    try args.finishT()
    return value.type
}
