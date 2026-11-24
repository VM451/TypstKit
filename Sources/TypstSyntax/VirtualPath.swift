import Foundation

/// Virtual, cross-platform reproducible path handling.
///
/// Port of `typst-syntax/src/path.rs` and the `PackageSpec` /
/// `PackageVersion` parts of `package.rs`.

// MARK: - Package spec

/// Identifies a package.
public struct PackageSpec: Hashable, Sendable, CustomStringConvertible {
    /// The namespace the package lives in.
    public var namespace: String
    /// The name of the package within its namespace.
    public var name: String
    /// The package's version.
    public var version: PackageVersion

    public init(namespace: String, name: String, version: PackageVersion) {
        self.namespace = namespace
        self.name = name
        self.version = version
    }

    /// Identifies the package without a specific version.
    public func versionless() -> VersionlessPackageSpec {
        VersionlessPackageSpec(namespace: namespace, name: name)
    }

    public var description: String { "@\(namespace)/\(name):\(version)" }
}

extension PackageSpec: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = try! PackageSpec.parse(value)
    }
}

extension PackageSpec {
    /// Parse `@namespace/name:major.minor.patch`.
    public static func parse(_ s: String) throws -> PackageSpec {
        var rest = s
        guard rest.hasPrefix("@") else {
            throw PathError.message("package specification must start with '@'")
        }
        rest.removeFirst()
        guard let slash = rest.firstIndex(of: "/") else {
            throw PathError.message("package specification is missing '/' after namespace")
        }
        let namespace = String(rest[..<slash])
        rest = String(rest[rest.index(after: slash)...])
        guard let colon = rest.firstIndex(of: ":") else {
            throw PathError.message("package specification is missing ':' before version")
        }
        let name = String(rest[..<colon])
        let version = try PackageVersion.parse(String(rest[rest.index(after: colon)...]))
        guard isValidPackagePart(namespace), isValidPackagePart(name) else {
            throw PathError.message("invalid package namespace or name")
        }
        return PackageSpec(namespace: namespace, name: name, version: version)
    }

    static func isValidPackagePart(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
        }
    }
}

/// Identifies a package, but not a specific version of it.
public struct VersionlessPackageSpec: Hashable, Sendable, CustomStringConvertible {
    public var namespace: String
    public var name: String

    public init(namespace: String, name: String) {
        self.namespace = namespace
        self.name = name
    }

    /// Fill in the `version` to get a complete `PackageSpec`.
    public func at(_ version: PackageVersion) -> PackageSpec {
        PackageSpec(namespace: namespace, name: name, version: version)
    }

    public var description: String { "@\(namespace)/\(name)" }
}

/// A package version (`major.minor.patch`).
public struct PackageVersion: Hashable, Sendable, Comparable, CustomStringConvertible {
    public var major: UInt32
    public var minor: UInt32
    public var patch: UInt32

    public init(major: UInt32, minor: UInt32, patch: UInt32) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public static func parse(_ s: String) throws -> PackageVersion {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = UInt32(parts[0]),
              let minor = UInt32(parts[1]),
              let patch = UInt32(parts[2]),
              parts.allSatisfy({ !$0.isEmpty }) else {
            throw PathError.message("invalid package version '\(s)'")
        }
        return PackageVersion(major: major, minor: minor, patch: patch)
    }

    public static func < (a: PackageVersion, b: PackageVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}

/// A version bound used in package manifests (`major`, `major.minor`,
/// `major.minor.patch`).
public struct VersionBound: Hashable, Sendable {
    public var major: UInt32
    public var minor: UInt32?
    public var patch: UInt32?

    public init(major: UInt32, minor: UInt32? = nil, patch: UInt32? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }
}

extension PackageVersion {
    /// Performs an `==` match with the given version bound. Version
    /// elements missing in the bound are ignored.
    public func matchesEq(_ bound: VersionBound) -> Bool {
        major == bound.major
            && (bound.minor.map { minor == $0 } ?? true)
            && (bound.patch.map { patch == $0 } ?? true)
    }

    /// Performs a `>` match with the given version bound.
    public func matchesGt(_ bound: VersionBound) -> Bool {
        if major != bound.major { return major > bound.major }
        guard let minorBound = bound.minor else { return false }
        if minor != minorBound { return minor > minorBound }
        guard let patchBound = bound.patch else { return false }
        return patch > patchBound
    }

    /// Performs a `<` match with the given version bound.
    public func matchesLt(_ bound: VersionBound) -> Bool {
        if major != bound.major { return major < bound.major }
        guard let minorBound = bound.minor else { return false }
        if minor != minorBound { return minor < minorBound }
        guard let patchBound = bound.patch else { return false }
        return patch < patchBound
    }

    /// `>=` match: `==` or `>`.
    public func matchesGe(_ bound: VersionBound) -> Bool {
        matchesEq(bound) || matchesGt(bound)
    }

