import Foundation

/// Resolve escape sequences in a quoted string literal's inner text.
/// Port of the unescape logic in `ast::Str::get` (`typst-syntax/src/ast.rs`).
///
/// `inner` must be the text between the quotes.
func unescapeTypstString(_ inner: String) -> String {
    guard inner.contains("\\") else { return inner }

    var out = String()
    out.reserveCapacity(inner.utf8.count)
    var s = Scanner(inner)

    while let c = s.eat() {
        if c != "\\" {
            out.unicodeScalars.append(c)
            continue
        }

        // The backslash is ASCII, so its byte index is `cursor - 1`.
        let start = s.cursor - 1
        guard let escaped = s.eat() else {
            out += s.from(start)
            break
        }

        switch escaped {
        case "\\": out.unicodeScalars.append("\\")
        case "\"": out.unicodeScalars.append("\"")
        case "n": out.unicodeScalars.append("\n")
        case "r": out.unicodeScalars.append("\r")
        case "t": out.unicodeScalars.append("\t")
        case "u" where s.eatIf("{"):
            let sequence = s.eatWhile { scalar in
                switch scalar.value {
                case 0x30...0x39, 0x41...0x46, 0x61...0x66: return true
                default: return false
                }
            }
            _ = s.eatIf("}")
            if let value = UInt32(sequence, radix: 16),
               let scalar = Unicode.Scalar(value) {
                out.unicodeScalars.append(scalar)
            } else {
                out += s.from(start)
            }
        default:
            out += s.from(start)
        }
    }

    return out
}
