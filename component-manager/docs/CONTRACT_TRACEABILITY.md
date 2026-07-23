# SLICE-0 public API traceability

Every exported SLICE-0 symbol is covered by one of these API-family rows; ordinary Go serialization methods belong to their owning type row.

| Public API family | Contract-v1 requirement | Evidence |
|---|---|---|
| identity.ComponentID, ParseComponentID | CMV1-ID-001 | logical syntax and negative tests |
| identity.ArtifactID, ParseArtifactID | CMV1-ARTIFACT-001 | content identity tests |
| identity.ModelID, ParseModelID | CMV1-MODEL-001 | opaque logical identity tests |
| identity.GenerationID, ParseGenerationID | CMV1-GEN-001 | prefix/digest tests |
| identity.ReceiptID, ParseReceiptID | CMV1-RECEIPT-001 | prefix/digest tests |
| identity.DeriveGenerationID, VerifyGenerationID | CMV1-GEN-001 | fixed omission/mismatch tests |
| digest.Digest, Parse, FromBytes | CMV1-ARTIFACT-001 | exact SHA-256 tests |
| version.SoftwareVersion, ParseSoftwareVersion | CMV1-VERSION-001 | SemVer precedence tests |
| version.ModelRevision, ParseModelRevision | CMV1-MODEL-001 | opaque case-sensitive tests |
| version.CatalogVersion, ParseCatalogVersion | CMV1-CATALOG-001 | catalog parser tests |
| schemaversion.SchemaVersion, CurrentWritable, Parse, ReaderSupports | CMV1-SCHEMA-COMPAT-001 | major/minor tests |
| platform.Platform, Architecture, Backend and parsers/constants | CMV1-PLATFORM-001 | allowlist tests |
| component.ComponentKind, ParseKind and constants | CMV1-CORE-001 | seven-kind tests |
| contract.Category, Error, Invalid | CMV1-ERROR-001 | stable-category/wrapping tests |
| contract.MaxJSONInputSize, ValidateJSON | CMV1-SCHEMA-COMPAT-001 | 21-schema/offline/size tests |
| schemas.Names, Load | CMV1-SCHEMA-COMPAT-001 | byte equality/hash drift test |
| catalog.Artifact, Component, Flow, Catalog | CMV1-CATALOG-001 | typed projection tests |
| catalog.MaxInputSize, ParseBytes, ParseReader | CMV1-CATALOG-001; CMV1-FAIL-011; CMV1-FAIL-012 | seven-flow, duplicate, digest-fork, size tests |

All 65 Contract-v1 requirements remain authoritative. Requirements outside this approved slice are intentionally unimplemented, not untraced; their absence is the SLICE-0 scope boundary.
