import Foundation
import TypstSyntax
import TypstUtils

// Port of `typst-eval/src/import.rs` — module import/include evaluation,
// file and package resolution, and manifest parsing.

// MARK: - ModuleImport

extension ModuleImport {
    /// Port of `ModuleImport::eval`.
    public func eval(_ vm: inout Vm) throws -> Value {
        let sourceExpr = self.source()
        let sourceSpan = sourceExpr.span

        var source = try sourceExpr.eval(&vm)
        var replacedSource = false

        switch source {
        case let .function(theFunc):
            if theFunc.scope == nil {
                throw SourceDiagnostics(SourceDiagnostic.error(
                    sourceSpan, "cannot import from user-defined functions"))
            }
        case .type, .module:
            break
        case let .str(path):
            let pathString = path.value
            let module = try tracedImport(.import(pathString), at: self.span) {
                try importModule(vm.engine, pathString, sourceSpan)
            }
            source = .module(module)
            replacedSource = true
        default:
            if RootedPath.castable(source) {
                let id = try unwrap(source.cast(RootedPath.self)
                    .at(sourceSpan)).intern()
                let module = try tracedImport(.import(id.vpath.withSlash),
                                              at: self.span) {
                    try importFile(vm.engine, id: id, span: sourceSpan)
                }
                source = .module(module)
                replacedSource = true
            } else {
                throw SourceDiagnostics(SourceDiagnostic.error(
                    sourceSpan,
                    "expected path, module, function, or type, found \(source.type)"))
            }
        }

        // If there is a rename, import the source itself under that name.
        let newName = self.newName()
        if let newName {
            if case let .ident(ident) = sourceExpr,
               ident.get() == newName.get() {
                // Warn on `import x as x`
                vm.engine.sink.warn(SourceDiagnostic.warning(
                    newName.span,
                    "unnecessary import rename to same name"))
            }

            // Define renamed module on the scope.
            vm.define(newName, source)
        }

        guard let scope = source.scope else {
            // Unreachable: all sources reaching here have a scope.
            throw SourceDiagnostics(SourceDiagnostic.error(
                sourceSpan, "cannot import from this value"))
        }

        switch self.imports() {
        case nil:
            if newName == nil {
                switch self.bareName() {
                case .success(let name)
                    where !replacedSource || isStrExpr(sourceExpr):
                    if case .ident = sourceExpr {
                        vm.engine.sink.warn(SourceDiagnostic.warning(
                            sourceExpr.span, "this import has no effect"))
                    }
                    vm.scopes.top.bind(
                        name, binding: Binding(value: source, span: sourceSpan))
                case .success, .failure(.dynamic):
                    var diag = SourceDiagnostic.error(
                        sourceSpan, "dynamic import requires an explicit name")
                    diag.hint("you can name the import with `as`")
                    throw SourceDiagnostics([diag])
                case .failure(.pathInvalid):
                    var diag = SourceDiagnostic.error(
                        sourceSpan,
                        "module name would not be a valid identifier")
                    diag.hint("you can rename the import with `as`")
                    throw SourceDiagnostics([diag])
                case .failure(.packageInvalid):
                    // Bad package spec would have failed the import already.
                    preconditionFailure("unexpected package-invalid bare import")
                }
            }
        case .wildcard:
            for (name, binding) in scope.bindings {
                // Filter out values that are in feature gated bindings and
                // ignore any deprecation warnings that are emitted.
                if case .success = binding.read(
                    vm.engine.world.silentBindingGuard()) {
                    vm.scopes.top.bind(name, binding: binding)
                }
            }
        case .items(let items):
            var errors: [SourceDiagnostic] = []
            for item in items.items() {
                let components = item.path().components()
                var itemScope = scope
                var index = 0
                importWalk: while index < components.count {
                    let component = components[index]
                    let field = component.get()
                    guard let binding = itemScope.get(field) else {
                        errors.append(SourceDiagnostic.error(
                            component.span,
                            "unresolved import"))
                        break importWalk
                    }

                    let value = try unwrap(binding
                    .read(vm.engine.bindingGuard())
                    .orCannot("import `\(field)`")
                    .at(component.span))

                    if index + 1 < components.count {
                        // Nested import — must be a submodule.
                        guard let submodule = value.scope else {
                            if case let .function(function) = value,
                               function.scope == nil {
                                errors.append(SourceDiagnostic.error(
                                    component.span,
                                    "cannot import from user-defined functions"))
                            } else if !isImportableScopeValue(value) {
                                errors.append(SourceDiagnostic.error(
                                    component.span,
                                    "expected module, function, or type, found \(value.type)"))
                            } else {
                                preconditionFailure(
                                    "unexpected nested import failure")
                            }
                            break importWalk
                        }
                        // Walk into the submodule.
                        itemScope = submodule
                    } else {
                        // Extract the desired item from the innermost scope.
                        // Warn on `import ...: x as x`
                        if case let .renamed(renamedItem) = item,
                           renamedItem.originalName().get()
                               == renamedItem.newName().get() {
                            vm.engine.sink.warn(SourceDiagnostic.warning(
                                renamedItem.newName().span,
                                "unnecessary import rename to same name"))
                        }
                        vm.bind(item.boundName(), binding)
                    }
                    index += 1
                }
            }
            if !errors.isEmpty {
                throw SourceDiagnostics(errors)
            }
        }

        return .none
    }
}

