/// A syntactical building block of a Typst file.
///
/// Port of `typst-syntax/src/kind.rs`. Can be created by the lexer or by
/// the parser.
public enum SyntaxKind: UInt8, Sendable, Hashable, CaseIterable {
    /// The end of token stream.
    case end
    /// An invalid sequence of characters.
    case error

    /// A shebang: `#! ...`
    case shebang
    /// A line comment: `// ...`.
    case lineComment
    /// A block comment: `/* ... */`.
    case blockComment

    /// The contents of a file or content block.
    case markup
    /// Plain text without markup.
    case text
    /// Whitespace with no newlines.
    case spaceNoNewline
    /// Whitespace with _exactly one_ newline in Markup (more would be a
    /// `parbreak`) and _at least one_ newline in Code/Math.
    case spaceWithNewline
    /// A forced line break: `\`.
    case linebreak
    /// A paragraph break, indicated by contiguous whitespace containing at
    /// least two newlines. Only produced in Markup.
    case parbreak
    /// An escape sequence: `\#`, `\u{1F5FA}`.
    case escape
    /// A shorthand for a unicode codepoint. For example, `~` for
    /// non-breaking space or `-?` for a soft hyphen.
    case shorthand
    /// A smart quote: `'` or `"`.
    case smartQuote
    /// Strong content: `*Strong*`.
    case strong
    /// Emphasized content: `_Emphasized_`.
    case emph
    /// Raw text with optional syntax highlighting: `` `...` ``.
    case raw
    /// A language tag at the start of raw text: `` typ ``.
    case rawLang
    /// A raw delimiter consisting of 1 or 3+ backticks: `` ` ``.
    case rawDelim
    /// A sequence of whitespace to ignore in a raw text: `    `.
    case rawTrimmed
    /// A hyperlink: `https://typst.org`.
    case link
    /// A label: `<intro>`.
    case label
    /// A reference: `@target`, `@target[..]`.
    case ref
    /// Introduces a reference: `@target`.
    case refMarker
    /// A section heading: `= Introduction`.
    case heading
    /// Introduces a section heading: `=`, `==`, ...
    case headingMarker
    /// An item in a bullet list: `- ...`.
    case listItem
    /// Introduces a list item: `-`.
    case listMarker
    /// An item in an enumeration (numbered list): `+ ...` or `1. ...`.
    case enumItem
    /// Introduces an enumeration item: `+`, `1.`.
    case enumMarker
    /// An item in a term list: `/ Term: Details`.
    case termItem
    /// Introduces a term item: `/`.
    case termMarker

    /// A mathematical equation: `$x$`, `$ x^2 $`.
    case equation
    /// The contents of a mathematical equation: `x^2 + 1`.
    case math
    /// A single letter in math, may be exactly one grapheme cluster:
    /// `x`, `π`, `ℱ`, `ℱ︀`.
    case mathLetter
    /// A non-letter symbol in math, may be exactly one grapheme cluster:
    /// `+`, `=`, `∅`, `∅︀`, `🏳️‍🌈`.
    case mathSymbol
    /// A number in math: `25`, `2.718`.
    case mathNumber
    /// An identifier in math: `pi`.
    case mathIdent
    /// A field access in math: `arrow.r.long.double.bar`.
    case mathFieldAccess
    case mathShorthand
    /// An alignment point in math: `&`.
    case mathAlignPoint
    /// A function call in math.
    case mathCall
    /// Function arguments in math.
    case mathArgs
    /// An opening delimiter in math: `(`, `{`.
    case mathOpening
    /// A closing delimiter in math: `)`, `}`.
    case mathClosing
    /// Matched delimiters in math: `[x + y]`.
    case mathDelimited
    /// A base with optional attachments in math: `a_1^2`.
    case mathAttach
    /// Grouped primes in math: `a'''`.
    case mathPrimes
    /// A fraction in math: `x/2`.
    case mathFrac
    /// A root in math: `√x`, `∛x` or `∜x`.
    case mathRoot

