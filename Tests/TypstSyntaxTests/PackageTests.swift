import Testing
@testable import TypstSyntax

/// Port of upstream `package.rs` tests plus spec/bound parsing coverage.
@Suite("Package")
struct PackageTests {
    /// Port of upstream `version_version_match`.
    @Test func versionVersionMatch() throws {
        let v111 = try PackageVersion.parse("1.1.1")

        #expect(try v111.matchesEq(VersionBound.parse("1")))
        #expect(try v111.matchesEq(VersionBound.parse("1.1")))
        #expect(try !v111.matchesEq(VersionBound.parse("1.2")))

        #expect(try !v111.matchesGt(VersionBound.parse("1")))
        #expect(try v111.matchesGt(VersionBound.parse("1.0")))
        #expect(try !v111.matchesGt(VersionBound.parse("1.1")))

        #expect(try !v111.matchesLt(VersionBound.parse("1")))
        #expect(try !v111.matchesLt(VersionBound.parse("1.1")))
        #expect(try v111.matchesLt(VersionBound.parse("1.2")))
    }

    @Test func packageSpecParse() throws {
        let spec = try PackageSpec.parse("@preview/pkg:1.2.3")
        #expect(spec.namespace == "preview")
        #expect(spec.name == "pkg")
        #expect(spec.version == PackageVersion(major: 1, minor: 2, patch: 3))
        #expect(spec.description == "@preview/pkg:1.2.3")
        #expect(spec.versionless().description == "@preview/pkg")

        // Unicode identifiers are valid (upstream `is_ident`).
        #expect(try PackageSpec.parse("@préfix/pkg:0.1.0").namespace == "préfix")
    }

    @Test func packageSpecErrors() {
        #expect(throws: (any Error).self) { try PackageSpec.parse("preview/pkg:1.0.0") }
        #expect(throws: (any Error).self) { try PackageSpec.parse("@/pkg:1.0.0") }
        #expect(throws: (any Error).self) { try PackageSpec.parse("@ns/:1.0.0") }
        #expect(throws: (any Error).self) { try PackageSpec.parse("@ns/pkg") }
        #expect(throws: (any Error).self) { try PackageSpec.parse("@ns/pkg:") }
        #expect(throws: (any Error).self) { try PackageSpec.parse("@ns/pkg:1.0") }
        #expect(throws: (any Error).self) { try PackageSpec.parse("@ns/pkg:1.0.0.1") }
        #expect(throws: (any Error).self) { try PackageSpec.parse("@ns/pkg name:1.0.0") }
    }

    @Test func versionlessSpecParse() throws {
        let spec = try VersionlessPackageSpec.parse("@preview/pkg")
        #expect(spec.namespace == "preview")
        #expect(spec.name == "pkg")
        #expect(spec.at(PackageVersion(major: 1, minor: 0, patch: 0)).description
                == "@preview/pkg:1.0.0")

        // A version suffix is rejected.
        #expect(throws: (any Error).self) {
            try VersionlessPackageSpec.parse("@preview/pkg:1.0.0")
        }
    }

    @Test func versionBoundParse() throws {
        #expect(try VersionBound.parse("1")
                == VersionBound(major: 1))
        #expect(try VersionBound.parse("1.2")
                == VersionBound(major: 1, minor: 2))
        #expect(try VersionBound.parse("1.2.3")
                == VersionBound(major: 1, minor: 2, patch: 3))
        #expect(try VersionBound.parse("1.2").description == "1.2")

        #expect(throws: (any Error).self) { try VersionBound.parse("") }
        #expect(throws: (any Error).self) { try VersionBound.parse("1.2.3.4") }
        #expect(throws: (any Error).self) { try VersionBound.parse("1.x") }
        #expect(throws: (any Error).self) { try VersionBound.parse("1.2.") }
    }

    @Test func manifestValidate() throws {
        let version = PackageVersion(major: 0, minor: 1, patch: 0)
        var info = PackageInfo(name: "pkg", version: version,
                                entrypoint: try VirtualPath("src/lib.typ"))
        let spec = PackageSpec(namespace: "preview", name: "pkg", version: version)

        // Valid manifest.
        try PackageManifest(package: info).validate(spec)

        // Name mismatch.
        info.name = "other"
        #expect(throws: PackageManifest.ValidationError.self) {
            try PackageManifest(package: info).validate(spec)
        }

        // Version mismatch.
        info.name = "pkg"
        info.version = PackageVersion(major: 0, minor: 2, patch: 0)
        #expect(throws: PackageManifest.ValidationError.self) {
            try PackageManifest(package: info).validate(spec)
        }

        // Compiler bound satisfied / violated.
        info.version = version
        info.compiler = try VersionBound.parse("0.15")
        try PackageManifest(package: info).validate(spec)
        info.compiler = try VersionBound.parse("99")
        #expect(throws: PackageManifest.ValidationError.self) {
            try PackageManifest(package: info).validate(spec)
        }
    }
}
