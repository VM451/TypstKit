import TypstSyntax

/// Adds a custom file to a bundle.
///
/// Port of `AssetElem` in `model/asset.rs`. The `ASSET_UNSUPPORTED_RULE`
/// show rule is deferred with the native show-rule milestone.
public struct AssetElem: NativeElement {
    public static let info = ElementInfo(
        name: "asset",
        title: "Asset",
        fields: [
            FieldInfo(id: 0, name: "path", required: true),
            FieldInfo(id: 1, name: "data", required: true),
        ],
        capabilities: [.locatable]
    )

    /// The path in the bundle at which the asset will be placed.
    public var path: BundlePath

    /// The raw data that will be written into the file.
    public var data: AssetData

    public var span: Span = .detached

    public init(path: BundlePath, data: AssetData) {
        self.path = path
        self.data = data
    }

    public func field(_ id: UInt8) -> Value? {
        switch id {
        case 0: return path.intoValue()
        case 1: return data.intoValue()
        default: return nil
        }
    }

    public mutating func setField(_ id: UInt8, _ value: Value) throws {
        switch (id, value) {
        case (0, let v): path = try BundlePath.fromValue(v).get()
        case (1, let v): data = try AssetData.fromValue(v).get()
        default: break
        }
    }
}

/// The raw data for an asset. Port of `AssetData` in `model/asset.rs`.
public struct AssetData: Sendable, Hashable {
    /// The wrapped bytes (upstream tuple field `.0`).
    public var bytes: Bytes

    public init(_ bytes: Bytes) { self.bytes = bytes }
}

extension AssetData: Castable, IntoValue, FromValue {
    public static var input: CastInfo {
        .union([.type(Type.of(Str.self)), .type(Type.of(Bytes.self))])
    }
    public static var output: CastInfo { input }

    public static func castable(_ value: Value) -> Bool {
        Str.castable(value) || Bytes.castable(value)
    }

    public func intoValue() -> Value { bytes.intoValue() }

    public static func fromValue(_ value: Value) -> HintedStrResult<Self> {
        switch value {
        case let .str(s): return .success(AssetData(Bytes(string: s.value)))
        case let .bytes(b): return .success(AssetData(b))
        default: return .failure(error(value))
        }
    }
}
