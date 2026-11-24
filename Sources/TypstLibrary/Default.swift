/// Rust's `Default` trait equivalent: a type with a canonical default value.
public protocol Default {
    static var `default`: Self { get }
}
