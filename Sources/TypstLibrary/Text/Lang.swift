import Foundation

// Language, region, and script identifiers plus the localized-string
// machinery from upstream `text/lang.rs`. The embedded translation data
// lives in `Translations.swift` (generated).
//
// Upstream stores `Lang`/`WritingScript` as space-padded byte arrays with a
// length byte; the port stores the normalized code as a `String` instead —
// equality, hashing, and ordering semantics are preserved (`Comparable`
// reproduces the derived `Ord` of the padded array + length tuple).

// MARK: - Locale

/// A locale consisting of a language and an optional region.
///
/// Port of `Locale` in `text/lang.rs`.
public struct Locale: Sendable, Hashable {
    /// The language.
    public var lang: Lang
    /// The region, if any.
    public var region: TextRegion?

    public init(lang: Lang, region: TextRegion?) {
        self.lang = lang
        self.region = region
    }

    /// The default locale: English without a region (`Locale::DEFAULT`).
    public static let DEFAULT = Locale(lang: .ENGLISH, region: nil)

    /// Read the locale from the style chain (`Locale::get_in`).
    ///
    /// The port stores `TextElem.lang`/`region` as raw `Smart<Str>` tags
    /// (fields 1 and 2), so the strings are parsed leniently here: absent,
    /// non-string, or unparseable values fall back to the English default
    /// language and no region.
    public static func getIn(_ styles: StyleChain) -> Locale {
        let text = Element(TextElem.self)
        var lang = Lang.ENGLISH
        if case let .str(s)? = styles.getValue(text, 1),
           let parsed = Lang(parsing: s.value) {
            lang = parsed
        }
        var region: TextRegion?
        if case let .str(s)? = styles.getValue(text, 2) {
            region = TextRegion(parsing: s.value)
        }
        return Locale(lang: lang, region: region)
    }

    /// The locale formatted as an RFC 3066 language tag (`en` / `en-US`).
    /// Port of `Locale::rfc_3066`.
    public func rfc3066() -> String {
        var buf = lang.asStr
        if let region {
            buf += "-"
            buf += region.asStr
        }
        return buf
    }
}

extension Locale: Comparable {
    /// Ordering on `(lang, region)` with `nil` regions sorting first,
    /// mirroring upstream's derived `Ord`.
    public static func < (lhs: Locale, rhs: Locale) -> Bool {
        if lhs.lang != rhs.lang { return lhs.lang < rhs.lang }
        switch (lhs.region, rhs.region) {
        case (.none, .some): return true
        case (.some, .none): return false
        case let (.some(l), .some(r)): return l < r
        case (.none, .none): return false
        }
    }
}

// MARK: - Lang

/// An identifier for a natural language.
///
/// Port of `Lang` in `text/lang.rs`. Codes are normalized to lowercase;
/// parsing accepts any two- or three-byte ASCII string without validating
/// against the constant table (mirroring upstream).
public struct Lang: Sendable, Hashable {
    /// The normalized lowercase language code.
    private let code: String

    /// Construct from an already normalized code (the constant table).
    private init(normalized code: String) {
        self.code = code
    }

    /// Construct a language from a two- or three-byte ISO 639-1/2/3 code.
    ///
    /// Port of `FromStr for Lang`: accepts any ASCII string of length two
    /// or three and lowercases it. Invalid inputs are rejected with
    /// "expected two or three letter language code (ISO 639-1/2/3)" at the
    /// cast boundary (`fromValue`).
    public init?(parsing iso: String) {
        guard (2...3).contains(iso.utf8.count),
              iso.utf8.allSatisfy({ $0 < 0x80 }) else { return nil }
        code = iso.lowercased()
    }

    /// The parse error message, surfaced by the cast.
    static let parseError =
        "expected two or three letter language code (ISO 639-1/2/3)"

    /// The language code as an all lowercase string (`Lang::as_str`).
    public var asStr: String { code }

    /// The default direction for the language (`Lang::dir`). Right-to-left
    /// for exactly the eleven languages upstream lists, left-to-right
    /// otherwise.
    public func dir() -> Dir {
        Self.rtlLanguages.contains(code) ? .rtl : .ltr
    }