    /// `<=` match: `==` or `<`.
    public func matchesLe(_ bound: VersionBound) -> Bool {
        matchesEq(bound) || matchesLt(bound)
    }
}

// MARK: - Errors

/// An error that can occur on construction or modification of a
/// `VirtualPath`.
public enum PathError: Error, Hashable, Sendable, CustomStringConvertible {
    /// A path segment is invalid.
    case invalid(String)
    /// A path tried to escape its root via `..`.
    case escapes
    /// A backslash was found in a path.
    case backslash
    /// A path contains a NUL byte.
    case nul
    /// A generic message error.
    case message(String)

    public var description: String {
        switch self {
        case .invalid(let s): return "invalid path segment '\(s)'"
        case .escapes: return "path escapes its root"
        case .backslash: return "path contains a backslash"
        case .nul: return "path contains a NUL byte"
        case .message(let m): return m
        }
    }
}

/// An error that can occur when realizing a virtual path on the host
/// file system.
public enum RealizeError: Error, Hashable, Sendable, CustomStringConvertible {
    /// A segment is not a valid platform path component.
    case invalid(String)

    public var description: String {
        switch self {
        case .invalid(let segment): return "cannot realize path segment '\(segment)'"
        }
    }
}

/// An error that can occur when virtualizing a real path.
public enum VirtualizeError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The real path is not valid UTF-8.
    case utf8
    /// The path could not be expressed virtually.
    case invalid(PathError)

    public var description: String {
        switch self {
        case .utf8: return "path is not valid UTF-8"
        case .invalid(let e): return e.description
        }
    }
}

// MARK: - VirtualPath

/// A path in a virtual file system.
///
/// The underlying storage is a normalized absolute path string that always
/// starts with `/`. Segments are never empty, `.`, or `..` and never
/// contain slashes.
public struct VirtualPath: Hashable, Sendable, CustomStringConvertible {
    /// Normalized absolute path, always starting with `/`.
    private var storage: String

    /// The root path `/`.
    public static let root = VirtualPath(unchecked: "/")

    private init(unchecked storage: String) {
        self.storage = storage
    }

    /// Creates a new virtual path, normalizing `.`/`..`/duplicate slashes.
    public init(_ path: String) throws {
        self.storage = try VirtualPath.normalize(path)
    }

    /// Whether this is the path `/`.
    public var isRoot: Bool { storage == "/" }

    /// The path with a leading slash.
    public var withSlash: String { storage }

    /// The path without a leading slash.
    public var withoutSlash: String {
        storage.hasPrefix("/") ? String(storage.dropFirst()) : storage
    }

    public var description: String { storage }

    /// The file name portion of the path.
    public var fileName: String? {
        guard !isRoot else { return nil }
        return storage.split(separator: "/").last.map(String.init)
    }

    /// The file name without its extension.
    public var fileStem: String? {
        guard let name = fileName else { return nil }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else {
            return name
        }
        return String(name[..<dot])
    }

    /// The file extension of the path.
    public var `extension`: String? {
        guard let name = fileName,
              let dot = name.lastIndex(of: "."), dot != name.startIndex,
              name.index(after: dot) < name.endIndex else { return nil }
        return String(name[name.index(after: dot)...])
    }

    /// Returns a modified path with an adjusted extension.
    public func withExtension(_ ext: String) -> VirtualPath {
        guard let stem = fileStem else { return self }
        let newName = "\(stem).\(ext)"
        guard !newName.contains("/") && !newName.contains("\\") else {
            return self
        }
        var copy = storage
        if let range = copy.range(of: "/" + (fileName ?? ""), options: .backwards) {
            copy.replaceSubrange(range, with: "/" + newName)
        }
        return VirtualPath(unchecked: copy)
    }

    /// Returns the path with its final component removed.
    public var parent: VirtualPath? {
        guard !isRoot else { return nil }
        let trimmed = String(storage.dropLast())
        guard let idx = trimmed.lastIndex(of: "/") else { return .root }
        return VirtualPath(unchecked: String(trimmed[..<idx]) + "/")
            .normalizedSlashes()
    }

    /// Joins the given `path` to `self`.
    public func join(_ path: String) throws -> VirtualPath {
        if path.hasPrefix("/") {
            return try VirtualPath(path)
        }
        let combined = storage + (storage.hasSuffix("/") ? "" : "/") + path
        return try VirtualPath(combined)
    }

    /// Expresses this path as a relative path from the given base path.
    public func relativeFrom(_ base: VirtualPath) -> String {
        let a = withoutSlash.isEmpty ? [] : withoutSlash.split(separator: "/").map(String.init)
        let b = base.withoutSlash.isEmpty ? [] : base.withoutSlash.split(separator: "/").map(String.init)
        var i = 0
        while i < a.count && i < b.count && a[i] == b[i] { i += 1 }
        var out = [String](repeating: "..", count: b.count - i)
        out.append(contentsOf: a[i...])
        return out.joined(separator: "/")
    }

    /// Appends a single segment (already validated).
    public func appending(_ segment: String) -> VirtualPath {
        (try? join(segment)) ?? self
    }

    /// Resolve the virtual path relative to an actual file system root.
    /// Returns nil when a segment is not a valid platform component.
    public func realize(_ root: URL) -> URL? {
        var out = root
        for seg in withoutSlash.split(separator: "/") {
            let s = String(seg)
            guard !s.isEmpty, s != ".", s != "..",
                  !s.contains("\\"), !s.contains("/") else { return nil }
            out.appendPathComponent(s)
        }
        return out
    }

