import Foundation

/// Introspection state for `locate`/`query`/`context`.
///
/// The `Introspector` protocol and `EmptyIntrospector` live in
/// `Introspection/ElementIntrospector.swift` alongside the target-agnostic
/// `ElementIntrospector<P>` core (port of `introspection/introspector.rs`).
/// This file previously held a storage shell; kept as a pointer so the
/// module layout stays stable.