    /// The codes of the eleven right-to-left languages in `Lang::dir`.
    private static let rtlLanguages: Set<String> = [
        Lang.ARABIC.code, Lang.DIVEHI.code, Lang.PERSIAN.code,
        Lang.HEBREW.code, Lang.KASHMIRI.code, Lang.PUNJABI.code,
        Lang.PASHTO.code, Lang.SINDHI.code, Lang.UYGHUR.code,
        Lang.URDU.code, Lang.YIDDISH.code,
    ]
}

extension Lang: Comparable {
    /// Byte-wise ordering of the space-padded three-byte array, then the
    /// length byte, mirroring upstream's derived `Ord` on `Lang([u8; 3], u8)`.
    public static func < (lhs: Lang, rhs: Lang) -> Bool {
        let (l, r) = (lhs.padded, rhs.padded)
        if l != r { return l < r }
        return lhs.code.count < rhs.code.count
    }

    /// The code space-padded to three bytes (upstream's array storage).
    private var padded: String {
        code.count == 3 ? code : code + String(repeating: " ", count: 3 - code.count)
    }
}

extension Lang: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Str.self)) }
    public static var output: CastInfo { input }

    public static func castable(_ value: Value) -> Bool {
        guard case let .str(s) = value else { return false }
        return Lang(parsing: s.value) != nil
    }

    public func intoValue() -> Value { .str(Str(code)) }

    /// Port of the `cast!` impl for `Lang`: parses the string, adding the
    /// `lang`/`region` parameter hint when the input looks like a combined
    /// language-region tag such as `en-US`.
    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .str(s) = value else { return .failure(error(value)) }
        let string = s.value
        if let lang = Lang(parsing: string) { return .success(lang) }

        var err = HintedString(parseError)
        if let dash = string.firstIndex(of: "-") {
            let langPart = String(string[string.startIndex..<dash])
            let regionPart = String(string[string.index(after: dash)...])
            if Lang(parsing: langPart) != nil, TextRegion(parsing: regionPart) != nil {
                err.hint(
                    "you should leave only \"\(langPart)\" in the `lang` parameter and specify \"\(regionPart)\" in the `region` parameter"
                )
            }
        }
        return .failure(err)
    }
}

