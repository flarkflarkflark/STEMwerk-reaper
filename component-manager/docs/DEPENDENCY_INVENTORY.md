# Dependency inventory

Direct dependencies:

- `github.com/santhosh-tekuri/jsonschema/v6@v6.0.2` — Apache-2.0 — runtime Draft 2020-12 validation.
- `github.com/gowebpki/jcs@v1.0.1` — Apache-2.0 — RFC 8785 canonicalization.

The complete Go module graph has eleven transitive modules: `github.com/dlclark/regexp2`, `golang.org/x/text` (runtime validator graph), plus upstream-declared test/tooling modules `davecgh/go-spew`, `pmezard/go-difflib`, `stretchr/objx`, `stretchr/testify`, `golang.org/x/mod`, `golang.org/x/sys`, `golang.org/x/tools`, `gopkg.in/check.v1`, and `gopkg.in/yaml.v3`. Their locally cached licenses are Apache-2.0, BSD-3-Clause, MIT, or BSD-2-Clause compatible permissive licenses. Checksums are pinned in `go.sum`. No CGO, SQLite driver, CLI/logging framework, syscall package, network client, or non-standard cryptography is used. Runtime schema loading is embedded and offline.