    /// A hash that switches into code mode: `#`.
    case hash
    case leftBrace
    case rightBrace
    case leftBracket
    case rightBracket
    case leftParen
    case rightParen
    /// A comma separator in a sequence: `,`.
    case comma
    /// A semicolon terminating an expression: `;`.
    case semicolon
    /// A colon between name/key and value in a dictionary, argument or
    /// parameter list, or between the term and body of a term list term.
    case colon
    /// The strong text toggle, multiplication operator, and wildcard
    /// import symbol: `*`.
    case star
    /// Toggles emphasized text and indicates a subscript in math: `_`.
    case underscore
    /// Starts and ends a mathematical equation: `$`.
    case dollar
    /// The unary plus and binary addition operator: `+`.
    case plus
    /// The unary negation and binary subtraction operator: `-`.
    case minus
    /// The division operator and fraction operator in math: `/`.
    case slash
    /// The superscript operator in math: `^`.
    case hat
    /// The field access and method call operator: `.`.
    case dot
    /// The assignment operator: `=`.
    case eq
    /// The equality operator: `==`.
    case eqEq
    /// The inequality operator: `!=`.
    case exclEq
    /// The less-than operator: `<`.
    case lt
    /// The less-than or equal operator: `<=`.
    case ltEq
    /// The greater-than operator: `>`.
    case gt
    /// The greater-than or equal operator: `>=`.
    case gtEq
    /// The add-assign operator: `+=`.
    case plusEq
    /// The subtract-assign operator: `-=`.
    case hyphEq
    /// The multiply-assign operator: `*=`.
    case starEq
    /// The divide-assign operator: `/=`.
    case slashEq
    /// Indicates a spread or sink: `..`.
    case dots
    /// An arrow between a closure's parameters and body: `=>`.
    case arrow
    /// A root: `√`, `∛` or `∜`.
    case root
    /// An exclamation mark; groups with directly preceding text in math.
    case bang

    /// The `not` operator.
    case not
    /// The `and` operator.
    case `and`
    /// The `or` operator.
    case `or`
    /// The `none` literal.
    case none
    /// The `auto` literal.
    case auto
    /// The `let` keyword.
    case `let`
    /// The `set` keyword.
    case `set`
    /// The `show` keyword.
    case `show`
    /// The `context` keyword.
    case `context`
    /// The `if` keyword.
    case `if`
    /// The `else` keyword.
    case `else`
    case `for`
    /// The `in` keyword.
    case `in`
    case `while`
    case `break`
    case `continue`
    case `return`
    case `import`
    case `include`
    case `as`

    /// The contents of a code block.
    case code
    /// An identifier: `it`.
    case ident
    /// A boolean: `true`, `false`.
    case bool
    /// An integer: `120`.
    case int
    /// A floating-point number: `1.2`, `10e-4`.
    case float
    /// A numeric value with a unit: `12pt`, `3cm`, `2em`, `90deg`, `50%`.
    case numeric
    /// A quoted string: `"..."`.
    case str
    /// A code block: `{ let x = 1; x + 2 }`.
    case codeBlock
    /// A content block: `[*Hi* there!]`.
    case contentBlock
    /// A grouped expression: `(1 + 2)`.
    case parenthesized
    /// An array: `(1, "hi", 12cm)`.
    case array
    /// A dictionary: `(thickness: 3pt, dash: "solid")`.
    case dict
    /// A named pair: `thickness: 3pt`.
    case named
    /// A keyed pair: `"spacy key": true`.
    case keyed
    /// A unary operation: `-x`.
    case unary
    /// A binary operation: `a + b`.
    case binary
    /// A field access: `properties.age`.
    case fieldAccess
    /// An invocation of a function or method: `f(x, y)`.
    case funcCall
    /// A function call's argument list: `(12pt, y)`.
    case args
    /// Spread arguments or an argument sink: `..x`.
    case spread
    /// A closure: `(x, y) => z`.
    case closure
    /// A closure's parameters: `(x, y)`.
    case params
    /// A let binding: `let x = 1`.
    case letBinding
    /// A set rule: `set text(...)`.
    case setRule
    /// A show rule: `show heading: it => emph(it.body)`.
    case showRule
    /// A contextual expression: `context text.lang`.
    case contextual
    /// An if-else conditional: `if x { y } else { z }`.
    case conditional
    /// A while loop: `while x { y }`.
    case whileLoop
    /// A for loop: `for x in y { z }`.
    case forLoop
    /// A module import: `import "utils.typ": a, b, c`.
    case moduleImport
    /// Items to import from a module: `a, b, c`.
    case importItems
    /// A path to an imported name from a submodule: `a.b.c`.
    case importItemPath
    /// A renamed import item: `a as d`.
    case renamedImportItem
    /// A module include: `include "chapter1.typ"`.
    case moduleInclude
    /// A break from a loop: `break`.
    case loopBreak
    /// A continue in a loop: `continue`.
    case loopContinue
    /// A return from a function: `return`, `return x + 1`.
    case funcReturn
    /// A destructuring pattern: `(x, _, ..y)`.
    case destructuring
    /// A destructuring assignment expression: `(x, y) = (1, 2)`.
    case destructAssignment