/// The language constants. Port of the inherent `impl Lang` constant table
/// in `text/lang.rs` — all 317 of them, in upstream order.
extension Lang {
    public static let ABKHAZIAN = Lang(normalized: "ab")
    public static let AFAR = Lang(normalized: "aa")
    public static let AFRIKAANS = Lang(normalized: "af")
    public static let AGHEM = Lang(normalized: "agq")
    public static let AKAN = Lang(normalized: "ak")
    public static let AKKADIAN = Lang(normalized: "akk")
    public static let ALBANIAN = Lang(normalized: "sq")
    public static let ALGERIAN_ARABIC = Lang(normalized: "arq")
    public static let AMHARIC = Lang(normalized: "am")
    public static let ANCIENT_EGYPTIAN = Lang(normalized: "egy")
    public static let ANCIENT_GREEK = Lang(normalized: "grc")
    public static let ANCIENT_HEBREW = Lang(normalized: "hbo")
    public static let ARABIC = Lang(normalized: "ar")
    public static let ARAMAIC = Lang(normalized: "arc")
    public static let ARMENIAN = Lang(normalized: "hy")
    public static let ASSAMESE = Lang(normalized: "as")
    public static let ASTURIAN = Lang(normalized: "ast")
    public static let ASU = Lang(normalized: "asa")
    public static let ATSAM = Lang(normalized: "cch")
    public static let AVESTAN = Lang(normalized: "ae")
    public static let AWADHI = Lang(normalized: "awa")
    public static let AYMARA = Lang(normalized: "ay")
    public static let AZERBAIJANI = Lang(normalized: "az")
    public static let BAFIA = Lang(normalized: "ksf")
    public static let BALINESE = Lang(normalized: "ban")
    public static let BALUCHI = Lang(normalized: "bal")
    public static let BAMBARA = Lang(normalized: "bm")
    public static let BANGLA = Lang(normalized: "bn")
    public static let BASAA = Lang(normalized: "bas")
    public static let BASHKIR = Lang(normalized: "ba")
    public static let BASQUE = Lang(normalized: "eu")
    public static let BATAK_TOBA = Lang(normalized: "bbc")
    public static let BAVARIAN = Lang(normalized: "bar")
    public static let BELARUSIAN = Lang(normalized: "be")
    public static let BEMBA = Lang(normalized: "bem")
    public static let BENA = Lang(normalized: "bez")
    public static let BETAWI = Lang(normalized: "bew")
    public static let BHOJPURI = Lang(normalized: "bho")
    public static let BLIN = Lang(normalized: "byn")
    public static let BODO = Lang(normalized: "brx")
    public static let BOSNIAN = Lang(normalized: "bs")
    public static let BRETON = Lang(normalized: "br")
    public static let BULGARIAN = Lang(normalized: "bg")
    public static let BURIAT = Lang(normalized: "bua")
    public static let BURMESE = Lang(normalized: "my")
    public static let CANTONESE = Lang(normalized: "yue")
    public static let CARIAN = Lang(normalized: "xcr")
    public static let CATALAN = Lang(normalized: "ca")
    public static let CEBUANO = Lang(normalized: "ceb")
    public static let CENTRAL_ATLAS_TAMAZIGHT = Lang(normalized: "tzm")
    public static let CENTRAL_KURDISH = Lang(normalized: "ckb")
    public static let CHAKMA = Lang(normalized: "ccp")
    public static let CHECHEN = Lang(normalized: "ce")
    public static let CHEROKEE = Lang(normalized: "chr")
    public static let CHIGA = Lang(normalized: "cgg")
    public static let CHINESE = Lang(normalized: "zh")
    public static let CHURCH_SLAVIC = Lang(normalized: "cu")
    public static let CHUVASH = Lang(normalized: "cv")
    public static let CLASSICAL_MANDAIC = Lang(normalized: "myz")
    public static let COLOGNIAN = Lang(normalized: "ksh")
    public static let COPTIC = Lang(normalized: "cop")
    public static let CORNISH = Lang(normalized: "kw")
    public static let CORSICAN = Lang(normalized: "co")
    public static let CROATIAN = Lang(normalized: "hr")
    public static let CZECH = Lang(normalized: "cs")
    public static let DANISH = Lang(normalized: "da")
    public static let DIVEHI = Lang(normalized: "dv")
    public static let DOGRI = Lang(normalized: "doi")
    public static let DUALA = Lang(normalized: "dua")
    public static let DUTCH = Lang(normalized: "nl")
    public static let DZONGKHA = Lang(normalized: "dz")
    public static let EGYPTIAN_ARABIC = Lang(normalized: "arz")
    public static let EMBU = Lang(normalized: "ebu")
    public static let ENGLISH = Lang(normalized: "en")
    public static let ERZYA = Lang(normalized: "myv")
    public static let ESPERANTO = Lang(normalized: "eo")
    public static let ESTONIAN = Lang(normalized: "et")
    public static let ETRUSCAN = Lang(normalized: "ett")
    public static let EWE = Lang(normalized: "ee")
    public static let EWONDO = Lang(normalized: "ewo")
    public static let FAROESE = Lang(normalized: "fo")
    public static let FILIPINO = Lang(normalized: "fil")
    public static let FINNISH = Lang(normalized: "fi")
    public static let FRENCH = Lang(normalized: "fr")
    public static let FRIULIAN = Lang(normalized: "fur")
    public static let FULAH = Lang(normalized: "ff")
    public static let GA = Lang(normalized: "gaa")
    public static let GALICIAN = Lang(normalized: "gl")
    public static let GANDA = Lang(normalized: "lg")
    public static let GEEZ = Lang(normalized: "gez")
    public static let GEORGIAN = Lang(normalized: "ka")
    public static let GERMAN = Lang(normalized: "de")
    public static let GOTHIC = Lang(normalized: "got")
    public static let GREEK = Lang(normalized: "el")
    public static let GUARANI = Lang(normalized: "gn")
    public static let GUJARATI = Lang(normalized: "gu")
    public static let GUSII = Lang(normalized: "guz")
    public static let HARYANVI = Lang(normalized: "bgc")
    public static let HAUSA = Lang(normalized: "ha")
    public static let HAWAIIAN = Lang(normalized: "haw")
    public static let HEBREW = Lang(normalized: "he")
    public static let HINDI = Lang(normalized: "hi")
    public static let HMONG_NJUA = Lang(normalized: "hnj")
    public static let HUNGARIAN = Lang(normalized: "hu")
    public static let ICELANDIC = Lang(normalized: "is")
    public static let IGBO = Lang(normalized: "ig")
    public static let INARI_SAMI = Lang(normalized: "smn")
    public static let INDONESIAN = Lang(normalized: "id")
    public static let INGUSH = Lang(normalized: "inh")
    public static let INTERLINGUA = Lang(normalized: "ia")
    public static let INTERSLAVIC = Lang(normalized: "isv")
    public static let INUKTITUT = Lang(normalized: "iu")
    public static let IRISH = Lang(normalized: "ga")
    public static let ITALIAN = Lang(normalized: "it")
    public static let JAPANESE = Lang(normalized: "ja")
    public static let JAVANESE = Lang(normalized: "jv")
    public static let JJU = Lang(normalized: "kaj")
    public static let JOLA_FONYI = Lang(normalized: "dyo")
    public static let KABUVERDIANU = Lang(normalized: "kea")
    public static let KABYLE = Lang(normalized: "kab")
    public static let KAINGANG = Lang(normalized: "kgp")
    public static let KAKO = Lang(normalized: "kkj")
    public static let KALAALLISUT = Lang(normalized: "kl")
    public static let KALENJIN = Lang(normalized: "kln")
    public static let KAMBA = Lang(normalized: "kam")
    public static let KANGRI = Lang(normalized: "xnr")
    public static let KANNADA = Lang(normalized: "kn")
    public static let KASHMIRI = Lang(normalized: "ks")
    public static let KAZAKH = Lang(normalized: "kk")
    public static let KHMER = Lang(normalized: "km")
    public static let KIKUYU = Lang(normalized: "ki")
    public static let KINYARWANDA = Lang(normalized: "rw")
    public static let KOMI = Lang(normalized: "kv")
    public static let KONKANI = Lang(normalized: "kok")
    public static let KOREAN = Lang(normalized: "ko")
    public static let KOYRABORO_SENNI = Lang(normalized: "ses")
    public static let KOYRA_CHIINI = Lang(normalized: "khq")
    public static let KURDISH = Lang(normalized: "ku")
    public static let KWASIO = Lang(normalized: "nmg")
    public static let KYRGYZ = Lang(normalized: "ky")
    public static let LADINO = Lang(normalized: "lad")
    public static let LAKOTA = Lang(normalized: "lkt")
    public static let LANGI = Lang(normalized: "lag")
    public static let LAO = Lang(normalized: "lo")
    public static let LATIN = Lang(normalized: "la")
    public static let LATVIAN = Lang(normalized: "lv")
    public static let LEPCHA = Lang(normalized: "lep")
    public static let LIGURIAN = Lang(normalized: "lij")
    public static let LIMBU = Lang(normalized: "lif")
    public static let LINEAR_A = Lang(normalized: "lab")
    public static let LINGALA = Lang(normalized: "ln")
    public static let LITHUANIAN = Lang(normalized: "lt")
    public static let LOMBARD = Lang(normalized: "lmo")
    public static let LOWER_SORBIAN = Lang(normalized: "dsb")
    public static let LOW_GERMAN = Lang(normalized: "nds")
    public static let LUBA_KATANGA = Lang(normalized: "lu")
    public static let LUO = Lang(normalized: "luo")
    public static let LUXEMBOURGISH = Lang(normalized: "lb")
    public static let LUYIA = Lang(normalized: "luy")
    public static let LYCIAN = Lang(normalized: "xlc")
    public static let LYDIAN = Lang(normalized: "xld")
    public static let LU = Lang(normalized: "khb")
    public static let MACEDONIAN = Lang(normalized: "mk")
    public static let MACHAME = Lang(normalized: "jmc")
    public static let MAITHILI = Lang(normalized: "mai")
    public static let MAKASAR = Lang(normalized: "mak")
    public static let MAKHUWA_MEETTO = Lang(normalized: "mgh")
    public static let MAKHUWA = Lang(normalized: "vmw")
    public static let MAKONDE = Lang(normalized: "kde")
    public static let MALAGASY = Lang(normalized: "mg")
    public static let MALAY = Lang(normalized: "ms")
    public static let MALAYALAM = Lang(normalized: "ml")
    public static let MALTESE = Lang(normalized: "mt")
    public static let MANIPURI = Lang(normalized: "mni")
    public static let MANX = Lang(normalized: "gv")
    public static let MARATHI = Lang(normalized: "mr")
    public static let MASAI = Lang(normalized: "mas")
    public static let MAZANDERANI = Lang(normalized: "mzn")
    public static let MERU = Lang(normalized: "mer")
    public static let METAʼ = Lang(normalized: "mgo")
    public static let MONGOLIAN = Lang(normalized: "mn")
    public static let MORISYEN = Lang(normalized: "mfe")
    public static let MUNDANG = Lang(normalized: "mua")
    public static let MUSCOGEE = Lang(normalized: "mus")
    public static let MAORI = Lang(normalized: "mi")
    public static let NAMA = Lang(normalized: "naq")
    public static let NAVAJO = Lang(normalized: "nv")
    public static let NEPALI = Lang(normalized: "ne")
    public static let NEWARI = Lang(normalized: "new")
    public static let NGIEMBOON = Lang(normalized: "nnh")
    public static let NGOMBA = Lang(normalized: "jgo")
    public static let NHEENGATU = Lang(normalized: "yrl")
    public static let NIGERIAN_PIDGIN = Lang(normalized: "pcm")
    public static let NORTHERN_FRISIAN = Lang(normalized: "frr")
    public static let NORTHERN_KURDISH = Lang(normalized: "kmr")
    public static let NORTHERN_LURI = Lang(normalized: "lrc")
    public static let NORTHERN_SAMI = Lang(normalized: "se")
    public static let NORTHERN_SOTHO = Lang(normalized: "nso")
    public static let NORTH_NDEBELE = Lang(normalized: "nd")
    public static let NORWEGIAN = Lang(normalized: "no")
    public static let NORWEGIAN_BOKMAL = Lang(normalized: "nb")
    public static let NORWEGIAN_NYNORSK = Lang(normalized: "nn")
    public static let NUER = Lang(normalized: "nus")
    public static let NYANJA = Lang(normalized: "ny")
    public static let NYANKOLE = Lang(normalized: "nyn")
    public static let NKO = Lang(normalized: "nqo")
    public static let OCCITAN = Lang(normalized: "oc")
    public static let ODIA = Lang(normalized: "or")
    public static let OLD_IRISH = Lang(normalized: "sga")
    public static let OLD_NORSE = Lang(normalized: "non")
    public static let OLD_PERSIAN = Lang(normalized: "peo")
    public static let OLD_UIGHUR = Lang(normalized: "oui")
    public static let OROMO = Lang(normalized: "om")
    public static let OSAGE = Lang(normalized: "osa")
    public static let OSSETIC = Lang(normalized: "os")
    public static let PAPIAMENTO = Lang(normalized: "pap")
    public static let PASHTO = Lang(normalized: "ps")
    public static let PERSIAN = Lang(normalized: "fa")
    public static let PHOENICIAN = Lang(normalized: "phn")
    public static let PIEDMONTESE = Lang(normalized: "pms")
    public static let POLISH = Lang(normalized: "pl")
    public static let PORTUGUESE = Lang(normalized: "pt")
    public static let PRUSSIAN = Lang(normalized: "prg")
    public static let PUNJABI = Lang(normalized: "pa")
    public static let QUECHUA = Lang(normalized: "qu")
    public static let RAJASTHANI = Lang(normalized: "raj")
    public static let ROMANIAN = Lang(normalized: "ro")
    public static let ROMANSH = Lang(normalized: "rm")
    public static let ROMBO = Lang(normalized: "rof")
    public static let RUNDI = Lang(normalized: "rn")
    public static let RUSSIAN = Lang(normalized: "ru")
    public static let RWA = Lang(normalized: "rwk")
    public static let SABAEAN = Lang(normalized: "xsa")
    public static let SAHO = Lang(normalized: "ssy")
    public static let SAKHA = Lang(normalized: "sah")
    public static let SAMARITAN = Lang(normalized: "smp")
    public static let SAMBURU = Lang(normalized: "saq")
    public static let SANGO = Lang(normalized: "sg")
    public static let SANGU = Lang(normalized: "sbp")
    public static let SANSKRIT = Lang(normalized: "sa")
    public static let SANTALI = Lang(normalized: "sat")
    public static let SARAIKI = Lang(normalized: "skr")
    public static let SARDINIAN = Lang(normalized: "sc")
    public static let SCOTTISH_GAELIC = Lang(normalized: "gd")
    public static let SENA = Lang(normalized: "seh")
    public static let SERBIAN = Lang(normalized: "sr")
    public static let SHAMBALA = Lang(normalized: "ksb")
    public static let SHONA = Lang(normalized: "sn")
    public static let SICHUAN_YI = Lang(normalized: "ii")
    public static let SICILIAN = Lang(normalized: "scn")
    public static let SILESIAN = Lang(normalized: "szl")
    public static let SINDHI = Lang(normalized: "sd")
    public static let SINHALA = Lang(normalized: "si")
    public static let SINTE_ROMANI = Lang(normalized: "rmo")
    public static let SLOVAK = Lang(normalized: "sk")
    public static let SLOVENIAN = Lang(normalized: "sl")
    public static let SOGA = Lang(normalized: "xog")
    public static let SOMALI = Lang(normalized: "so")
    public static let SOUTHERN_ALTAI = Lang(normalized: "alt")
    public static let SOUTHERN_SOTHO = Lang(normalized: "st")
    public static let SOUTH_NDEBELE = Lang(normalized: "nr")
    public static let SPANISH = Lang(normalized: "es")
    public static let STANDARD_MOROCCAN_TAMAZIGHT = Lang(normalized: "zgh")
    public static let SUNDANESE = Lang(normalized: "su")
    public static let SWAHILI = Lang(normalized: "sw")
    public static let SWATI = Lang(normalized: "ss")
    public static let SWEDISH = Lang(normalized: "sv")
    public static let SWISS_GERMAN = Lang(normalized: "gsw")
    public static let SYRIAC = Lang(normalized: "syr")
    public static let TACHELHIT = Lang(normalized: "shi")
    public static let TAITA = Lang(normalized: "dav")
    public static let TAI_NUA = Lang(normalized: "tdd")
    public static let TAJIK = Lang(normalized: "tg")
    public static let TAMIL = Lang(normalized: "ta")
    public static let TANGUT = Lang(normalized: "txg")
    public static let TAROKO = Lang(normalized: "trv")
    public static let TASAWAQ = Lang(normalized: "twq")
    public static let TATAR = Lang(normalized: "tt")
    public static let TELUGU = Lang(normalized: "te")
    public static let TESO = Lang(normalized: "teo")
    public static let THAI = Lang(normalized: "th")
    public static let TIBETAN = Lang(normalized: "bo")
    public static let TIGRE = Lang(normalized: "tig")
    public static let TIGRINYA = Lang(normalized: "ti")
    public static let TOK_PISIN = Lang(normalized: "tpi")
    public static let TONGAN = Lang(normalized: "to")
    public static let TSONGA = Lang(normalized: "ts")
    public static let TSWANA = Lang(normalized: "tn")
    public static let TURKISH = Lang(normalized: "tr")
    public static let TURKMEN = Lang(normalized: "tk")
    public static let TYAP = Lang(normalized: "kcg")
    public static let UGARITIC = Lang(normalized: "uga")
    public static let UKRAINIAN = Lang(normalized: "uk")
    public static let UNKNOWN_LANGUAGE = Lang(normalized: "und")
    public static let UPPER_SORBIAN = Lang(normalized: "hsb")
    public static let URDU = Lang(normalized: "ur")
    public static let UYGHUR = Lang(normalized: "ug")
    public static let UZBEK = Lang(normalized: "uz")
    public static let VAI = Lang(normalized: "vai")
    public static let VENDA = Lang(normalized: "ve")
    public static let VENETIAN = Lang(normalized: "vec")
    public static let VIETNAMESE = Lang(normalized: "vi")
    public static let VOLAPUK = Lang(normalized: "vo")
    public static let VUNJO = Lang(normalized: "vun")
    public static let WALSER = Lang(normalized: "wae")
    public static let WARAY = Lang(normalized: "war")
    public static let WELSH = Lang(normalized: "cy")
    public static let WESTERN_FRISIAN = Lang(normalized: "fy")
    public static let WOLAYTTA = Lang(normalized: "wal")
    public static let WOLOF = Lang(normalized: "wo")
    public static let XHOSA = Lang(normalized: "xh")
    public static let YANGBEN = Lang(normalized: "yav")
    public static let YIDDISH = Lang(normalized: "yi")
    public static let YORUBA = Lang(normalized: "yo")
    public static let ZARMA = Lang(normalized: "dje")
    public static let ZHUANG = Lang(normalized: "za")
    public static let ZULU = Lang(normalized: "zu")
}

