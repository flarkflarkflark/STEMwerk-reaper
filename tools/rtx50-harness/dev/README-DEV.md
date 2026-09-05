# Development-only test suite (NOT part of the tester ZIP)

Everything in this folder exists to validate `..\STEMwerk-RTX50-cu128-test.ps1`
and `..\STEMwerk-RTX50-rollback.ps1` on a non-Blackwell development
machine. None of it is needed by, or should be sent to, real RTX 50-series
testers - the packaging step excludes this whole folder.

## Mandatory regression test (harness failure #2)

`Test-NativeProcess.ps1` proves the fix for the Windows PowerShell 5.1
`NativeCommandError` bug that aborted the second harness generation:

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File Test-NativeProcess.ps1
```

- `warn_exit0.py` prints to stdout, emits a `UserWarning` on stderr
  (mirroring torch's real `cuda\__init__.py` warning), and exits 0. The
  helper (`..\lib\Invoke-NativeProcess.ps1`) must report `Success = $true`,
  the real exit code (0), and must retain both the stdout text and the
  warning text.
- `err_exit_nonzero.py` writes to stderr and exits 7. The helper must
  report `Success = $false`, exit code 7, and retain the stderr text.

## Safe install-failure injection

`Test-InstallFailureInjection.ps1` attempts to install a deliberately
nonexistent torch version spec against the REAL STEMwerk venv on this
machine. pip rejects an invalid version specifier during parsing, before
touching any installed package, so this is safe to run for real - the
test itself asserts that `torch`/`torchvision`/`torchaudio` versions are
byte-for-byte identical before and after the attempt.

## Verification-failure -> automatic rollback

There is no separate fixture script for this because inducing it safely
requires a real, successful cu128 install first. It was instead validated
by temporarily changing the expected-version check in
`STEMwerk-RTX50-cu128-test.ps1` to an impossible value, running a full
`-SimulateBlackwell` pass, confirming the script detected the (injected)
mismatch, ran `Invoke-RollbackFlow`, and both restored and re-verified the
real baseline - then reverting the temporary change. See the #118
investigation report for the exact commands and resulting report files.

## Precheck rejection (non-Blackwell hardware)

Covered by running the real tester with no simulation flag on this
machine (a real RTX 3060 Laptop GPU, compute capability 8.6): it must
detect `PRECHECK_PASS_NON_BLACKWELL` and exit 0 without touching any
package.