    // MARK: - Normalization

    private static func normalize(_ path: String) throws -> String {
        if path.contains("\0") { throw PathError.nul }
        var segments: [String] = []
        let absolute = path.hasPrefix("/")
        for raw in path.split(separator: "/", omittingEmptySubsequences: true) {
            let s = String(raw)
            if s == "." { continue }
            if s == ".." {
                guard !segments.isEmpty else {
                    if absolute { continue }
                    throw PathError.escapes
                }
                segments.removeLast()
                continue
            }
            if s.contains("\\") { throw PathError.backslash }
            guard !s.isEmpty else { continue }
            segments.append(s)
        }
        if segments.isEmpty { return "/" }
        return "/" + segments.joined(separator: "/")
    }

    private func normalizedSlashes() -> VirtualPath {
        var s = storage
        while s.hasSuffix("//") { s.removeLast() }
        if s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return VirtualPath(unchecked: s.isEmpty ? "/" : s)
    }
}

// MARK: - RootedPath / VirtualRoot / FileId

/// The root of a virtual file system.
public enum VirtualRoot: Hashable, Sendable {
    /// The canonical root of the Typst project.
    case project
    /// A root in a package.
    case package(PackageSpec)
}

/// A path in a specific virtual file system root.
public struct RootedPath: Hashable, Sendable, CustomStringConvertible {
    public var root: VirtualRoot
    public var vpath: VirtualPath

    public init(root: VirtualRoot, vpath: VirtualPath) {
        self.root = root
        self.vpath = vpath
    }

    /// Turns this path into a `FileId`.
    public func intern() -> FileId { FileId(path: self) }

    /// The package the path resides in, if any.
    public var package: PackageSpec? {
        if case .package(let spec) = root { return spec }
        return nil
    }

    public var description: String {
        switch root {
        case .project: return vpath.description
        case .package(let spec): return "\(spec)\(vpath)"
        }
    }
}

/// An interned version of `RootedPath`.
///
/// Globally interned and thus cheap to copy, compare, and hash. The raw
/// value is a non-zero `UInt16`, matching upstream's `NonZeroU16` layout.
public struct FileId: Hashable, Sendable, CustomStringConvertible {
    /// Non-zero interned id.
    public let raw: UInt16

    private init(raw: UInt16) {
        self.raw = raw
    }

    /// Create a new interned file id for a rooted path.
    public init(path: RootedPath) {
        self = FilePool.shared.intern(path)
    }

    /// Create a new unique ("fake") file id that is not reachable by path.
    public static func unique(_ path: RootedPath) -> FileId {
        FilePool.shared.unique(path)
    }

    /// Create a file id for use in tests.
    public static func newForTest(_ name: String) -> FileId {
        (try? VirtualPath(name)).map {
            FileId(path: RootedPath(root: .project, vpath: $0))
        } ?? FilePool.shared.fallback
    }

    /// The interned rooted path.
    public var path: RootedPath { FilePool.shared.path(for: self) }

    /// The virtual path within the root.
    public var vpath: VirtualPath { path.vpath }

    /// The package the file resides in, if any.
    public var package: PackageSpec? { path.package }

    public var description: String { path.description }
}

extension FileId {
    /// Construct from a raw number (numbers from `rawValue`-style APIs).
    public init(rawValue: UInt16) {
        self = FilePool.shared.id(rawValue: rawValue)
    }
}

/// The global interner for rooted paths, mirroring upstream's `INTERNER`.
final class FilePool: @unchecked Sendable {
    static let shared = FilePool()

    private let lock = NSLock()
    private var toId: [RootedPath: UInt16] = [:]
    private var fromId: [RootedPath?] = [] // nil = unique (unreachable) id

    /// A reserved fallback for out-of-range raw values.
    lazy var fallback: FileId = FileId(rawValue: 1)

    private init() {}

    func intern(_ path: RootedPath) -> FileId {
        lock.lock()
        defer { lock.unlock() }
        if let existing = toId[path] {
            return FileId(rawValue: existing)
        }
        let raw = nextRaw()
        toId[path] = raw
        fromId.append(path)
        return FileId(rawValue: raw)
    }

    func unique(_ path: RootedPath) -> FileId {
        lock.lock()
        defer { lock.unlock() }
        let raw = nextRaw()
        fromId.append(nil)
        return FileId(rawValue: raw)
    }

    private func nextRaw() -> UInt16 {
        let num = fromId.count + 1
        precondition(num <= Int(UInt16.max), "out of file ids")
        return UInt16(num)
    }

    func path(for id: FileId) -> RootedPath {
        lock.lock()
        defer { lock.unlock() }
        let index = Int(id.raw) - 1
        guard index >= 0, index < fromId.count, let path = fromId[index] else {
            return RootedPath(root: .project, vpath: .root)
        }
        return path
    }

    func id(rawValue: UInt16) -> FileId {
        FileId(rawValue: max(rawValue, 1))
    }
}