// MARK: - TextRegion

/// An identifier for a region somewhere in the world.
///
/// Port of `Region` in `text/lang.rs`: a two-letter ISO 3166-1 alpha-2
/// code, normalized to uppercase, not validated against the standard.
///
/// Renamed `TextRegion` because Swift types share one module-wide
/// namespace and `Layout/Regions.swift` already claims `Region` (upstream
/// Rust keeps the two in separate modules).
public struct TextRegion: Sendable, Hashable {
    /// The normalized uppercase region code.
    private let code: String

    /// Construct a region from its two-byte ISO 3166-1 alpha-2 code.
    ///
    /// Port of `FromStr for Region`. Invalid inputs are rejected with
    /// "expected two letter region code (ISO 3166-1 alpha-2)" at the cast
    /// boundary (`fromValue`).
    public init?(parsing iso: String) {
        guard iso.utf8.count == 2,
              iso.utf8.allSatisfy({ $0 < 0x80 }) else { return nil }
        code = iso.uppercased()
    }

    /// The parse error message, surfaced by the cast.
    static let parseError = "expected two letter region code (ISO 3166-1 alpha-2)"

    /// The region code as an all uppercase string (`Region::as_str`).
    public var asStr: String { code }
}

extension TextRegion: Comparable {
    public static func < (lhs: TextRegion, rhs: TextRegion) -> Bool {
        lhs.code < rhs.code
    }
}