/// Apply a tracepoint to diagnostics thrown by `body`.
/// Port of upstream `SourceResult::trace` for the throwing style.
private func tracedImport<T>(_ point: Tracepoint, at span: Span,
                             _ body: () throws -> T) throws -> T {
    do {
        return try body()
    } catch let diagnostics as SourceDiagnostics {
        throw SourceDiagnostics(diagnostics.diagnostics.map {
            $0.traced(point, at: span)
        })
    }
}

/// Whether the source expression is a string literal.
private func isStrExpr(_ expr: Expr) -> Bool {
    if case .str = expr { return true }
    return false
}

/// Whether the value can contain an importable scope (function, module,
/// or type) — used for the nested-import error taxonomy.
private func isImportableScopeValue(_ value: Value) -> Bool {
    switch value {
    case .function, .module, .type: return true
    default: return false
    }
}

// MARK: - ModuleInclude

extension ModuleInclude {
    /// Port of `ModuleInclude::eval`.
    public func eval(_ vm: inout Vm) throws -> Content {
        let sourceSpan = self.source().span
        let source = try self.source().eval(&vm)
        let module: Module
        switch source {
        case let .str(path):
            let pathString = path.value
            module = try tracedImport(.include(pathString), at: self.span) {
                try importModule(vm.engine, pathString, sourceSpan)
            }
        case let .module(m):
            module = m
        default:
            if RootedPath.castable(source) {
                let id = try unwrap(source.cast(RootedPath.self)
                    .at(sourceSpan)).intern()
                module = try tracedImport(.include(id.vpath.withSlash),
                                          at: self.span) {
                    try importFile(vm.engine, id: id, span: sourceSpan)
                }
            } else {
                throw SourceDiagnostics(SourceDiagnostic.error(
                    sourceSpan,
                    "expected path or module, found \(source.type)"))
            }
        }
        return module.content
    }
}

// MARK: - Resolution

/// Process an import of a package or file relative to the current location.
/// Port of `import` in `import.rs`.
public func importModule(_ engine: Engine, _ from: String,
                         _ span: Span) throws -> Module {
    if from.hasPrefix("@") {
        let spec: PackageSpec
        do {
            spec = try PackageSpec.parse(from)
        } catch {
            throw SourceDiagnostics(SourceDiagnostic.error(
                span.diag, "\(error)"))
        }
        return try importPackage(engine, spec: spec, span: span)
    } else {
        let path = PathOrStr.str(Str(from))
            .resolveIfSome(within: span.id)
        let resolved: RootedPath
        switch path {
        case .success(let r): resolved = r
        case .failure(let e):
            var diag = SourceDiagnostic.error(span, e.message)
            for hint in e.hints { diag.hint(hint) }
            throw SourceDiagnostics([diag])
        }
        return try importFile(engine, id: resolved.intern(), span: span)
    }
}

