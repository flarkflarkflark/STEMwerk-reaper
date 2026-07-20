# Production reimplementation constraints

POA code cannot be promoted. It may inform a separately reviewed
reimplementation after schema and transaction-contract review.

## POA_ALLOWED_ONLY

- Manual/minimal JSON routes and string construction.
- Subprocess `sqlite3` and Rust subprocess `sha256sum`.
- Shell-based fault injection and fixture-only shortcuts.
- Test-only filesystem assumptions.

## PRODUCTION_REQUIRED

- Real JSON parsing and schema validation.
- Native SHA256 library.
- Embedded or reliably linked SQLite with explicit WAL/transaction policy.
- Native platform filesystem/process/locking APIs and platform abstractions.
- Structured errors; no parsing command output as the primary state interface.
- No dependency on accidentally installed shell utilities.
- No real component mutation before schema and transaction review.

## Candidate research table (not a dependency decision)

| Area | Rust candidates | Go candidates |
|---|---|---|
| JSON | serde, serde_json | encoding/json |
| Schema validation | jsonschema | santhosh-tekuri/jsonschema |
| SHA256 | sha2 | crypto/sha256 |
| SQLite | rusqlite/sqlx | modernc.org/sqlite or reviewed cgo driver |
| Filesystem | std::fs plus platform modules | os/path/filepath plus platform files |
| Process management | std::process plus native APIs | os/exec plus x/sys |
| File locking | fs2 or native wrapper | gofrs/flock or native wrapper |
| Error handling | thiserror/anyhow policy | typed errors with wrapping |
| Test tooling | cargo test, proptest, assert_cmd | testing, fuzzing, exec harness |

Candidate quality, licensing, maintenance, transitive dependencies, and native
support must be researched afresh before Contract v1.