extension TextRegion: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Str.self)) }
    public static var output: CastInfo { input }

    public static func castable(_ value: Value) -> Bool {
        guard case let .str(s) = value else { return false }
        return TextRegion(parsing: s.value) != nil
    }

    public func intoValue() -> Value { .str(Str(code)) }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .str(s) = value else { return .failure(error(value)) }
        guard let region = TextRegion(parsing: s.value) else {
            return .failure(HintedString(parseError))
        }
        return .success(region)
    }
}

// MARK: - WritingScript

/// An ISO 15924-type script identifier.
///
/// Port of `WritingScript` in `text/lang.rs`: three or four ASCII letters,
/// normalized to lowercase.
public struct WritingScript: Sendable, Hashable {
    /// The normalized lowercase script code.
    private let code: String

    /// Construct a script from its ISO 15924 code.
    ///
    /// Port of `FromStr for WritingScript`. Invalid inputs are rejected
    /// with "expected three or four letter script code (ISO 15924 or
    /// 'math')" at the cast boundary (`fromValue`).
    public init?(parsing iso: String) {
        guard (3...4).contains(iso.utf8.count),
              iso.utf8.allSatisfy({ $0 < 0x80 }) else { return nil }
        code = iso.lowercased()
    }

    /// The parse error message, surfaced by the cast.
    static let parseError =
        "expected three or four letter script code (ISO 15924 or 'math')"