    /// Is this a bracket, brace, or parenthesis?
    public var isGrouping: Bool {
        switch self {
        case .leftBracket, .leftBrace, .leftParen,
             .rightBracket, .rightBrace, .rightParen:
            return true
        default:
            return false
        }
    }

    /// Does this node terminate a preceding expression?
    public var isTerminator: Bool {
        switch self {
        case .end, .semicolon, .rightBrace, .rightParen, .rightBracket:
            return true
        default:
            return false
        }
    }

    /// Is this a code or content block.
    public var isBlock: Bool {
        self == .codeBlock || self == .contentBlock
    }

    /// Does this node need termination through a semicolon or linebreak?
    public var isStmt: Bool {
        switch self {
        case .letBinding, .setRule, .showRule, .moduleImport, .moduleInclude:
            return true
        default:
            return false
        }
    }

    /// Is this node is a keyword.
    public var isKeyword: Bool {
        switch self {
        case .not, .and, .or, .none, .auto, .let, .set, .show, .context,
             .if, .else, .for, .in, .while, .break, .continue, .return,
             .import, .include, .as:
            return true
        default:
            return false
        }
    }

    /// Does this produce textual content matching itself?
    public var isTextLike: Bool {
        switch self {
        case .text, .mathLetter, .mathSymbol, .mathNumber:
            return true
        default:
            return false
        }
    }

    /// Whether this kind of node is automatically skipped by the parser
    /// in code and math mode.
    public var isTrivia: Bool {
        switch self {
        case .shebang, .lineComment, .blockComment,
             .spaceNoNewline, .spaceWithNewline, .parbreak:
            return true
        default:
            return false
        }
    }

    /// Whether this is an error.
    public var isError: Bool { self == .error }

