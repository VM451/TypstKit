import Foundation
import Testing
@testable import TypstSyntax

/// Parser-diagnostic gate for the upstream `tests/suite/syntax/` corpus.
///
/// Ports the annotation machinery of `tests/src/notes.rs` + `collect.rs`:
/// `--- name attrs ---` sections, `// Error:` / `// Warning:` / `// Hint:`
/// annotations with line/column ranges, and `VERSION` substitution. Each
/// section body is parsed with `Source` and every produced syntax
/// diagnostic must match an annotation exactly (kind, byte range, message).
///
/// Annotations that only fire in later pipeline stages (eval/render) cannot
/// be produced by the parser; they are tolerated but must belong to the
/// reviewed `expectedUnevaluated` set so a *missing* parse diagnostic still
/// fails the suite.
@Suite("Syntax suite", .serialized)
struct SyntaxSuiteTests {
    /// An annotated or emitted diagnostic note.
    struct Note: Hashable {
        enum Kind: Int, Hashable {
            case error, warning, hint
        }
        var kind: Kind
        /// Byte range in the cleaned test body, or nil for detached spans.
        var range: Range<Int>?
        var message: String
    }

    struct Section {
        var name: String
        var body: String
    }

    /// A note line before range resolution.
    struct RawNote {
        var kind: Note.Kind
        /// Index (in cleaned body lines) of the annotated line.
        var annotatedLine: Int
        /// Text after `// Kind: ` (untrimmed).
        var spec: String
    }

    // MARK: - Suite loading