    /// The script as an all lowercase string (`WritingScript::as_str`).
    public var asStr: String { code }

    /// The script as space-padded bytes (`WritingScript::as_bytes`,
    /// upstream's `[u8; 4]` storage).
    public var asBytes: [UInt8] {
        var bytes = Array(code.utf8)
        while bytes.count < 4 { bytes.append(UInt8(ascii: " ")) }
        return bytes
    }
}

extension WritingScript: Comparable {
    /// Byte-wise ordering of the space-padded four-byte array, then the
    /// length byte, mirroring upstream's derived `Ord`.
    public static func < (lhs: WritingScript, rhs: WritingScript) -> Bool {
        let (l, r) = (lhs.padded, rhs.padded)
        if l != r { return l < r }
        return lhs.code.count < rhs.code.count
    }

    /// The code space-padded to four bytes (upstream's array storage).
    private var padded: String {
        code.count == 4 ? code : code + String(repeating: " ", count: 4 - code.count)
    }
}

extension WritingScript: Castable, IntoValue, FromValue {
    public static var input: CastInfo { .type(Type.of(Str.self)) }
    public static var output: CastInfo { input }

    public static func castable(_ value: Value) -> Bool {
        guard case let .str(s) = value else { return false }
        return WritingScript(parsing: s.value) != nil
    }

