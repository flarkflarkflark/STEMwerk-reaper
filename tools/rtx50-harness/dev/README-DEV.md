# Development-only test suite (NOT part of the tester ZIP)

Everything in this folder exists to validate the harness
(`..\STEMwerk-RTX50-cu128-test.ps1`, `..\STEMwerk-RTX50-rollback.ps1`,
`..\lib\HarnessCore.ps1`) on a non-Blackwell development machine. None of
it is needed by, or should be sent to, real RTX 50-series testers - the
packaging step excludes this whole folder.

## v2 architecture in one paragraph

`..\lib\HarnessCore.ps1` holds the whole state machine
(`Invoke-RTX50Harness`); both `..\STEMwerk-RTX50-cu128-test.ps1` (public)
and `STEMwerk-RTX50-cu128-test-SIMULATED.ps1` (here, dev-only) call it -
the only difference is whether a non-null `$SimulatedTarget` is passed,
and only this dev script's own double opt-in (`-SimulateBlackwell` switch
+ `STEMWERK_RTX50_DEV_SIMULATION_ACK` env var) can ever produce one.
`..\lib\RuntimeState.ps1` holds the transaction-safety core: classifying
the installed trio as `RELEASE_BASELINE` / `EXPERIMENTAL_CU128` /
`MIXED_OR_UNKNOWN`, and reading/writing the durable transaction record at
`%LOCALAPPDATA%\STEMwerk\rtx50-test-state\transaction.json` (atomically,
via write-to-temp + rename).

## Run this first after editing any .ps1 file

```
powershell -File Test-Syntax.ps1
```

Parses every `.ps1` file with the PowerShell language parser (no
execution). Catches two things that have both bitten this harness for
real: an unescaped `` ` `` `` ` `` `` ` `` (triple backtick) inside a
double-quoted string, where the closing backtick escapes the string's own
terminating quote and produces a cascade of confusing downstream parse
errors; and `$var:` inside a double-quoted string being misread as a
scope/drive qualifier (`Variable reference is not valid`).

## Mandatory regression test (harness failure #2)

`Test-NativeProcess.ps1` proves the fix for the Windows PowerShell 5.1
`NativeCommandError` bug that aborted the second harness generation - see
its own header comment for `warn_exit0.py` / `err_exit_nonzero.py`.

## Heartbeat (v2, spec section 7)

`Test-Heartbeat.ps1` runs a 12-second sleep fixture through
`Invoke-NativeProcess -HeartbeatSeconds 3` and asserts heartbeat lines are
printed periodically while the process runs, AND that stdout/exit code
are still captured correctly afterward - a real pip install uses
`-HeartbeatSeconds 20` (see `lib\VenvSafety.ps1` / `lib\HarnessCore.ps1`)
so a multi-minute download never looks like the tester has hung (this is
exactly what one real RTX 5070 tester reported before v2).

## Safe install-failure injection

`Test-InstallFailureInjection.ps1` attempts to install a deliberately
nonexistent torch version spec against the REAL STEMwerk venv on this
machine. pip rejects an invalid version specifier during parsing, before
touching any installed package, so this is safe to run for real - the
test itself asserts that `torch`/`torchvision`/`torchaudio` versions are
byte-for-byte identical before and after the attempt.

## Interrupted transaction recovery (v2, THE critical test)

`Test-InterruptedTransactionRecovery.ps1` reproduces, for real, the exact
mixed state a real RTX 5070 tester hit when v1 appeared to hang and was
killed mid-install: `torch 2.7.1+cu128` with `torchvision`/`torchaudio`
still at their old cu121 versions. It manually writes a trusted
transaction record (as a real run would), creates the mixed state, then
runs the REAL public tester script and asserts it detects the interrupted
transaction, recovers using the recorded baseline (never the mixed
state), ends at the exact original trio, and clears the transaction
record. This performs real pip operations on the real STEMwerk venv (as
instructed) - it verifies venv identity first and requires starting from
a coherent baseline.

## Mixed state with NO trusted baseline (v2)

`Test-MixedNoBaseline.ps1` covers the other dangerous case: a mixed trio
with no transaction record at all (e.g. a v1 tester was used previously).
Creates the mixed state without ever writing a transaction record, clears
any pre-existing one, then runs the real public tester with `-Yes` and
asserts it takes the documented-release-fallback recovery path (gated by
`Test-LooksLikeKnownStemwerkReleaseEnvironment` in `RuntimeState.ps1`) and
ends at the exact original baseline. This test is also what caught a real
bug: an early version of that corroboration check matched `^...$` against
raw multi-line `pip list` output without splitting on `\r\n` first,
so the trailing `\r` before each `$` silently broke the exact-line match
and caused an incorrect fail-closed - fixed by splitting into lines first
(matching the pattern `Get-InstalledTorchTrio` already used).

## Precheck rejection (non-Blackwell hardware) / public-path simulation isolation

Covered by running the real public tester (no simulation anything) on
this machine (a real RTX 3060 Laptop GPU, compute capability 8.6): it
must detect `PRECHECK_PASS_NON_BLACKWELL` and exit 0 without touching any
package - and passing `-SimulateBlackwell` to it is confirmed to be an
inert no-op (the flag isn't declared, so PowerShell's `-File` argument
binding just drops it into an unused `$args`; there is no
`$SimulatedTarget`-setting code path in the public script at all).

## Real STEMwerk separation smoke test (post-cu128-install validation)

`make_test_audio.py` generates a short synthetic stereo WAV.
`Run-RealSeparationSmoke.ps1` runs the REAL production separation backend
(`..\..\..\scripts\reaper\audio_separator_process.py` - the exact script
REAPER's Lua actions invoke) against it through the harness's own
`Invoke-NativeProcess` helper, so captured logs are never corrupted by
Windows PowerShell 5.1's raw-redirection stderr-to-ErrorRecord bug.

Usage (after installing the experimental runtime via
`STEMwerk-RTX50-cu128-test-SIMULATED.ps1 -SimulateBlackwell` with the ack
env var set):

```
powershell -File Run-RealSeparationSmoke.ps1 -Model htdemucs_ft -Device auto -InputWav <wav> -OutputDir <dir>
```

Checks exit code 0 and that stem WAV files were actually produced - not
just that the UI/CLI reported progress. Output is generated under
`smoke_run\` at runtime and is git-ignored (large binary WAV output; not
meant to be committed).