    private var suiteDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Suite/syntax")
    }

    /// Split a suite file into `--- name attrs ---` sections.
    ///
    /// Port of the body-scanning loop in upstream `collect.rs::parse`:
    /// the preamble may only contain comments/blank lines and a body ends
    /// at a line starting with `---`.
    private func sections(of file: String) throws -> [Section] {
        let text = try String(contentsOf: suiteDir.appendingPathComponent(file),
                              encoding: .utf8)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var s = String(line)
                if s.hasSuffix("\r") { s.removeLast() }
                return s
            }
        // Rust `str::lines` yields no trailing empty line.
        if lines.last == "" { lines.removeLast() }

        var result: [Section] = []
        var i = 0
        // Skip preamble (comments and blank lines only).
        while i < lines.count, !lines[i].hasPrefix("---") {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, !trimmed.hasPrefix("//") {
                Issue.record("preamble of \(file) has non-comment line \(i + 1)")
            }
            i += 1
        }
        while i < lines.count {
            // Parse header: `--- name attrs ---`; attrs are irrelevant here.
            let header = lines[i]
            i += 1
            var rest = Substring(header)
            guard rest.hasPrefix("---") else {
                Issue.record("expected --- header at line \(i) of \(file)")
                break
            }
            rest = rest.dropFirst(3).drop(while: { $0 == " " })
            let name = String(rest.prefix(while: { !$0.isWhitespace }))
            guard !name.isEmpty else {
                Issue.record("expected test name in \(file):\(i)")
                continue
            }
            var bodyLines: [String] = []
            while i < lines.count, !lines[i].hasPrefix("---") {
                bodyLines.append(lines[i])
                i += 1
            }
            // Upstream pushes '\n' after every body line.
            result.append(Section(name: name,
                                  body: bodyLines.joined(separator: "\n") + "\n"))
        }
        return result
    }

    // MARK: - Annotation extraction

    /// Extract note lines from a test body.
    ///
    /// Port of `parse_test_body` in upstream `notes.rs`: note lines are
    /// removed from the body and annotate the next non-note line. Returns
    /// the raw notes (unresolved) and the cleaned body.
    private func extractNotes(_ body: String) -> (notes: [RawNote], cleaned: String) {
        var cleaned = ""
        var notes: [RawNote] = []
        var annotatedLine = 0
        // `body` always ends with '\n'; drop the artificial trailing empty.
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast() {
            var line = String(rawLine)
            if line.hasSuffix("\r") { line.removeLast() }

            let trimmed = line.drop(while: { $0 == " " })
            // `// Trace:` notes are eval-internal; the parser never emits
            // them, so they are removed from the body but not recorded.
            if trimmed.hasPrefix("// Trace:") { continue }

            var kind: Note.Kind? = nil
            var rest = trimmed[...]
            for (prefix, k) in [("// Error:", Note.Kind.error),
                                ("// Warning:", Note.Kind.warning),
                                ("// Hint:", Note.Kind.hint)] {
                if rest.hasPrefix(prefix) {
                    kind = k
                    rest = rest.dropFirst(prefix.count)
                    break
                }
            }

            if let kind {
                notes.append(RawNote(kind: kind, annotatedLine: annotatedLine,
                                     spec: String(rest)))
                continue
            }

            cleaned += line + "\n"
            annotatedLine += 1
        }
        return (notes, cleaned)
    }

    /// A 0-indexed line/column pair.
    private struct LineCol: Comparable {
        var line: Int
        var col: Int
        static func < (a: LineCol, b: LineCol) -> Bool {
            (a.line, a.col) < (b.line, b.col)
        }
    }

    /// Resolve raw notes into byte-ranged annotations over `cleaned`.
    ///
    /// Port of `parse_note`/`parse_note_range`/`parse_line_col_range` for
    /// internal ranges. Malformed notes are recorded as issues.
    private func resolveNotes(_ raw: [RawNote], cleaned: String,
                              context: String) -> [Note] {
        let lines = Lines(text: cleaned)
        var result: [Note] = []
        for note in raw {
            var s = Substring(note.spec)
            // expect_space_after(kind)
            guard s.first == " " else {
                Issue.record("\(context): expected space after annotation kind")
                continue
            }
            s = s.dropFirst()

            var byteRange: Range<Int>? = nil
            if s.first?.isNumber == true {
                guard let positions = parseLineColRange(&s, annotatedLine: note.annotatedLine),
                      let start = lines.lineColumnToByte(
                        lineIdx: positions.lowerBound.line,
                        columnIdx: positions.lowerBound.col),
                      let end = lines.lineColumnToByte(
                        lineIdx: positions.upperBound.line,
                        columnIdx: positions.upperBound.col) else {
                    Issue.record("\(context): annotation range out of bounds")
                    continue
                }
                byteRange = start..<end
                // expect_space_after(range)
                guard s.first == " " else {
                    Issue.record("\(context): expected space after range")
                    continue
                }
                s = s.dropFirst()
            } else if s.first == "\"" {
                Issue.record("\(context): external file annotation unsupported")
                continue
            }

            var message = s.trimmingCharacters(in: .whitespaces)
            // Upstream substitutes VERSION with the compiler version.
            message = message.replacingOccurrences(
                of: "VERSION", with: PackageVersion.compiler().description)
            result.append(Note(kind: note.kind, range: byteRange,
                               message: message))
        }
        return result
    }

    /// Parse `<line>:<col>-<line>:<col>`, `<col>-<col>`, `<line>:<col>`,
    /// or `<col>` where line numbers are relative to `annotatedLine`
    /// (the next non-note body line) and all numbers are 1-indexed.
    private func parseLineColRange(_ s: inout Substring,
                                   annotatedLine: Int) -> Range<LineCol>? {
        func number() -> Int? {
            let digits = s.prefix(while: { $0.isNumber })
            guard !digits.isEmpty, let n = Int(digits), n >= 1 else { return nil }
            s = s.dropFirst(digits.count)
            return n - 1
        }

        let lineBase = annotatedLine
        guard let first = number() else { return nil }

        var hadColon = false
        var start: LineCol
        if s.first == ":" {
            s = s.dropFirst()
            guard let col = number() else { return nil }
            hadColon = true
            start = LineCol(line: first + lineBase, col: col)
        } else {
            start = LineCol(line: lineBase, col: first)
        }

        var end = start
        if s.first == "-" {
            s = s.dropFirst()
            guard let second = number() else { return nil }
            if hadColon, s.first == ":" {
                s = s.dropFirst()
                guard let col = number() else { return nil }
                end = LineCol(line: second + lineBase, col: col)
            } else if !hadColon, s.first != ":" {
                end = LineCol(line: start.line, col: second)
            } else {
                return nil
            }
        }
        return start <= end ? start..<end : nil
    }

    // MARK: - Diagnostic collection

    /// Resolve a diagnostic span to a byte range in `source`, or nil when
    /// detached or pointing into another file.
    private func byteRange(of span: DiagSpan, in source: Source) -> Range<Int>? {
        switch span.kind {
        case .detached:
            return nil
        case .range(let id, let range):
            return id == source.id ? range : nil
        case .number(let id, let num, let subRange):
            guard id == source.id else { return nil }
            return source.range(num: num, subRange: subRange)
        }
    }

    /// Collect all syntax diagnostics (errors, warnings, and their hints)
    /// of a parsed source as notes.
    private func emittedNotes(of source: Source) -> [Note] {
        let (errors, warnings) = source.root.errorsAndWarnings()
        var notes: [Note] = []
        for diag in errors {
            notes.append(Note(kind: .error,
                              range: byteRange(of: diag.span, in: source),
                              message: diag.message.replacingOccurrences(
                                of: "\n", with: "\\n")))
            for hint in diag.hints {
                // Upstream `run.rs`: a detached hint span falls back to the
                // parent diagnostic's span.
                notes.append(Note(kind: .hint,
                                  range: byteRange(
                                    of: hint.span.or(diag.span), in: source),
                                  message: hint.value.replacingOccurrences(
                                    of: "\n", with: "\\n")))
            }
        }
        for diag in warnings {
            notes.append(Note(kind: .warning,
                              range: byteRange(of: diag.span, in: source),
                              message: diag.message.replacingOccurrences(
                                of: "\n", with: "\\n")))
            for hint in diag.hints {
                notes.append(Note(kind: .hint,
                                  range: byteRange(
                                    of: hint.span.or(diag.span), in: source),
                                  message: hint.value.replacingOccurrences(
                                    of: "\n", with: "\\n")))
            }
        }
        return notes
    }

    // MARK: - Comparison

    /// Multiset-match emitted notes against annotations; returns the
    /// emitted notes that had no matching annotation.
    private func unmatchedEmitted(_ emitted: [Note], _ annotated: [Note])
        -> [Note] {
        var remaining = Dictionary(grouping: annotated, by: { $0 })
            .mapValues { $0.count }
        var unmatched: [Note] = []
        for note in emitted {
            if var count = remaining[note], count > 0 {
                count -= 1
                if count == 0 { remaining.removeValue(forKey: note) }
                else { remaining[note] = count }
            } else {
                unmatched.append(note)
            }
        }
        return unmatched
    }

    /// Annotations left over after matching emitted notes.
    private func unmatchedAnnotations(_ emitted: [Note], _ annotated: [Note])
        -> [Note] {
        var emittedCounts = Dictionary(grouping: emitted, by: { $0 })
            .mapValues { $0.count }
        var leftover: [Note] = []
        for ann in annotated {
            if var count = emittedCounts[ann], count > 0 {
                count -= 1
                if count == 0 { emittedCounts.removeValue(forKey: ann) }
                else { emittedCounts[ann] = count }
            } else {
                leftover.append(ann)
            }
        }
        return leftover
    }

    /// Annotations that are expected to remain unmatched because they are
    /// produced by later pipeline stages (eval/render), keyed by
    /// `"file/section"` → set of `"kind message"` strings.
    ///
    /// Reviewed after the first harness run: every entry is an eval-stage
    /// diagnostic (the section bodies call `eval()` on generated strings,
    /// or destructure values at runtime). When TypstEval lands, this set
    /// empties and these become hard failures if still unmatched.
    private static let expectedUnevaluated: [String: Set<String>] = [
        "backtracking.typ/parser-backtracking-destructuring-assignment": [
            "error cannot destructure integer",
        ],
        "depth.typ/parser-depth-exceeded-balanced": [
            "error maximum parsing depth exceeded",
            "hint from index `256` to `258`",
        ],
        "depth.typ/parser-depth-exceeded-unbalanced": [
            "error unclosed delimiter",
            "hint from index `0` to `1`",
            "error maximum parsing depth exceeded",
            "hint from index `256` to `1024`",
        ],
        "depth.typ/parser-depth-exceeded-unbalanced-arrow": [
            "error the character `#` is not valid in code",
            "hint you are already in code mode",
            "hint try removing the `#`",
            "hint from index `0` to `1`",
            "error unclosed delimiter",
            "hint from index `1` to `2`",
            "error unexpected arrow",
            "hint from index `3` to `5`",
            "error maximum parsing depth exceeded",
            "hint from index `641` to `2560`",
        ],
        "depth.typ/parser-depth-exceeded-unop": [
            "error maximum parsing depth exceeded",
            "hint from index `512` to `513`",
            "error expected expression",
            "hint at index `1023`",
        ],
    ]

    // MARK: - Tests

    @Test(arguments: [
        "backtracking.typ", "code.typ", "comment.typ", "depth.typ",
        "escape.typ", "newlines.typ", "numbers.typ", "panics.typ",
        "shebang.typ", "shorthand.typ",
    ])
    func suiteFile(file: String) throws {
        let sections = try sections(of: file)
        #expect(!sections.isEmpty)

        for section in sections {
            let key = "\(file)/\(section.name)"
            let (rawNotes, cleaned) = extractNotes(section.body)
            let annotations = resolveNotes(rawNotes, cleaned: cleaned,
                                           context: key)
            let source = Source(id: FileId.newForTest(key), text: cleaned)
            let emitted = emittedNotes(of: source)

            // Every produced diagnostic must be annotated: this is the
            // strict parser-parity check.
            for note in unmatchedEmitted(emitted, annotations) {
                let rangeDesc = note.range.map { "\($0)" } ?? "<detached>"
                Issue.record(
                    "\(key): unannotated \(note.kind) diagnostic \(rangeDesc) \"\(note.message)\"")
            }

            // Annotations the parser cannot produce must be the reviewed
            // eval/render-stage set; anything else means a missing parse
            // diagnostic (or a parser message/range divergence that
            // happened to consume a different annotation).
            let expected = Self.expectedUnevaluated[key] ?? []
            for ann in unmatchedAnnotations(emitted, annotations) {
                let sig = "\(ann.kind) \(ann.message)"
                if !expected.contains(sig) {
                    let rangeDesc = ann.range.map { "\($0)" } ?? "<detached>"
                    Issue.record(
                        "\(key): annotation unmatched by parser and not in expectedUnevaluated: \(sig) \(rangeDesc)")
                }
            }
            // Expected-unmatched annotations that DID match indicate the
            // parser now covers them; keep the set honest.
            let leftover = unmatchedAnnotations(emitted, annotations)
            for ann in annotations where expected.contains(
                "\(ann.kind) \(ann.message)") {
                if !leftover.contains(ann) {
                    print("note: \(key): expectedUnevaluated entry now "
                        + "matched by parser: \(ann.kind) \(ann.message)")
                }
            }
        }
    }
}