    /// A human-readable name for the kind.
    public var name: String {
        switch self {
        case .end: return "end of tokens"
        case .error: return "syntax error"
        case .shebang: return "shebang"
        case .lineComment: return "line comment"
        case .blockComment: return "block comment"
        case .markup: return "markup"
        case .text: return "text"
        case .spaceNoNewline: return "space"
        case .spaceWithNewline: return "space"
        case .linebreak: return "line break"
        case .parbreak: return "paragraph break"
        case .escape: return "escape sequence"
        case .shorthand: return "shorthand"
        case .smartQuote: return "smart quote"
        case .strong: return "strong content"
        case .emph: return "emphasized content"
        case .raw: return "raw block"
        case .rawLang: return "raw language tag"
        case .rawTrimmed: return "raw trimmed"
        case .rawDelim: return "raw delimiter"
        case .link: return "link"
        case .label: return "label"
        case .ref: return "reference"
        case .refMarker: return "reference marker"
        case .heading: return "heading"
        case .headingMarker: return "heading marker"
        case .listItem: return "list item"
        case .listMarker: return "list marker"
        case .enumItem: return "enum item"
        case .enumMarker: return "enum marker"
        case .termItem: return "term list item"
        case .termMarker: return "term marker"
        case .equation: return "equation"
        case .math: return "math"
        case .mathLetter: return "math letter"
        case .mathSymbol: return "math symbol"
        case .mathNumber: return "math number"
        case .mathIdent: return "math identifier"
        case .mathFieldAccess: return "math field access"
        case .mathShorthand: return "math shorthand"
        case .mathAlignPoint: return "math alignment point"
        case .mathCall: return "math function call"
        case .mathArgs: return "math call arguments"
        case .mathOpening: return "math opening delimiter"
        case .mathClosing: return "math closing delimiter"
        case .mathDelimited: return "delimited math"
        case .mathAttach: return "math attachments"
        case .mathFrac: return "math fraction"
        case .mathRoot: return "math root"
        case .mathPrimes: return "math primes"
        case .hash: return "hash"
        case .leftBrace: return "opening brace"
        case .rightBrace: return "closing brace"
        case .leftBracket: return "opening bracket"
        case .rightBracket: return "closing bracket"
        case .leftParen: return "opening paren"
        case .rightParen: return "closing paren"
        case .comma: return "comma"
        case .semicolon: return "semicolon"
        case .colon: return "colon"
        case .star: return "star"
        case .underscore: return "underscore"
        case .dollar: return "dollar sign"
        case .plus: return "plus"
        case .minus: return "minus"
        case .slash: return "slash"
        case .hat: return "hat"
        case .dot: return "dot"
        case .eq: return "equals sign"
        case .eqEq: return "equality operator"
        case .exclEq: return "inequality operator"
        case .lt: return "less-than operator"
        case .ltEq: return "less-than or equal operator"
        case .gt: return "greater-than operator"
        case .gtEq: return "greater-than or equal operator"
        case .plusEq: return "add-assign operator"
        case .hyphEq: return "subtract-assign operator"
        case .starEq: return "multiply-assign operator"
        case .slashEq: return "divide-assign operator"
        case .dots: return "dots"
        case .arrow: return "arrow"
        case .root: return "root"
        case .bang: return "exclamation mark"
        case .not: return "operator `not`"
        case .and: return "operator `and`"
        case .or: return "operator `or`"
        case .none: return "`none`"
        case .auto: return "`auto`"
        case .let: return "keyword `let`"
        case .set: return "keyword `set`"
        case .show: return "keyword `show`"
        case .context: return "keyword `context`"
        case .if: return "keyword `if`"
        case .else: return "keyword `else`"
        case .for: return "keyword `for`"
        case .in: return "keyword `in`"
        case .while: return "keyword `while`"
        case .break: return "keyword `break`"
        case .continue: return "keyword `continue`"
        case .return: return "keyword `return`"
        case .import: return "keyword `import`"
        case .include: return "keyword `include`"
        case .as: return "keyword `as`"
        case .code: return "code"
        case .ident: return "identifier"
        case .bool: return "boolean"
        case .int: return "integer"
        case .float: return "float"
        case .numeric: return "numeric value"
        case .str: return "string"
        case .codeBlock: return "code block"
        case .contentBlock: return "content block"
        case .parenthesized: return "group"
        case .array: return "array"
        case .dict: return "dictionary"
        case .named: return "named pair"
        case .keyed: return "keyed pair"
        case .unary: return "unary expression"
        case .binary: return "binary expression"
        case .fieldAccess: return "field access"
        case .funcCall: return "function call"
        case .args: return "call arguments"
        case .spread: return "spread"
        case .closure: return "closure"
        case .params: return "closure parameters"
        case .letBinding: return "`let` expression"
        case .setRule: return "`set` expression"
        case .showRule: return "`show` expression"
        case .contextual: return "`context` expression"
        case .conditional: return "`if` expression"
        case .whileLoop: return "while-loop expression"
        case .forLoop: return "for-loop expression"
        case .moduleImport: return "`import` expression"
        case .importItems: return "import items"
        case .importItemPath: return "imported item path"
        case .renamedImportItem: return "renamed import item"
        case .moduleInclude: return "`include` expression"
        case .loopBreak: return "`break` expression"
        case .loopContinue: return "`continue` expression"
        case .funcReturn: return "`return` expression"
        case .destructuring: return "destructuring pattern"
        case .destructAssignment: return "destructuring assignment expression"
        }
    }
}

/// Which syntactic mode the lexer/parser is currently in.
public enum SyntaxMode: Sendable, Hashable {
    /// Markup mode: text with markup constructs.
    case markup
    /// Code mode: expressions and statements.
    case code
    /// Math mode: mathematical content.
    case math
}