    public func intoValue() -> Value { .str(Str(code)) }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        guard case let .str(s) = value else { return .failure(error(value)) }
        guard let script = WritingScript(parsing: s.value) else {
            return .failure(HintedString(parseError))
        }
        return .success(script)
    }
}

// MARK: - Localized strings

/// Retrieves the localized string for a given language and region.
///
/// Port of `localized_str` in `text/lang.rs`. Lookup order:
/// 1. the `lang-REGION` bundle,
/// 2. the `lang` bundle,
/// 3. the English bundle.
///
/// Silently falls back to English if no fitting string exists for the given
/// language + region. Missing files yield empty maps, not errors. A key
/// missing even in English is a port bug (the data is embedded), hence the
/// precondition failure — mirroring upstream's `unwrap`.
public func localizedStr(lang: Lang, region: TextRegion?, key: String) -> String {
    if let hit = parsedBundles[langStr(lang, region)]?[key] {
        return hit
    }
    if let hit = parsedBundles[lang.asStr]?[key] {
        return hit
    }
    guard let hit = parsedBundles[Lang.ENGLISH.asStr]?[key] else {
        preconditionFailure(
            "missing translation for key \"\(key)\" in the English bundle")
    }
    return hit
}

/// All translation bundles, parsed once from the embedded files. Upstream
/// memoizes `parse_language_bundle` per language; since the data is static
/// and tiny, the port parses everything eagerly into an immutable table.
private let parsedBundles: [String: [String: String]] = {
    var result: [String: [String: String]] = [:]
    for (name, contents) in Translations.translationData {
        result[name] = parseTranslationBundle(contents)
    }
    return result
}()

/// Parse one translation file into a key-value map.
///
/// Port of `parse_language_bundle` in `text/lang.rs`: `key = value` lines,
/// `#` comments and blank lines skipped. Malformed input is a port bug —
/// the data is embedded and verified — so violations are precondition
/// failures carrying upstream's error messages.
private func parseTranslationBundle(_ contents: String) -> [String: String] {
    var bundle: [String: String] = [:]
    let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
    for rawLine in trimmed.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(rawLine)
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
        if trimmedLine.isEmpty || trimmedLine.hasPrefix("#") {
            continue
        }
        guard let eq = line.firstIndex(of: "=") else {
            preconditionFailure("malformed translation file: line without \"=\"")
        }
        let key = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces)
        let val = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if val.isEmpty {
            preconditionFailure("malformed translation file: empty translation value")
        }
        if bundle.updateValue(val, forKey: key) != nil {
            preconditionFailure("malformed translation file: duplicate key")
        }
    }
    return bundle
}

/// Convert language + region to the bundle key (`lang_str` upstream):
/// the lowercase language, plus `-REGION` when a region is present.
private func langStr(_ lang: Lang, _ region: TextRegion?) -> String {
    guard let region else { return lang.asStr }
    return lang.asStr + "-" + region.asStr
}
