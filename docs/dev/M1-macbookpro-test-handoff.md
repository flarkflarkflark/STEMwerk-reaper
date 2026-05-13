# STEMwerk M1 MacBook Pro Test Handoff

This handoff is for testing STEMwerk for REAPER on an Apple Silicon MacBook Pro M1. It uses the current source-tree setup flow, not a release installer.

## 1. Wat we willen testen

- macOS setup/bootstrap from `STEMwerk-SETUP.lua`.
- Apple Silicon host/runtime diagnostics in the macOS bootstrap log.
- Native arm64 Python selection for the STEMwerk runtime; x86_64/Rosetta Python on M1 should be treated as a test failure to report.
- Backend dependency install into STEMwerk's managed virtual environment.
- MPS/GPU/CPU diagnostics and fallback reporting.
- First real separation from REAPER into new stem tracks.
- Support bundle/log collection after success or failure.
- Safe cleanup of only STEMwerk test/runtime files.

Current-branch note: the macOS bootstrap logs host and Python architecture, pins separate Apple Silicon vs Intel torch stacks, and probes MPS. The separate `copilot/fix-macos-setup-apple-silicon` branch contains explicit Rosetta/Python architecture hardening commits; if this branch accepts an x86_64 Python on an M1, report it with logs.

## 2. Voorwaarden

- Apple Silicon M1 MacBook Pro.
- REAPER is already installed.
- Internet connection for Python packages/model downloads.
- Terminal access.
- Several GB of free disk space for the runtime, packages, model cache, and temporary stems.
- A short test audio file, preferably WAV/AIFF/MP3.
- Use an empty test project, not a production REAPER project.

Homebrew is not required just to start setup. The current bootstrap can use Homebrew to install `ffmpeg` if `brew` already exists, but it does not install Homebrew itself. Python 3.10, 3.11, or 3.12 is required; Python 3.13+ is intentionally rejected by setup.

Run these checks in Terminal before opening REAPER:

```sh
uname -m
sysctl -n hw.optional.arm64
arch
which python3
python3 --version
python3 -c 'import platform,sys; print(platform.machine()); print(sys.executable)'
```

Expected on M1:

- `uname -m` should be `arm64`.
- `sysctl -n hw.optional.arm64` should print `1`.
- `arch` should normally be `arm64`.
- `python3` should preferably report `arm64` from `platform.machine()`, not `x86_64`.
- Do not run REAPER itself under Rosetta for this test.

## 3. Installatie / script plaatsen in REAPER

Confirmed REAPER resource path on macOS:

```text
~/Library/Application Support/REAPER/
```

Confirmed STEMwerk scripts path on macOS:

```text
~/Library/Application Support/REAPER/Scripts/STEMwerk-reaper/
```

Use this manual test route from Terminal:

```sh
REPO_OR_EXTRACTED_FOLDER="/path/to/STEMwerk"
REAPER_STEMWERK_DIR="$HOME/Library/Application Support/REAPER/Scripts/STEMwerk-reaper"

mkdir -p "$REAPER_STEMWERK_DIR"
rsync -a --delete \
  --exclude='__pycache__/' \
  --exclude='*.pyc' \
  --exclude='*.pyo' \
  --exclude='*.bak' \
  --exclude='*.bak2' \
  --exclude='.DS_Store' \
  --exclude='sync_to_reaper.sh' \
  --exclude='STEMwerk_Enable_Debug.lua' \
  --exclude='STEMwerk_Disable_Debug.lua' \
  --exclude='STEMwerk_Set_FFmpegPath.lua' \
  --exclude='STEMwerk_Set_PythonPath.lua' \
  --exclude='STEMwerk_separate.lua' \
  --exclude='vendor/stemwerk-core/build/' \
  "$REPO_OR_EXTRACTED_FOLDER/scripts/reaper/" \
  "$REAPER_STEMWERK_DIR/"

rsync -a --delete \
  --exclude='__pycache__/' \
  --exclude='*.pyc' \
  --exclude='*.pyo' \
  --exclude='.DS_Store' \
  "$REPO_OR_EXTRACTED_FOLDER/i18n/" \
  "$REAPER_STEMWERK_DIR/i18n/"
```

Alternative if you have a full repo checkout:

```sh
cd "$REPO_OR_EXTRACTED_FOLDER"
bash scripts/reaper/sync_to_reaper.sh
```

The relevant actions/scripts for this test are:

- `STEMwerk-SETUP.lua` / `STEMwerk: Setup`
- `STEMwerk.lua` / `STEMwerk: Main`
- `STEMwerk_Save_Support_Bundle.lua`

`STEMwerk_First_Run_Setup.lua` and `STEMwerk_Repair_Install.lua` are not present in the current branch; use `STEMwerk-SETUP.lua`.

## 4. Eerste setup in REAPER

1. Start REAPER.
2. Open `Actions > Show action list...`.
3. If the actions are not visible yet, use `New action... > Load ReaScript...` and load:
   - `~/Library/Application Support/REAPER/Scripts/STEMwerk-reaper/STEMwerk-SETUP.lua`
   - `~/Library/Application Support/REAPER/Scripts/STEMwerk-reaper/STEMwerk.lua`
   - `~/Library/Application Support/REAPER/Scripts/STEMwerk-reaper/STEMwerk_Save_Support_Bundle.lua`
4. Run `STEMwerk-SETUP.lua` first.
5. On a first install, let setup run the bootstrap.
6. If a runtime already exists, the setup menu can show:
   - `Check only` - fast file/path check, no reinstall.
   - `Repair` - rerun setup and keep downloaded models.
   - `Rebuild venv` - recreate the Python environment and keep downloaded models.
   - `Save Support Bundle` - collect diagnostics without changing runtime files.
   - `Delete models...` / `Delete runtime...` - destructive cleanup actions; do not use until after testing unless setup is stuck.
7. After setup completes, run `STEMwerk.lua` from the Action List.

Main runtime paths confirmed by the current scripts:

```text
~/Library/Application Support/STEMwerk/.venv/
~/Library/Application Support/STEMwerk/models/
~/Library/Application Support/STEMwerk/state/bootstrap.env
~/Library/Application Support/STEMwerk/state/capabilities.env
~/Library/Application Support/STEMwerk/logs/bootstrap.log
```

## 5. Smoke test matrix

### Test A - Setup check only

Steps:

- Run `STEMwerk-SETUP.lua`.
- If the setup menu appears, choose `Check only`.

Expected:

- No crash.
- Setup reports useful Python/FFmpeg/runtime status.
- `bootstrap.log` or the support bundle shows Apple Silicon/macOS and Python architecture diagnostics.
- x86_64/Rosetta Python on M1 is not acceptable for final confidence; report it if observed.

### Test B - Repair/Rebuild venv

Steps:

- Run `STEMwerk-SETUP.lua`.
- Choose `Repair`.
- If dependency state looks stale or broken, rerun and choose `Rebuild venv`.

Expected:

- The venv is created or repaired under `~/Library/Application Support/STEMwerk/.venv/`.
- `torch`, `torchvision`, `torchaudio`, `audio-separator`, `onnxruntime`, and `stemwerk-core` install or verify.
- Missing Python, unsupported Python, missing FFmpeg, or dependency failures produce a clear setup message.
- Downloaded models are kept during `Repair` and `Rebuild venv`.

### Test C - Single item separation

Steps:

- Create a new empty REAPER project.
- Import a short audio file.
- Select the item.
- Run `STEMwerk.lua`.
- Choose `Vocals` or a 4-stem model.
- Use `New Tracks` with `Folder` enabled.
- Start processing.

Expected:

- Processing starts normally.
- Stem output is imported back into REAPER.
- No Python/backend crash.
- No unexpected project or media-file changes outside the test project.

### Test D - MPS/GPU diagnostics

Expected:

- Runtime diagnostics show whether MPS is built/available.
- Current Auto behavior may choose CPU on Apple Silicon for safety; explicit MPS availability should still be visible in diagnostics if torch exposes it.
- No Rosetta/x86_64 Python should be used for final confidence.
- If MPS fails or falls back, the support bundle should include enough diagnostics to see why.

### Test E - Cancel

Steps:

- Start a longer separation job.
- Cancel while processing is active.

Expected:

- Workers stop or the run exits without crashing REAPER.
- REAPER remains usable.
- The UI should not report a false full success for killed jobs.
- Partial logs remain readable.

### Test F - Support bundle

Steps:

- Run `STEMwerk_Save_Support_Bundle.lua`, or choose `Save Support Bundle` from setup if available.

Expected:

- A support bundle folder is created under:

```text
~/Library/Application Support/REAPER/STEMwerk-support-bundles/
```

- It contains diagnostics, runtime state, runtime logs, recent text logs, platform details, and Python diagnostics.
- It intentionally excludes audio/media files, model payloads, project media, and large binary temp artifacts.

