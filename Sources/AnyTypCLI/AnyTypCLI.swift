import AnyTyp
import Darwin
import Foundation

@main
struct AnyTypCLI {
    private static let usageCode: Int32 = 2
    private static let convCode: Int32 = 1
    private static let ocrCode: Int32 = 3

    private static let helpText = """
    anytyp: convert any document to idiomatic Typst (.typ)

    Usage:
      anytyp <file> [options]
      anytyp - [options] < file

    Options:
      -o, --output <path>      Write Typst output to <path> instead of stdout
      -f, --format <format>    Explicit input format (doc, docx, odt, pdf, ppt, pptx,
                               rtf, epub, xlsx, ods, odp, csv, tsv, md, html, tex, json, txt)
      --assets-dir <dir>       Extract embedded images into <dir> and emit #image("...")
      --standalone             Prepend standalone Typst preamble (#set page, #set par)
      --title <title>          Document title for #set document(title: "...")
      -h, --help               Print this help and exit
      -V, --version            Print version and exit
    """

    static func main() {
        let argv = Array(CommandLine.arguments.dropFirst())
        var input: String?
        var output: String?
        var formatRaw: String?
        var assetsDir: String?
        var standalone = false
        var title: String?
        var positionalOnly = false
        var idx = 0

        while idx < argv.count {
            let arg = argv[idx]
            if positionalOnly || arg == "-" || !arg.hasPrefix("-") {
                if input != nil {
                    fail(usageCode, "one document per invocation: unexpected second input '\(arg)'")
                }
                input = arg
                idx += 1
                continue
            }
            if arg == "--" {
                positionalOnly = true
                idx += 1
                continue
            }
            let flag: String
            let inlineVal: String?
            if arg.hasPrefix("--"), let eq = arg.firstIndex(of: "=") {
                flag = String(arg[..<eq])
                inlineVal = String(arg[arg.index(after: eq)...])
            } else {
                flag = arg
                inlineVal = nil
            }
            func nextValue() -> String {
                if let inlineVal { return inlineVal }
                idx += 1
                guard idx < argv.count else { fail(usageCode, "\(flag) requires a value") }
                return argv[idx]
            }
            switch flag {
            case "-h", "--help":
                print(helpText)
                exit(0)
            case "-V", "--version":
                print("0.1.0")
                exit(0)
            case "-o", "--output":
                output = nextValue()
            case "-f", "--format":
                formatRaw = nextValue()
            case "--assets-dir":
                assetsDir = nextValue()
            case "--standalone":
                standalone = true
            case "--title":
                title = nextValue()
            default:
                fail(usageCode, "unknown option '\(flag)' (see anytyp --help)")
            }
            idx += 1
        }

        guard let input else {
            fail(usageCode, "missing input: pass a document path, or - for stdin (see anytyp --help)")
        }

        let format: AnyTypFormat?
        if let formatRaw {
            guard let parsed = AnyTypFormat(fileExtension: formatRaw) else {
                fail(usageCode, "invalid format '\(formatRaw)'")
            }
            format = parsed
        } else {
            format = nil
        }

        let assetsURL = assetsDir.map { URL(filePath: $0) }
        let prefix: String?
        if let assetsDir, let output {
            let outParent = URL(filePath: output).deletingLastPathComponent().path(percentEncoded: false)
            let fullAssets = URL(filePath: assetsDir).path(percentEncoded: false)
            if fullAssets.hasPrefix(outParent + "/") {
                prefix = String(fullAssets.dropFirst(outParent.count + 1))
            } else {
                prefix = assetsDir
            }
        } else {
            prefix = assetsDir
        }

        let opts = AnyTypOptions(
            standalone: standalone,
            title: title,
            extractAssetsTo: assetsURL,
            assetsPrefix: prefix
        )

        do {
            let typst: String
            if input == "-" {
                let data = FileHandle.standardInput.readDataToEndOfFile()
                typst = try AnyTyp.convert(data, format: format, options: opts)
            } else if let format {
                let data = try Data(contentsOf: URL(filePath: input))
                typst = try AnyTyp.convert(data, format: format, options: opts)
            } else {
                typst = try AnyTyp.convert(URL(filePath: input), options: opts)
            }

            if let output {
                try Data(typst.utf8).write(to: URL(filePath: output))
            } else {
                FileHandle.standardOutput.write(Data(typst.utf8))
            }
        } catch let error as AnyTypError {
            if case .needsOCR = error {
                fail(ocrCode, error.localizedDescription)
            }
            fail(convCode, error.localizedDescription)
        } catch {
            fail(convCode, error.localizedDescription)
        }
    }

    private static func fail(_ code: Int32, _ message: String) -> Never {
        FileHandle.standardError.write(Data("anytyp: \(message)\n".utf8))
        exit(code)
    }
}
