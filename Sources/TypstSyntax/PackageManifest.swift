import Foundation

/// A value in a TOML document, used for package manifest fields that are
/// parsed but not interpreted by Typst itself (`[tool.*]` sections and
/// unknown fields).
public indirect enum TomlValue: Hashable, Sendable {
    case string(String)
    case bool(Bool)
    case int(Int64)
    case float(Double)
    case datetime(String)
    case array([TomlValue])
    case table([String: TomlValue])
}

/// A type alias for a map of key-value pairs used to collect unknown fields
/// where values are preserved verbatim for validation.
public typealias UnknownFields = [String: TomlValue]

/// A parsed package manifest.
///
/// The `unknownFields` contains fields which were found but not expected.
public struct PackageManifest: Equatable, Sendable {
    /// Details about the package itself.
    public var package: PackageInfo
    /// Details about the template, if the package is one.
    public var template: TemplateInfo?
    /// The tools section for third-party configuration.
    public var tool: ToolInfo
    /// All parsed but unknown fields, this can be used for validation.
    public var unknownFields: UnknownFields

    /// Create a new package manifest with the given package info.
    public init(package: PackageInfo) {
        self.package = package
        self.template = nil
        self.tool = ToolInfo()
        self.unknownFields = [:]
    }

    /// Ensure that this manifest is indeed for the specified package.
    public func validate(_ spec: PackageSpec) throws(ValidationError) {
        if package.name != spec.name {
            throw .message(
                "package manifest contains mismatched name `\(package.name)`")
        }
        if package.version != spec.version {
            throw .message(
                "package manifest contains mismatched version \(package.version)")
        }
        if let required = package.compiler {
            let current = PackageVersion.compiler()
            if !current.matchesGe(required) {
                throw .message(
                    "package requires Typst \(required) or newer "
                        + "(current version is \(current))")
            }
        }
    }

    /// An error produced by `PackageManifest.validate`.
    public enum ValidationError: Error, Hashable, Sendable, CustomStringConvertible {
        case message(String)

        public var description: String {
            switch self {
            case .message(let m): return m
            }
        }
    }
}

/// The `[tool]` key in the manifest. This field can be used to retrieve
/// 3rd-party tool configuration.
public struct ToolInfo: Equatable, Sendable {
    /// Any fields parsed in the tool section.
    public var sections: [String: [String: TomlValue]]

    public init(sections: [String: [String: TomlValue]] = [:]) {
        self.sections = sections
    }
}

/// The `[template]` key in the manifest.
public struct TemplateInfo: Equatable, Sendable {
    /// The directory within the package that contains the files that should
    /// be copied into the user's new project directory.
    public var path: VirtualPath
    /// A path relative to the template's path that points to the file
    /// serving as the compilation target.
    public var entrypoint: VirtualPath
    /// A path relative to the package's root that points to a PNG or
    /// lossless WebP thumbnail for the template.
    public var thumbnail: VirtualPath?
    /// All parsed but unknown fields, this can be used for validation.
    public var unknownFields: UnknownFields

    /// Create a new template info with only required fields.
    public init(path: VirtualPath, entrypoint: VirtualPath) {
        self.path = path
        self.entrypoint = entrypoint
        self.thumbnail = nil
        self.unknownFields = [:]
    }
}

/// The `[package]` key in the manifest.
public struct PackageInfo: Equatable, Sendable {
    /// The name of the package within its namespace.
    public var name: String
    /// The package's version.
    public var version: PackageVersion
    /// The path of the entrypoint into the package.
    public var entrypoint: VirtualPath
    /// A list of the package's authors.
    public var authors: [String]
    /// The package's license.
    public var license: String?
    /// A short description of the package.
    public var description: String?
    /// A link to the package's web presence.
    public var homepage: String?
    /// A link to the repository where this package is developed.
    public var repository: String?
    /// An array of search keywords for the package.
    public var keywords: [String]
    /// An array with up to three of the predefined categories to help users
    /// discover the package.
    public var categories: [String]
    /// An array of disciplines defining the target audience for which the
    /// package is useful.
    public var disciplines: [String]
    /// The minimum required compiler version for the package.
    public var compiler: VersionBound?
    /// An array of globs specifying files that should not be part of the
    /// published bundle.
    public var exclude: [String]
    /// All parsed but unknown fields, this can be used for validation.
    public var unknownFields: UnknownFields

    /// Create a new package info with only required fields.
    public init(
        name: String,
        version: PackageVersion,
        entrypoint: VirtualPath
    ) {
        self.name = name
        self.version = version
        self.entrypoint = entrypoint
        self.authors = []
        self.categories = []
        self.compiler = nil
        self.description = nil
        self.disciplines = []
        self.exclude = []
        self.homepage = nil
        self.keywords = []
        self.license = nil
        self.repository = nil
        self.unknownFields = [:]
    }

    /// Full memberwise initializer for manifest decoding.
    public init(
        name: String,
        version: PackageVersion,
        entrypoint: VirtualPath,
        authors: [String] = [],
        license: String? = nil,
        description: String? = nil,
        homepage: String? = nil,
        repository: String? = nil,
        keywords: [String] = [],
        categories: [String] = [],
        disciplines: [String] = [],
        compiler: VersionBound? = nil,
        exclude: [String] = [],
        unknownFields: UnknownFields = [:]
    ) {
        self.name = name
        self.version = version
        self.entrypoint = entrypoint
        self.authors = authors
        self.license = license
        self.description = description
        self.homepage = homepage
        self.repository = repository
        self.keywords = keywords
        self.categories = categories
        self.disciplines = disciplines
        self.compiler = compiler
        self.exclude = exclude
        self.unknownFields = unknownFields
    }
}