/// Import a file from a path. The path is resolved relative to the given
/// `span`. Port of `import_file` in `import.rs`.
func importFile(_ engine: Engine, id: FileId, span: Span) throws -> Module {
    // Load the source file.
    let source: Source
    switch engine.world.source(id) {
    case .success(let s): source = s
    case .failure(let error):
        throw SourceDiagnostics(SourceDiagnostic.error(span, error.message))
    }

    // Prevent cyclic importing.
    if engine.route.contains(source.id) {
        throw SourceDiagnostics(SourceDiagnostic.error(span, "cyclic import"))
    }

    // Evaluate the file.
    return try evalModule(engine, source)
}

/// Import an external package. Port of `import_package` in `import.rs`.
func importPackage(_ engine: Engine, spec: PackageSpec,
                   span: Span) throws -> Module {
    let (name, id) = try resolvePackage(engine, spec: spec, span: span)
    var module = try importFile(engine, id: id, span: span)
    module.name = Str(name)
    return module
}

/// Resolve the name and entrypoint of a package.
/// Port of `resolve_package` in `import.rs`.
func resolvePackage(_ engine: Engine, spec: PackageSpec,
                    span: Span) throws -> (String, FileId) {
    // Evaluate the manifest.
    guard let manifestPath = try? VirtualPath("typst.toml") else {
        throw SourceDiagnostics(SourceDiagnostic.error(
            span, "invalid manifest path"))
    }
    let manifestRooted = RootedPath(root: .package(spec), vpath: manifestPath)
    let manifestId = manifestRooted.intern()
    let bytes: Bytes
    switch engine.world.file(manifestId) {
    case .success(let b): bytes = b
    case .failure(let error):
        throw SourceDiagnostics(SourceDiagnostic.error(span, error.message))
    }
    let string: String
    switch bytes.toStr() {
    case .success(let s): string = s.value
    case .failure:
        throw SourceDiagnostics(SourceDiagnostic.error(
            span, "file is not valid UTF-8"))
    }
    let manifest: PackageManifest
    switch parseTOML(string) {
    case .success(let dict):
        do {
            manifest = try parsePackageManifest(dict)
        } catch let error as StrError {
            throw SourceDiagnostics(SourceDiagnostic.error(
                span.diag, "package manifest is malformed (\(error.message))"))
        } catch {
            throw SourceDiagnostics(SourceDiagnostic.error(
                span.diag, "package manifest is malformed"))
        }
    case .failure(let error):
        throw SourceDiagnostics(SourceDiagnostic.error(
            span.diag, "package manifest is malformed (\(error))"))
    }
    do {
        try manifest.validate(spec)
    } catch {
        throw SourceDiagnostics(SourceDiagnostic.error(
            span.diag, "\(error)"))
    }

    // Evaluate the entry point.
    let entrypoint = RootedPath(
        root: manifestRooted.root, vpath: manifest.package.entrypoint)
    return (manifest.package.name, entrypoint.intern())
}

// MARK: - Manifest parsing

