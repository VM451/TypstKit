import Foundation
import TypstSyntax
import TypstUtils

// The `label` type's associated scope — port of the `#[scope] impl Label`
// block in upstream `foundations/label.rs`.

/// `label(..)` — port of `Label::construct`.
///
/// Unlike the `<name>` syntax, this constructor accepts any non-empty
/// string, including names with special characters.
let labelConstruct = nativeFunc(
    "label",
    title: "Label",
    since: .forever,
    docs: "Creates a label from a string.",
    params: [
        NativeParamInfo(name: "name", input: Str.input, required: true)
    ],
    returns: Label.output
) { _, _, args in
    let name: Str = try args.expectT("name")
    try args.finishT()

    if name.value.isEmpty {
        throw bailHint("label name must not be empty")
    }
    // `Label.init?` only fails on the empty name, checked above.
    return Label(name: .intern(name.value))!
}
