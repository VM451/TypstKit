import Foundation

/// High-speed, App-Sandbox-safe document-to-Typst (`.typ`) converter.
public enum AnyTyp {
    /// Convert a local document URL into idiomatic Typst markup.
    public static func convert(
        _ url: URL,
        options: AnyTypOptions = AnyTypOptions()
    ) throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw AnyTypError.io(error.localizedDescription)
        }
        let format = Format.detect(from: [UInt8](data)) ?? Format.fromPath(url.path)
        guard let format else {
            throw AnyTypError.unsupported(
                "unrecognized file content and extension: \(url.path(percentEncoded: false))"
            )
        }
        return try convertLoaded(data, format: format, options: options)
    }

    /// Convert in-memory document bytes into Typst markup.
    public static func convert(
        _ data: Data,
        format: AnyTypFormat? = nil,
        options: AnyTypOptions = AnyTypOptions()
    ) throws -> String {
        let bytes = [UInt8](data)
        let resolved: Format
        if let format {
            resolved = format.format
        } else if let detected = Format.detect(from: bytes) {
            resolved = detected
        } else {
            throw AnyTypError.unsupported(
                "unrecognized file content: name the format explicitly"
            )
        }
        return try convertLoaded(data, format: resolved, options: options)
    }

    /// Parse in-memory document bytes into the structured `AnyTypDocument`
    /// model, including embedded assets.
    public static func parseDocument(
        _ data: Data,
        format: AnyTypFormat? = nil
    ) throws -> AnyTypDocument {
        try toDocument(data, format: format)
    }

    /// Parse a local document URL into the structured `AnyTypDocument` model.
    public static func parseDocument(_ url: URL) throws -> AnyTypDocument {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw AnyTypError.io(error.localizedDescription)
        }
        let detected = AnyTypFormat.detect(from: data) ?? AnyTypFormat(url: url)
        guard let format = detected else {
            throw AnyTypError.unsupported(
                "unrecognized file content and extension: \(url.path(percentEncoded: false))"
            )
        }
        return try parseDocument(data, format: format)
    }

    /// Non-isolated concurrent conversion of a file URL.
    @concurrent
    public static func convertAsync(
        _ url: URL,
        options: AnyTypOptions = AnyTypOptions()
    ) async throws -> String {
        try Task.checkCancellation()
        return try convert(url, options: options)
    }

    /// Non-isolated concurrent conversion of `Data`.
    @concurrent
    public static func convertAsync(
        _ data: Data,
        format: AnyTypFormat? = nil,
        options: AnyTypOptions = AnyTypOptions()
    ) async throws -> String {
        try Task.checkCancellation()
        return try convert(data, format: format, options: options)
    }

    /// Non-isolated concurrent document model parsing.
    @concurrent
    public static func parseDocumentAsync(
        _ data: Data,
        format: AnyTypFormat? = nil
    ) async throws -> AnyTypDocument {
        try Task.checkCancellation()
        return try parseDocument(data, format: format)
    }

    // MARK: - Internals

    /// Parse bytes into the document model (port of `anytyp::to_document`).
    static func toDocument(_ data: Data, format: AnyTypFormat?) throws -> AnyTypDocument {
        let bytes = [UInt8](data)
        let resolved: Format
        if let format {
            resolved = format.format
        } else if let detected = Format.detect(from: bytes) {
            resolved = detected
        } else {
            throw ConvertError.unsupported(
                "unrecognized file content: name the format explicitly"
            ).anyTypError
        }
        do {
            return try Formats.parse(bytes, resolved).get()
        } catch let e as ConvertError {
            throw e.anyTypError
        }
    }

    private static func convertLoaded(
        _ data: Data,
        format: Format,
        options: AnyTypOptions
    ) throws -> String {
        let bytes = [UInt8](data)
        let doc: AnyTypDocument
        do {
            doc = try Formats.parse(bytes, format).get()
        } catch let e as ConvertError {
            throw e.anyTypError
        }
        if let dir = options.extractAssetsTo {
            do {
                try writeAssets(doc, to: dir)
            } catch let e as ConvertError {
                throw e.anyTypError
            } catch {
                throw AnyTypError.io(error.localizedDescription)
            }
        }
        let prefix = resolvedPrefix(for: options)
            ?? options.extractAssetsTo?.lastPathComponent
        let renderOptions = RenderOptions(
            standalone: options.standalone || options.title != nil,
            title: options.title,
            assetsDir: prefix
        )
        return documentToTypstWithOptions(doc, renderOptions)
    }

    private static func resolvedPrefix(for options: AnyTypOptions) -> String? {
        if let explicit = options.assetsPrefix, !explicit.isEmpty {
            return explicit
        }
        return nil
    }
}