/// Parse a `[package]`/`[template]`/`[tool]` TOML document into a
/// `PackageManifest`. Port of the serde `Deserialize` impl for
/// `PackageManifest` in upstream `package.rs`.
func parsePackageManifest(_ dict: Dict) throws -> PackageManifest {
    func table(_ dict: Dict, _ key: String) throws -> Dict {
        guard let value = dict.get(key) else {
            throw StrError("missing field `\(key)`")
        }
        guard case let .dict(d) = value else {
            throw StrError("invalid type for `\(key)`")
        }
        return d
    }
    func reqStr(_ dict: Dict, _ key: String) throws -> String {
        guard let value = dict.get(key) else {
            throw StrError("missing field `\(key)`")
        }
        guard case let .str(s) = value else {
            throw StrError("invalid type for `\(key)`")
        }
        return s.value
    }
    func optStr(_ dict: Dict, _ key: String) throws -> String? {
        guard let value = dict.get(key) else { return nil }
        if case .none = value { return nil }
        guard case let .str(s) = value else {
            throw StrError("invalid type for `\(key)`")
        }
        return s.value
    }
    func strArray(_ dict: Dict, _ key: String) throws -> [String] {
        guard let value = dict.get(key) else { return [] }
        guard case let .array(a) = value else {
            throw StrError("invalid type for `\(key)`")
        }
        return try a.items.map { item in
            guard case let .str(s) = item else {
                throw StrError("invalid type for `\(key)`")
            }
            return s.value
        }
    }
    func vpath(_ string: String, _ key: String) throws -> VirtualPath {
        do {
            return try VirtualPath(string)
        } catch {
            throw StrError("invalid `\(key)` path: \(error)")
        }
    }

    // [package] (required)
    let packageDict = try table(dict, "package")
    let packageName = try reqStr(packageDict, "name")
    let versionText = try reqStr(packageDict, "version")
    let packageVersion: PackageVersion
    do {
        packageVersion = try PackageVersion.parse(versionText)
    } catch {
        throw StrError("invalid `version`: \(error)")
    }
    let entrypointText = try reqStr(packageDict, "entrypoint")
    let packageEntrypoint = try vpath(entrypointText, "entrypoint")
    let compilerText = try optStr(packageDict, "compiler")
    var packageCompiler: VersionBound? = nil
    if let compilerText {
        do {
            packageCompiler = try VersionBound.parse(compilerText)
        } catch {
            throw StrError("invalid `compiler`: \(error)")
        }
    }
    let package = PackageInfo(
        name: packageName,
        version: packageVersion,
        entrypoint: packageEntrypoint,
        authors: try strArray(packageDict, "authors"),
        license: try optStr(packageDict, "license"),
        description: try optStr(packageDict, "description"),
        homepage: try optStr(packageDict, "homepage"),
        repository: try optStr(packageDict, "repository"),
        keywords: try strArray(packageDict, "keywords"),
        categories: try strArray(packageDict, "categories"),
        disciplines: try strArray(packageDict, "disciplines"),
        compiler: packageCompiler,
        exclude: try strArray(packageDict, "exclude"),
        unknownFields: unknownFields(
            packageDict, known: ["name", "version", "entrypoint", "authors",
                                 "license", "description", "homepage",
                                 "repository", "keywords", "categories",
                                 "disciplines", "compiler", "exclude"]))

    // [template] (optional)
    var template: TemplateInfo? = nil
    if let templateValue = dict.get("template") {
        guard case let .dict(templateDict) = templateValue else {
            throw StrError("invalid type for `template`")
        }
        var info = TemplateInfo(
            path: try vpath(reqStr(templateDict, "path"), "path"),
            entrypoint: try vpath(
                reqStr(templateDict, "entrypoint"), "entrypoint"))
        if let thumbnailText = try optStr(templateDict, "thumbnail") {
            info.thumbnail = try vpath(thumbnailText, "thumbnail")
        }
        info.unknownFields = unknownFields(
            templateDict, known: ["path", "entrypoint", "thumbnail"])
        template = info
    }

    // [tool] (optional) — sections are kept verbatim.
    var tool = ToolInfo()
    if let toolValue = dict.get("tool") {
        guard case let .dict(toolDict) = toolValue else {
            throw StrError("invalid type for `tool`")
        }
        for (key, value) in toolDict.pairs {
            guard case let .dict(section) = value else { continue }
            var table: [String: TomlValue] = [:]
            for (k, v) in section.pairs {
                table[k.value] = tomlValue(v)
            }
            tool.sections[key.value] = table
        }
    }

    var manifest = PackageManifest(package: package)
    manifest.template = template
    manifest.tool = tool
    manifest.unknownFields = unknownFields(
        dict, known: ["package", "template", "tool"])
    return manifest
}

/// Collect fields not in `known` as `TomlValue`s (serde `flatten`).
private func unknownFields(_ dict: Dict, known: [String]) -> UnknownFields {
    var result: UnknownFields = [:]
    for (key, value) in dict.pairs where !known.contains(key.value) {
        result[key.value] = tomlValue(value)
    }
    return result
}

/// Convert a `Value` into a manifest `TomlValue`.
private func tomlValue(_ value: Value) -> TomlValue {
    switch value {
    case let .str(s): return .string(s.value)
    case let .bool(b): return .bool(b)
    case let .int(i): return .int(i)
    case let .float(f): return .float(f)
    case let .datetime(d): return .datetime(d.repr())
    case let .array(a): return .array(a.items.map(tomlValue))
    case let .dict(d):
        var table: [String: TomlValue] = [:]
        for (k, v) in d.pairs { table[k.value] = tomlValue(v) }
        return .table(table)
    default:
        return .string(value.repr())
    }
}
