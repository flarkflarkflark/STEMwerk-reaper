from __future__ import annotations

import hashlib
import importlib.util
import json
import shutil
import subprocess
import sys
from pathlib import Path

import pytest
import yaml


ASSET = Path("tools/assets/drumsep/config_drumsep_mdx23c.yaml")
CONTRACT = Path("tools/assets/drumsep/compatibility_config_contract.json")
MAC_BUILDER = Path("tools/build_macos_apple_silicon_payload.py")
WINDOWS_BUILDER = Path("tools/build_windows_drumsep_payload.py")
WINDOWS_BOOTSTRAP = Path("scripts/reaper/STEMwerk_Bootstrap_Windows.ps1")
CANONICAL_SHA = "b7165bb73a0b08df49ac4ed5fe7424e29bf2f707b5878300f729a7e92671257a"
LEGACY_SHA = "17d1649a227f841165bdb4c11a42082898192a1ea3ceab7e7e0b9293d6589dd6"


def load_module(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def ps_function(script: str, name: str) -> str:
    marker = f"function {name}"
    start = script.index(marker)
    brace = script.index("{", start)
    depth = 0
    for pos in range(brace, len(script)):
        if script[pos] == "{":
            depth += 1
        elif script[pos] == "}":
            depth -= 1
            if depth == 0:
                return script[start : pos + 1]
    raise AssertionError(f"unterminated PowerShell function: {name}")


def run_materializer(
    tmp_path: Path,
    source_bytes: bytes | None,
    destination_bytes: bytes | None,
    *,
    lock_destination: bool = False,
    tamper_temp_hash: bool = False,
) -> tuple[subprocess.CompletedProcess[str], bytes | None, list[Path]]:
    shell = shutil.which("pwsh") or shutil.which("powershell")
    if not shell:
        pytest.skip("PowerShell is unavailable")
    source = tmp_path / "payload" / ASSET.name
    destination = tmp_path / "models" / ASSET.name
    source.parent.mkdir(parents=True)
    destination.parent.mkdir(parents=True)
    if source_bytes is not None:
        source.write_bytes(source_bytes)
    if destination_bytes is not None:
        destination.write_bytes(destination_bytes)

    script = WINDOWS_BOOTSTRAP.read_text(encoding="utf-8")
    functions = "\n\n".join(
        ps_function(script, name)
        for name in ("GetSha256Lower", "SetDrumsepCompatYamlResult", "MaterializeDrumsepCompatYaml")
    )
    override = ""
    if tamper_temp_hash:
        override = r'''
function GetSha256Lower([string]$Path) {
    if ([IO.Path]::GetFileName($Path) -like ".*.tmp-*") { return ("0" * 64) }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
'''
    harness = tmp_path / "materialize.ps1"
    harness.write_text(
        f'''param([string]$SourcePath, [string]$DestinationPath, [switch]$LockDestination)
$ErrorActionPreference = "Stop"
$drumsepCompatYamlExpectedSize = 2331
$drumsepCompatYamlExpectedSha256 = "{CANONICAL_SHA}"
$drumsepCompatYamlLegacyCrlfSize = 2417
$drumsepCompatYamlLegacyCrlfSha256 = "{LEGACY_SHA}"
$script:DrumsepCompatYamlStatus = ""
$script:DrumsepCompatYamlReason = ""
$script:DrumsepCompatYamlPreviousSha256 = ""
$script:DrumsepCompatYamlSha256 = ""
function LogLine([string]$Message) {{ Write-Host $Message }}
{functions}
{override}
$lock = $null
try {{
    if ($LockDestination) {{
        $lock = [IO.File]::Open($DestinationPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    }}
    $ok = MaterializeDrumsepCompatYaml $SourcePath $DestinationPath
}} finally {{
    if ($lock) {{ $lock.Dispose() }}
}}
Write-Output "RESULT=$ok"
if (-not $ok) {{ exit 1 }}
''',
        encoding="utf-8",
    )
    command = [
        shell,
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(harness),
        "-SourcePath",
        str(source),
        "-DestinationPath",
        str(destination),
    ]
    if lock_destination:
        command.append("-LockDestination")
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    final = destination.read_bytes() if destination.exists() else None
    temps = list(destination.parent.glob(f".{destination.name}.tmp-*"))
    temps += list(destination.parent.glob(f".{destination.name}.bak-*"))
    return result, final, temps


def test_shared_asset_and_cross_platform_contract(tmp_path):
    contract = json.loads(CONTRACT.read_text(encoding="utf-8"))
    canonical = ASSET.read_bytes()
    assert contract["filename"] == ASSET.name
    assert contract["role"] == "compatibility_config"
    assert len(canonical) == contract["canonical"]["size"] == 2331
    assert hashlib.sha256(canonical).hexdigest() == contract["canonical"]["sha256"] == CANONICAL_SHA
    assert canonical.count(b"\n") == contract["canonical"]["lf_count"] == 86
    assert canonical.count(b"\r") == contract["canonical"]["cr_count"] == 0
    assert tuple(yaml.load(canonical, Loader=yaml.FullLoader)["training"]["instruments"]) == tuple(contract["canonical"]["instruments"])
    legacy = canonical.replace(b"\n", b"\r\n")
    assert len(legacy) == contract["legacy_crlf"]["size"] == 2417
    assert hashlib.sha256(legacy).hexdigest() == contract["legacy_crlf"]["sha256"] == LEGACY_SHA
    assert contract["legacy_crlf"]["status"] == "supported_migration_source"
    assert not Path("tools/assets/macos/drumsep/config_drumsep_mdx23c.yaml").exists()
    assert list(Path("tools/assets").rglob(ASSET.name)) == [ASSET]

    blob = subprocess.run(
        ["git", "cat-file", "blob", f"HEAD:{ASSET.as_posix()}"], capture_output=True, check=False
    )
    # Before commit the exact staged move is authoritative; after commit HEAD is authoritative.
    if blob.returncode == 0:
        assert blob.stdout == canonical
    attributes = Path(".gitattributes").read_text(encoding="utf-8")
    assert f"{ASSET.as_posix()} text eol=lf whitespace=-blank-at-eol" in attributes

    source_repo = tmp_path / "source"
    source_repo.mkdir()
    shutil.copy2(".gitattributes", source_repo / ".gitattributes")
    checkout_asset = source_repo / ASSET
    checkout_asset.parent.mkdir(parents=True)
    checkout_asset.write_bytes(canonical)
    subprocess.run(["git", "init", "-q"], cwd=source_repo, check=True)
    subprocess.run(["git", "add", "."], cwd=source_repo, check=True)
    subprocess.run(
        ["git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "fixture"],
        cwd=source_repo,
        check=True,
    )
    for autocrlf in ("true", "false"):
        checkout = tmp_path / f"checkout-{autocrlf}"
        subprocess.run(
            ["git", "-c", f"core.autocrlf={autocrlf}", "clone", "-q", str(source_repo), str(checkout)],
            check=True,
        )
        assert (checkout / ASSET).read_bytes() == canonical

    mac = load_module(MAC_BUILDER, "mac_compat_contract")
    windows = load_module(WINDOWS_BUILDER, "windows_compat_contract")
    assert mac.DRUMSEP_COMPAT_ASSET == ASSET
    assert windows.DRUMSEP_COMPAT_ASSET.resolve() == ASSET.resolve()
    assert mac.DRUMSEP_COMPAT_CONTRACT == windows.DRUMSEP_COMPAT_CONTRACT == contract
    print("DRUMSEP_COMPAT_SHARED_ASSET_TEST=PASS")
    print("DRUMSEP_COMPAT_CROSS_PLATFORM_CONTRACT_TEST=PASS")


def test_windows_payload_inventory_contract_is_closed_and_manifested():
    builder = load_module(WINDOWS_BUILDER, "windows_payload_contract")
    assert set(builder.DRUMSEP_MODEL_POLICY) == {
        "aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.ckpt",
        "aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.yaml",
        ASSET.name,
    }
    compat = builder.DRUMSEP_MODEL_POLICY[ASSET.name]
    assert compat == {
        "role": "compatibility_config",
        "size": 2331,
        "sha256": CANONICAL_SHA,
        "source": "shared_repository_asset",
    }
    script = WINDOWS_BUILDER.read_text(encoding="utf-8")
    assert "drumsep_inventory_mismatch" in script
    assert "# backend\\tsource_family\\trole\\trelpath\\tsize_bytes\\tsha256" in script
    assert '"directml"' in script and '"cpu"' in script and '"nvidia"' in script
    iss = Path("installer/windows/STEMwerk.iss").read_text(encoding="utf-8")
    assert "tools\\assets\\drumsep\\config_drumsep_mdx23c.yaml" in iss
    release_gate = Path("tools/release_gate.py").read_text(encoding="utf-8")
    assert 'DRUMSEP_COMPAT_ASSET = "tools/assets/drumsep/config_drumsep_mdx23c.yaml"' in release_gate
    print("WINDOWS_DRUMSEP_COMPAT_PAYLOAD_INVENTORY_TEST=PASS")


def test_windows_materializer_created_exists_legacy_and_idempotent(tmp_path):
    canonical = ASSET.read_bytes()
    created, final, temps = run_materializer(tmp_path / "created", canonical, None)
    assert created.returncode == 0, created.stderr or created.stdout
    assert "DRUMSEP_COMPAT_YAML_STATUS=created" in created.stdout
    assert final == canonical and not temps

    existing, final, temps = run_materializer(tmp_path / "existing", canonical, canonical)
    assert existing.returncode == 0
    assert "DRUMSEP_COMPAT_YAML_STATUS=exists_valid" in existing.stdout
    assert final == canonical and not temps

    legacy = canonical.replace(b"\n", b"\r\n")
    migrated, final, temps = run_materializer(tmp_path / "legacy", canonical, legacy)
    assert migrated.returncode == 0, migrated.stderr or migrated.stdout
    assert "DRUMSEP_COMPAT_YAML_STATUS=migrated_legacy_crlf" in migrated.stdout
    assert "DRUMSEP_COMPAT_YAML_REASON=migrated_known_legacy_crlf" in migrated.stdout
    assert f"DRUMSEP_COMPAT_YAML_PREVIOUS_SHA256={LEGACY_SHA}" in migrated.stdout
    assert f"DRUMSEP_COMPAT_YAML_SHA256={CANONICAL_SHA}" in migrated.stdout
    assert final == canonical and not temps
    print("WINDOWS_DRUMSEP_COMPAT_MATERIALIZATION_TEST=PASS")


@pytest.mark.parametrize("source", [None, b"damaged payload\n"])
def test_windows_materializer_rejects_missing_or_damaged_source_before_target_mutation(tmp_path, source):
    original = b"unknown existing bytes\n"
    result, final, temps = run_materializer(tmp_path, source, original)
    assert result.returncode == 1
    assert final == original and not temps
    assert "payload_source_" in result.stdout


def test_windows_materializer_rejects_unknown_target_and_cleans_failure_temp(tmp_path):
    canonical = ASSET.read_bytes()
    unknown = b"unknown existing bytes\n"
    result, final, temps = run_materializer(tmp_path / "unknown", canonical, unknown)
    assert result.returncode == 1
    assert "DRUMSEP_COMPAT_YAML_REASON=existing_checksum_mismatch" in result.stdout
    assert final == unknown and not temps

    mismatch, final, temps = run_materializer(
        tmp_path / "post-copy", canonical, None, tamper_temp_hash=True
    )
    assert mismatch.returncode == 1
    assert "DRUMSEP_COMPAT_YAML_REASON=temporary_checksum_mismatch" in mismatch.stdout
    assert final is None and not temps


def test_windows_materializer_atomic_replace_failure_preserves_legacy(tmp_path):
    canonical = ASSET.read_bytes()
    legacy = canonical.replace(b"\n", b"\r\n")
    result, final, temps = run_materializer(
        tmp_path, canonical, legacy, lock_destination=True
    )
    assert result.returncode == 1
    assert "DRUMSEP_COMPAT_YAML_REASON=atomic_materialization_failed" in result.stdout
    assert final == legacy and not temps


def test_windows_bundled_copy_preserves_identical_checkpoint_and_yaml(tmp_path):
    shell = shutil.which("pwsh") or shutil.which("powershell")
    if not shell:
        pytest.skip("PowerShell is unavailable")
    source = tmp_path / "bundled"
    destination = tmp_path / "models"
    source.mkdir()
    destination.mkdir()
    names = ("model.ckpt", "model.yaml")
    for index, name in enumerate(names):
        (source / name).write_bytes(f"payload-{index}".encode())
        (destination / name).write_bytes(f"payload-{index}".encode())
    before = {name: (destination / name).stat().st_mtime_ns for name in names}
    function = ps_function(WINDOWS_BOOTSTRAP.read_text(encoding="utf-8"), "CopyBundledDrumsepAssets")
    harness = tmp_path / "copy.ps1"
    harness.write_text(
        f'''param([string]$ModelDir, [string]$BundledDir)
$ErrorActionPreference = "Stop"
$bundledDrumsepModelsDir = $BundledDir
$drumsepModelFileName = "{names[0]}"
$drumsepModelYamlName = "{names[1]}"
$script:DrumsepRuntimeWheelSource = ""
function TestBundledDrumsepModelsAvailable {{ return $true }}
function SetDrumsepOfflinePayloadState {{ }}
function LogLine {{ }}
function LogProgress {{ }}
function GetSha256Lower([string]$Path) {{ return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }}
{function}
if (-not (CopyBundledDrumsepAssets $ModelDir)) {{ exit 1 }}
''',
        encoding="utf-8",
    )
    result = subprocess.run(
        [
            shell,
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(harness),
            "-ModelDir",
            str(destination),
            "-BundledDir",
            str(source),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr or result.stdout
    assert {name: (destination / name).stat().st_mtime_ns for name in names} == before


def test_windows_setup_guard_and_no_network_contract():
    bootstrap = WINDOWS_BOOTSTRAP.read_text(encoding="utf-8")
    ensure = ps_function(bootstrap, "EnsureDrumsepAssets")
    materialize_call = "MaterializeDrumsepCompatYaml $compatSource $compatDestination"
    assert ensure.index(materialize_call) < ensure.index("$offlineBundledAllmodelsMode")
    assert "Invoke-WebRequest" not in ps_function(bootstrap, "MaterializeDrumsepCompatYaml")
    assert "DownloadFileWithRetry" not in ps_function(bootstrap, "MaterializeDrumsepCompatYaml")
    assert "curl" not in ps_function(bootstrap, "MaterializeDrumsepCompatYaml").lower()
    directml = ps_function(bootstrap, "InstallDrumsepDirectmlRuntime")
    assert directml.index("EnsureDrumsepAssets $modelDir") < directml.index("rebuilding runtime")
    assert 'if ($existingVerifyResult -eq "ok")' in directml
    bundled_copy = ps_function(bootstrap, "CopyBundledDrumsepAssets")
    assert "Bundled DrumSep asset already matches:" in bundled_copy
    assert bundled_copy.index("(GetSha256Lower $src) -eq (GetSha256Lower $dest)") < bundled_copy.index(
        "Copy-Item -Path $src -Destination $dest -Force"
    )
    runtime_guard = Path("scripts/reaper/_internal/stemwerk_drumsep_process.py").read_text(encoding="utf-8")
    assert CANONICAL_SHA in runtime_guard
    assert LEGACY_SHA not in runtime_guard
    assert "config_drumsep_mdx23c.yaml" in runtime_guard
    assert "MDX23C-DrumSep-aufr33-jarredou.ckpt" in Path("scripts/reaper/models.json").read_text(encoding="utf-8")
    print("WINDOWS_DRUMSEP_COMPAT_SETUP_CONVERGENCE_TEST=PASS")
    print("WINDOWS_DRUMSEP_COMPAT_RUNTIME_GUARD_TEST=PASS")
    print("WINDOWS_DRUMSEP_COMPAT_NO_NETWORK_TEST=PASS")
