# Windows Rust directory-handle durability fix

## Evidence and root cause

Targeted diagnostic run `29789679479` proved that CMN-001 and the CMN-008
prerequisite both completed selector replacement and then failed at ordinary
`File::open(state-directory)` with raw Win32 error 5. `sync_all()` was never
reached. The isolated Rust directory-open probe reproduced the same error.

Windows requires `FILE_FLAG_BACKUP_SEMANTICS` when opening a directory handle.
The POA-only Rust implementation now routes directory opens through this exact
platform split:

```rust
#[cfg(windows)]
fn open_directory_for_sync(path: &Path) -> std::io::Result<File> {
    use std::os::windows::fs::OpenOptionsExt;

    const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x0200_0000;

    if !fs::metadata(path)?.is_dir() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "directory sync target is not a directory",
        ));
    }
    OpenOptions::new()
        .read(true)
        .custom_flags(FILE_FLAG_BACKUP_SEMANTICS)
        .open(path)
}

#[cfg(not(windows))]
fn open_directory_for_sync(path: &Path) -> std::io::Result<File> {
    File::open(path)
}
```

No other custom flag, share mode, retry, fallback, dependency, or write access
was added. Selector replacement still precedes directory open, the existing
`sync_all()` call remains mandatory, and both open and sync failures retain the
structured `ACTIVATION_IO_ERROR` envelope and non-zero exit behavior.

## Verification

- New directory-sync helper tests: 10/10; total Rust unit tests: 23/23.
- `cargo fmt --check`, `cargo check`, `cargo test`, and `cargo clippy`: PASS.
- Local Rust: common/platform 24/24, lease 10/10, Linux 4/4, mixed 0.
- Local Go: common/platform 24/24, lease 10/10, Linux 4/4, mixed 0.
- Verifier policy tests: 20/20.
- Cases, expectations, fixtures, schemas, Go, Rust SHA-256 implementation,
  fault injections, frozen manifest, verifier policy, selector-replace logic,
  and durability contract remain unchanged.

The Windows-specific compile/runtime result is intentionally deferred to the
targeted native Windows Rust CMN-001/008 workflow. This is disposable POA-only
code and is not a production-runtime or language decision.