## 6. Wat hij moet terugsturen

Terminal output:

```sh
uname -m
arch
sysctl -n hw.optional.arm64
which python3
python3 --version
python3 -c 'import platform,sys; print(platform.machine()); print(sys.executable)'
```

REAPER/STEMwerk results:

- Screenshot of the setup result.
- Screenshot of the STEMwerk main window.
- Short note for each smoke test: passed, failed, or skipped.
- Exact error message if anything fails.
- The created support bundle folder/zip.
- Any relevant logs if a support bundle could not be created.

Likely locations:

```text
~/Library/Application Support/REAPER/STEMwerk-support-bundles/
~/Library/Application Support/STEMwerk/logs/bootstrap.log
~/Library/Application Support/STEMwerk/state/bootstrap.env
~/Library/Application Support/STEMwerk/state/capabilities.env
~/.cache/STEMwerk/logs/
${TMPDIR:-/tmp}/STEMwerk_debug.log
```

## 7. Cleanup na test

Do not delete the general REAPER folder and do not delete project/audio folders.

Soft cleanup - logs and support bundles only:

```sh
rm -rf "$HOME/Library/Application Support/REAPER/STEMwerk-support-bundles"
rm -rf "$HOME/.cache/STEMwerk/logs"
rm -f "${TMPDIR:-/tmp}/STEMwerk_debug.log"
```

Full STEMwerk cleanup - scripts plus managed runtime/cache:

```sh
rm -rf "$HOME/Library/Application Support/REAPER/Scripts/STEMwerk-reaper"
rm -rf "$HOME/Library/Application Support/STEMwerk"
rm -rf "$HOME/.cache/STEMwerk"
```

The current macOS scripts do not use `/Users/Shared/STEMwerk`. Only remove that path if you created it manually for this test.

## 8. Troubleshooting

- Rosetta/x86_64 Python detected: make sure REAPER is not running under Rosetta, install/use native arm64 Python 3.10-3.12, preferably from `/opt/homebrew/bin/python3.12` or a native python.org build, then rerun `STEMwerk-SETUP.lua`.
- `python3` ontbreekt or unsupported Python: install Python 3.11 or 3.12, then run setup again.
- Venv build fails: run `Repair`; if still broken, run `Rebuild venv`; then send `bootstrap.log` and a support bundle.
- `torch`/MPS unavailable: Auto may use CPU on Apple Silicon by design. Send the support bundle so `torch_mps_built`, `torch_mps_available`, selected backend, and package versions can be checked.
- FFmpeg missing: install FFmpeg or install Homebrew and run `brew install ffmpeg`; setup can use Homebrew if it already exists.
- macOS quarantine/permissions: if copied files are blocked, run `xattr -dr com.apple.quarantine "$REAPER_STEMWERK_DIR"` only on the STEMwerk test script folder.
- REAPER action not visible: manually load `STEMwerk-SETUP.lua`, `STEMwerk.lua`, and `STEMwerk_Save_Support_Bundle.lua` from the Action List.
- Support bundle location unknown: run `STEMwerk_Save_Support_Bundle.lua`; default output is under `~/Library/Application Support/REAPER/STEMwerk-support-bundles/`.

## 9. Message template voor tester

Hey, wil je STEMwerk even testen op je M1 MacBook Pro?

Gebruik een leeg REAPER testproject en een korte audiofile. Kopieer eerst de testfolder naar `~/Library/Application Support/REAPER/Scripts/STEMwerk-reaper/`, run daarna in REAPER `STEMwerk-SETUP.lua`, en daarna `STEMwerk.lua`.

Belangrijkste checks:

1. Terminal vooraf: `uname -m`, `arch`, `sysctl -n hw.optional.arm64`, `which python3`, `python3 --version`, en `python3 -c 'import platform,sys; print(platform.machine()); print(sys.executable)'`.
2. Setup: `Check only`, daarna zo nodig `Repair` of `Rebuild venv`.
3. Smoke: één korte audio-item scheiden naar `Vocals`, `New Tracks`, `Folder ON`.
4. Cancel-test: start een langere job en cancel.
5. Run `STEMwerk_Save_Support_Bundle.lua` en stuur de bundle terug met screenshots van setup/main window en een korte pass/fail per test.

Als Python of REAPER onder `x86_64`/Rosetta draait op je M1, stop niet te lang met debuggen: stuur vooral de logs en support bundle terug.
