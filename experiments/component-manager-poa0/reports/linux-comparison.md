# Linux comparison

Both implementations passed the same 20-case Linux harness. The harness ran
40 language/case combinations with zero failures and zero observed mixed
component views. Built-in unit-test counts are zero; the reported `20/20`
counts refer to native process-level contract cases per language.

| Metric | Rust | Go |
|---|---:|---:|
| Clean release build | 0.508 s | 2.336 s |
| Incremental build | 0.016 s | 0.030 s |
| Fixture install | 0.071 s | 0.041 s |
| Startup (`plan`) | 0.0018 s | 0.0023 s |
| Peak RSS during fixture install | 2,356 KiB | 6,884 KiB |
| Binary size | 611,960 B | 3,881,805 B |
| External language packages | 0 crates | 0 modules |
| Platform-specific source modules | 0 | 2 crashhook files |
| Unsafe blocks / cgo | 0 | cgo disabled |
| Lint warnings | 0 (`clippy -D warnings`) | 0 (`go vet`) |
| Informative source lines | 619 | 486 |

Measurements are single local runs, not statistically robust benchmarks.
Coverage was not collected because no large extra tooling was installed and
the behavior is exercised by the external harness rather than unit tests.

Rust is locally smaller, lower-RSS, and slightly faster to start/build. Go is
locally faster for this tiny install operation and its explicit build tags made
the Windows crashhook boundary visible early. Rust's compact output comes with
dynamic glibc/libgcc dependencies; Go is statically linked, but both still
invoke the system `sqlite3` executable, and Rust also invokes `sha256sum`.
Therefore neither is self-contained.

Readability and reviewability are close: Go has straightforward JSON and SHA
support in its standard library, while the dependency-free Rust POA needed
manual JSON emission/parsing that would be inappropriate production code.
Rust exposes filesystem/error boundaries explicitly but has more ceremony.
Go has less ceremony but already required platform isolation for hard-kill
injection. No local difference justifies a final language choice.

LOCAL_PREFERENCE=none
